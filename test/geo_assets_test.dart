import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bpb/models/settings.dart';
import 'package:bpb/services/xray_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tags (country_code) in a geosite.dat / geoip.dat: a protobuf list whose entries
/// (field 1) each start with `string country_code = 1`.
Set<String> datTags(String path) {
  final buf = File(path).readAsBytesSync();
  var i = 0;
  int varint(Uint8List b) {
    var shift = 0, result = 0;
    while (true) {
      final byte = b[i++];
      result |= (byte & 0x7f) << shift;
      if (byte < 0x80) return result;
      shift += 7;
    }
  }

  final tags = <String>{};
  while (i < buf.length) {
    final key = varint(buf);
    final length = varint(buf);
    final end = i + length;
    if (key >> 3 == 1 && buf[i] == (1 << 3 | 2)) {
      i++;
      final n = varint(buf);
      tags.add(utf8.decode(buf.sublist(i, i + n)).toLowerCase());
    }
    i = end;
  }
  return tags;
}

void main() {
  test('every geosite/geoip tag the configs use exists in the bundled assets', () async {
    const assets = 'android/app/src/main/assets';
    final geosite = datTags('$assets/geosite.dat');
    final geoip = datTags('$assets/geoip.dat');

    // Every routing preset on.
    Map<String, dynamic> all(Map<String, bool> presets) => {
      'presets': {for (final k in presets.keys) k: true},
    };
    final profile = Profile.fromJson({
      'routing': {
        'bypass': all(RoutingPresets.bypass),
        'sanctionBypass': all(RoutingPresets.sanctionBypass),
        'block': all(RoutingPresets.block),
      },
    });
    final builder = XrayConfigBuilder(
      profile,
      const DeviceSettings(),
      worker: const ActiveWorker(
        accountId: 'a',
        name: 'w',
        type: WorkerType.workers,
        host: 'w.example.workers.dev',
      ),
      uuid: 'u',
      resolver: (host, {required ipv6}) async => ['104.21.1.1'],
    );
    final json = jsonEncode((await builder.build(ConnectionMode.worker)).config);

    final used = RegExp(r'(geosite|geoip):([a-z0-9@!_-]+)').allMatches(json).map((m) => m[0]!).toSet();
    expect(used, contains('geosite:ir'));
    for (final tag in used) {
      final [kind, name] = tag.split(':');
      expect((kind == 'geosite' ? geosite : geoip).contains(name), isTrue, reason: '$tag missing from $kind.dat');
    }
  });
}
