import 'dart:io';

import 'package:bpb/services/mitm_ca.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generates a PEM CA certificate and EC key', () {
    final ca = MitmCa.generate();
    expect(ca.cert, startsWith('-----BEGIN CERTIFICATE-----\n'));
    expect(ca.key, startsWith('-----BEGIN EC PRIVATE KEY-----\n'));
    expect(MitmCa.generate().key, isNot(ca.key));

    // For checking with Xray / openssl outside the test.
    final out = Platform.environment['XRAY_TEST_OUT'];
    if (out != null) {
      Directory(out).createSync(recursive: true);
      File('$out/${MitmCa.certFile}').writeAsStringSync(ca.cert);
      File('$out/${MitmCa.keyFile}').writeAsStringSync(ca.key);
    }
  });
}
