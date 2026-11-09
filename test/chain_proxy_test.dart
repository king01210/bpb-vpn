import 'package:bpb/services/chain_proxy.dart';
import 'package:bpb/services/proxy_uri.dart';
import 'package:bpb/services/xray_config.dart';
import 'package:flutter_test/flutter_test.dart';

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
PersistentKeepalive = 25
''';

void main() {
  test('a WireGuard config becomes a wireguard:// link that reads back the same', () {
    final chain = wireGuardConfToChain(wgConf);
    expect(chain.name, 'vpn.example.com');
    final p = ProxyUri.parse(chain.link);
    expect([p.protocol, p.server, p.port], ['wireguard', 'vpn.example.com', 51820]);
    // Keys keep their '+' and '='.
    expect(p['privateKey'], 'cHJpdmF0ZWtleXByaXZhdGVrZXlwcml2YXRla2V5MDE=');
    expect(p['publickey'], 'cHVibGlja2V5cHVibGlja2V5cHVibGlja2V5cHViMDE+');
    expect(p['presharedkey'], 'cHJlc2hhcmVka2V5cHJlc2hhcmVka2V5cHJlc2hhcjE=');
    expect([p['address'], p['mtu'], p['keepalive']], ['10.0.0.2/32,fd00::2/128', '1380', '25']);
    expect(p['dns'], '10.0.0.1,fd00::1'); // the search domain is left out
    expect(ChainInfo(p).tags, ['WireGuard']);
    expect(ChainInfo(p).address, 'vpn.example.com:51820');
  });

  test('a v2rayN-style link with a raw + in the key', () {
    final p = ProxyUri.parse(
      'wireguard://cHJpdmF0ZQ+key=@[2001:db8::1]:51820?publickey=pub+key=&address=10.0.0.2/32&reserved=1,2,3#Home',
    );
    expect([p['privateKey'], p['publickey'], p.remark], ['cHJpdmF0ZQ+key=', 'pub+key=', 'Home']);
    expect(ChainInfo(p).address, '[2001:db8::1]:51820');
  });

  test('a WireGuard file is named after the file, without its extension', () {
    final chain = parseChainProxies(wgConf, fileName: 'home.vpn.conf').single;
    expect(chain.name, 'home.vpn');
    expect(ProxyUri.parse(chain.link).remark, 'home.vpn');
    expect(wireGuardConfToChain(wgConf, name: 'wg0').name, 'wg0');
    expect(wireGuardConfToChain(wgConf, name: '.conf').name, 'vpn.example.com'); // nothing left: the host
  });

  test('a config missing its keys or endpoint is refused', () {
    expect(() => wireGuardConfToChain('[Interface]\nAddress = 10.0.0.2/32\n'), throwsFormatException);
  });

  test('pasted text: share links, one per line, or a WireGuard config', () {
    final links = parseChainProxies('''
vless://11111111-2222-4333-8444-555555555555@192.0.2.1:443?security=reality&type=grpc&sni=example.com&pbk=AAAA#Reality
not a link
socks://user:pass@192.0.2.2:1080
''');
    expect(links.map((c) => c.name), ['Reality', '192.0.2.2:1080']);
    expect(ChainInfo.of(links.first.link)!.tags, ['VLESS', 'gRPC', 'Reality']);
    expect(ChainInfo.of(links.last.link)!.tags, ['SOCKS', 'TCP']); // no security tag
    expect(links.map((c) => c.id).toSet().length, 2);
    expect(parseChainProxies(wgConf).single.link, startsWith('wireguard://'));
    expect(() => parseChainProxies('hello'), throwsFormatException);
  });

  test('a Hysteria2 link: hy2:// too, always TLS', () {
    final p = ProxyUri.parse('hy2://secret@192.0.2.3:443?sni=example.com&obfs=salamander&obfs-password=x#H');
    expect([p.protocol, p['auth'], p['sni'], p.remark], ['hysteria2', 'secret', 'example.com', 'H']);
    expect(ChainInfo(p).tags, ['Hysteria2', 'TLS']);
  });

  test('WireGuard and Hysteria2 ride WARP and MASQUE only', () {
    final wg = ChainInfo.of(wireGuardConfToChain(wgConf).link)!;
    expect(ConnectionMode.values.where(wg.canChainOver), [ConnectionMode.warp, ConnectionMode.masque]);
    final hy2 = ChainInfo.of('hysteria2://secret@192.0.2.3:443')!;
    expect(ConnectionMode.values.where(hy2.canChainOver), [ConnectionMode.warp, ConnectionMode.masque]);
    expect(ChainInfo.of('socks://192.0.2.2:1080')!.canChainOver(ConnectionMode.worker), isTrue);
  });
}
