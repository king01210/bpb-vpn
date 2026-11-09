import 'dart:convert';

import 'package:bpb/models/cf_account.dart';
import 'package:bpb/models/settings.dart';
import 'package:bpb/services/cloudflare_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeToken', () {
    // Made-up token in the new cfut_ format (not a real credential).
    const token = 'cfut_Ab12Cd34Ef56Gh78Ij90Kl12Mn34Op56Qr78St90Uv12Wx34a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6';

    test('joins a token copied across two lines', () {
      final split = '${token.substring(0, 53)}\n${token.substring(53)}';
      expect(CloudflareApi.normalizeToken(split), token);
      expect(CloudflareApi.normalizeToken('${token.substring(0, 53)} ${token.substring(53)}'), token);
    });

    test('drops quotes, invisible characters and surrounding whitespace', () {
      expect(CloudflareApi.normalizeToken('  "$token"\n'), token);
      expect(CloudflareApi.normalizeToken('${token.substring(0, 10)}­‎${token.substring(10)}'), token);
      expect(CloudflareApi.normalizeToken(' $token '), token);
    });

    test('takes the token out of a pasted curl command', () {
      final curl =
          'curl "https://api.cloudflare.com/client/v4/user/tokens/verify" \\\n'
          '     -H "Authorization: Bearer $token"';
      expect(CloudflareApi.normalizeToken(curl), token);
      expect(CloudflareApi.normalizeToken('Bearer $token'), token);
    });

    test('rejects empty input and the Global API Key', () {
      expect(() => CloudflareApi.normalizeToken('   '), throwsA(isA<CloudflareException>()));
      expect(
        () => CloudflareApi.normalizeToken('0123456789abcdef0123456789abcdef01234'),
        throwsA(isA<CloudflareException>().having((e) => e.message, 'message', contains('Global API Key'))),
      );
    });
  });

  test('token creation link pre-selects the Wizard permissions', () {
    final uri = Uri.parse(CloudflareApi.tokenCreationUrl());
    expect(uri.host, 'dash.cloudflare.com');
    final keys = (jsonDecode(uri.queryParameters['permissionGroupKeys']!) as List).map((p) => p['key']).toSet();
    expect(keys, {'workers_scripts', 'page', 'dns', 'user_details'});
  });

  test('an account and its deployments survive their JSON; VLESS settings stored sparse', () {
    const a = SavedCfAccount(
      id: 'acc',
      name: 'Mine',
      token: 'tok',
      email: 'me@example.com',
      uuid: 'u-1',
      deployments: [
        Deployment(
          type: WorkerType.pages,
          name: 'pg',
          host: 'pg-x1.pages.dev',
          version: 1,
          vless: VlessSettings(proxyIps: ['p.example.com']),
        ),
        Deployment(
          type: WorkerType.workers,
          name: 'wk',
          host: 'wk.me.workers.dev',
          customDomain: 'vpn.example.com',
          version: 1,
          pending: true,
        ),
      ],
    );
    final json = jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>;
    expect((json['deployments'] as List)[1]['vless'], isEmpty); // Defaults aren't stored.
    final back = SavedCfAccount.fromJson(json)!;
    expect(back.toJson(), {...a.toJson(), 'deployments': [for (final d in a.deployments.reversed) d.toJson()]});
    expect(back.deployments.map((d) => d.type), [WorkerType.workers, WorkerType.pages]); // Workers first.
    expect(back.deployment(WorkerType.workers)!.pending, isTrue);
    expect(back.deployment(WorkerType.pages)!.vless.proxyIps, ['p.example.com']);
    // Without a UUID (an older version) or deployments, an entry isn't usable: accounts are
    // saved only once deployed.
    expect(SavedCfAccount.fromJson({'id': 'acc', 'apiToken': 'tok'}), isNull);
    expect(SavedCfAccount.fromJson({'id': 'acc', 'apiToken': 'tok', 'uuid': 'u-1'}), isNull);
  });
}
