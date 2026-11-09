import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mitm_ca.dart';

enum VpnStatus { disconnected, connecting, connected, disconnecting }

class VpnStateEvent {
  final VpnStatus status;
  final String? error;
  final DateTime? connectedAt;

  /// What the Psiphon / Tor exit is doing ("Tor 45% · Loading relay descriptors",
  /// "Psiphon reconnecting…"); null otherwise.
  final String? detail;
  const VpnStateEvent(this.status, this.error, this.connectedAt, this.detail);
}

class InstalledApp {
  final String packageName;
  final String label;
  final bool isSystem;
  final Uint8List? icon;
  const InstalledApp(this.packageName, this.label, this.isSystem, this.icon);
}

/// Bridge to the Android VPN service and Xray core (see MainActivity.kt).
class VpnChannel {
  static const _methods = MethodChannel('bpb/core');
  static const _events = EventChannel('bpb/state');
  static Future<bool>? _supportsAppendHttpProxy;

  static Future<bool> get supportsAppendHttpProxy {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return Future.value(false);
    }
    return _supportsAppendHttpProxy ??= _methods
        .invokeMethod<bool>('supportsAppendHttpProxy')
        .then((supported) => supported ?? false);
  }

  static Stream<VpnStateEvent> get states => _events.receiveBroadcastStream().map((e) {
    final map = Map<String, dynamic>.from(e as Map);
    final at = (map['connectedAt'] as num?)?.toInt() ?? 0;
    return VpnStateEvent(
      VpnStatus.values.byName(map['state'] as String),
      map['error'] as String?,
      at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : null,
      map['detail'] as String?,
    );
  });

  /// Asks for VPN permission if needed; true when granted.
  /// Asks for notification permission and, when [vpn], the VPN permission.
  static Future<bool> prepare({bool vpn = true}) async =>
      await _methods.invokeMethod<bool>('prepare', {'vpn': vpn}) ?? false;

  static Future<void> start({
    required Map<String, dynamic> config,
    required String remark,
    required String perAppMode,
    required List<String> apps,
    required int mtu,
    bool appendHttpProxy = false,
    bool proxyOnly = false,
    String? exit,
    bool exitDirect = false,
    String exitRegion = '',
    String? torBridge,
    List<String> torCustomBridges = const [],
    Map<String, dynamic>? psiphonConfig,
    bool browserDialer = false,
  }) => _methods.invokeMethod('start', {
    'config': jsonEncode(config),
    'remark': remark,
    'perAppMode': perAppMode,
    'apps': apps,
    'mtu': mtu,
    'appendHttpProxy': appendHttpProxy,
    'proxyOnly': proxyOnly,
    // Starts that exit process ("psiphon" / "tor"); null for none.
    'exit': exit,
    // The Psiphon / Tor type: the exit connects by itself, not through Xray's psiphon-in / tor-in.
    'exitDirect': exitDirect,
    // The exit's region; "" for the fastest.
    'exitRegion': exitRegion,
    // Tor type: direct, a built-in bridge transport, or custom (torCustomBridges).
    'torBridge': torBridge,
    'torCustomBridges': torCustomBridges,
    // Psiphon config fields for the mode, added to the app's psiphon_config.json (see PsiphonExit.kt).
    'psiphonConfig': psiphonConfig == null ? null : jsonEncode(psiphonConfig),
    // Worker's Browser Dialer: Xray's WebSockets are opened by a WebView (see BrowserDialer.kt).
    'browserDialer': browserDialer,
  });

  /// The end of Xray's log for the current/last connection.
  static Future<String> readLog({String log = 'xray'}) async =>
      await _methods.invokeMethod<String>('readLog', {'log': log}) ?? '';

  /// Bytes in each log ("xray", "tor", "psiphon") since the last connect.
  static Future<Map<String, int>> logSizes() async =>
      (await _methods.invokeMapMethod<String, int>('logSizes')) ?? const {};

  static Future<void> clearLog() => _methods.invokeMethod('clearLog');

  /// Saves [content] as [name] and opens the share sheet so the user picks an app.
  static Future<void> shareFile({required String name, required String content, String title = 'Share'}) =>
      _methods.invokeMethod('shareFile', {'name': name, 'content': content, 'title': title});

  /// Saves [content] as [name] in Downloads (Android 7-9: a Save-as screen). Returns where
  /// it was saved, or null if the user cancelled.
  static Future<String?> saveFile({required String name, required String content}) =>
      _methods.invokeMethod<String>('saveFile', {'name': name, 'content': content});

  /// Opens the system file picker and returns the chosen file's name and text, or null if cancelled.
  static Future<({String name, String content})?> pickFile() async {
    final file = await _methods.invokeMapMethod<String, String>('pickFile');
    if (file == null) return null;
    return (name: file['name'] ?? '', content: file['content'] ?? '');
  }

  static Future<void> stop() => _methods.invokeMethod('stop');

  /// Starts the setup wizard's Tor with [bridges]; returns its HTTP proxy port (SetupTor.kt).
  static Future<int> startSetupTor(List<String> bridges) async =>
      await _methods.invokeMethod<int>('startSetupTor', {'bridges': bridges}) ?? 0;

  /// The setup wizard's Tor: bootstrap progress (0-100), whether it runs, and why it stopped.
  static Future<({int progress, bool running, String? error})> setupTorStatus() async {
    final m = await _methods.invokeMapMethod<String, dynamic>('setupTorStatus') ?? const {};
    return (progress: (m['progress'] as int?) ?? 0, running: m['running'] == true, error: m['error'] as String?);
  }

  static Future<void> stopSetupTor() => _methods.invokeMethod('stopSetupTor');

  /// Opens [url] in the browser; false if nothing could handle it.
  static Future<bool> openUrl(String url) async {
    try {
      return await _methods.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Domain Fronting's CA files (bpb-cert.crt / .key) are in the app's storage.
  static Future<bool> mitmCaExists() async => await _methods.invokeMethod<bool>('mitmCaExists') ?? false;

  static Future<void> saveMitmCa(MitmCa ca) => _methods.invokeMethod('saveMitmCa', {'cert': ca.cert, 'key': ca.key});

  /// Opens Android's CA install; on Android 11+ after saving bpb-cert.crt to Downloads,
  /// whose path it returns.
  static Future<String?> installMitmCa() => _methods.invokeMethod<String>('installMitmCa');

  /// Replaces Xray's geo files (geoip.dat, geosite.dat) with [files], each checked against its
  /// SHA-256 (hex) first: none is replaced unless all match. Xray uses them from its next start.
  static Future<void> saveGeoAssets(Map<String, ({Uint8List data, String sha256})> files) =>
      _methods.invokeMethod('saveGeoAssets', {
        'files': {
          for (final e in files.entries) e.key: {'data': e.value.data, 'sha256': e.value.sha256},
        },
      });

  /// The cores' versions, from their own reports: Xray (e.g. 26.10.21) and
  /// the Psiphon (its core's module version) and Tor ("Tor version …") binaries; empty if unknown.
  static Future<({String xray, String psiphon, String tor})> versions() async {
    final m = await _methods.invokeMapMethod<String, String>('versions') ?? const {};
    return (xray: m['xray'] ?? '', psiphon: m['psiphon'] ?? '', tor: m['tor'] ?? '');
  }

  /// The installed app's version (from pubspec.yaml) and the phone's ABIs, preferred first.
  static Future<({String version, List<String> abis})> appInfo() async {
    final m = await _methods.invokeMapMethod<String, dynamic>('appInfo') ?? const {};
    return (
      version: '${m['version'] ?? ''}',
      abis: (m['abis'] as List? ?? const []).map((e) => '$e').toList(),
    );
  }

  /// Delay in ms through the running tunnel.
  static Future<int> measureDelay() async {
    final ms = await _methods.invokeMethod<int>('measureDelay');
    return ms ?? -1;
  }

  /// Proxied traffic: bytes in the last second and since connecting, sampled by the
  /// VPN service (which also shows proxy and direct rates in its notification).
  static Future<({int up, int down, int totalUp, int totalDown})> traffic() async {
    final m = await _methods.invokeMapMethod<String, int>('trafficStats');
    return (
      up: m?['proxyUp'] ?? 0,
      down: m?['proxyDown'] ?? 0,
      totalUp: m?['proxyUpTotal'] ?? 0,
      totalDown: m?['proxyDownTotal'] ?? 0,
    );
  }

  static Future<List<InstalledApp>> installedApps() async {
    final list = await _methods.invokeListMethod<Map>('installedApps') ?? const [];
    return list
        .map(
          (m) => InstalledApp(
            m['package'] as String,
            m['label'] as String,
            m['system'] as bool? ?? false,
            m['icon'] as Uint8List?,
          ),
        )
        .toList();
  }
}
