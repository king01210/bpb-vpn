import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'der.dart';
import 'local_proxy.dart';

/// A WARP account enrolled for MASQUE (Xray's masque outbound, CONNECT-IP over HTTP/2 or 3),
/// separate from the WireGuard one: enrolling replaces an account's key.
///
/// Stored in the profile as `masque.account` (left out of exported files).
class MasqueAccount {
  /// The client's ECDSA P-256 key, base64 SEC 1 DER.
  final String privateKey;

  /// Cloudflare's endpoint key, base64 SubjectPublicKeyInfo (Xray takes PEM or base64).
  final String publicKey;

  /// The account's addresses in the tunnel, e.g. "172.16.0.2" and "2606:4700:…".
  final String ipv4;
  final String ipv6;

  const MasqueAccount({required this.privateKey, required this.publicKey, required this.ipv4, required this.ipv6});

  Map<String, dynamic> toJson() => {'privateKey': privateKey, 'publicKey': publicKey, 'ipv4': ipv4, 'ipv6': ipv6};

  /// [key] as plain base64: a PEM block's body, or [key] as it is.
  static String base64Key(String key) => key.contains('-----BEGIN')
      ? key.split('\n').where((l) => !l.startsWith('-----')).map((l) => l.trim()).join()
      : key.trim();

  static MasqueAccount? fromJson(Map<String, dynamic> json) {
    final a = MasqueAccount(
      privateKey: '${json['privateKey'] ?? ''}',
      // Accounts saved before were PEM: the same key, without its armor.
      publicKey: base64Key('${json['publicKey'] ?? ''}'),
      ipv4: '${json['ipv4'] ?? ''}',
      ipv6: '${json['ipv6'] ?? ''}',
    );
    return [a.privateKey, a.publicKey, a.ipv4, a.ipv6].any((s) => s.isEmpty) ? null : a;
  }
}

class MasqueException implements Exception {
  final String message;

  /// The server couldn't be reached (rather than refusing): another route may help.
  final bool network;
  const MasqueException(this.message, {this.network = false});

  @override
  String toString() => message;
}

/// A registered account, and the MASQUE endpoints Cloudflare offered with it.
typedef MasqueRegistration = ({MasqueAccount account, List<String> endpoints});

/// Registers a WARP account and enrolls an ECDSA key for MASQUE, like usque
/// (github.com/Diniboy1123/usque, api/cloudflare.go): a registration as the Android app, then
/// a PATCH with the key, "secp256r1" / "masque".
class MasqueRegistrar {
  static const _api = 'https://api.cloudflareclient.com/v0a4471/reg';
  static const _headers = {
    'User-Agent': 'WARP for Android',
    'CF-Client-Version': 'a-6.35-4471',
    'Content-Type': 'application/json; charset=UTF-8',
  };

  /// When set, requests go through this local HTTP proxy (the running tunnel).
  final int? proxyPort;

  const MasqueRegistrar({this.proxyPort});

  Future<MasqueRegistration> register() async {
    final inner = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    if (proxyPort != null) LocalProxy.apply(inner, port: proxyPort!);
    final client = IOClient(inner);
    try {
      return await _register(client);
    } finally {
      client.close();
    }
  }

  Future<MasqueRegistration> _register(http.Client client) async {
    final random = Random.secure();
    // The registration's WireGuard key is never used, as in usque: only enrollment's counts.
    final registration = await _call(
      () => client.post(
        Uri.parse(_api),
        headers: _headers,
        body: jsonEncode({
          'key': base64.encode(List.generate(32, (_) => random.nextInt(256))),
          'install_id': '',
          'fcm_token': '',
          'tos': DateTime.now().toUtc().toIso8601String(),
          'model': 'PC',
          'serial_number': List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join(),
          'os_version': '',
          'key_type': 'curve25519',
          'tunnel_type': 'wireguard',
          'locale': 'en_US',
        }),
      ),
    );
    final keys = P256KeyPair.generate();
    final enrolled = await _call(
      () => client.patch(
        Uri.parse('$_api/${registration['id']}'),
        headers: {..._headers, 'Authorization': 'Bearer ${registration['token']}'},
        body: jsonEncode({'key': base64.encode(keys.spki), 'key_type': 'secp256r1', 'tunnel_type': 'masque'}),
      ),
    );
    try {
      final config = enrolled['config'] as Map<String, dynamic>;
      final addresses = (config['interface'] as Map)['addresses'] as Map;
      final peer = (config['peers'] as List).first as Map<String, dynamic>;
      final account = MasqueAccount(
        privateKey: base64.encode(keys.sec1),
        publicKey: MasqueAccount.base64Key('${peer['public_key']}'),
        ipv4: '${addresses['v4']}',
        ipv6: '${addresses['v6']}',
      );
      return (account: account, endpoints: offeredEndpoints(peer['endpoint']));
    } catch (_) {
      throw const MasqueException('Unexpected response from Cloudflare WARP');
    }
  }

  Future<Map<String, dynamic>> _call(Future<http.Response> Function() send) async {
    final http.Response res;
    try {
      res = await send().timeout(const Duration(seconds: 30));
    } catch (e) {
      throw MasqueException('Could not reach Cloudflare WARP: $e', network: true);
    }
    if (res.statusCode != 200) throw MasqueException('MASQUE registration failed (HTTP ${res.statusCode})');
    try {
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw const MasqueException('Unexpected response from Cloudflare WARP');
    }
  }

  /// The MASQUE endpoints in an enrollment's `peers[0].endpoint`: its v4 and v6 addresses
  /// on each of its ports, e.g. "162.159.198.2:443" … "[2606:4700:103::2]:8095". Its `host`
  /// is WireGuard's (engage.cloudflareclient.com:2408), so it's left out.
  static List<String> offeredEndpoints(Object? endpoint) {
    if (endpoint is! Map) return const [];
    final ports = (endpoint['ports'] as List?)?.whereType<int>().toList() ?? const [443];
    // "162.159.198.2:0" / "[2606:4700:103::2]:0": the port is left to the client.
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
