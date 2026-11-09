import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import '../models/settings.dart';

class CloudflareException implements Exception {
  final String message;
  const CloudflareException(this.message);

  @override
  String toString() => message;
}

class CfAccount {
  final String id;
  final String name;
  const CfAccount(this.id, this.name);
}

/// Minimal Cloudflare REST client for deploying the worker (as a Worker or as a Pages project,
/// like BPB-Wizard). Every change is a full deployment: the script with its one ENV binding.
class CloudflareApi {
  static const _base = 'https://api.cloudflare.com/client/v4';
  static const workerAsset = 'worker/worker.min.js';

  /// The bundled worker's version, bumped with every change to worker/worker.js; deployments
  /// older than [minWorkerVersion] are redeployed automatically, the rest offer an update.
  static const workerVersion = 1;
  static const minWorkerVersion = 1;

  /// The worker's only binding (plain text): base64 of a JSON object, see [encodeEnv].
  static const envVar = 'ENV';

  /// ENV's value: `{v, id, pips, fb}` as JSON, base64.
  static String encodeEnv({required String uuid, required List<String> proxyIps, required String fallbackUrl}) =>
      base64.encode(
        utf8.encode(jsonEncode({'v': 1, 'id': uuid, 'pips': proxyIps, 'fb': fallbackUrl})),
      );

  /// Token creation page with the permissions pre-selected (same set as BPB-Wizard).
  static String tokenCreationUrl() {
    final permissions = jsonEncode([
      {'key': 'workers_scripts', 'type': 'edit'},
      {'key': 'page', 'type': 'edit'},
      {'key': 'dns', 'type': 'edit'},
      {'key': 'user_details', 'type': 'read'},
    ]);
    return Uri.https('dash.cloudflare.com', '/profile/api-tokens', {
      'permissionGroupKeys': permissions,
      'accountId': '*',
      'zoneId': 'all',
      'name': 'BPB-VPN',
    }).toString();
  }

  /// Extracts the API token from pasted text.
  ///
  /// Cloudflare only accepts `[A-Za-z0-9_-]` in a Bearer token (anything else is
  /// error 6003/6111), so every other character is dropped. Long `cfut_` tokens that
  /// were copied across two lines are joined back together, and invisible characters
  /// and quotes disappear. For a pasted `curl ... "Authorization: Bearer <token>"`
  /// command only the part after "Bearer" is used.
  /// Throws for a Global API Key, which can't be used as a Bearer token.
  static String normalizeToken(String input) {
    var text = input;
    final bearer = text.toLowerCase().lastIndexOf('bearer');
    if (bearer >= 0) {
      text = text.substring(bearer + 6).trimLeft();
      final quote = text.indexOf(RegExp('["\']'));
      if (quote > 0) text = text.substring(0, quote);
    }
    final token = text.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    if (token.isEmpty) throw const CloudflareException('Enter your API token');
    if (RegExp(r'^[0-9a-f]{37}$').hasMatch(token)) {
      throw const CloudflareException(
        'This looks like the Global API Key. Create an API token instead (use the button above).',
      );
    }
    if (token.length < 30) {
      throw const CloudflareException("That doesn't look like a Cloudflare API token. Copy the token itself.");
    }
    return token;
  }

  final String token;
  final http.Client _client;

  CloudflareApi(String token, {http.Client? client}) : token = normalizeToken(token), _client = client ?? http.Client();

  void close() => _client.close();

  Map<String, String> get _auth => {'Authorization': 'Bearer $token'};

  Future<dynamic> _send(String method, String path, {Object? json, String? body, String? contentType}) async {
    final request = http.Request(method, Uri.parse('$_base$path'))..headers.addAll(_auth);
    if (json != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(json);
    } else if (body != null) {
      request.headers['Content-Type'] = contentType ?? 'text/plain';
      request.body = body;
    }
    return _decode(await http.Response.fromStream(await _client.send(request).timeout(const Duration(seconds: 30))));
  }

  Future<dynamic> _sendMultipart(String method, String path, void Function(http.MultipartRequest) build) async {
    final request = http.MultipartRequest(method, Uri.parse('$_base$path'))..headers.addAll(_auth);
    build(request);
    return _decode(await http.Response.fromStream(await _client.send(request).timeout(const Duration(seconds: 90))));
  }

  dynamic _decode(http.Response response) {
    Map<String, dynamic>? data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      // Not JSON; handled below.
    }
    if (data != null && data['success'] == true) return data['result'];
    // Some endpoints (e.g. deleting a Workers custom domain) answer 2xx with an empty body.
    if (data == null && response.statusCode >= 200 && response.statusCode < 300) return null;
    String describe(Map e) {
      final chain = (e['error_chain'] as List? ?? const []).whereType<Map>().map(describe).join(', ');
      return '${e['message']}${e['code'] != null ? ' (${e['code']})' : ''}${chain.isNotEmpty ? ': $chain' : ''}';
    }

    final errors = (data?['errors'] as List? ?? const []).whereType<Map>().map(describe).join('; ');
    throw CloudflareException(errors.isNotEmpty ? errors : 'Cloudflare API error ${response.statusCode}');
  }

  /// Email of the token's user (needs User Details: Read), or '' if not available.
  Future<String> userEmail() async {
    try {
      final result = await _send('GET', '/user') as Map;
      return '${result['email'] ?? ''}';
    } on CloudflareException {
      return '';
    }
  }

  Future<List<CfAccount>> accounts() async {
    final result = await _send('GET', '/accounts?per_page=50') as List;
    return result.whereType<Map>().map((a) => CfAccount('${a['id']}', '${a['name']}')).toList();
  }

  // region workers

  /// Returns the account's workers.dev subdomain, registering a random one if it has none yet.
  Future<String> ensureSubdomain(String accountId) async {
    try {
      final result = await _send('GET', '/accounts/$accountId/workers/subdomain') as Map;
      final sub = '${result['subdomain'] ?? ''}';
      if (sub.isNotEmpty) return sub;
    } on CloudflareException catch (e) {
      if (!e.message.contains('10007')) rethrow; // 10007: no subdomain registered
    }
    final name = _randomName(10);
    final result = await _send('PUT', '/accounts/$accountId/workers/subdomain', json: {'subdomain': name}) as Map;
    return '${result['subdomain']}';
  }

  /// Uploads the worker script with its ENV binding (replacing every other binding).
  Future<void> uploadScript(String accountId, String scriptName, String env) async {
    final script = await rootBundle.loadString(workerAsset);
    final metadata = {
      'main_module': 'worker.js',
      'compatibility_date': _currentCompatibilityDate(),
      'bindings': [
        {'type': 'plain_text', 'name': envVar, 'text': env},
      ],
    };
    await _sendMultipart('PUT', '/accounts/$accountId/workers/scripts/$scriptName', (r) {
      r.files
        ..add(
          http.MultipartFile.fromString(
            'metadata',
            jsonEncode(metadata),
            contentType: MediaType('application', 'json'),
          ),
        )
        ..add(
          http.MultipartFile.fromString(
            'worker.js',
            script,
            filename: 'worker.js',
            contentType: MediaType('application', 'javascript+module'),
          ),
        );
    });
  }

  Future<void> enableWorkersDev(String accountId, String scriptName) => _send(
    'POST',
    '/accounts/$accountId/workers/scripts/$scriptName/subdomain',
    json: {'enabled': true, 'previews_enabled': false},
  );

  /// Routes [hostname] to the worker. The hostname's zone must be on the same account.
  ///
  /// Only needs "Workers Scripts: Edit". The zone is passed by name, trying the
  /// hostname's parent domains (longest first), so no zone-read permission is needed.
  Future<void> _attachWorkerDomain(String accountId, String scriptName, String hostname) async {
    CloudflareException? lastError;
    for (final zoneName in _zoneCandidates(hostname)) {
      try {
        await _send(
          'PUT',
          '/accounts/$accountId/workers/domains',
          json: {'hostname': hostname, 'service': scriptName, 'zone_name': zoneName},
        );
        return;
      } on CloudflareException catch (e) {
        if (_isAuthError(e)) rethrow;
        lastError = e;
      }
    }
    throw CloudflareException(
      'Could not attach $hostname: ${lastError?.message ?? 'no matching zone'}. '
      'The domain must be a zone on this Cloudflare account.',
    );
  }

  Future<void> _detachWorkerDomain(String accountId, String scriptName, String hostname) async {
    final domains = await _send(
      'GET',
      '/accounts/$accountId/workers/domains?hostname=${Uri.encodeQueryComponent(hostname)}'
          '&service=${Uri.encodeQueryComponent(scriptName)}',
    ) as List;
    for (final d in domains.whereType<Map>().where((d) => '${d['hostname']}' == hostname)) {
      await _send('DELETE', '/accounts/$accountId/workers/domains/${d['id']}');
    }
  }

  // endregion

  // region pages

  /// Direct-upload deployment of the worker as Pages' `_worker.js`.
  Future<void> uploadPagesDeployment(String accountId, String projectName) async {
    final script = await rootBundle.loadString(workerAsset);
    await _sendMultipart('POST', '/accounts/$accountId/pages/projects/$projectName/deployments', (r) {
      r.fields['manifest'] = '{}';
      r.fields['branch'] = 'main';
      r.files.add(
        http.MultipartFile.fromString(
          '_worker.js',
          script,
          filename: '_worker.js',
          contentType: MediaType('application', 'javascript'),
        ),
      );
    });
  }

  /// Pages custom domain: add it to the project and point a proxied CNAME at its [target]
  /// (*.pages.dev) host.
  Future<void> _attachPagesDomain(String accountId, String projectName, String target, String hostname) async {
    final zoneId = await _zoneIdFor(hostname);
    await _send('POST', '/accounts/$accountId/pages/projects/$projectName/domains', json: {'name': hostname});

    final records = await _send('GET', '/zones/$zoneId/dns_records?name=${Uri.encodeQueryComponent(hostname)}') as List;
    final existing = records.whereType<Map>().toList();
    final record = {'type': 'CNAME', 'name': hostname, 'content': target, 'proxied': true, 'ttl': 1};
    final cname = existing.where((r) => r['type'] == 'CNAME').firstOrNull;
    if (cname != null) {
      await _send('PUT', '/zones/$zoneId/dns_records/${cname['id']}', json: record);
    } else if (existing.any((r) => r['type'] == 'A' || r['type'] == 'AAAA')) {
      throw CloudflareException('$hostname already has an A/AAAA record. Remove it in the Cloudflare dashboard first.');
    } else {
      await _send('POST', '/zones/$zoneId/dns_records', json: record);
    }
  }

  Future<void> _detachPagesDomain(String accountId, String projectName, String target, String hostname) async {
    try {
      await _send('DELETE', '/accounts/$accountId/pages/projects/$projectName/domains/$hostname');
    } on CloudflareException catch (e) {
      if (_isAuthError(e)) rethrow; // Otherwise it was already removed.
    }
    final zoneId = await _zoneIdFor(hostname);
    final records =
        await _send('GET', '/zones/$zoneId/dns_records?type=CNAME&name=${Uri.encodeQueryComponent(hostname)}') as List;
    // Only remove the record we created (pointing at this project).
    for (final r in records.whereType<Map>().where((r) => '${r['content']}' == target)) {
      await _send('DELETE', '/zones/$zoneId/dns_records/${r['id']}');
    }
  }

  Future<String> _zoneIdFor(String hostname) async {
    for (final name in _zoneCandidates(hostname)) {
      final zones = await _send('GET', '/zones?name=${Uri.encodeQueryComponent(name)}') as List;
      if (zones.isNotEmpty) return '${(zones.first as Map)['id']}';
    }
    throw CloudflareException(
      'No Cloudflare zone found for $hostname. '
      'The domain must be on this account and the token needs DNS: Edit.',
    );
  }

  // endregion

  // region usage

  /// Workers requests in the last 24 hours (BPB's GraphQL query): account total and,
  /// when [scriptName] is given, that worker alone. Free plan limit: 100,000 per day.
  Future<({int total, int worker})> workerUsage(String accountId, String scriptName) async {
    final end = DateTime.now().toUtc();
    final start = end.subtract(const Duration(hours: 24));
    final request = http.Request('POST', Uri.parse('$_base/graphql'))
      ..headers.addAll({..._auth, 'Content-Type': 'application/json'})
      ..body = jsonEncode({
        'query': r'''
          query GetUsage($accountTag: String!, $scriptName: String!, $start: String!, $end: String!) {
            viewer {
              accounts(filter: { accountTag: $accountTag }) {
                total: workersInvocationsAdaptive(limit: 100, filter: { datetime_geq: $start, datetime_leq: $end }) {
                  sum { requests }
                }
                worker: workersInvocationsAdaptive(
                  limit: 100
                  filter: { scriptName: $scriptName, datetime_geq: $start, datetime_leq: $end }
                ) {
                  sum { requests }
                }
              }
            }
          }''',
        'variables': {
          'accountTag': accountId,
          'scriptName': scriptName,
          'start': start.toIso8601String(),
          'end': end.toIso8601String(),
        },
      });
    final response = await http.Response.fromStream(await _client.send(request).timeout(const Duration(seconds: 30)));
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw CloudflareException('Usage query failed (HTTP ${response.statusCode})');
    }
    final errors = (data['errors'] as List? ?? const []).whereType<Map>().map((e) => '${e['message']}').toList();
    if (errors.isNotEmpty) throw CloudflareException('Usage query failed: ${errors.join('; ')}');
    final account = ((data['data'] as Map?)?['viewer'] as Map?)?['accounts'] as List?;
    if (account == null || account.isEmpty) throw const CloudflareException('No usage data for this account');
    int sum(Object? rows) => (rows as List? ?? const []).whereType<Map>().fold(
      0,
      (n, r) => n + (((r['sum'] as Map?)?['requests'] as num?)?.toInt() ?? 0),
    );
    final a = account.first as Map;
    return (total: sum(a['total']), worker: sum(a['worker']));
  }

  // endregion

  // region deployments

  /// A random name (8–18 characters) not used yet by a [type] project in the account.
  Future<String> freeName(String accountId, WorkerType type) async {
    for (var i = 0; i < 5; i++) {
      final name = _randomName(8 + _random.nextInt(11));
      final path = type == WorkerType.pages
          ? '/accounts/$accountId/pages/projects/$name'
          : '/accounts/$accountId/workers/scripts/$name/settings';
      try {
        await _send('GET', path);
      } on CloudflareException catch (e) {
        if (_isAuthError(e)) rethrow;
        return name; // Not found: free.
      }
    }
    throw const CloudflareException('Could not find a free worker name');
  }

  /// Deploys the Worker [name] with [env] (creating it or replacing it) and turns on its
  /// workers.dev route. Returns its workers.dev host.
  Future<String> deployWorker(String accountId, String name, String env) async {
    final subdomain = await ensureSubdomain(accountId);
    await uploadScript(accountId, name, env);
    await enableWorkersDev(accountId, name);
    return '$name.$subdomain.workers.dev';
  }

  /// Deploys the Pages project [name] with [env]: creates it ([create]) or sets its ENV, then
  /// uploads a deployment (variables only apply to new ones). Returns its pages.dev host.
  Future<String> deployPages(String accountId, String name, String env, {required bool create}) async {
    final compatibilityDate = _currentCompatibilityDate();
    final production = {
      'compatibility_date': compatibilityDate,
      'env_vars': {
        envVar: {'type': 'plain_text', 'value': env},
      },
    };
    final project = create
        ? await _send(
            'POST',
            '/accounts/$accountId/pages/projects',
            json: {
              'name': name,
              'production_branch': 'main',
              'deployment_configs': {
                'production': production,
              },
            },
          )
        : await _send(
            'PATCH',
            '/accounts/$accountId/pages/projects/$name',
            json: {
              'deployment_configs': {'production': production},
            },
          );
    await uploadPagesDeployment(accountId, name);
    return '${(project as Map)['subdomain']}';
  }

  static String _currentCompatibilityDate() => DateTime.now().toUtc().toIso8601String().substring(0, 10);

  Future<void> attachCustomDomain(ActiveWorker w, String hostname) => w.type == WorkerType.pages
      ? _attachPagesDomain(w.accountId, w.name, w.host, hostname)
      : _attachWorkerDomain(w.accountId, w.name, hostname);

  Future<void> detachCustomDomain(ActiveWorker w, String hostname) => w.type == WorkerType.pages
      ? _detachPagesDomain(w.accountId, w.name, w.host, hostname)
      : _detachWorkerDomain(w.accountId, w.name, hostname);

  /// Deletes the Worker or Pages project [w] from Cloudflare, its custom domains first: a Pages
  /// project with a domain can't be deleted, and its CNAME record (which we created) is removed
  /// from the zone. A Workers custom domain's DNS record goes with the domain. Anything already
  /// gone is skipped.
  Future<void> deleteDeployment(ActiveWorker w) async {
    Future<void> ignoringGone(Future<void> Function() action) async {
      try {
        await action();
      } on CloudflareException catch (e) {
        if (!_isGone(e)) rethrow;
      }
    }

    if (w.type == WorkerType.pages) {
      final domains = <String>{?w.customDomain};
      await ignoringGone(() async {
        final listed = await _send('GET', '/accounts/${w.accountId}/pages/projects/${w.name}/domains') as List?;
        domains.addAll((listed ?? const []).whereType<Map>().map((d) => '${d['name']}'));
      });
      for (final domain in domains.where((d) => d.isNotEmpty && d != w.host)) {
        await ignoringGone(() => _detachPagesDomain(w.accountId, w.name, w.host, domain));
      }
      await ignoringGone(() => _send('DELETE', '/accounts/${w.accountId}/pages/projects/${w.name}'));
    } else {
      await ignoringGone(() async {
        final domains =
            await _send(
                  'GET',
                  '/accounts/${w.accountId}/workers/domains?service=${Uri.encodeQueryComponent(w.name)}',
                )
                as List? ??
            const [];
        for (final d in domains.whereType<Map>()) {
          await _send('DELETE', '/accounts/${w.accountId}/workers/domains/${d['id']}');
        }
      });
      await ignoringGone(() => _send('DELETE', '/accounts/${w.accountId}/workers/scripts/${w.name}?force=true'));
    }
  }

  // endregion

  static List<String> _zoneCandidates(String hostname) {
    final labels = hostname.split('.');
    return [for (var i = 0; i <= labels.length - 2; i++) labels.sublist(i).join('.')];
  }

  /// The thing asked for doesn't exist (any more).
  static bool _isGone(CloudflareException e) {
    final m = e.message.toLowerCase();
    return m.contains('not found') || m.contains('not_found') || m.contains('does not exist');
  }

  static bool _isAuthError(CloudflareException e) =>
      e.message.contains('(10000)') || e.message.contains('(9109)') || e.message.contains('(6003)');
}

final _random = Random.secure();

/// Random lowercase alphanumeric name.
String _randomName(int length) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(length, (_) => chars[_random.nextInt(chars.length)]).join();
}

String generateUuid() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}
