import 'package:bpb/models/settings.dart';
import 'package:bpb/services/xray_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const vless = ChainProxy(
    id: 'a1',
    name: 'VLESS',
    link: 'vless://x@192.0.2.1:443#VLESS',
  );
  const wg = ChainProxy(
    id: 'b2',
    name: 'WG',
    link: 'wireguard://cHJpdmF0ZQ%3D%3D@192.0.2.2:51820?publickey=cHVibGlj&address=10.0.0.2%2F32#WG',
  );

  test('the chain proxy exit: per connection type, only with a chain proxy the type can carry', () {
    const device = DeviceSettings(
      exitNodes: {'worker': ExitNode.chain, 'warp': ExitNode.chain},
    );
    // No chain proxies: the worker is the exit.
    expect(
      XrayConfigBuilder.exitFor(ConnectionMode.worker, device, const []),
      ExitNode.worker,
    );
    expect(
      XrayConfigBuilder.exitFor(ConnectionMode.worker, device, const [vless]),
      ExitNode.chain,
    );
    // WireGuard is UDP: the worker can't carry it, WARP can.
    expect(
      XrayConfigBuilder.exitFor(ConnectionMode.worker, device, const [wg]),
      ExitNode.worker,
    );
    expect(
      XrayConfigBuilder.exitFor(ConnectionMode.warp, device, const [wg]),
      ExitNode.chain,
    );
    // The exit chosen for another type doesn't apply.
    expect(
      XrayConfigBuilder.exitFor(ConnectionMode.masque, device, const [vless]),
      ExitNode.worker,
    );
    // The chain chosen for the type, else the first one it can carry.
    const chosen = DeviceSettings(exitChains: {'warp': 'b2'});
    expect(
      XrayConfigBuilder.chainFor(ConnectionMode.warp, chosen, const [
        vless,
        wg,
      ]),
      wg,
    );
    expect(
      XrayConfigBuilder.chainFor(ConnectionMode.worker, chosen, const [
        wg,
        vless,
      ]),
      vless,
    );
    expect(
      XrayConfigBuilder.chainFor(ConnectionMode.masque, chosen, const [
        vless,
        wg,
      ]),
      vless,
    );
    // Stored and read back; unknown exit nodes are dropped.
    final stored = DeviceSettings.fromJson(
      DeviceSettings.fromJson({
        'exit': {
          'nodes': {'warp': 'chain', 'tor': 'mars'},
          'chains': {'warp': 'b2'},
        },
      }).toJson(),
    );
    expect(
      [stored.exitNodes, stored.exitChains],
      [
        {'warp': ExitNode.chain},
        {'warp': 'b2'},
      ],
    );
    expect(
      [stored.exitNodeFor('warp'), stored.exitNodeFor('worker')],
      [ExitNode.chain, ExitNode.worker],
    );
  });

  test('chain proxies are saved and exported with their links', () {
    final p = Profile.fromJson({
      'chains': [
        vless.toJson(),
        {'id': 'c3'}, // no link: dropped
        wg.toJson(),
      ],
    });
    expect(p.chains.map((c) => c.id), ['a1', 'b2']);
    expect(p.toExportJson()['chains'], [vless.toJson(), wg.toJson()]);
  });

  test('legacy connection types become Worker and WARP variants', () {
    DeviceSettings device(Map<String, dynamic> connection) =>
        DeviceSettings.fromJson({'connection': connection});

    final fragment = device({'type': 'fragment'});
    expect(
      [fragment.connectionType, fragment.workerVariant],
      ['worker', 'fragment'],
    );
    final pro = device({'type': 'warpPro'});
    expect(
      [pro.connectionType, pro.warpVariant, pro.workerVariant],
      ['warp', 'obfuscated', 'normal'],
    );
    final normal = device({'type': 'normal'});
    expect([normal.connectionType, normal.workerVariant], ['worker', 'normal']);
    expect(
      device({'type': 'warp', 'warpVariant': 'invalid'}).warpVariant,
      'normal',
    );
  });

  test('only current variant names are accepted from settings', () {
    DeviceSettings device(Map<String, dynamic> connection) =>
        DeviceSettings.fromJson({'connection': connection});

    expect(device({'workerVariant': 'fragment'}).workerVariant, 'fragment');
    expect(device({'warpVariant': 'obfuscated'}).warpVariant, 'obfuscated');
    expect(device({'masqueVariant': 'obfuscated'}).masqueVariant, 'obfuscated');
    expect(device({'workerVariant': 'unknown'}).workerVariant, 'normal');
    expect(device({'warpVariant': 'unknown'}).warpVariant, 'normal');
    expect(device({'masqueVariant': 'unknown'}).masqueVariant, 'normal');

    final canonical =
        DeviceSettings(
              workerVariant: 'fragment',
              warpVariant: 'obfuscated',
              masqueVariant: 'obfuscated',
            ).toJson()['connection']
            as Map;
    expect(canonical['workerVariant'], 'fragment');
    expect(canonical['warpVariant'], 'obfuscated');
    expect(canonical['masqueVariant'], 'obfuscated');
  });

  test('stored sparse: only values that differ from the defaults', () {
    expect(const Profile().toSparseJson(), {'schemaVersion': 1});
    expect(const DeviceSettings().toSparseJson(), {'schemaVersion': 1});
    final device = const DeviceSettings().updated('appendHttpProxy', true);
    expect(device.toSparseJson(), {
      'schemaVersion': 1,
      'appendHttpProxy': true,
    });
    expect(
      DeviceSettings.fromJson(device.toSparseJson()).appendHttpProxy,
      isTrue,
    );

    final p = const Profile().updated('vless.ech.enabled', true).updated(
      'warp.endpoints',
      ['162.159.192.1:500'],
    );
    expect(p.toSparseJson(), {
      'schemaVersion': 1,
      'vless': {
        'ech': {'enabled': true},
      },
      'warp': {
        'endpoints': ['162.159.192.1:500'],
      },
    });
    // Reading it back gives the same profile, defaults filled in.
    expect(Profile.fromJson(p.toSparseJson()).toJson(), p.toJson());
  });

  test('a changed default reaches profiles that never set the value', () {
    final stored = const Profile().updated('vless.ports', [
      443,
      8443,
    ]).toSparseJson();
    expect(stored['vless'], {
      'ports': [443, 8443],
    });
    expect(
      (stored['vless'] as Map).containsKey('speedTestInterval'),
      isFalse,
    ); // so a new default applies
  });

  test('malformed or unknown values fall back to defaults', () {
    final p = Profile.fromJson({
      'general': {'enableIpv6': 'yes', 'localDns': 42},
      'vless': {
        'ports': 'all',
        'speedTestInterval': 30.7,
        'ech': {
          'enabled': true,
          'serverName': 'legacy.example',
          'dns': '1.1.1.1',
        },
      },
      'fragments': [
        {'packets': '1-4', 'lengths': 'x'},
      ],
      'routing': {
        'bypass': {
          'presets': {'iran': true, 'mars': true},
        },
      },
      'somethingElse': true,
    });
    expect(p.general.enableIpv6, isFalse);
    expect(p.general.localDns, '8.8.8.8');
    expect(p.vless.ports, [443]);
    expect(p.vless.speedTestInterval, 30);
    expect(p.vless.ech.dns, '1.1.1.1');
    expect(p.vless.ech.toJson(), {'enabled': true, 'dns': '1.1.1.1'});
    expect(
      p.fragments.single.packets,
      FragmentPackets.tlsHello,
    ); // not a preset → default
    expect(p.fragments.single.lengths, const [Range(100, 200)]);
    expect(p.routing.bypass.presets, {
      'iran': true,
      'china': false,
      'russia': false,
      'bittorrent': false,
    }); // unknown preset dropped
  });

  test('noise payload field follows the type', () {
    final noises = Profile.fromJson({
      'udpNoises': [
        {
          'type': 'rand',
          'size': {'min': 10, 'max': 20},
          'packet': 'ignored',
        },
        {
          'type': 'array',
          'bytes': [1, 2, 3],
        },
        {'type': 'exp', 'packet': '<r 8>'},
      ],
    }).udpNoises;
    expect(noises.map((n) => n.toJson()).toList(), [
      {
        'type': 'rand',
        'size': {'min': 10, 'max': 20},
        'count': 1,
        'delay': {'min': 1, 'max': 5},
      },
      {
        'type': 'array',
        'bytes': [1, 2, 3],
        'count': 1,
        'delay': {'min': 1, 'max': 5},
      },
      {
        'type': 'exp',
        'packet': '<r 8>',
        'count': 1,
        'delay': {'min': 1, 'max': 5},
      },
    ]);
  });

  test('export leaves out only the WARP account', () {
    final p = const Profile().updated('vless.cleanIps', ['1.1.1.1']).updated(
      'warp.account',
      {
        'privateKey': 'p',
        'publicKey': 'k',
        'ipv6': '2606:4700::1/128',
        'reserved': [1, 2, 3],
      },
    );
    final exported = p.toExportJson();
    expect(exported['vless'], {
      'cleanIps': ['1.1.1.1'],
    });
    expect(exported.containsKey('warp'), isFalse);
    expect(p.updated('warp.remoteDns', '9.9.9.9').toExportJson()['warp'], {
      'remoteDns': '9.9.9.9',
    });
  });

  test('ECH export keeps DNS but drops the removed SNI setting', () {
    final p = Profile.fromJson({
      'vless': {
        'ech': {
          'enabled': true,
          'serverName': 'legacy.example',
          'dns': '1.1.1.1',
        },
      },
    });

    expect(p.vless.ech.toJson(), {'enabled': true, 'dns': '1.1.1.1'});
    expect((p.toExportJson()['vless'] as Map)['ech'], {
      'enabled': true,
      'dns': '1.1.1.1',
    });
  });

  test('Tor bridges: cleaned up, private (not exported) and kept on import / reset', () {
    final p = const Profile().updated('tor.bridges', [
      'Bridge webtunnel [2001:db8::1]:443 FP url=https://example.com/x ver=0.0.1',
      'snowflake 192.0.2.3:80 FP ice=stun:a.example:3478,stun:b.example:3478',
      'vmess://not-a-bridge',
    ]);
    expect(p.tor.bridges, [
      'webtunnel [2001:db8::1]:443 FP url=https://example.com/x ver=0.0.1',
      'snowflake 192.0.2.3:80 FP ice=stun:a.example:3478,stun:b.example:3478',
    ]);
    expect(p.toExportJson().containsKey('tor'), isFalse);
    expect(p.keepingPrivate(const Profile()).tor.bridges, p.tor.bridges);
  });

  test('LAN login only with sharing on and both fields set', () {
    DeviceSettings lan(Map<String, dynamic> v) =>
        DeviceSettings.fromJson({'lanSharing': v});
    expect(lan({'enabled': true, 'username': 'me', 'password': 'x'}).lanAuth, (
      user: 'me',
      pass: 'x',
    ));
    expect(
      lan({'enabled': false, 'username': 'me', 'password': 'x'}).lanAuth,
      isNull,
    );
    expect(lan({'enabled': true, 'username': 'me'}).lanAuth, isNull);
  });

  test('paths read and write nested values', () {
    final json = writePath({'a': 1}, 'b.c.d', true);
    expect(json, {
      'a': 1,
      'b': {
        'c': {'d': true},
      },
    });
    expect(readPath(json, 'b.c.d'), true);
    expect(readPath(json, 'b.x'), isNull);
  });
}
