import 'dart:convert';
import 'dart:io';

import 'package:bpb/models/settings.dart';
import 'package:bpb/services/chain_proxy.dart';
import 'package:bpb/services/domain_fronting_v23.dart';
import 'package:bpb/services/mitm_ca.dart';
import 'package:bpb/services/proxy_uri.dart';
import 'package:bpb/services/public_dns.dart';
import 'package:bpb/services/warp.dart';
import 'package:bpb/services/xray_config.dart';
import 'package:bpb/ui/noises_page.dart';
import 'package:flutter_test/flutter_test.dart';

const worker = ActiveWorker(
  accountId: '0123456789abcdef0123456789abcdef',
  name: 'k3x9m2q7tz',
  type: WorkerType.workers,
  host: 'k3x9m2q7tz.example.workers.dev',
  customDomain: 'vpn.example.com',
);
const uuid = '6f0c3d7e-1b2a-4c5d-8e9f-0a1b2c3d4e5f';

Future<List<String>> fakeResolve(String host, {required bool ipv6}) async => [
  '104.21.1.1',
  '172.67.1.1',
  if (ipv6) '2606:4700::1',
];

XrayConfigBuilder builder(
  Map<String, dynamic> profile, [
  Map<String, dynamic> device = const {},
]) => XrayConfigBuilder(
  Profile.fromJson(profile),
  DeviceSettings.fromJson(device),
  worker: worker,
  uuid: uuid,
  resolver: fakeResolve,
);

/// Writes configs for `xray run -test` when XRAY_TEST_OUT is set.
void dump(String name, Map<String, dynamic> config) {
  final out = Platform.environment['XRAY_TEST_OUT'];
  if (out == null) return;
  File('$out/$name.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(config));
}

Map<String, int> r(int min, [int? max]) => {'min': min, 'max': max ?? min};

const chainExit = {
  'exit': {'node': 'chain'},
};

/// A profile with one chain proxy.
Map<String, dynamic> chains(String link) => {
  'chains': [
    {'id': 'a1', 'name': 'chain', 'link': link},
  ],
};

const wgConf = '''
[Interface]
PrivateKey = cHJpdmF0ZWtleXByaXZhdGVrZXlwcml2YXRla2V5MDE=
Address = 10.0.0.2/32, fd00::2/128
DNS = 10.0.0.1, fd00::1, corp.example
MTU = 1380

[Peer]
PublicKey = cHVibGlja2V5cHVibGlja2V5cHVibGlja2V5cHViMDE+
PresharedKey = cHJlc2hhcmVka2V5cHJlc2hhcmVka2V5cHJlc2hhcjE=
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
''';

void main() {
  final everything = <String, dynamic>{
    'general': {'enableFakeDns': true, 'enableIpv6': true},
    'vless': {
      'ports': [443, 8443, 80],
      'cleanIps': ['www.speedtest.net', '188.114.97.3'],
      'customCdn': {
        'addresses': ['cdn.example.net'],
        'host': 'cdn-host.example.net',
        'sni': 'cdn-sni.example.net',
      },
      'remoteDns': {'server': 'https://dns.google/dns-query'},
      'enableTcpFastOpen': true,
      'ech': {'enabled': true},
    },
    'routing': {
      'bypass': {
        'presets': {'iran': true, 'china': true},
        'domains': ['example.ir'],
        'ips': ['10.10.0.0/16'],
      },
      'sanctionBypass': {
        'presets': {'openAi': true, 'microsoft': true},
        'domains': ['sanctioned.example.com'],
      },
      'block': {
        'presets': {
          'ads': true,
          'malware': true,
          'phishing': true,
          'quic': true,
        },
        'domains': ['ads.example.com'],
        'ips': ['1.2.3.4'],
      },
    },
    'fragments': [
      {
        'packets': 'tlsHello',
        'lengths': [r(3, 5), r(6, 8), r(10, 20)],
        'delays': [r(10, 20)],
        'maxSplit': r(3, 6),
      },
      {
        'packets': '1-3',
        'lengths': [r(100, 200)],
        'delays': [r(0)],
        'maxSplit': null,
      },
    ],
  };
  const everythingDevice = {'mtu': 1400};

  List<Map> outboundsOf(Map<String, dynamic> c, String tagPrefix) =>
      (c['outbounds'] as List)
          .cast<Map>()
          .where((o) => '${o['tag']}'.startsWith(tagPrefix))
          .toList();

  /// The chain proxy (the exit outbound, dialing exit-dialer), or null.
  Map? chainOf(Map<String, dynamic> c) => (c['outbounds'] as List)
      .cast<Map>()
      .where((o) => o['tag'] == 'exit')
      .where(
        (o) => o['streamSettings']?['sockopt']?['dialerProxy'] == 'exit-dialer',
      )
      .firstOrNull;

  test('config has tun inbound, vless outbounds and UDP block', () async {
    final c = (await builder({}).build(ConnectionMode.worker)).config;
    expect((c['inbounds'] as List).first['protocol'], 'tun');
    final proxy = (c['outbounds'] as List).first as Map;
    expect(proxy['tag'], 'proxy-1');
    expect(proxy['protocol'], 'vless');
    expect(proxy['settings'], {
      'address': proxy['settings']['address'],
      'port': 443,
      'id': uuid,
      'encryption': 'none',
    });
    expect(proxy['streamSettings']['wsSettings']['path'], endsWith('?ed=2560'));
    final rules = c['routing']['rules'] as List;
    expect(
      rules.any((r) => r['network'] == 'udp' && r['outboundTag'] == 'block'),
      isTrue,
    );
    expect(rules.last['balancerTag'], 'all-proxies');
    dump('worker_best', c);
  });

  test('every catch-all only matches IPs, so IPIfNonMatch resolves domain-only connections', () async {
    final configs = [
      await builder({}).build(ConnectionMode.worker),
      await builder({}, chainExit).build(ConnectionMode.serverless),
      await builder(everything, {
        'exit': {'node': 'tor'},
      }).build(ConnectionMode.worker),
      await builder({}).build(ConnectionMode.psiphon),
    ];
    for (final b in configs) {
      expect(b.config['routing']['domainStrategy'], 'IPIfNonMatch');
      final rules = (b.config['routing']['rules'] as List).cast<Map>();
      expect(rules.last['ip'], ['0.0.0.0/0', '::/0'], reason: 'routing rules');
      expect(rules.last['network'], isNull, reason: 'routing rules');
      // Where UDP isn't carried, the block rule takes it before the catch-all.
      final udpBlock = rules.indexWhere(
        (r) =>
            r['network'] == 'udp' &&
            r['port'] == null &&
            r['outboundTag'] == 'block',
      );
      if (udpBlock >= 0) {
        expect(
          rules.sublist(udpBlock + 1).any((r) => r['network'] == 'udp'),
          isFalse,
        );
      }
    }
  });

  test(
    'custom CDN addresses only with the switch on, with their own host and SNI',
    () async {
      Future<List<Map>> cdnProxies(Map<String, dynamic> customCdn) async {
        final c = (await builder({
          'vless': {'customCdn': customCdn},
        }).build(ConnectionMode.worker)).config;
        return outboundsOf(
          c,
          'proxy-',
        ).where((o) => o['settings']['address'] == 'cdn.example.net').toList();
      }

      const cdn = {
        'addresses': ['cdn.example.net'],
        'host': 'cdn-host.example.net',
        'sni': 'cdn-sni.example.net',
      };
      final on = await cdnProxies({...cdn, 'enabled': true});
      expect(on, isNotEmpty);
      expect(
        on.first['streamSettings']['wsSettings']['host'],
        'cdn-host.example.net',
      );
      expect(
        on.first['streamSettings']['tlsSettings']['serverName'],
        'cdn-sni.example.net',
      );
      expect(await cdnProxies({...cdn, 'enabled': false}), isEmpty);
      expect(await cdnProxies(cdn), isNotEmpty); // saved before the switch: on
      expect(const CustomCdnSettings().enabled, isFalse);
    },
  );

  test('unsafe TLS fingerprint sets the configured cipher suites', () async {
    final c = (await builder({
      'vless': {'tlsFingerprint': 'unsafe'},
    }).build(ConnectionMode.worker)).config;
    final tls =
        outboundsOf(c, 'proxy-').first['streamSettings']['tlsSettings'] as Map;
    expect(tls['fingerprint'], 'unsafe');
    expect(
      tls['cipherSuites'],
      'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA:TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA:TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256:TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256',
    );

    final defaultConfig = (await builder({}).build(ConnectionMode.worker))
        .config;
    final defaultTls =
        outboundsOf(
              defaultConfig,
              'proxy-',
            ).first['streamSettings']['tlsSettings']
            as Map;
    expect(defaultTls.containsKey('cipherSuites'), isFalse);
  });

  test('needs a worker for VLESS types', () async {
    final noWorker = XrayConfigBuilder(const Profile(), const DeviceSettings());
    expect(() => noWorker.build(ConnectionMode.worker), throwsStateError);
  });

  test('best ping uses balancer over all addresses', () async {
    final c = (await builder(
      everything,
      everythingDevice,
    ).build(ConnectionMode.worker)).config;
    expect(outboundsOf(c, 'proxy-').length, greaterThan(10));
    expect(c['routing']['balancers'][0]['tag'], 'all-proxies');
    expect(c.containsKey('observatory'), isFalse);
    final burst = c['burstObservatory'] as Map;
    expect(burst['subjectSelector'], ['proxy']);
    expect(burst['pingConfig'], {
      'destination': XrayConfigBuilder.probeUrl,
      'connectivity': XrayConfigBuilder.connectivityUrl,
      'interval': '60s',
      'sampling': 3,
      'timeout': '5s',
    });
    expect(c['routing']['balancers'][0]['strategy'], {'type': 'leastPing'});
    expect((c['dns']['servers'] as List).first['address'], 'fakedns');
    dump('worker_best_everything', c);
  });

  test('fragment config carries finalmask and skips ECH', () async {
    final c = (await builder(
      everything,
      everythingDevice,
    ).build(ConnectionMode.worker, variant: ConnectionVariant.fragment)).config;
    final stream = (c['outbounds'] as List).first['streamSettings'] as Map;
    final masks = stream['finalmask']['tcp'] as List;
    expect(masks.length, 2);
    expect(masks[0]['settings'], {
      'packets': 'tlshello',
      'lengths': ['3-5', '6-8', '10-20'],
      'delays': ['10-20'],
      'maxSplit': '3-6',
    });
    expect(masks[1]['settings'], {
      'packets': '1-3',
      'lengths': ['100-200'],
      'delays': ['0'],
    });
    expect((c['inbounds'] as List).first['settings']['MTU'], 1400);
    expect(
      (stream['tlsSettings'] as Map).containsKey('echConfigList'),
      isFalse,
    );
    dump('fragment_best', c);
  });

  test('chain proxy outbound dials through proxy', () async {
    final vmess = base64.encode(
      utf8.encode(
        jsonEncode({
          'add': 'v.example.org',
          'port': '443',
          'id': '11111111-2222-4333-8444-555555555555',
          'net': 'ws',
          'path': '/v',
          'host': 'v.example.org',
          'tls': 'tls',
          'sni': 'v.example.org',
        }),
      ),
    );
    final ss = base64Url.encode(utf8.encode('chacha20-ietf-poly1305:secret'));
    final links = {
      'vless_reality':
          'vless://11111111-2222-4333-8444-555555555555@1.2.3.4:443?security=reality&type=tcp'
          '&sni=www.microsoft.com&fp=chrome&pbk=SUtl6NDexiBFgmw5fpuB6ESqUwSsC4dHrbRmBAdjgD8&sid=0123'
          '&flow=xtls-rprx-vision#r',
      'trojan_ws': 'trojan://pass@example.org:443?security=tls&type=ws&host=example.org&path=%2Fws&sni=example.org#t',
      'ss': 'ss://$ss@5.6.7.8:8388#s',
      'socks': 'socks://user:pass@9.9.9.9:1080#x',
      'vmess_ws': 'vmess://$vmess',
    };
    for (final MapEntry(key: name, value: link) in links.entries) {
      final c = (await builder(
        chains(link),
        chainExit,
      ).build(ConnectionMode.worker)).config;
      final outbounds = (c['outbounds'] as List).cast<Map>();
      // One exit, first (Xray's default), dialing the loopback back into routing as chain-in.
      expect(outbounds.first['tag'], 'exit', reason: name);
      expect(
        outbounds.first['streamSettings']['sockopt']['dialerProxy'],
        'exit-dialer',
        reason: name,
      );
      expect(outbounds[1], {
        'protocol': 'loopback',
        'settings': {'inboundTag': 'chain-in'},
        'tag': 'exit-dialer',
      }, reason: name);
      expect(outboundsOf(c, 'exit').length, 2, reason: name);
      final rules = (c['routing']['rules'] as List).cast<Map>();
      // chain-in goes through the connection with the remote DNS, before the bypass / block rules.
      final chainIn = rules.indexWhere(
        (r) => (r['inboundTag'] as List?)?.contains('chain-in') ?? false,
      );
      expect(rules[chainIn]['inboundTag'], [
        'chain-in',
        'remote-dns',
      ], reason: name);
      expect(rules[chainIn]['balancerTag'], 'all-proxies', reason: name);
      expect(
        rules.indexWhere((r) => r['domain'] != null || r['ip'] != null),
        greaterThan(chainIn),
        reason: name,
      );
      expect(rules.last['outboundTag'], 'exit', reason: name);
      // Only the proxies are balanced and pinged.
      expect((c['routing']['balancers'] as List).map((b) => b['tag']), [
        'all-proxies',
      ], reason: name);
      expect(c['burstObservatory']['subjectSelector'], ['proxy'], reason: name);
      // UDP goes to the chain proxy too: no UDP block.
      final udpBlocked = rules.any(
        (r) =>
            r['network'] == 'udp' &&
            r['port'] == null &&
            r['outboundTag'] == 'block',
      );
      expect(udpBlocked, isFalse, reason: name);
      dump('chain_best_$name', c);
    }
  });

  test('a TLS chain proxy pins its certificate and verifies it by name (pcs / vcn)', () async {
    const fp =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    final c = (await builder(
      chains(
        'trojan://pass@192.0.2.4:443?security=tls&sni=front.example.com&pcs=$fp&vcn=real.example.com#t',
      ),
      chainExit,
    ).build(ConnectionMode.worker)).config;
    final tls = chainOf(c)!['streamSettings']['tlsSettings'] as Map;
    expect(tls['pinnedPeerCertSha256'], fp);
    expect(tls['verifyPeerCertByName'], 'real.example.com');
    dump('chain_best_trojan_pinned', c);
    // Without them, neither key is set.
    final plain = (await builder(
      chains('trojan://pass@192.0.2.4:443?security=tls#t'),
      chainExit,
    ).build(ConnectionMode.worker)).config;
    final plainTls = chainOf(plain)!['streamSettings']['tlsSettings'] as Map;
    expect(plainTls.keys, isNot(contains('pinnedPeerCertSha256')));
    expect(plainTls.keys, isNot(contains('verifyPeerCertByName')));
  });

  test('chain proxy is only used when it is the exit node', () async {
    final profile = chains('socks://user:pass@9.9.9.9:1080#x');
    final c = (await builder(profile).build(ConnectionMode.worker)).config;
    expect(outboundsOf(c, 'exit'), isEmpty);
    // Chain exit without chain proxies: the worker is the exit.
    final none = (await builder({}, chainExit).build(ConnectionMode.worker))
        .config;
    expect(outboundsOf(none, 'exit'), isEmpty);
    // Serverless has no chain: it connects directly.
    final s = (await builder(
      profile,
      chainExit,
    ).build(ConnectionMode.serverless)).config;
    expect(outboundsOf(s, 'exit'), isEmpty);
  });

  group('Psiphon exit', () {
    const psiphonExit = {
      'exit': {'node': 'psiphon', 'region': 'DE'},
    };
    Map socksOut(Map c) => (c['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['tag'] == 'exit',
    );
    List<Map> rulesOf(Map c) => (c['routing']['rules'] as List).cast<Map>();

    test('traffic (TCP and UDP) exits through Psiphon; Psiphon dials through the worker', () async {
      final b = await builder(everything, {
        ...everythingDevice,
        ...psiphonExit,
      }).build(ConnectionMode.worker);
      final c = b.config;
      expect(socksOut(c)['settings'], {
        'address': '127.0.0.1',
        'port': XrayConfigBuilder.exitPort,
      });
      final up = (c['inbounds'] as List).cast<Map>().firstWhere(
        (i) => i['tag'] == 'psiphon-in',
      );
      expect(up['port'], XrayConfigBuilder.exitUpstreamPort);
      expect(up['listen'], '127.0.0.1');

      final rules = rulesOf(c);
      final upRule = rules.firstWhere(
        (r) => (r['inboundTag'] as List?)?.contains('psiphon-in') ?? false,
      );
      expect(upRule['balancerTag'], 'all-proxies');
      // Remote DNS: the VLESS remote DNS through the balancer, as BPB does with a chain proxy.
      final remote = (c['dns']['servers'] as List).whereType<Map>().firstWhere(
        (d) => d['tag'] == 'remote-dns',
      );
      expect(remote['address'], 'https://dns.google/dns-query');
      expect(
        rules.firstWhere(
          (r) => (r['inboundTag'] as List?)?.contains('remote-dns') ?? false,
        )['balancerTag'],
        'all-proxies',
      );
      expect(rules.last, containsPair('outboundTag', 'exit'));
      expect(rules.last['network'], isNull);
      // UDP isn't blocked as it is through the worker alone, but bypass and block rules still apply first.
      expect(
        rules.any(
          (r) =>
              r['network'] == 'udp' &&
              r['port'] == null &&
              r['outboundTag'] == 'block',
        ),
        isFalse,
      );
      final bypass = rules.indexWhere(
        (r) => (r['domain'] as List?)?.contains('geosite:ir') ?? false,
      );
      expect(bypass, lessThan(rules.length - 1));
      expect(outboundsOf(c, 'exit-dialer'), isEmpty);
      dump('worker_psiphon', c);
    });

    test('Serverless: Psiphon dials through the fragment outbound', () async {
      final c = (await builder(
        everything,
        psiphonExit,
      ).build(ConnectionMode.serverless)).config;
      final rules = rulesOf(c);
      final upRule = rules.firstWhere(
        (r) => (r['inboundTag'] as List?)?.contains('psiphon-in') ?? false,
      );
      expect(upRule['outboundTag'], 'proxy');
      expect(rules.last['outboundTag'], 'exit');
      expect(rules.any((r) => r['outboundTag'] == 'udp-noise'), isFalse);
      dump('serverless_psiphon', c);
    });

    test('Psiphon type: no worker; the proxy is a socks outbound to Psiphon, which connects by itself', () async {
      final b = await builder(everything, {
        'connection': {'type': 'psiphon'},
        'exit': {
          'node': 'worker',
          'region': 'NL',
        }, // the type always exits through Psiphon
      }).build(ConnectionMode.psiphon);
      final c = b.config;
      expect(outboundsOf(c, 'proxy').single, {
        'tag': 'proxy',
        'protocol': 'socks',
        'settings': {
          'address': '127.0.0.1',
          'port': XrayConfigBuilder.exitPort,
        },
      });
      // No exit outbound or upstream inbound: Psiphon is outside the VPN like the rest of the app.
      expect(outboundsOf(c, 'exit'), isEmpty);
      expect(
        (c['inbounds'] as List).cast<Map>().map((i) => i['tag']),
        isNot(contains('psiphon-in')),
      );
      final rules = rulesOf(c);
      expect(
        rules.any(
          (r) => (r['inboundTag'] as List?)?.contains('remote-dns') ?? false,
        ),
        isFalse,
      );
      expect(
        rules.any(
          (r) =>
              r['network'] == 'udp' &&
              r['port'] == null &&
              r['outboundTag'] == 'block',
        ),
        isFalse,
      );
      expect(rules.last, containsPair('outboundTag', 'proxy'));
      expect(rules.last['network'], isNull);
      expect(c.containsKey('burstObservatory'), isFalse);
      // Remote DNS: Psiphon's DNS server on this phone (not the DoH setting), under the DNS
      // module's tag (routed direct) rather than remote-dns.
      final servers = (c['dns']['servers'] as List).whereType<Map>();
      expect(servers.where((d) => d['address'] == '127.0.0.1').single, {
        'address': '127.0.0.1',
        'port': XrayConfigBuilder.exitDnsPort,
      });
      expect(servers.any((d) => d['tag'] == 'remote-dns'), isFalse);
      expect(
        rules.any(
          (r) => (r['inboundTag'] as List?)?.contains('remote-dns') ?? false,
        ),
        isFalse,
      );
      expect(
        (c['dns']['hosts'] as Map? ?? const {}).containsKey('dns.google'),
        isFalse,
      );
      dump('psiphon_type', c);
    });
  });

  group('Tor exit', () {
    Map socksOut(Map c) => (c['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['tag'] == 'exit',
    );
    List<Map> rulesOf(Map c) => (c['routing']['rules'] as List).cast<Map>();
    Map inboundRule(Map c, String tag) => rulesOf(c)
        .firstWhere((r) => (r['inboundTag'] as List?)?.contains(tag) ?? false);

    test('TCP exits through Tor, which dials relays through the worker; UDP is blocked', () async {
      final b = await builder(everything, {
        ...everythingDevice,
        'exit': {'node': 'tor', 'region': 'NL'},
      }).build(ConnectionMode.worker);
      final c = b.config;
      expect(socksOut(c)['settings'], {
        'address': '127.0.0.1',
        'port': XrayConfigBuilder.exitPort,
      });
      final up = (c['inbounds'] as List).cast<Map>().firstWhere(
        (i) => i['tag'] == 'tor-in',
      );
      expect(up['port'], XrayConfigBuilder.exitUpstreamPort);
      expect(
        (c['inbounds'] as List).cast<Map>().any(
          (i) => i['tag'] == 'psiphon-in',
        ),
        isFalse,
      );
      expect(inboundRule(c, 'tor-in')['balancerTag'], 'all-proxies');
      expect(inboundRule(c, 'tor-in')['inboundTag'], [
        'tor-in',
        'remote-dns',
      ]); // one rule for both
      // Remote DNS: the VLESS remote DNS through the balancer, not Tor's DNSPort (that's for the
      // Tor type, which has no VLESS / WARP to go through).
      final servers = (c['dns']['servers'] as List).whereType<Map>();
      expect(
        servers.firstWhere((d) => d['tag'] == 'remote-dns')['address'],
        'https://dns.google/dns-query',
      );
      expect(servers.any((d) => d['address'] == '127.0.0.1'), isFalse);
      expect(inboundRule(c, 'remote-dns')['balancerTag'], 'all-proxies');
      final rules = rulesOf(c);
      expect(
        rules.any(
          (r) =>
              r['network'] == 'udp' &&
              r['port'] == null &&
              r['outboundTag'] == 'block',
        ),
        isTrue,
      );
      expect(rules.last, containsPair('outboundTag', 'exit'));
      expect(rules.last['network'], isNull);
      dump('worker_tor', c);
    });

    test('over WARP: UDP is blocked too (Tor has no UDP)', () async {
      final kp = X25519KeyPair.generate();
      final c = (await builder(
        {
          'warp': {
            'account': WarpAccount(
              privateKey: kp.privateKey,
              publicKey: 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=',
              ipv6: '2606:4700:110:8a36:df92:102a:9602:fa18/128',
              reserved: const [1, 2, 3],
            ).toJson(),
            'endpoints': ['162.159.192.2:2408'],
          },
        },
        {
          'exit': {'node': 'tor'},
        },
      ).build(ConnectionMode.warp)).config;
      expect(
        rulesOf(c)
            .any((r) => r['network'] == 'udp' && r['outboundTag'] == 'block'),
        isTrue,
      );
      expect(rulesOf(c).last['network'], isNull);
    });

    test('Tor type: no worker; the proxy is a socks outbound to Tor; UDP is blocked', () async {
      final b = await builder(everything, {
        'connection': {'type': 'tor', 'torBridge': 'obfs4'},
        'exit': {
          'node': 'psiphon',
          'region': 'DE',
        }, // the type always exits through Tor
      }).build(ConnectionMode.tor);
      final c = b.config;
      expect(outboundsOf(c, 'proxy').single['protocol'], 'socks');
      expect(outboundsOf(c, 'exit'), isEmpty);
      expect(
        (c['inbounds'] as List).cast<Map>().map((i) => i['tag']),
        isNot(contains('tor-in')),
      );
      expect(
        rulesOf(c)
            .any((r) => r['network'] == 'udp' && r['outboundTag'] == 'block'),
        isTrue,
      );
      expect(rulesOf(c).last, containsPair('outboundTag', 'proxy'));
      expect(rulesOf(c).last['network'], isNull);
      expect(c.containsKey('burstObservatory'), isFalse);
      dump('tor_type', c);
    });

    test('Custom bridges need bridges in Settings → Tor', () async {
      const device = {
        'connection': {'type': 'tor', 'torBridge': 'custom'},
      };
      expect(
        () => builder({}, device).build(ConnectionMode.tor),
        throwsStateError,
      );
      final c = await builder({
        'tor': {
          'bridges': ['obfs4 192.0.2.1:443 FP cert=abc iat-mode=0'],
        },
      }, device).build(ConnectionMode.tor);
    });

    test('unknown bridge falls back to Snowflake', () {
      expect(
        DeviceSettings.fromJson({
          'connection': {'torBridge': 'webtunnel'},
        }).torBridge,
        'snowflake',
      );
    });
  });

  test(
    'serverless config routes tls/http/quic to fragment and noise',
    () async {
      final c = (await builder(
        everything,
        everythingDevice,
      ).build(ConnectionMode.serverless)).config;
      final tags = (c['outbounds'] as List).map((o) => o['tag']).toList();
      expect(tags, containsAll(['proxy', 'http-fragment', 'udp-noise']));
      expect((c['routing']['rules'] as List).last['outboundTag'], 'direct');
      dump('serverless_fragment', c);
    },
  );

  test(
    'serverless races Google and Cloudflare DoH as its remote DNS',
    () async {
      final dns =
          (await builder({}).build(ConnectionMode.serverless)).config['dns']
              as Map;
      expect(dns['enableParallelQuery'], isTrue);
      final remote = (dns['servers'] as List).whereType<Map>().where(
        (s) => s['tag'] == 'remote-dns',
      );
      expect(remote.map((s) => s['address']), [
        'https://dns.google/dns-query',
        'https://cloudflare-dns.com/dns-query',
      ]);
      expect(dns['hosts']['dns.google'], ['8.8.8.8', '8.8.4.4']);
      expect(dns['hosts']['cloudflare-dns.com'], ['cloudflare.com']);
      // Other types keep serial queries.
      final worker =
          (await builder({}).build(ConnectionMode.worker)).config['dns'] as Map;
      expect(worker['enableParallelQuery'], isNull);
    },
  );

  group('Domain Fronting', () {
    const fronting = {
      'connection': {'serverlessMode': 'domainFronting'},
    };

    test(
      "is patterniha's v23 config with the app's inbounds, log and stats",
      () async {
        final b = await builder(
          everything,
          fronting,
        ).build(ConnectionMode.serverless);
        final c = b.config;
        final original = jsonDecode(domainFrontingV23) as Map<String, dynamic>;
        expect(c['routing'], original['routing']);
        expect(c['dns'], original['dns']);
        expect(c['outbounds'], original['outbounds']);

        final inbounds = (c['inbounds'] as List).cast<Map>();
        expect(inbounds.map((i) => i['tag']), [
          'tun',
          'mixed-in',
          'tls-decrypt-h11',
          'tls-decrypt-h211',
        ]);
        final mixed = (original['inbounds'] as List).cast<Map>().firstWhere(
          (i) => i['tag'] == 'mixed-in',
        );
        expect(
          inbounds[0]['sniffing'],
          mixed['sniffing'],
        ); // fakedns + tls, routeOnly false
        expect(inbounds[1]['sniffing'], mixed['sniffing']);
        expect(inbounds[1]['streamSettings'], mixed['streamSettings']);
        expect(inbounds[1]['port'], XrayConfigBuilder.localProxyPort);
        for (final decrypt in inbounds.skip(2)) {
          final cert =
              decrypt['streamSettings']['tlsSettings']['certificates'].single
                  as Map;
          expect(cert, {
            'usage': 'issue',
            'certificateFile': MitmCa.certFile,
            'keyFile': MitmCa.keyFile,
          });
        }
        expect(c['policy']['levels'], original['policy']['levels']);
        expect(c['policy']['system'], {
          'statsOutboundUplink': true,
          'statsOutboundDownlink': true,
        });
        expect(c['stats'], isEmpty);
        dump('serverless_domain_fronting', c);
      },
    );

    test("Psiphon / Tor exit: the regular config, only the exit's own connections fronted", () async {
      final original = jsonDecode(domainFrontingV23) as Map<String, dynamic>;
      final v23Rules = (original['routing']['rules'] as List).cast<Map>();
      for (final exit in ['psiphon', 'tor']) {
        final b = await builder({}, {
          'connection': {'serverlessMode': 'domainFronting'},
          'exit': {'node': exit},
        }).build(ConnectionMode.serverless);
        final c = b.config;

        final inbounds = (c['inbounds'] as List).cast<Map>();
        expect(inbounds.map((i) => i['tag']), [
          'tun',
          'mixed-in',
          '$exit-in',
          'tls-decrypt-h11',
          'tls-decrypt-h211',
        ]);
        // Your traffic: the regular sniffing, with FakeDNS (always on in Serverless).
        expect(inbounds[0]['sniffing'], {
          'enabled': true,
          'destOverride': ['http', 'tls', 'fakedns'],
          'routeOnly': true,
        });
        expect(inbounds[2]['sniffing'], {
          'enabled': true,
          'destOverride': ['tls'],
          'routeOnly': true,
        });
        expect(inbounds.skip(3), (original['inbounds'] as List).skip(1));

        final outbounds = (c['outbounds'] as List).cast<Map>();
        expect(outbounds.first['tag'], 'exit');
        expect(outbounds.map((o) => o['tag']), [
          'exit',
          'redirect-out-h11',
          'redirect-out-h211',
          'tls-repack-dns',
          'tls-repack-google',
          'tls-repack-fastly',
          'tls-repack-meta',
          'dns-out',
          'direct',
          'block',
        ]);
        for (final o in outbounds.where(
          (o) => (o['tag'] as String).startsWith('tls-repack-'),
        )) {
          expect(
            o,
            (original['outbounds'] as List).firstWhere(
              (v) => v['tag'] == o['tag'],
            ),
          );
        }

        final rules = (c['routing']['rules'] as List)
            .cast<Map>()
            .map((r) => {...r}..remove('type'))
            .toList();
        expect(c['routing']['domainStrategy'], 'IPIfNonMatch');
        final redirects = v23Rules
            .where(
              (r) => (r['outboundTag'] as String).startsWith('redirect-out-'),
            )
            .toList();
        final decrypted = v23Rules
            .where(
              (r) =>
                  (r['inboundTag'] as List?)?.any(
                    (t) => (t as String).startsWith('tls-decrypt-'),
                  ) ??
                  false,
            )
            .toList();
        expect(redirects, hasLength(3));
        expect(decrypted, hasLength(7));
        const yours = ['tun', 'mixed-in'];
        expect(rules, [
          for (final r in redirects)
            {
              'inboundTag': ['$exit-in'],
              ...r,
            },
          ...decrypted,
          {
            'inboundTag': ['no-filter-dns'],
            'outboundTag': 'tls-repack-dns',
          },
          {
            'inboundTag': ['$exit-in'],
            'outboundTag': 'direct',
          },
          {'inboundTag': yours, 'port': 53, 'outboundTag': 'dns-out'},
          {
            'inboundTag': yours,
            'domain': ['geosite:private'],
            'outboundTag': 'direct',
          },
          {
            'inboundTag': yours,
            'ip': ['geoip:private'],
            'outboundTag': 'direct',
          },
          if (exit == 'tor')
            {'inboundTag': yours, 'network': 'udp', 'outboundTag': 'block'},
          {
            'inboundTag': yours,
            'ip': ['0.0.0.0/0', '::/0'],
            'outboundTag': 'exit',
          },
        ]);

        // Rules from the routing settings are limited to your traffic too.
        final withSettings = (await builder(
          {
            'routing': {
              'bypass': {
                'presets': {'iran': true},
              },
            },
          },
          {
            'connection': {'serverlessMode': 'domainFronting'},
            'exit': {'node': exit},
          },
        ).build(ConnectionMode.serverless)).config;
        final iran = (withSettings['routing']['rules'] as List)
            .cast<Map>()
            .where(
              (r) =>
                  ((r['domain'] ?? r['ip']) as List?)?.any(
                    (v) => '$v'.endsWith(':ir'),
                  ) ??
                  false,
            );
        expect(iran, hasLength(2));
        expect(iran.every((r) => '${r['inboundTag']}' == '$yours'), isTrue);
        // Your apps' queries for bypass domains: dns-out hands them to the DNS module (local DNS).
        final dnsOut = (withSettings['outbounds'] as List)
            .cast<Map>()
            .firstWhere((o) => o['tag'] == 'dns-out');
        expect(dnsOut['settings']['rules'], [
          {
            'action': 'hijack',
            'qType': '1,28',
            'domain': ['geosite:ir'],
          },
          {'action': 'direct'},
        ]);
        final withSettingsServers = (withSettings['dns']['servers'] as List)
            .cast<Map>();
        final local = withSettingsServers.where(
          (s) => s['address'] == 'localhost',
        );
        // FakeDNS, always on as in v23, for the domains dns-out hands to the DNS module.
        expect(withSettingsServers.first, {
          'address': 'fakedns',
          'domains': ['geosite:ir', 'full:github.githubassets.com'],
          'skipFallback': false,
        });
        expect(
          (withSettings['inbounds'] as List).first['sniffing']['destOverride'],
          contains('fakedns'),
        );
        expect(local.expand((s) => s['domains'] as List), [
          'geosite:ir',
          'full:github.githubassets.com',
        ]);

        final dns = c['dns'] as Map;
        final servers = (dns['servers'] as List).cast<Map>();
        expect(servers.firstWhere((s) => s['tag'] != null), {
          'address': 'h2c://1.1.1.1/dns-query',
          'tag': 'no-filter-dns',
          'timeoutMs': 6000,
        });
        expect(dns['tag'], isNull);
        expect(
          servers.where((s) => s['tag'] == null).map((s) => s['address']),
          everyElement(isIn(['localhost', 'fakedns'])),
        );
        // remote-dns: your apps' queries go straight to the exit's DNS.
        final appDns = (c['outbounds'] as List).cast<Map>().firstWhere(
          (o) => o['tag'] == 'dns-out',
        );
        expect(appDns['settings'], {
          'network': 'udp',
          'address': '127.0.0.1',
          'port': XrayConfigBuilder.exitDnsPort,
          'rules': [
            {'action': 'direct'},
          ],
        });
        expect(
          dns['hosts']['dns.redirect'],
          original['dns']['hosts']['dns.redirect'],
        );
        expect(dns['hosts']['fastly.redirect'], 'github.githubassets.com');
        expect(
          servers.any(
            (s) =>
                (s['domains'] as List?)?.contains(
                  'full:github.githubassets.com',
                ) ??
                false,
          ),
          isTrue,
        );
        dump('serverless_domain_fronting_$exit', c);
      }

      // Direct: the original as is.
      final direct = (await builder(
        {},
        fronting,
      ).build(ConnectionMode.serverless)).config;
      expect(direct['routing'], original['routing']);
    });

    test('Psiphon exit: limited to fronted meek, the protocol the fronting can carry', () {
      DeviceSettings device(String mode, String exit) =>
          DeviceSettings.fromJson({
            'connection': {'serverlessMode': mode},
            'exit': {'node': exit},
          });
      expect(
        XrayConfigBuilder.psiphonConfigFor(
          ConnectionMode.serverless,
          device('domainFronting', 'psiphon'),
        ),
        {
          'LimitTunnelProtocols': ['FRONTED-MEEK-OSSH'],
        },
      );
      expect(
        XrayConfigBuilder.psiphonConfigFor(
          ConnectionMode.serverless,
          device('fragment', 'psiphon'),
        ),
        isNull,
      );
      expect(
        XrayConfigBuilder.psiphonConfigFor(
          ConnectionMode.worker,
          device('domainFronting', 'psiphon'),
        ),
        isNull,
      );
      // The Psiphon type: no limit, Psiphon picks (Conduit too, where its tactics enable it).
      expect(
        XrayConfigBuilder.psiphonConfigFor(
          ConnectionMode.psiphon,
          device('domainFronting', 'psiphon'),
        ),
        isNull,
      );
    });

    test('proxy mode drops the TUN inbound', () async {
      final c = (await builder({}, {
        ...fronting,
        'appMode': 'proxy',
      }).build(ConnectionMode.serverless)).config;
      expect((c['inbounds'] as List).map((i) => i['tag']), [
        'mixed-in',
        'tls-decrypt-h11',
        'tls-decrypt-h211',
      ]);
    });
  });

  test(
    'BitTorrent bypass goes direct by protocol, before the UDP block',
    () async {
      List<Map> rulesOf(Map c) => (c['routing']['rules'] as List).cast<Map>();
      final tor = {
        'connection': {'type': 'tor'},
      };
      final off = (await builder({}, tor).build(ConnectionMode.tor)).config;
      expect(
        rulesOf(
          off,
        ).any((r) => (r['protocol'] as List?)?.contains('bittorrent') ?? false),
        isFalse,
      );

      final c = (await builder({
        'routing': {
          'bypass': {
            'presets': {'bittorrent': true},
          },
        },
      }, tor).build(ConnectionMode.tor)).config;
      final rules = rulesOf(c);
      final bt = rules.indexWhere(
        (r) => (r['protocol'] as List?)?.contains('bittorrent') ?? false,
      );
      expect(rules[bt], containsPair('outboundTag', 'direct'));
      expect(rules[bt]['network'], isNull);
      expect(
        bt,
        lessThan(
          rules.indexWhere(
            (r) => r['network'] == 'udp' && r['outboundTag'] == 'block',
          ),
        ),
      );
    },
  );

  test(
    'sanction rules get their own direct rule, apart from bypass rules',
    () async {
      // Anti-sanction applies with WARP / Serverless (not VLESS, see below).
      final c = (await builder(everything).build(ConnectionMode.serverless))
          .config;
      final rules = (c['routing']['rules'] as List).cast<Map>();
      final bypass = rules.firstWhere(
        (r) => (r['domain'] as List?)?.contains('geosite:ir') ?? false,
      );
      final sanction = rules.firstWhere(
        (r) => (r['domain'] as List?)?.contains('geosite:openai') ?? false,
      );
      expect(identical(bypass, sanction), isFalse);
      expect(
        bypass['domain'],
        containsAll(['geosite:cn', 'domain:example.ir']),
      );
      expect(bypass['domain'], isNot(contains('geosite:microsoft')));
      expect(
        bypass['domain'],
        isNot(contains('domain:sanctioned.example.com')),
      );
      expect(
        sanction['domain'],
        containsAll(['geosite:microsoft', 'domain:sanctioned.example.com']),
      );
      expect(sanction['outboundTag'], 'direct');
      final block = rules.firstWhere(
        (r) =>
            (r['domain'] as List?)?.contains('geosite:category-ads-all') ??
            false,
      );
      expect(
        block['domain'],
        containsAll(['geosite:malware', 'domain:ads.example.com']),
      );
      expect(block['outboundTag'], 'block');
    },
  );

  test('remote DNS host: a public one\'s built-in IPs, any other looked up with the local DNS', () async {
    Future<Map<String, dynamic>> dns(
      Map<String, dynamic> remoteDns, {
      bool ipv6 = false,
    }) async {
      final c = (await builder({
        'general': {'enableIpv6': ipv6},
        'vless': {'remoteDns': remoteDns},
      }).build(ConnectionMode.worker)).config;
      return c['dns'] as Map<String, dynamic>;
    }

    Future<Map> hosts(
      Map<String, dynamic> remoteDns, {
      bool ipv6 = false,
    }) async => (await dns(remoteDns, ipv6: ipv6))['hosts'] as Map? ?? const {};

    // Public: its own IPs (IPv6 ones with IPv6 on).
    expect(
      (await hosts({'server': 'https://dns.google/dns-query'}))['dns.google'],
      ['8.8.8.8', '8.8.4.4'],
    );
    expect(
      (await hosts({
        'server': 'https://dns.google/dns-query',
      }, ipv6: true))['dns.google'],
      publicDnsIps['dns.google'],
    );
    // Any other domain: resolved by Xray with the local DNS server, not pinned in hosts.
    final other = await dns({'server': 'https://dns.example.com/dns-query'});
    expect(
      (other['hosts'] as Map? ?? const {}).containsKey('dns.example.com'),
      isFalse,
    );
    final local = (other['servers'] as List).whereType<Map>().firstWhere(
      (s) =>
          s['address'] == '8.8.8.8' &&
          ((s['domains'] as List?)?.contains('full:dns.example.com') ?? false),
    );
    expect(local['skipFallback'], isTrue);
    expect(
      await hosts({'server': 'https://8.8.8.8/dns-query'}),
      isNot(contains('8.8.8.8')),
    ); // IP: nothing to map
  });

  test(
    'anti-sanction DoH with a domain: resolved with the local DNS',
    () async {
      final c = (await builder({
        'general': {'antiSanctionDns': 'https://dns.test/dns-query'},
        'routing': {
          'sanctionBypass': {
            'presets': {'openAi': true},
          },
        },
      }).build(ConnectionMode.serverless)).config;
      final servers = (c['dns']['servers'] as List).whereType<Map>();
      final sanction = servers.firstWhere(
        (s) => (s['domains'] as List?)?.contains('geosite:openai') ?? false,
      );
      expect(sanction['address'], 'https://dns.test/dns-query');
      expect(
        (c['dns']['hosts'] as Map? ?? const {}).containsKey('dns.test'),
        isFalse,
      );
      // The local DNS entry lists it (Serverless's FakeDNS entry does too, as in BPB). Serverless's
      // local DNS is always the system's resolver.
      final local = servers.where(
        (s) => s['address'] == 'localhost' && s['expectIPs'] == null,
      );
      expect(
        local.any(
          (s) => (s['domains'] as List?)?.contains('full:dns.test') ?? false,
        ),
        isTrue,
      );
      dump('anti_sanction_doh', c);
    },
  );

  test('anti-sanction only with WARP / Serverless, and not with a Psiphon / Tor exit', () async {
    const profile = {
      'routing': {
        'sanctionBypass': {
          'presets': {'openAi': true},
        },
      },
    };
    Future<bool> hasSanction(
      ConnectionMode mode, [
      Map<String, dynamic> device = const {},
    ]) async {
      final c = (await builder(profile, device).build(mode)).config;
      final dns = (c['dns']['servers'] as List).whereType<Map>();
      final rules = (c['routing']['rules'] as List).cast<Map>();
      final inDns = dns.any(
        (s) => (s['domains'] as List?)?.contains('geosite:openai') ?? false,
      );
      final inRules = rules.any(
        (r) => (r['domain'] as List?)?.contains('geosite:openai') ?? false,
      );
      expect(inDns, inRules);
      return inDns;
    }

    expect(await hasSanction(ConnectionMode.serverless), isTrue);
    expect(await hasSanction(ConnectionMode.worker), isFalse);
    expect(await hasSanction(ConnectionMode.psiphon), isFalse);
    expect(
      await hasSanction(ConnectionMode.serverless, {
        'exit': {'node': 'tor'},
      }),
      isFalse,
    );
  });

  test('IPv6 off: no IPv6 clean IPs', () async {
    Future<Set<String>> addresses(bool ipv6) async {
      final c = (await builder({
        'general': {'enableIpv6': ipv6},
        'vless': {
          'cleanIps': ['104.16.1.1', '2606:4700::1', '[2606:4700::2]'],
        },
      }).build(ConnectionMode.worker)).config;
      return outboundsOf(
        c,
        'proxy-',
      ).map((o) => '${o['settings']['address']}').toSet();
    }

    final off = await addresses(false);
    expect(off, contains('104.16.1.1'));
    expect(off.where((a) => a.contains(':')), isEmpty);
    expect(
      await addresses(true),
      containsAll(['2606:4700::1', '[2606:4700::2]']),
    );
  });

  group('WARP', () {
    Map<String, dynamic> account() {
      final kp = X25519KeyPair.generate();
      return WarpAccount(
        privateKey: kp.privateKey,
        publicKey: 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=',
        ipv6: '2606:4700:110:8a36:df92:102a:9602:fa18/128',
        reserved: const [1, 2, 3],
      ).toJson();
    }

    final warpSettings = {
      ...everything,
      'warp': {
        'account': account(),
        'endpoints': [
          'engage.cloudflareclient.com:2408',
          '162.159.192.10:878',
          '[2606:4700:d0::a29f:c001]:2408',
        ],
      },
    };
    const chainLink =
        'vless://11111111-2222-4333-8444-555555555555@1.2.3.4:443?security=reality&type=tcp'
        '&sni=www.microsoft.com&fp=chrome&pbk=SUtl6NDexiBFgmw5fpuB6ESqUwSsC4dHrbRmBAdjgD8&sid=0123'
        '&flow=xtls-rprx-vision#r';

    test('needs a registered account', () async {
      expect(() => builder({}).build(ConnectionMode.warp), throwsStateError);
    });

    test(
      'every balancer falls back to a proxy until the first pings are in',
      () async {
        Map balancerOf(Map<String, dynamic> c) =>
            (c['routing']['balancers'] as List).single as Map;
        // Without it, a chain's first dial would take the default route: the chain (exit) itself.
        for (final variant in [
          ConnectionVariant.normal,
          ConnectionVariant.obfuscated,
        ]) {
          final warp = (await builder({
            ...warpSettings,
            ...chains(chainLink),
          }, chainExit).build(ConnectionMode.warp, variant: variant)).config;
          expect(
            balancerOf(warp)['fallbackTag'],
            'proxy-1',
            reason: '$variant',
          );
        }
        expect(ConnectionVariant.of(ConnectionMode.worker), [
          ConnectionVariant.normal,
          ConnectionVariant.fragment,
          ConnectionVariant.browserDialer,
        ]);
        expect(
          ConnectionVariant.of(ConnectionMode.worker)
              .map((v) => v.label(ConnectionMode.worker)),
          ['Normal', 'Fragment', 'Browser Dialer'],
        );
        expect(
          ConnectionVariant.of(ConnectionMode.warp)
              .map((v) => v.label(ConnectionMode.warp)),
          ['Normal', 'Obfuscated'],
        );
        final bestPing = (await builder({}).build(ConnectionMode.worker))
            .config;
        expect(balancerOf(bestPing)['fallbackTag'], 'proxy-2'); // BPB's
      },
    );

    test('best ping balances wireguard outbounds and allows UDP', () async {
      final c = (await builder(warpSettings).build(ConnectionMode.warp)).config;
      final proxies = outboundsOf(c, 'proxy-');
      expect(proxies.length, 3);
      expect(proxies.every((o) => o['protocol'] == 'wireguard'), isTrue);
      expect(proxies.first['settings']['reserved'], [1, 2, 3]);
      expect(proxies.first['settings']['address'], [
        '172.16.0.2/32',
        '2606:4700:110:8a36:df92:102a:9602:fa18/128',
      ]);
      expect(outboundsOf(c, 'exit'), isEmpty);
      final rules = (c['routing']['rules'] as List).cast<Map>();
      expect(
        rules.any(
          (r) =>
              r['network'] == 'udp' &&
              r['port'] == null &&
              r['outboundTag'] == 'block',
        ),
        isFalse,
      );
      expect(rules.last['network'], isNull);
      expect(
        c['dns']['servers'].firstWhere(
          (d) => d is Map && d['tag'] == 'remote-dns',
        )['address'],
        '1.1.1.1',
      );
      expect(c['dns']['queryStrategy'], 'UseIP'); // IPv6 is on in `everything`
      dump('warp_best', c);
    });

    test('IPv6 off: no IPv6 endpoints; an error if none are left', () async {
      final c = (await builder({
        'warp': warpSettings['warp'],
      }).build(ConnectionMode.warp)).config;
      expect(
        outboundsOf(
          c,
          'proxy-',
        ).map((o) => o['settings']['peers'][0]['endpoint']),
        ['engage.cloudflareclient.com:2408', '162.159.192.10:878'],
      );
      expect(
        () => builder({
          'warp': {
            ...warpSettings['warp'] as Map,
            'endpoints': ['[2606:4700:d0::a29f:c001]:2408'],
          },
        }).build(ConnectionMode.warp),
        throwsStateError,
      );
    });

    test('reserved bytes can be switched off', () async {
      final c = (await builder({
        'warp': {...warpSettings['warp'] as Map, 'enableReservedBytes': false},
      }).build(ConnectionMode.warp)).config;
      expect(outboundsOf(c, 'proxy-').first['settings']['reserved'], [0, 0, 0]);
    });

    test('sanction rules only with the Default exit node', () async {
      bool hasSanction(Map<String, dynamic> c) =>
          (c['routing']['rules'] as List).cast<Map>().any(
            (r) =>
                (r['domain'] as List?)?.contains(
                  'domain:sanctioned.example.com',
                ) ??
                false,
          );
      final profile = {
        ...warpSettings,
        ...chains(chainLink),
        'routing': everything['routing'],
      };
      expect(
        hasSanction((await builder(profile).build(ConnectionMode.warp)).config),
        isTrue,
      );
      expect(
        hasSanction(
          (await builder(profile, chainExit).build(ConnectionMode.warp)).config,
        ),
        isFalse,
      );
    });

    test('chain proxy is dialed through WARP', () async {
      final c = (await builder({
        ...warpSettings,
        ...chains(chainLink),
        'general': {'enableIpv6': true}, // keeps the IPv6 endpoint
      }, chainExit).build(ConnectionMode.warp)).config;
      expect(chainOf(c)!['protocol'], 'vless');
      expect(outboundsOf(c, 'proxy-').length, 3);
      expect((c['routing']['balancers'] as List).map((x) => x['tag']), [
        'all-proxies',
      ]);
      final rules = (c['routing']['rules'] as List).cast<Map>();
      expect(rules.firstWhere((r) => r['balancerTag'] != null)['inboundTag'], [
        'chain-in',
        'remote-dns',
      ]);
      expect(rules.last['outboundTag'], 'exit');
      dump('warp_chain_best', c);
    });

    test(
      'a WireGuard chain proxy is dialed through WARP, not through the worker',
      () async {
        final link = wireGuardConfToChain(wgConf).link;
        final c = (await builder({
          ...warpSettings,
          ...chains(link),
        }, chainExit).build(ConnectionMode.warp)).config;
        final chain = chainOf(c)!;
        expect(chain['protocol'], 'wireguard');
        expect(chain['settings'], {
          'secretKey': 'cHJpdmF0ZWtleXByaXZhdGVrZXlwcml2YXRla2V5MDE=',
          'address': ['10.0.0.2/32', 'fd00::2/128'],
          'peers': [
            {
              'publicKey': 'cHVibGlja2V5cHVibGlja2V5cHVibGlja2V5cHViMDE+',
              'preSharedKey': 'cHJlc2hhcmVka2V5cHJlc2hhcmVka2V5cHJlc2hhcjE=',
              'endpoint': 'vpn.example.com:51820',
              'keepAlive': 25,
              'allowedIPs': ['0.0.0.0/0', '::/0'],
            },
          ],
          'mtu': 1380,
          'remoteDNS': ['10.0.0.1', 'fd00::1'], // IPs only
        });
        dump('warp_chain_wireguard', c);
        // A config without MTU leaves it to Xray's default.
        final noMtu = wireGuardConfToChain(
          wgConf.replaceFirst('MTU = 1380\n', ''),
        ).link;
        final d = (await builder({
          ...warpSettings,
          ...chains(noMtu),
        }, chainExit).build(ConnectionMode.warp)).config;
        expect((chainOf(d)!['settings'] as Map).containsKey('mtu'), isFalse);
        // The worker relays TCP only.
        final w = (await builder(
          chains(link),
          chainExit,
        ).build(ConnectionMode.worker)).config;
        expect(chainOf(w), isNull);
      },
    );

    test('a Hysteria2 chain proxy is dialed through WARP, not through the worker', () async {
      // OpenSSL's format: colons between the bytes.
      const pin =
          'E3:B0:C4:42:98:FC:1C:14:9A:FB:F4:C8:99:6F:B9:24:27:AE:41:E4:64:9B:93:4C:A4:95:99:1B:78:52:B8:55';
      const link =
          'hysteria2://secret@hy.example.com:8443?sni=sni.example.com&obfs=salamander&obfs-password=mask'
          '&pinSHA256=$pin&mport=20000-30000,443#hy2';
      final c = (await builder({
        ...warpSettings,
        ...chains(link),
      }, chainExit).build(ConnectionMode.warp)).config;
      final chain = chainOf(c)!;
      expect(chain['protocol'], 'hysteria');
      expect(chain['settings'], {
        'version': 2,
        'address': 'hy.example.com',
        'port': 8443,
      });
      expect(chain['streamSettings'], {
        'network': 'hysteria',
        'hysteriaSettings': {'version': 2, 'auth': 'secret'},
        'security': 'tls',
        'tlsSettings': {
          'serverName': 'sni.example.com',
          'pinnedPeerCertSha256': pin,
        },
        'finalmask': {
          'udp': [
            // Last: Xray reverses the list, and udphop must come first there.
            {
              'type': 'salamander',
              'settings': {'password': 'mask'},
            },
            {
              'type': 'udphop',
              'settings': {
                'mode': 'intervalRemote,intervalLocal',
                'remotePorts': '20000-30000,443',
              },
            },
          ],
        },
        'sockopt': {'dialerProxy': 'exit-dialer'},
      });
      dump('warp_chain_hysteria2', c);
      final w = (await builder(
        chains(link),
        chainExit,
      ).build(ConnectionMode.worker)).config;
      expect(chainOf(w), isNull);
    });

    test(
      'UDP noise reset interval: 30-60 by default, else from the profile',
      () async {
        Future<Object?> reset(Map<String, dynamic> extra) async {
          final c = (await builder({...warpSettings, ...extra}).build(
            ConnectionMode.warp,
            variant: ConnectionVariant.obfuscated,
          )).config;
          return outboundsOf(
            c,
            'proxy-',
          ).first['streamSettings']['finalmask']['udp'][0]['settings']['reset'];
        }

        expect(await reset({}), '30-60');
        expect(
          await reset({
            'udpNoiseReset': {'min': 5, 'max': 15},
          }),
          '5-15',
        );
      },
    );

    test('Obfuscation adds UDP noise to the WARP outbounds', () async {
      final c = (await builder(warpSettings).build(
        ConnectionMode.warp,
        variant: ConnectionVariant.obfuscated,
      )).config;
      final proxies = outboundsOf(c, 'proxy-');
      expect(
        proxies.every(
          (o) => o['streamSettings']['finalmask']['udp'][0]['type'] == 'noise',
        ),
        isTrue,
      );
      final noise =
          proxies.first['streamSettings']['finalmask']['udp'][0]['settings']['noise']
              as List;
      expect(noise.length, 5); // the default: random 50-100 bytes, 5 times
      expect(noise.first, {
        'rand': '50-100',
        'randRange': '0-255',
        'delay': '1-5',
      });
      dump('warp_pro_best', c);
    });

    test('WARP obfuscation passes every noise type through to Xray', () async {
      final noises = [
        for (final exp in noiseExpPresets.values)
          {'type': 'exp', 'packet': exp, 'count': 1, 'delay': r(1, 5)},
        {'type': 'rand', 'size': r(50, 100), 'count': 2, 'delay': r(1, 5)},
        {
          'type': 'array',
          'bytes': [1, 10, 128],
          'count': 1,
          'delay': r(1),
        },
        {'type': 'hex', 'packet': '1a2b', 'count': 1, 'delay': r(1)},
      ];
      final c = (await builder({...warpSettings, 'udpNoises': noises}).build(
        ConnectionMode.warp,
        variant: ConnectionVariant.obfuscated,
      )).config;
      final noise =
          outboundsOf(
                c,
                'proxy-',
              ).first['streamSettings']['finalmask']['udp'][0]['settings']['noise']
              as List;
      expect(noise.length, noiseExpPresets.length + 4);
      expect(noise.first, {
        'type': 'exp',
        'packet': noiseExpPresets.values.first,
        'delay': '1-5',
      });
      expect(noise[noiseExpPresets.length], {
        'rand': '50-100',
        'randRange': '0-255',
        'delay': '1-5',
      });
      expect(noise[noiseExpPresets.length + 2], {
        'type': 'array',
        'packet': [1, 10, 128],
        'delay': '1',
      });
      expect(noise.last, {'type': 'hex', 'packet': '1a2b', 'delay': '1'});
      dump('warp_pro_noise_types', c);
    });
  });

  test('ECH fetches its config from the ECH DNS (IPv4 or DoH with an IPv4 host), dialed directly', () async {
    Future<Map> tls(Map<String, dynamic> ech) async {
      final c = (await builder({
        'vless': {
          'ech': {'enabled': true, ...ech},
        },
      }).build(ConnectionMode.worker)).config;
      return (c['outbounds'] as List).first['streamSettings']['tlsSettings']
          as Map;
    }

    final byDefault = await tls({});
    expect(byDefault['echConfigList'], 'cloudflare-ech.com+udp://8.8.8.8');
    expect(byDefault['echSockopt'], {'dialerProxy': 'direct'});

    expect(
      (await tls({'serverName': 'legacy.example'}))['echConfigList'],
      'cloudflare-ech.com+udp://8.8.8.8',
    );
    expect(
      (await tls({'dns': '1.1.1.1'}))['echConfigList'],
      'cloudflare-ech.com+udp://1.1.1.1',
    );
    expect(
      (await tls({'dns': '2001:4860:4860::8888'}))['echConfigList'],
      'cloudflare-ech.com+udp://[2001:4860:4860::8888]',
    );
    expect(
      (await tls({
        'dns': 'https://[2001:4860:4860::8888]/dns-query',
      }))['echConfigList'],
      'cloudflare-ech.com+https://[2001:4860:4860::8888]/dns-query',
    );
    // DoH with an IPv4 host, as in BPB: passed as is.
    expect(
      (await tls({'dns': 'https://1.1.1.1/dns-query'}))['echConfigList'],
      'cloudflare-ech.com+https://1.1.1.1/dns-query',
    );
    expect(
      (await tls({'dns': 'https://1.1.1.1/dns-query'}))['echConfigList'],
      'cloudflare-ech.com+https://1.1.1.1/dns-query',
    );

    // Fragment configs never use ECH.
    final f = (await builder(
      {
        'vless': {
          'ech': {'enabled': true},
        },
      },
    ).build(ConnectionMode.worker, variant: ConnectionVariant.fragment)).config;
    final fTls =
        (f['outbounds'] as List).first['streamSettings']['tlsSettings'] as Map;
    expect(fTls.containsKey('echSockopt'), isFalse);
  });

  test('Browser Dialer: one outbound to the custom domain, no balancer, no TLS extras', () async {
    final c = (await builder(everything).build(
      ConnectionMode.worker,
      variant: ConnectionVariant.browserDialer,
    )).config;
    final proxy = (c['outbounds'] as List).cast<Map>().singleWhere(
      (o) => (o['tag'] as String).startsWith('proxy'),
    );
    expect(proxy['tag'], 'proxy');
    expect(proxy['settings']['address'], worker.customDomain);
    expect(proxy['settings']['port'], 443);
    final stream = proxy['streamSettings'] as Map;
    expect(stream['wsSettings']['host'], worker.customDomain);
    expect(stream['tlsSettings'], {
      'serverName': worker.customDomain,
      'alpn': ['http/1.1'],
    });
    expect(stream.containsKey('finalmask'), isFalse);
    expect(c['routing'].containsKey('balancers'), isFalse);
    expect(
      ConnectionVariant.of(ConnectionMode.warp),
      isNot(contains(ConnectionVariant.browserDialer)),
    );
    dump('browser_dialer', c);
  });

  test('Serverless uses its own fragments and UDP noises, not the Worker / WARP ones', () async {
    final c = (await builder({
      ...everything,
      'serverless': {
        'fragments': [
          {
            'packets': 'tlsHello',
            'lengths': [r(7, 9)],
          },
        ],
        'udpNoises': [
          {'type': 'rand', 'size': r(11, 22), 'count': 1},
        ],
        'udpNoiseReset': r(3, 4),
      },
    }).build(ConnectionMode.serverless)).config;
    final mask =
        outboundsOf(c, 'proxy').single['streamSettings']['finalmask'] as Map;
    expect((mask['tcp'] as List).single['settings']['lengths'], ['7-9']);
    final noise =
        outboundsOf(
              c,
              'udp-noise',
            ).single['streamSettings']['finalmask']['udp'].single['settings']
            as Map;
    expect(noise['reset'], '3-4');
    expect((noise['noise'] as List).single['rand'], '11-22');
  });

  test(
    'Fragment: uses configured fragments without generated presets',
    () async {
      final c = (await builder(everything).build(
        ConnectionMode.worker,
        variant: ConnectionVariant.fragment,
      )).config;
      final proxies = outboundsOf(c, 'proxy-');
      expect(proxies, isNotEmpty);
      for (final proxy in proxies) {
        final masks = proxy['streamSettings']['finalmask']['tcp'] as List;
        expect(masks.length, 2);
        expect(masks[0]['settings'], {
          'packets': 'tlshello',
          'lengths': ['3-5', '6-8', '10-20'],
          'delays': ['10-20'],
          'maxSplit': '3-6',
        });
        expect(masks[1]['settings']['lengths'], ['100-200']);
      }
      dump('worker_fragment', c);
    },
  );

  test(
    'upstream proxy is an extra TLS server, not used with fragment',
    () async {
      final b = builder({
        'vless': {
          'upstreamProxy': 'relay.example.org:8443',
          'ports': [443],
        },
      });
      final c = (await b.build(ConnectionMode.worker)).config;
      final relays = outboundsOf(
        c,
        'proxy-',
      ).where((o) => o['settings']['address'] == 'relay.example.org').toList();
      expect(relays.length, 1); // only one relay outbound, not one per port
      expect(relays.last['settings']['port'], 8443);
      final stream = relays.last['streamSettings'] as Map;
      expect(
        stream['security'],
        'tls',
      ); // always TLS even on a non-Cloudflare port
      expect(worker.domains, contains(stream['wsSettings']['host']));
      dump('upstream_best', c);

      final frag = (await b.build(
        ConnectionMode.worker,
        variant: ConnectionVariant.fragment,
      )).config;
      expect(
        (frag['outbounds'] as List).any(
          (o) => o['settings']?['address'] == 'relay.example.org',
        ),
        isFalse,
      );
    },
  );

  test('Proxy mode has no TUN inbound, only the local mixed proxy', () async {
    final c = (await builder(everything, {
      'appMode': 'proxy',
    }).build(ConnectionMode.worker)).config;
    final inbounds = (c['inbounds'] as List).cast<Map>();
    expect(inbounds.map((i) => i['tag']), ['mixed-in']);
    expect(inbounds.single['port'], XrayConfigBuilder.localProxyPort);
    dump('worker_proxy_mode', c);
  });

  test('LAN sharing: 0.0.0.0, with password auth only when both login fields are set', () async {
    Future<Map> mixed(Map<String, dynamic> lan) async {
      final c = (await builder({}, {
        'lanSharing': lan,
      }).build(ConnectionMode.worker)).config;
      return (c['inbounds'] as List).firstWhere((i) => i['tag'] == 'mixed-in')
          as Map;
    }

    final login = await mixed({
      'enabled': true,
      'username': 'me',
      'password': 'p@ss',
    });
    expect(login['listen'], '0.0.0.0');
    expect(login['settings'], {
      'auth': 'password',
      'accounts': [
        {'user': 'me', 'pass': 'p@ss'},
      ],
      'udp': true,
    });
    const noauth = {'auth': 'noauth', 'udp': true};
    // LAN off: localhost only, no login even if one is saved.
    final off = await mixed({
      'enabled': false,
      'username': 'me',
      'password': 'x',
    });
    expect(off['listen'], '127.0.0.1');
    expect(off['settings'], noauth);
    // Only one field: no login (both are optional, but they go together).
    expect(
      (await mixed({'enabled': true, 'username': 'me'}))['settings'],
      noauth,
    );
  });

  test('proxy uri parser handles common formats', () {
    final vless = ProxyUri.parse(
      'vless://uuid-1@[2001:db8::1]:443?type=ws&path=%2Fa%3Fed%3D2560#My%20Server',
    );
    expect(vless.server, '2001:db8::1');
    expect(vless['path'], '/a?ed=2560');
    expect(vless.remark, 'My Server');
    final ss = ProxyUri.parse(
      'ss://${base64.encode(utf8.encode('aes-256-gcm:pw@host.example:8388'))}',
    );
    expect(ss['method'], 'aes-256-gcm');
    expect(ss.port, 8388);
    final socks = ProxyUri.parse(
      'socks://${base64.encode(utf8.encode('u:p'))}@h.example:1080',
    );
    expect(socks['user'], 'u');
    expect(socks['pass'], 'p');
  });
}
