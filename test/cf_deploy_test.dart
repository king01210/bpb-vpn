import 'dart:convert';

import 'package:bpb/models/settings.dart';
import 'package:bpb/services/cloudflare_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const token = 'cfut_Ab12Cd34Ef56Gh78Ij90Kl12Mn34Op56Qr78St90Uv12Wx34a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6';
const acc = '0123456789abcdef0123456789abcdef';

http.Response ok(Object? result) => http.Response(jsonEncode({'success': true, 'errors': [], 'result': result}), 200);

http.Response notFound() =>
    http.Response(jsonEncode({'success': false, 'errors': [{'code': 10007, 'message': 'not found'}]}), 404);

String call(http.BaseRequest req) => '${req.method} ${req.url.path.replaceFirst('/client/v4', '')}';

/// The JSON "metadata" part of a multipart script upload.
Map<String, dynamic> uploadMetadata(http.Request req) {
  final body = req.body;
  final start = body.indexOf('{"main_module"');
  final end = body.indexOf('\r\n--', start);
  return jsonDecode(body.substring(start, end)) as Map<String, dynamic>;
}

Map<String, dynamic> decodeEnv(String env) => jsonDecode(utf8.decode(base64.decode(env))) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('user email comes from /user, empty when not permitted', () async {
    final client = MockClient((req) async {
      expect(req.url.path, '/client/v4/user');
      return ok({'id': 'x', 'email': 'me@example.com'});
    });
    expect(await CloudflareApi(token, client: client).userEmail(), 'me@example.com');

    final denied = MockClient(
      (_) async => http.Response(
        '{"success":false,"errors":[{"code":9109,"message":"Unauthorized to access requested resource"}]}',
        403,
      ),
    );
    expect(await CloudflareApi(token, client: denied).userEmail(), '');
  });

  test('ENV is base64 JSON with the UUID, proxy IPs and fallback website', () {
    final env = CloudflareApi.encodeEnv(uuid: 'u-1', proxyIps: ['p.example.com', '1.2.3.4:443'], fallbackUrl: '');
    expect(decodeEnv(env), {
      'v': 1,
      'id': 'u-1',
      'pips': ['p.example.com', '1.2.3.4:443'],
      'fb': '',
    });
  });

  test('a free name: 8–18 characters, retried while taken', () async {
    final asked = <String>[];
    final client = MockClient((req) async {
      final name = req.url.pathSegments.reversed.skip(1).first; // …/scripts/<name>/settings
      asked.add(name);
      return asked.length == 1 ? ok({}) : notFound(); // The first one exists.
    });
    final name = await CloudflareApi(token, client: client).freeName(acc, WorkerType.workers);
    expect(asked, hasLength(2));
    expect(name, asked.last);
    expect(name, matches(RegExp(r'^[a-z0-9]{8,18}$')));
  });

  test('a new Workers subdomain is a 10-character alphanumeric label', () async {
    String? requested;
    final client = MockClient((req) async {
      if (req.method == 'GET') return notFound();
      requested = (jsonDecode(req.body) as Map<String, dynamic>)['subdomain'] as String;
      return ok({'subdomain': requested});
    });

    await CloudflareApi(token, client: client).ensureSubdomain(acc);

    expect(requested, matches(RegExp(r'^[a-z0-9][a-z0-9]{9}$')));
  });

  test('Workers: one plain-text ENV binding, then the workers.dev route', () async {
    final calls = <String>[];
    late Map<String, dynamic> metadata;
    final client = MockClient((req) async {
      calls.add(call(req));
      if (req.url.path.endsWith('/workers/subdomain')) return ok({'subdomain': 'me'});
      if (req.method == 'PUT' && req.url.path.contains('/workers/scripts/')) metadata = uploadMetadata(req);
      return ok(null);
    });
    final env = CloudflareApi.encodeEnv(uuid: 'u-1', proxyIps: const [], fallbackUrl: 'https://example.com');

    final dateBeforeDeploy = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final host = await CloudflareApi(token, client: client).deployWorker(acc, 'wk', env);
    final dateAfterDeploy = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    expect(host, 'wk.me.workers.dev');
    expect([dateBeforeDeploy, dateAfterDeploy], contains(metadata['compatibility_date']));
    expect(metadata['bindings'], [
      {'type': 'plain_text', 'name': 'ENV', 'text': env},
    ]);
    expect(metadata.containsKey('keep_bindings'), isFalse); // A full deployment.
    expect(calls, [
      'GET /accounts/$acc/workers/subdomain',
      'PUT /accounts/$acc/workers/scripts/wk',
      'POST /accounts/$acc/workers/scripts/wk/subdomain',
    ]);
  });

  test('Pages: create with ENV (or set it), then deploy; the host comes from Cloudflare', () async {
    final calls = <String>[];
    final bodies = <String, dynamic>{};
    final client = MockClient((req) async {
      calls.add(call(req));
      if (req.method != 'POST' || !req.url.path.endsWith('/deployments')) bodies[call(req)] = jsonDecode(req.body);
      return ok({'subdomain': 'pg-x1.pages.dev'});
    });
    final api = CloudflareApi(token, client: client);
    final env = CloudflareApi.encodeEnv(uuid: 'u-1', proxyIps: const [], fallbackUrl: '');
    final envVars = {
      'ENV': {'type': 'plain_text', 'value': env},
    };

    final createDateBeforeDeploy = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    expect(await api.deployPages(acc, 'pg', env, create: true), 'pg-x1.pages.dev');
    final createDateAfterDeploy = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final created = bodies['POST /accounts/$acc/pages/projects'] as Map;
    expect(created['name'], 'pg');
    final createdProduction = created['deployment_configs']['production'] as Map;
    expect([createDateBeforeDeploy, createDateAfterDeploy], contains(createdProduction['compatibility_date']));
    expect(createdProduction['env_vars'], envVars);

    final updateDateBeforeDeploy = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    expect(await api.deployPages(acc, 'pg', env, create: false), 'pg-x1.pages.dev');
    final updateDateAfterDeploy = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final updated = bodies['PATCH /accounts/$acc/pages/projects/pg'] as Map;
    final updateProduction = updated['deployment_configs']['production'] as Map;
    expect([updateDateBeforeDeploy, updateDateAfterDeploy], contains(updateProduction['compatibility_date']));
    expect(updateProduction['env_vars'], envVars);
    expect(calls.where((c) => c == 'POST /accounts/$acc/pages/projects/pg/deployments'), hasLength(2));
  });

  group('deleting a deployment', () {
    test('Pages: custom domains and their CNAME records first, then the project', () async {
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add('${call(req)}${req.url.query.isEmpty ? '' : '?${req.url.query}'}');
        final path = req.url.path.replaceFirst('/client/v4', '');
        if (path.endsWith('/pages/projects/pg/domains') && req.method == 'GET') {
          return ok([
            {'name': 'pg-x1.pages.dev'},
            {'name': 'vpn.example.com'},
          ]);
        }
        if (path == '/zones') return ok([{'id': 'z1'}]);
        if (path == '/zones/z1/dns_records') {
          return ok([
            {'id': 'r1', 'content': 'pg-x1.pages.dev'},
            {'id': 'r2', 'content': 'other.example.net'},
          ]);
        }
        return ok(null);
      });
      await CloudflareApi(token, client: client).deleteDeployment(
        const ActiveWorker(accountId: acc, name: 'pg', type: WorkerType.pages, host: 'pg-x1.pages.dev'),
      );
      expect(calls, contains('DELETE /accounts/$acc/pages/projects/pg/domains/vpn.example.com'));
      expect(calls, contains('DELETE /zones/z1/dns_records/r1')); // Only the record pointing at it.
      expect(calls, isNot(contains('DELETE /zones/z1/dns_records/r2')));
      expect(calls.where((c) => c.contains('pg-x1.pages.dev') && c.startsWith('DELETE')), isEmpty);
      expect(calls.last, 'DELETE /accounts/$acc/pages/projects/pg');
    });

    test('Workers: custom domains first, then the script (forced); something already gone is skipped', () async {
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add('${call(req)}${req.url.query.isEmpty ? '' : '?${req.url.query}'}');
        if (req.method == 'GET') return ok([{'id': 'd1', 'hostname': 'vpn.example.com'}]);
        if (req.url.path.contains('/workers/scripts/')) {
          return http.Response(
            jsonEncode({'success': false, 'errors': [{'code': 10007, 'message': 'workers.api.error.script_not_found'}]}),
            404,
          );
        }
        return ok(null);
      });
      await CloudflareApi(token, client: client).deleteDeployment(
        const ActiveWorker(accountId: acc, name: 'wk', type: WorkerType.workers, host: 'wk.me.workers.dev'),
      );
      expect(calls, [
        'GET /accounts/$acc/workers/domains?service=wk',
        'DELETE /accounts/$acc/workers/domains/d1',
        'DELETE /accounts/$acc/workers/scripts/wk?force=true',
      ]);
    });
  });
}
