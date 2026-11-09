import 'dart:convert';
import 'dart:io';

import 'package:bpb/models/settings.dart';
import 'package:bpb/services/der.dart';
import 'package:bpb/services/masque.dart';
import 'package:bpb/services/xray_config.dart';
import 'package:flutter_test/flutter_test.dart';

const account = {
  'privateKey': 'cHJpdmF0ZQ==',
  'publicKey': '-----BEGIN PUBLIC KEY-----\nMFkw\n-----END PUBLIC KEY-----\n',
  'ipv4': '172.16.0.2',
  'ipv6': '2606:4700:110:1::2',
};

Map<String, dynamic> masque([Map<String, dynamic> extra = const {}]) => {
  'masque': {
    'account': account,
    'endpoints': ['162.159.198.2:443', '[2606:4700:103::2]:8443'],
    ...extra,
  },
};

Future<XrayBuild> build(
  String mode, [
  Map<String, dynamic> profile = const {},
  Map<String, dynamic> device = const {},
]) {
  final baseProfile = masque();
  final profileMasque = profile['masque'] as Map? ?? const {};
  final settings = {
    ...baseProfile,
    ...profile,
    'masque': {
      ...baseProfile['masque'] as Map<String, dynamic>,
      ...Map<String, dynamic>.from(profileMasque),
    },
  };
  final deviceConnection = device['connection'] as Map? ?? const {};
  return XrayConfigBuilder(
    Profile.fromJson(settings),
    DeviceSettings.fromJson({
      ...device,
      'connection': {
        ...Map<String, dynamic>.from(deviceConnection),
        'masqueVariant': mode,
      },
    }),
    resolver: (host, {required bool ipv6}) async => const [],
  ).build(ConnectionMode.masque);
}

List<Map> proxies(Map c) => (c['outbounds'] as List)
    .cast<Map>()
    .where((o) => '${o['tag']}'.startsWith('proxy-'))
    .toList();

/// Writes configs for `xray run -test` when XRAY_TEST_OUT is set.
void dump(String name, Map<String, dynamic> config) {
  final out = Platform.environment['XRAY_TEST_OUT'];
  if (out == null) return;
  File('$out/$name.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(config));
}

void main() {
  test('Normal H2: a balancer over every endpoint, MASQUE over HTTP/2 with the account', () async {
    final b = await build('normal', {
      ...masque({'tlsFingerprint': 'firefox'}),
      'general': {'enableIpv6': true},
    });
    final out = proxies(b.config);
    expect(out.map((o) => o['settings']), [
      {'address': '162.159.198.2', 'port': 443},
      {'address': '2606:4700:103::2', 'port': 8443},
    ]);
    final stream = out.first['streamSettings'] as Map;
    expect(out.first['protocol'], 'masque');
    expect(stream['network'], 'masque');
    expect(stream['tlsSettings'], {
      'serverName': MasqueSettings.defaultSni,
      'alpn': ['h2'],
      'fingerprint': 'firefox',
    });
    expect(stream['masqueSettings'], {
      'warp': {
        'privateKey': account['privateKey'],
        'publicKey': 'MFkw', // the PEM fixture's body: base64, one line
        'address': [account['ipv4'], account['ipv6']],
      },
    });
    expect(stream['finalmask'], isNull);
    expect(b.config['routing']['balancers'][0]['tag'], 'all-proxies');
    expect(
      b.config['burstObservatory']['pingConfig']['interval'],
      '${const MasqueSettings().speedTestInterval}s',
    );
    // WARP-like: the remote DNS is an IP through the tunnel, and UDP isn't blocked.
    final remote = (b.config['dns']['servers'] as List)
        .whereType<Map>()
        .firstWhere((s) => s['tag'] == 'remote-dns');
    expect(remote['address'], '1.1.1.1');
    expect(
      (b.config['routing']['rules'] as List).any(
        (r) => r['network'] == 'udp' && r['outboundTag'] == 'block',
      ),
      isFalse,
    );
    dump('masque_normal_h2', b.config);
  });

  test('Normal H3: the same over HTTP/3, without a TLS fingerprint', () async {
    final b = await build(
      'normal',
      masque({'transport': 'h3', 'tlsFingerprint': 'unsafe'}),
    );
    final stream =
        proxies(b.config).single['streamSettings']
            as Map; // IPv6 off: the IPv4 endpoint
    expect(stream['tlsSettings'], {
      'serverName': MasqueSettings.defaultSni,
      'alpn': ['h3'],
    });
    dump('masque_normal_h3', b.config);
  });

  test('Unsafe H2 fingerprint adds the VLESS cipher suites', () async {
    final b = await build(
      'normal',
      masque({'transport': 'h2', 'tlsFingerprint': 'unsafe'}),
    );
    final tls = proxies(b.config).first['streamSettings']['tlsSettings'] as Map;
    expect(tls['fingerprint'], 'unsafe');
    expect(
      tls['cipherSuites'],
      'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA:TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA:TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256:TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256',
    );
  });

  test(
    'Fragment H2: applies the configured fragments on each endpoint',
    () async {
      final b = await build('obfuscated', {
        ...masque({
          'transport': 'h2',
          'endpoints': ['162.159.198.2:443', '[2606:4700:103::2]:8443'],
          'fragments': [
            {
              'packets': '1-1',
              'lengths': [
                {'min': 1, 'max': 2},
              ],
              'delays': [
                {'min': 7, 'max': 9},
              ],
              'maxSplit': {'min': 3, 'max': 4},
            },
            {
              'packets': 'tlsHello',
              'lengths': [
                {'min': 5, 'max': 6},
              ],
              'delays': [
                {'min': 8, 'max': 8},
              ],
            },
          ],
        }),
        'general': {'enableIpv6': true},
      });
      final out = proxies(b.config);
      expect(out, hasLength(2));
      expect(out.map((o) => o['settings']).toList(), [
        {'address': '162.159.198.2', 'port': 443},
        {'address': '2606:4700:103::2', 'port': 8443},
      ]);
      final fragments = [
        {
          'type': 'fragment',
          'settings': {
            'packets': '1-1',
            'lengths': ['1-2'],
            'delays': ['7-9'],
            'maxSplit': '3-4',
          },
        },
        {
          'type': 'fragment',
          'settings': {
            'packets': 'tlshello',
            'lengths': ['5-6'],
            'delays': ['8'],
          },
        },
      ];
      for (final outbound in out) {
        expect(outbound['streamSettings']['finalmask']['tcp'], fragments);
      }
      dump('masque_fragment_h2', b.config);
    },
  );

  test('Obfuscation H3: configured noises on every endpoint', () async {
    final b = await build('obfuscated', {
      'general': {'enableIpv6': true},
      ...masque({
        'transport': 'h3',
        'udpNoises': [
          {
            'type': 'rand',
            'size': {'min': 50, 'max': 100},
            'count': 1,
            'delay': {'min': 3, 'max': 4},
          },
        ],
        'udpNoiseReset': {'min': 10, 'max': 20},
      }),
    });
    final out = proxies(b.config);
    expect(out, hasLength(2));
    expect(out.map((o) => o['settings']).toList(), [
      {'address': '162.159.198.2', 'port': 443},
      {'address': '2606:4700:103::2', 'port': 8443},
    ]);
    for (final outbound in out) {
      final stream = outbound['streamSettings'] as Map;
      final noise = (stream['finalmask']['udp'] as List).single['settings'];
      expect(noise, {
        'reset': '10-20',
        'noise': [
          {'rand': '50-100', 'randRange': '0-255', 'delay': '3-4'},
        ],
      });
      expect(stream['tlsSettings']['alpn'], ['h3']);
    }
    dump('masque_obfuscation_h3', b.config);
  });

  test(
    'SNI, remote DNS and speed test interval from the MASQUE settings; no ECH',
    () async {
      final b = await build(
        'normal',
        masque({
          'transport': 'h2',
          'ech': {
            'enabled': true,
            'dns': '8.8.8.8',
          }, // saved before ECH was dropped: ignored
          'sni': 'masque.example.com',
          'remoteDns': '9.9.9.9',
          'speedTestInterval': 30,
        }),
      );
      final tls =
          proxies(b.config).first['streamSettings']['tlsSettings'] as Map;
      expect(tls['serverName'], 'masque.example.com');
      expect(tls.containsKey('echConfigList'), isFalse);
      final remote = (b.config['dns']['servers'] as List)
          .whereType<Map>()
          .firstWhere((s) => s['tag'] == 'remote-dns');
      expect(remote['address'], '9.9.9.9');
      expect(b.config['burstObservatory']['pingConfig']['interval'], '30s');
    },
  );

  test('remote DNS by domain: its IPs in hosts, so reaching it needs no DNS; anti-sanction DoQ as quic+local', () async {
    final c = await XrayConfigBuilder(
      Profile.fromJson({
        ...masque({'remoteDns': 'https://dns.google/dns-query'}),
        'general': {'antiSanctionDns': 'quic://dns.adguard-dns.com'},
        'routing': {
          'sanctionBypass': {
            'presets': {'openAi': true},
          },
        },
      }),
      DeviceSettings.fromJson(const {
        'connection': {'masqueVariant': 'normal'},
      }),
      resolver: (host, {required bool ipv6}) async =>
          host == 'dns.google' ? const ['8.8.8.8', '8.8.4.4'] : const [],
    ).build(ConnectionMode.masque);
    final dns = c.config['dns'] as Map;
    expect(dns['hosts']['dns.google'], ['8.8.8.8', '8.8.4.4']);
    final servers = (dns['servers'] as List).whereType<Map>();
    expect(
      servers.firstWhere((s) => s['tag'] == 'remote-dns')['address'],
      'https://dns.google/dns-query',
    );
    expect(
      servers.map((s) => s['address']),
      contains('quic+local://dns.adguard-dns.com'),
    );
  });

  test('needs an account and an endpoint IPv4 can use', () async {
    final noAccount = XrayConfigBuilder(
      const Profile(),
      const DeviceSettings(),
    ).build(ConnectionMode.masque);
    expect(noAccount, throwsStateError);
    expect(
      () => build(
        'normal',
        masque({
          'endpoints': ['[2606:4700:103::2]:443'],
        }),
      ),
      throwsStateError,
    );
  });

  test('a chain proxy exits through MASQUE', () async {
    final b = await build(
      'normal',
      {
        'chains': [
          {
            'id': 'a1',
            'name': 'socks',
            'link': 'socks://user:pass@203.0.113.1:1080',
          },
        ],
      },
      {
        'exit': {'node': 'chain'},
      },
    );
    final exits = (b.config['outbounds'] as List).cast<Map>().where(
      (o) => o['tag'] == 'exit',
    );
    expect(
      exits.single['streamSettings']['sockopt']['dialerProxy'],
      'exit-dialer',
    );
    final rules = (b.config['routing']['rules'] as List).cast<Map>();
    final chainIn = rules.firstWhere(
      (r) => (r['inboundTag'] as List?)?.contains('chain-in') ?? false,
    );
    expect(chainIn['balancerTag'], 'all-proxies');
    expect(
      (b.config['routing']['balancers'] as List).single['fallbackTag'],
      'proxy-1',
    );
  });

  test("defaults: MASQUE's fragments and noises are the profile's, and its account isn't exported", () {
    const p = Profile();
    expect(
      p.masque.fragments.map((f) => f.toJson()),
      p.fragments.map((f) => f.toJson()),
    );
    expect(
      p.masque.udpNoises.map((n) => n.toJson()),
      p.udpNoises.map((n) => n.toJson()),
    );
    expect(p.masque.udpNoiseReset.toJson(), p.udpNoiseReset.toJson());
    expect(const DeviceSettings().masqueVariant, 'normal');
    expect(const MasqueSettings().transport, 'h2');
    expect(
      Profile.fromJson({
        'masque': {'transport': 'h3'},
      }).masque.transport,
      'h3',
    );
    expect(const MasqueSettings().tlsFingerprint, 'chrome');
    expect(
      Profile.fromJson({
        'masque': {'tlsFingerprint': 'firefox'},
      }).masque.tlsFingerprint,
      'firefox',
    );
    expect(MasqueVariant.values.map((v) => v.label(false)), [
      'Normal',
      'Fragment',
    ]);
    expect(MasqueVariant.values.map((v) => v.label(true)), [
      'Normal',
      'Obfuscated',
    ]);

    final withAccount = Profile.fromJson(masque());
    expect(withAccount.masque.account?.ipv4, '172.16.0.2');
    expect(
      (withAccount.toExportJson()['masque'] as Map).containsKey('account'),
      isFalse,
    );
    expect(const Profile().keepingPrivate(withAccount).masque.account, isNull);
    expect(
      withAccount.keepingPrivate(const Profile()).masque.account?.ipv6,
      account['ipv6'],
    );
  });

  test("registration offers the MASQUE v4 / v6 addresses on each port, not WireGuard's host", () {
    expect(
      MasqueRegistrar.offeredEndpoints({
        'v4': '162.159.198.2:0',
        'v6': '[2606:4700:103::2]:0',
        'host': 'engage.cloudflareclient.com:2408',
        'ports': [443, 8443],
      }),
      [
        '162.159.198.2:443',
        '162.159.198.2:8443',
        '[2606:4700:103::2]:443',
        '[2606:4700:103::2]:8443',
      ],
    );
  });

  test('P-256 keys: a SEC 1 private key and a PKIX public key', () {
    final keys = P256KeyPair.generate();
    expect(keys.point, hasLength(65));
    expect(keys.sec1.first, 0x30);
    expect(
      keys.spki,
      hasLength(91),
    ); // the usual size of a P-256 SubjectPublicKeyInfo
    final out = Platform.environment['XRAY_TEST_OUT'];
    if (out != null) {
      File('$out/p256.key')
          .writeAsStringSync(Der.pem('EC PRIVATE KEY', keys.sec1));
      File('$out/p256.pub').writeAsStringSync(Der.pem('PUBLIC KEY', keys.spki));
    }
  });
}
