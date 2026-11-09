import 'package:bpb/ui/noises_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('presets are valid exp noise', () {
    for (final MapEntry(key: name, value: exp) in noiseExpPresets.entries) {
      expect(validateNoiseExp(exp), isNull, reason: name);
    }
    expect(validateNoisePacket('exp', generateNoisePacket('exp')), isNull);
  });

  test('accepts every token form Xray does', () {
    for (final exp in [
      '<b 0x1a2b>',
      '<b 1a 2b>', // spaces in hex are allowed
      '<r 16>',
      '<rc 8-32>',
      '<rd 4>',
      '<t><c><n>',
      ' < r 10 >  <b 0xff> ', // whitespace around and inside tokens
    ]) {
      expect(validateNoiseExp(exp), isNull, reason: exp);
    }
  });

  test('rejects what Xray would reject', () {
    final bad = {
      '': 'Add at least one',
      'abc': 'Unexpected text',
      '<b 0x1a2>': 'even-length hex',
      '<b>': 'even-length hex',
      '<r>': 'needs a size',
      '<r 32-8>': 'low to high',
      '<r 70000>': '0-65535',
      '<t 4>': 'takes no value',
      '<x 4>': 'Unknown <x>',
      '<r 4> junk': 'Unexpected text',
    };
    for (final MapEntry(key: exp, value: message) in bad.entries) {
      expect(validateNoiseExp(exp), contains(message), reason: exp);
    }
  });
}
