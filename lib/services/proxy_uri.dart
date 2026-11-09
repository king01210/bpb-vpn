import 'dart:convert';

/// A parsed share link (vless://, vmess://, trojan://, ss://, socks://, http://, wireguard://,
/// hysteria2://).
///
/// Field names follow BPB's `extractProxyParams` so the chain outbound can be
/// built the same way the panel does.
class ProxyUri {
  /// Xray protocol name: vless, vmess, trojan, shadowsocks, socks, http or wireguard; hysteria2 for
  /// Hysteria2 (Xray's hysteria protocol, version 2).
  final String protocol;
  final String server;
  final int port;
  final Map<String, String> params;
  final String remark;

  const ProxyUri({
    required this.protocol,
    required this.server,
    required this.port,
    this.params = const {},
    this.remark = '',
  });

  String? operator [](String key) {
    final v = params[key];
    return v == null || v.isEmpty ? null : v;
  }

  static const supportedSchemes = {
    'vless',
    'vmess',
    'trojan',
    'ss',
    'socks',
    'socks5',
    'http',
    'wireguard',
    'wg',
    'hysteria2',
    'hy2',
  };

  /// Parses [input]; throws [FormatException] if it isn't a supported link.
  factory ProxyUri.parse(String input) {
    final text = input.trim();
    final schemeEnd = text.indexOf('://');
    if (schemeEnd <= 0) throw const FormatException('Not a proxy link');
    final scheme = text.substring(0, schemeEnd).toLowerCase();
    if (!supportedSchemes.contains(scheme)) throw FormatException('Unsupported protocol: $scheme');

    var body = text.substring(schemeEnd + 3);
    var remark = '';
    final hash = body.indexOf('#');
    if (hash >= 0) {
      remark = _tryDecode(body.substring(hash + 1));
      body = body.substring(0, hash);
    }

    if (scheme == 'vmess') return _parseVmess(body, remark);
    // WireGuard keys are base64: a literal "+" in the query is part of a key, not a space.
    if (scheme == 'wireguard' || scheme == 'wg') body = body.replaceAll('+', '%2B');

    // ss:// may carry the whole "method:pass@host:port" base64-encoded.
    if (scheme == 'ss' && !body.contains('@')) {
      final query = body.indexOf('?');
      final encoded = query >= 0 ? body.substring(0, query) : body;
      body = decodeBase64Loose(encoded) + (query >= 0 ? body.substring(query) : '');
    }

    final uri = Uri.parse('$scheme://$body');
    if (uri.host.isEmpty || !uri.hasPort) throw const FormatException('Link is missing host or port');

    final params = Map<String, String>.of(uri.queryParameters);
    final userInfo = Uri.decodeComponent(uri.userInfo);
    final protocol = switch (scheme) {
      'ss' => 'shadowsocks',
      'socks5' => 'socks',
      'wg' => 'wireguard',
      'hy2' => 'hysteria2',
      _ => scheme,
    };

    switch (protocol) {
      case 'vless':
        params['uuid'] = userInfo;
      case 'trojan':
        params['password'] = userInfo;
      case 'wireguard':
        // wireguard://<private key>@host:port?publickey=…&address=…&mtu=…&reserved=…
        //   &presharedkey=…&dns=…&keepalive=…#name (as v2rayN, NekoBox and Hiddify share them).
        if (userInfo.isEmpty || params['publickey'] == null) {
          throw const FormatException('WireGuard link is missing its keys');
        }
        params['privateKey'] = userInfo;
      case 'hysteria2':
        // hysteria2://<auth>@host:port?sni=…&obfs=salamander&obfs-password=…&pinSHA256=…&mport=…#name
        params['auth'] = userInfo;
      case 'shadowsocks':
        final creds = userInfo.contains(':') ? userInfo : decodeBase64Loose(userInfo);
        final sep = creds.indexOf(':');
        if (sep < 0) throw const FormatException('Invalid shadowsocks credentials');
        params['method'] = creds.substring(0, sep);
        params['password'] = creds.substring(sep + 1);
      case 'socks':
      case 'http':
        if (userInfo.isNotEmpty) {
          var creds = userInfo;
          if (!creds.contains(':')) {
            try {
              creds = decodeBase64Loose(creds);
            } on FormatException {
              // Plain username without password.
            }
          }
          final sep = creds.indexOf(':');
          params['user'] = sep < 0 ? creds : creds.substring(0, sep);
          if (sep >= 0) params['pass'] = creds.substring(sep + 1);
        }
    }

    return ProxyUri(protocol: protocol, server: uri.host, port: uri.port, params: params, remark: remark);
  }

  static ProxyUri _parseVmess(String body, String remark) {
    final json = jsonDecode(decodeBase64Loose(body)) as Map<String, dynamic>;
    String s(String k) => json[k]?.toString() ?? '';
    return ProxyUri(
      protocol: 'vmess',
      server: s('add'),
      port: int.tryParse(s('port')) ?? 0,
      remark: remark.isNotEmpty ? remark : s('ps'),
      params: {
        'uuid': s('id'),
        'type': s('net'),
        'headerType': s('type'),
        'serviceName': s('path'),
        'authority': s('authority'),
        'path': s('path'),
        'host': s('host'),
        'security': s('tls'),
        'sni': s('sni'),
        'fp': s('fp'),
        'alpn': s('alpn'),
        'pcs': s('pcs'),
        'vcn': s('vcn'),
      },
    );
  }

  static String _tryDecode(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }
}

/// Decodes standard or URL-safe base64, with or without padding.
String decodeBase64Loose(String input) {
  var s = input.trim().replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
  final pad = s.length % 4;
  if (pad == 1) throw const FormatException('Invalid base64');
  if (pad > 0) s += '=' * (4 - pad);
  return utf8.decode(base64.decode(s), allowMalformed: true);
}
