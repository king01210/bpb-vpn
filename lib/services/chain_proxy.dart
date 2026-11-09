import 'dart:io';
import 'dart:math';

import '../models/settings.dart';
import 'proxy_uri.dart';
import 'xray_config.dart';

/// What a chain proxy's link says about it, for the UI: name, address and tags.
class ChainInfo {
  final ProxyUri uri;
  const ChainInfo(this.uri);

  /// Null if [link] isn't a supported share link.
  static ChainInfo? of(String link) {
    try {
      return ChainInfo(ProxyUri.parse(link));
    } on FormatException {
      return null;
    }
  }

  bool get isWireGuard => uri.protocol == 'wireguard';

  /// WireGuard and Hysteria2 (QUIC) run over UDP.
  bool get isUdp => isWireGuard || uri.protocol == 'hysteria2';

  /// `host:port` (an IPv6 host in brackets).
  String get address =>
      '${uri.server.contains(':') ? '[${uri.server}]' : uri.server}:${uri.port}';

  String get protocol => switch (uri.protocol) {
    'vless' => 'VLESS',
    'vmess' => 'VMess',
    'trojan' => 'Trojan',
    'shadowsocks' => 'SS',
    'socks' => 'SOCKS',
    'http' => 'HTTP',
    'wireguard' => 'WireGuard',
    'hysteria2' => 'Hysteria2',
    final p => p.toUpperCase(),
  };

  /// The link's `type` for the V2Ray protocols; null for WireGuard and Hysteria2, which have none.
  String? get transport {
    if (isUdp) return null;
    return switch ((uri['type'] ?? 'tcp').toLowerCase()) {
      'tcp' || 'raw' => 'TCP',
      'ws' => 'WS',
      'grpc' => 'gRPC',
      'xhttp' || 'splithttp' => 'XHTTP',
      'httpupgrade' => 'HTTPUpgrade',
      'kcp' || 'mkcp' => 'mKCP',
      'h2' || 'http' => 'HTTP/2',
      final t => t.toUpperCase(),
    };
  }

  /// TLS or Reality; null without security. Hysteria2 is always TLS.
  String? get security => uri.protocol == 'hysteria2'
      ? 'TLS'
      : switch (uri['security']?.toLowerCase()) {
          'tls' => 'TLS',
          'reality' => 'Reality',
          _ => null,
        };

  /// Protocol, transport and security (when there are), as the UI shows them.
  List<String> get tags => [protocol, ?transport, ?security];

  /// What it carries: everything but HTTP proxies also relays UDP.
  List<String> get carries =>
      uri.protocol == 'http' ? const ['TCP'] : const ['TCP', 'UDP'];

  /// Whether a [mode] connection can carry it: WireGuard and Hysteria2 are UDP, which only WARP
  /// and MASQUE carry (the worker relays TCP only).
  bool canChainOver(ConnectionMode mode) =>
      !isUdp || mode == ConnectionMode.warp || mode == ConnectionMode.masque;
}

/// A new chain proxy's id.
String newChainId() {
  final random = Random.secure();
  return List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
}

/// The chain proxies in [text] (pasted, a scanned QR code or a file): share links, one per line,
/// or a WireGuard config (`[Interface]` / `[Peer]`), named [fileName] without its extension when
/// it comes from a file. Throws [FormatException] if none is found.
List<ChainProxy> parseChainProxies(String text, {String? fileName}) {
  if (text.contains('[Interface]')) {
    return [wireGuardConfToChain(text, name: fileName)];
  }
  final proxies = <ChainProxy>[];
  for (final line in text.split(RegExp(r'\s+'))) {
    if (!line.contains('://')) continue;
    final info = ChainInfo.of(line);
    if (info == null) continue;
    final name = info.uri.remark.isNotEmpty ? info.uri.remark : info.address;
    proxies.add(ChainProxy(id: newChainId(), name: name, link: line.trim()));
  }
  if (proxies.isEmpty) {
    throw const FormatException(
      'No supported proxy link or WireGuard config found',
    );
  }
  return proxies;
}

/// A WireGuard config file (`[Interface]` / first `[Peer]`) as a chain proxy, stored as a
/// wireguard:// link named [name] without its extension (wg0.conf → wg0), else the endpoint's
/// host. Throws [FormatException] if a required field is missing.
ChainProxy wireGuardConfToChain(String conf, {String? name}) {
  final interface = <String, String>{};
  final peer = <String, String>{};
  Map<String, String>? section;
  var peers = 0;
  for (final raw in conf.split('\n')) {
    final line = raw.split('#').first.trim();
    if (line.isEmpty) continue;
    if (line.toLowerCase() == '[interface]') {
      section = interface;
    } else if (line.toLowerCase() == '[peer]') {
      section = ++peers == 1 ? peer : null; // Only the first peer.
    } else if (section != null && line.contains('=')) {
      final i = line.indexOf('=');
      section[line.substring(0, i).trim().toLowerCase()] = line
          .substring(i + 1)
          .trim();
    }
  }
  final privateKey = interface['privatekey'];
  final address = interface['address'];
  final publicKey = peer['publickey'];
  final endpoint = peer['endpoint'];
  if (privateKey == null ||
      address == null ||
      publicKey == null ||
      endpoint == null) {
    throw const FormatException(
      'Not a WireGuard config: PrivateKey, Address, PublicKey and Endpoint are needed',
    );
  }
  List<String> list(String? v) => [
    for (final s in (v ?? '').split(','))
      if (s.trim().isNotEmpty) s.trim(),
  ];
  final colon = endpoint.lastIndexOf(':');
  if (colon <= 0) {
    throw const FormatException('WireGuard Endpoint needs host:port');
  }
  final host = endpoint.substring(0, colon).replaceAll(RegExp(r'^\[|\]$'), '');
  final baseName = name?.replaceFirst(RegExp(r'\.[^.]*$'), '').trim() ?? '';
  final label = baseName.isEmpty ? host : baseName;
  final query = {
    'publickey': publicKey,
    'address': list(address).join(','),
    'mtu': ?interface['mtu'],
    'presharedkey': ?peer['presharedkey'],
    'keepalive': ?peer['persistentkeepalive'],
    if (list(peer['allowedips']).isNotEmpty)
      'allowedips': list(peer['allowedips']).join(','),
    // Xray's remoteDNS takes IPs only; search domains in DNS = are left out.
    if (list(interface['dns']).where(_isIp).isNotEmpty)
      'dns': list(interface['dns']).where(_isIp).join(','),
  };
  final link = Uri(
    scheme: 'wireguard',
    userInfo: Uri.encodeComponent(privateKey),
    host: host,
    port: int.tryParse(endpoint.substring(colon + 1)),
    queryParameters: query,
    fragment: label,
  ).toString();
  return ChainProxy(id: newChainId(), name: label, link: link);
}

bool _isIp(String v) => InternetAddress.tryParse(v) != null;
