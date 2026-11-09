import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'local_proxy.dart';

/// A WARP (WireGuard) account registered with Cloudflare.
///
/// Stored in the profile as `warp.account` (left out of exported files).
class WarpAccount {
  final String privateKey;

  /// Cloudflare's peer public key.
  final String publicKey;

  /// The account's WARP IPv6 address, e.g. "2606:4700:…/128".
  final String ipv6;

  /// WireGuard's 3 "reserved" bytes (decoded from WARP's client_id).
  final List<int> reserved;

  const WarpAccount({required this.privateKey, required this.publicKey, required this.ipv6, required this.reserved});

  Map<String, dynamic> toJson() => {
    'privateKey': privateKey,
    'publicKey': publicKey,
    'ipv6': ipv6,
    'reserved': reserved,
  };

  static WarpAccount? fromJson(Map<String, dynamic> json) {
    final reserved = json['reserved'];
    final a = WarpAccount(
      privateKey: '${json['privateKey'] ?? ''}',
      publicKey: '${json['publicKey'] ?? ''}',
      ipv6: '${json['ipv6'] ?? ''}',
      reserved: reserved is List && reserved.length == 3
          ? reserved.whereType<num>().map((e) => e.toInt()).toList()
          : const [0, 0, 0],
    );
    return a.privateKey.isEmpty || a.publicKey.isEmpty || a.ipv6.isEmpty ? null : a;
  }

  /// WARP's base64 client_id as WireGuard reserved bytes, like BPB's base64ToDecimal.
  static List<int> reservedFromClientId(String clientId) {
    try {
      final bytes = base64.decode(clientId);
      return bytes.length == 3 ? bytes.toList() : const [0, 0, 0];
    } on FormatException {
      return const [0, 0, 0];
    }
  }
}

class WarpException implements Exception {
  final String message;

  /// The server couldn't be reached (rather than refusing): another route may help.
  final bool network;
  const WarpException(this.message, {this.network = false});

  @override
  String toString() => message;
}

/// A registered account, and the WARP endpoints Cloudflare offered with it (see
/// [WarpRegistrar.offeredEndpoints]).
typedef WarpRegistration = ({WarpAccount account, List<String> endpoints});

/// Registers WARP accounts directly from the device (BPB's src/api/warp.ts).
class WarpRegistrar {
  static const _endpoint = 'https://api.cloudflareclient.com/v0a4005/reg';

  /// When set, requests go through this local HTTP proxy (the running tunnel).
  final int? proxyPort;

  const WarpRegistrar({this.proxyPort});

  /// Registers one WARP account.
  Future<WarpRegistration> register() async {
    final inner = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    if (proxyPort != null) LocalProxy.apply(inner, port: proxyPort!);
    final client = IOClient(inner);
    try {
      return await _register(client);
    } finally {
      client.close();
    }
  }

  Future<WarpRegistration> _register(http.Client client) async {
    final keys = X25519KeyPair.generate();
    final http.Response res;
    try {
      res = await client
          .post(
            Uri.parse(_endpoint),
            headers: {'User-Agent': 'insomnia/13.0.2', 'Content-Type': 'application/json'},
            body: jsonEncode({
              'install_id': '',
              'fcm_token': '',
              'tos': DateTime.now().toUtc().toIso8601String(),
              'type': 'Android',
              'model': 'PC',
              'locale': 'en_US',
              'warp_enabled': true,
              'key': keys.publicKey,
            }),
          )
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw WarpException('Could not reach Cloudflare WARP: $e', network: true);
    }
    if (res.statusCode != 200) {
      throw WarpException('WARP registration failed (HTTP ${res.statusCode})');
    }
    try {
      final config = (jsonDecode(res.body) as Map<String, dynamic>)['config'] as Map<String, dynamic>;
      final interface = config['interface'] as Map<String, dynamic>;
      final peer = (config['peers'] as List).first as Map<String, dynamic>;
      final account = WarpAccount(
        privateKey: keys.privateKey,
        publicKey: '${peer['public_key']}',
        ipv6: '${(interface['addresses'] as Map)['v6']}/128',
        reserved: WarpAccount.reservedFromClientId('${config['client_id']}'),
      );
      return (account: account, endpoints: offeredEndpoints(peer['endpoint']));
    } catch (_) {
      throw const WarpException('Unexpected response from Cloudflare WARP');
    }
  }

  /// The endpoints in a registration's `peers[0].endpoint`: its v4 and v6 addresses on each of
  /// its ports, e.g. "162.159.192.4:2408", … "[2606:4700:d0::a29f:c004]:4500". Its `host`
  /// (engage.cloudflareclient.com:2408) is left out: only the addresses are used.
  static List<String> offeredEndpoints(Object? endpoint) {
    if (endpoint is! Map) return const [];
    final ports = (endpoint['ports'] as List?)?.whereType<int>().toList() ?? const [2408];
    // "162.159.192.4:0" / "[2606:4700:d0::a29f:c004]:0": the port is left to the client.
    String? address(Object? v) {
      final s = v is String ? v : null;
      if (s == null || s.isEmpty) return null;
      return s.substring(0, s.lastIndexOf(':'));
    }

    return [
      for (final ip in [address(endpoint['v4']), address(endpoint['v6'])].nonNulls)
        for (final port in ports) '$ip:$port',
    ];
  }
}

/// Curve25519 key pair, generated the same way as `xray wg` (RFC 7748 X25519).
class X25519KeyPair {
  final String privateKey;
  final String publicKey;

  const X25519KeyPair(this.privateKey, this.publicKey);

  factory X25519KeyPair.generate([Random? random]) {
    final rnd = random ?? Random.secure();
    final private = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
    _clamp(private);
    return X25519KeyPair(base64.encode(private), base64.encode(x25519Base(private)));
  }

  /// Public key for a base64 private key.
  static String publicKeyOf(String privateKey) => base64.encode(x25519Base(base64.decode(privateKey)));

  static void _clamp(Uint8List k) {
    k[0] &= 248;
    k[31] &= 127;
    k[31] |= 64;
  }

  static final _p = (BigInt.one << 255) - BigInt.from(19);
  static final _a24 = BigInt.from(121665);

  /// scalar * basepoint(9).
  static Uint8List x25519Base(List<int> scalar) => x25519(scalar, [9, ...List.filled(31, 0)]);

  static Uint8List x25519(List<int> scalar, List<int> uBytes) {
    final k = Uint8List.fromList(scalar);
    _clamp(k);
    final kn = _decodeLE(k);
    final u = Uint8List.fromList(uBytes);
    u[31] &= 127;
    final x1 = _decodeLE(u) % _p;

    var x2 = BigInt.one, z2 = BigInt.zero, x3 = x1, z3 = BigInt.one;
    var swap = 0;
    for (var t = 254; t >= 0; t--) {
      final kt = ((kn >> t) & BigInt.one).toInt();
      swap ^= kt;
      if (swap == 1) {
        (x2, x3) = (x3, x2);
        (z2, z3) = (z3, z2);
      }
      swap = kt;

      final a = (x2 + z2) % _p;
      final aa = (a * a) % _p;
      final b = (x2 - z2) % _p;
      final bb = (b * b) % _p;
      final e = (aa - bb) % _p;
      final c = (x3 + z3) % _p;
      final d = (x3 - z3) % _p;
      final da = (d * a) % _p;
      final cb = (c * b) % _p;
      x3 = ((da + cb) * (da + cb)) % _p;
      final diff = (da - cb) % _p;
      z3 = (x1 * diff * diff) % _p;
      x2 = (aa * bb) % _p;
      z2 = (e * (aa + _a24 * e)) % _p;
    }
    if (swap == 1) {
      (x2, x3) = (x3, x2);
      (z2, z3) = (z3, z2);
    }
    return _encodeLE((x2 * z2.modPow(_p - BigInt.two, _p)) % _p);
  }

  static BigInt _decodeLE(List<int> bytes) {
    var n = BigInt.zero;
    for (var i = bytes.length - 1; i >= 0; i--) {
      n = (n << 8) | BigInt.from(bytes[i]);
    }
    return n;
  }

  static Uint8List _encodeLE(BigInt n) {
    final out = Uint8List(32);
    var v = n;
    for (var i = 0; i < 32; i++) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    return out;
  }
}
