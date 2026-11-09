import 'dart:convert';

import 'package:bpb/services/warp.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _hex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

void main() {
  test('registration endpoints: v4 and v6 on each offered port (not the host)', () {
    // peers[0].endpoint as Cloudflare returns it.
    final endpoints = WarpRegistrar.offeredEndpoints({
      'v4': '162.159.192.4:0',
      'v6': '[2606:4700:d0::a29f:c004]:0',
      'host': 'engage.cloudflareclient.com:2408',
      'ports': [2408, 500, 1701, 4500],
    });
    expect(endpoints, [
      '162.159.192.4:2408',
      '162.159.192.4:500',
      '162.159.192.4:1701',
      '162.159.192.4:4500',
      '[2606:4700:d0::a29f:c004]:2408',
      '[2606:4700:d0::a29f:c004]:500',
      '[2606:4700:d0::a29f:c004]:1701',
      '[2606:4700:d0::a29f:c004]:4500',
    ]);
    // Older answers without ports: 2408.
    expect(WarpRegistrar.offeredEndpoints({'v4': '162.159.192.1:0'}), ['162.159.192.1:2408']);
    expect(WarpRegistrar.offeredEndpoints(null), isEmpty);
  });

  test('X25519 matches the RFC 7748 test vector', () {
    final out = X25519KeyPair.x25519(
      _hex('a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4'),
      _hex('e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c'),
    );
    expect(out, _hex('c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552'));
  });

  test('public keys match xray wg', () {
    // Pairs printed by `xray wg` (Xray 26.10.10).
    const pairs = {
      'iMcL8jySc9UxHzSVHTNFURuX6ROdw1sBST55CHMGoHQ=': '0SDWSRww2XcZAcE3cFhTEA3f+6PNMZF/o2qr3OJrnzQ=',
      'SINMCeXjDCqRSuc4bMfSmtovFuzudZzceguDSPegpHI=': 'GCybVRx90WfOEvNpLbEr4ZS2A3wXa3yKf4Iz/gPVjwQ=',
      'MFO3sE1u0aToRhWJl8YsUR9njU2gdWJZhwfEtdr0+UE=': 'YjGFYpIFt2fqxpweluoBfTkw2901iL1W3RwpnxIMi2U=',
    };
    for (final e in pairs.entries) {
      expect(X25519KeyPair.publicKeyOf(e.key), e.value);
    }
  });

  test('generated keys are clamped and self-consistent', () {
    final kp = X25519KeyPair.generate();
    final priv = base64.decode(kp.privateKey);
    expect(priv.length, 32);
    expect(priv[0] & 7, 0);
    expect(priv[31] & 0xc0, 0x40);
    expect(X25519KeyPair.publicKeyOf(kp.privateKey), kp.publicKey);
  });

  test('reserved bytes decode from client_id', () {
    expect(WarpAccount.reservedFromClientId('AQID'), [1, 2, 3]);
    expect(WarpAccount.reservedFromClientId('not base64!'), [0, 0, 0]);
  });

  test('account JSON round-trips; incomplete accounts are rejected', () {
    const a = WarpAccount(privateKey: 'p', publicKey: 'k', ipv6: '2606:4700::1/128', reserved: [1, 2, 3]);
    final back = WarpAccount.fromJson(a.toJson())!;
    expect(back.toJson(), a.toJson());
    expect(WarpAccount.fromJson({'privateKey': 'p', 'publicKey': 'k'}), isNull); // no IPv6
  });
}
