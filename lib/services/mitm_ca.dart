import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'der.dart';

/// The certificate authority Domain Fronting's TLS decryption issues site certificates from
/// (Xray's `"usage": "issue"`), like `xray tls cert -ca`: an ECDSA P-256 CA, self-signed.
/// Saved as bpb-cert.crt / bpb-cert.key in the app's private storage; only the crt leaves
/// it, to be installed as a trusted CA.
class MitmCa {
  static const certFile = 'bpb-cert.crt';
  static const keyFile = 'bpb-cert.key';
  static const _name = 'BPB MITM CA';

  /// PEM, "CERTIFICATE".
  final String cert;

  /// PEM, "EC PRIVATE KEY" (SEC 1), which Xray parses like its own.
  final String key;

  const MitmCa(this.cert, this.key);

  static MitmCa generate({DateTime? now}) {
    final random = P256KeyPair.secureRandom();
    final keys = P256KeyPair.generate(random);

    final from = (now ?? DateTime.now()).toUtc().subtract(const Duration(hours: 1));
    final name = Der.seq([
      Der.set([
        Der.seq([Der.oid('2.5.4.3'), Der.utf8String(_name)]),
      ]),
    ]);
    final ecdsaWithSha256 = Der.seq([Der.oid('1.2.840.10045.4.3.2')]);
    final keyId = (SHA1Digest()).process(Uint8List.fromList(keys.point));
    final tbs = Der.seq([
      Der.tlv(0xa0, Der.integer(BigInt.two)), // v3
      Der.integer(_serial(random)),
      ecdsaWithSha256,
      name,
      Der.seq([Der.utcTime(from), Der.utcTime(from.add(const Duration(days: 365 * 20)))]),
      name,
      keys.spki,
      Der.tlv(
        0xa3,
        Der.seq([
          // Basic constraints, critical: a CA.
          Der.seq([
            Der.oid('2.5.29.19'),
            Der.boolean(true),
            Der.octet(Der.seq([Der.boolean(true)])),
          ]),
          // Key usage, critical: digitalSignature, keyCertSign, cRLSign (bits 0, 5, 6).
          Der.seq([
            Der.oid('2.5.29.15'),
            Der.boolean(true),
            Der.octet(Der.tlv(0x03, [0x01, 0x86])),
          ]),
          // Subject key identifier.
          Der.seq([Der.oid('2.5.29.14'), Der.octet(Der.octet(keyId))]),
        ]),
      ),
    ]);

    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter<ECPrivateKey>(keys.privateKey));
    final signature = signer.generateSignature(Uint8List.fromList(tbs)) as ECSignature;
    final cert = Der.seq([
      tbs,
      ecdsaWithSha256,
      Der.bitString(Der.seq([Der.integer(signature.r), Der.integer(signature.s)])),
    ]);

    return MitmCa(Der.pem('CERTIFICATE', cert), Der.pem('EC PRIVATE KEY', keys.sec1));
  }

  /// 127 random bits: positive, like Go's serials.
  static BigInt _serial(SecureRandom random) {
    final bytes = random.nextBytes(16)..[0] &= 0x7f;
    return bytes.fold(BigInt.zero, (n, b) => (n << 8) | BigInt.from(b));
  }
}
