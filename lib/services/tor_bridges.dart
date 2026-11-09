import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/settings.dart';
import 'local_proxy.dart';

class TorBridgesException implements Exception {
  final String message;
  const TorBridgesException(this.message);

  @override
  String toString() => message;
}

/// Gets bridges from Tor Project's Moat API, the endpoint Tor Browser's Connection Assist uses:
/// no captcha, bridges handed out by Tor's distributor (rdsys) for the given country.
class TorBridgeFetcher {
  static const _endpoint = 'https://bridges.torproject.org/moat/circumvention/settings';

  /// Sent explicitly: otherwise Moat goes by the asking IP, which through the tunnel is the
  /// worker's (or WARP's) country.
  static const country = 'ir';

  /// Transports Moat can hand out, with display names.
  static const transports = {'webtunnel': 'WebTunnel', 'obfs4': 'obfs4', 'snowflake': 'Snowflake'};

  /// When set, requests go through this local HTTP proxy (the running tunnel).
  final int? proxyPort;

  const TorBridgeFetcher({this.proxyPort});

  /// Bridges of the given [transports] (keys of [TorBridgeFetcher.transports]).
  Future<List<String>> fetch(List<String> transports) async {
    final inner = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    if (proxyPort != null) LocalProxy.apply(inner, port: proxyPort!);
    final client = IOClient(inner);
    try {
      return await _fetch(client, transports);
    } finally {
      client.close();
    }
  }

  Future<List<String>> _fetch(http.Client client, List<String> transports) async {
    final http.Response res;
    try {
      res = await client
          .post(
            Uri.parse(_endpoint),
            headers: {'Content-Type': 'application/vnd.api+json'},
            body: jsonEncode({'country': country, 'transports': transports}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw TorBridgesException('Could not reach Tor Project: $e');
    }
    if (res.statusCode != 200) throw TorBridgesException('Tor Project answered HTTP ${res.statusCode}');
    final lines = parse(res.body).where((l) => transports.contains(l.split(' ').first)).toList();
    if (lines.isEmpty) throw const TorBridgesException('Tor Project sent no bridges of these types');
    return lines;
  }

  /// The bridge lines in a Moat circumvention/settings response.
  static List<String> parse(String body) {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw const TorBridgesException('Unexpected response from Tor Project');
    }
    final errors = json['errors'];
    if (errors is List && errors.isNotEmpty) {
      final detail = errors.first is Map ? (errors.first as Map)['detail'] : null;
      throw TorBridgesException('Tor Project: ${detail ?? 'request failed'}');
    }
    final lines = <String>[
      for (final s in (json['settings'] as List? ?? const []).whereType<Map>())
        for (final line in ((s['bridges'] as Map?)?['bridge_strings'] as List? ?? const []))
          if (line is String && TorSettings.isBridge(line)) TorSettings.normalize(line),
    ];
    if (lines.isEmpty) throw const TorBridgesException('Tor Project sent no bridges');
    return lines;
  }
}
