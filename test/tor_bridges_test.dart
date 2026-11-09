import 'dart:convert';
import 'dart:io';

import 'package:bpb/models/settings.dart';
import 'package:bpb/services/tor_bridges.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Shaped like a real Moat circumvention/settings response; the bridges are made up.
  final response = jsonEncode({
    'settings': [
      {
        'bridges': {
          'type': 'webtunnel',
          'source': 'bridgedb',
          'bridge_strings': [
            'webtunnel [2001:db8::1]:443 0123456789ABCDEF0123456789ABCDEF01234567 url=https://example.com/a ver=0.0.1',
          ],
        },
      },
      {
        'bridges': {
          'type': 'obfs4',
          'source': 'bridgedb',
          'bridge_strings': [
            'obfs4 192.0.2.10:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=abc iat-mode=0',
            'Bridge obfs4 192.0.2.11:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=def iat-mode=0',
          ],
        },
      },
    ],
    'country': 'ir',
  });

  test('bridge lines from every setting, normalised', () {
    expect(TorBridgeFetcher.parse(response), [
      'webtunnel [2001:db8::1]:443 0123456789ABCDEF0123456789ABCDEF01234567 url=https://example.com/a ver=0.0.1',
      'obfs4 192.0.2.10:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=abc iat-mode=0',
      'obfs4 192.0.2.11:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=def iat-mode=0',
    ]);
  });

  test('errors and empty answers are reported', () {
    expect(
      () => TorBridgeFetcher.parse(
        jsonEncode({
          'errors': [
            {'code': 406, 'detail': 'Unknown country'},
          ],
        }),
      ),
      throwsA(isA<TorBridgesException>().having((e) => e.message, 'message', contains('Unknown country'))),
    );
    expect(() => TorBridgeFetcher.parse(jsonEncode({'settings': []})), throwsA(isA<TorBridgesException>()));
    expect(() => TorBridgeFetcher.parse('<html>'), throwsA(isA<TorBridgesException>()));
  });

  // scripts/fetch_tor_bridges.sh writes this before a release build; a bad line would stop the
  // setup wizard's Tor, so the release stops here instead. The bridges are kept out of the
  // (public) build log: a failure names only the line's number and transport.
  final embedded = File('assets/tor/bridges.json');
  test(
    "the build's Tor bridges are valid bridge lines",
    () {
      final json = jsonDecode(embedded.readAsStringSync()) as Map<String, dynamic>;
      final bridges = (json['bridges'] as List).cast<String>();
      expect(bridges.length, greaterThan(0), reason: 'no bridges');
      final invalid = [
        for (final (i, line) in bridges.indexed)
          if (!TorSettings.isBridge(line)) '#${i + 1} (${line.split(' ').first})',
      ];
      expect(invalid.isEmpty, isTrue, reason: 'invalid bridge lines: ${invalid.join(', ')}');
    },
    skip: embedded.existsSync() ? false : 'no assets/tor/bridges.json (scripts/fetch_tor_bridges.sh)',
  );
}
