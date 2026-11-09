import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Just enough DER to write X.509 certificates and EC keys (see MitmCa, MasqueRegistrar).
abstract final class Der {
  static List<int> tlv(int tag, List<int> value) {
    final length = value.length;
    final lengthBytes = <int>[];
    if (length < 0x80) {
      lengthBytes.add(length);
    } else {
      final bytes = <int>[];
      for (var n = length; n > 0; n >>= 8) {
        bytes.insert(0, n & 0xff);
      }
      lengthBytes.addAll([0x80 | bytes.length, ...bytes]);
    }
    return [tag, ...lengthBytes, ...value];
  }

  static List<int> seq(List<List<int>> items) => tlv(0x30, [for (final i in items) ...i]);

  static List<int> set(List<List<int>> items) => tlv(0x31, [for (final i in items) ...i]);

  static List<int> boolean(bool v) => tlv(0x01, [v ? 0xff : 0x00]);

  static List<int> octet(List<int> v) => tlv(0x04, v);

  static List<int> bitString(List<int> v) => tlv(0x03, [0x00, ...v]);

  static List<int> utf8String(String v) => tlv(0x0c, utf8.encode(v));

  /// A non-negative INTEGER, with a leading 0 when the top bit is set.
  static List<int> integer(BigInt v) {
    final bytes = <int>[];
    for (var n = v; n > BigInt.zero; n >>= 8) {
      bytes.insert(0, (n & BigInt.from(0xff)).toInt());
    }
    if (bytes.isEmpty || bytes.first & 0x80 != 0) bytes.insert(0, 0);
    return tlv(0x02, bytes);
  }

  /// [v] as exactly [length] big-endian bytes.
  static List<int> unsigned(BigInt v, int length) => [
    for (var i = length - 1; i >= 0; i--) ((v >> (8 * i)) & BigInt.from(0xff)).toInt(),
  ];

  static List<int> oid(String dotted) {
    final parts = dotted.split('.').map(int.parse).toList();
    final bytes = <int>[40 * parts[0] + parts[1]];
    for (final part in parts.skip(2)) {
      final chunk = <int>[part & 0x7f];
      for (var n = part >> 7; n > 0; n >>= 7) {
        chunk.insert(0, 0x80 | (n & 0x7f));
      }
      bytes.addAll(chunk);
    }
    return tlv(0x06, bytes);
  }

  static List<int> utcTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final s = '${two(t.year % 100)}${two(t.month)}${two(t.day)}${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
    return tlv(0x17, ascii.encode(s));
  }

  static String pem(String label, List<int> der) {
    final b64 = base64.encode(der);
    final lines = [for (var i = 0; i < b64.length; i += 64) b64.substring(i, min(i + 64, b64.length))];
    return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
  }
}

/// An ECDSA P-256 key pair, as Go's crypto/x509 reads it.
class P256KeyPair {
  static const _curve = '1.2.840.10045.3.1.7';

  final ECPrivateKey privateKey;

  /// The uncompressed public point (0x04 ‖ X ‖ Y).
  final List<int> point;

  P256KeyPair._(this.privateKey, this.point);

  static P256KeyPair generate([SecureRandom? random]) {
    final pair =
        (ECKeyGenerator()..init(
              ParametersWithRandom(ECKeyGeneratorParameters(ECDomainParameters('secp256r1')), random ?? secureRandom()),
            ))
            .generateKeyPair();
    return P256KeyPair._(pair.privateKey, pair.publicKey.Q!.getEncoded(false));
  }

  static SecureRandom secureRandom() {
    final seed = Random.secure();
    return FortunaRandom()..seed(KeyParameter(Uint8List.fromList([for (var i = 0; i < 32; i++) seed.nextInt(256)])));
  }

  /// The private key, SEC 1 ("EC PRIVATE KEY").
  List<int> get sec1 => Der.seq([
    Der.integer(BigInt.one),
    Der.octet(Der.unsigned(privateKey.d!, 32)),
    Der.tlv(0xa0, Der.oid(_curve)),
    Der.tlv(0xa1, Der.bitString(point)),
  ]);

  /// The public key, PKIX SubjectPublicKeyInfo ("PUBLIC KEY").
  List<int> get spki => Der.seq([
    Der.seq([Der.oid('1.2.840.10045.2.1'), Der.oid(_curve)]),
    Der.bitString(point),
  ]);
}
