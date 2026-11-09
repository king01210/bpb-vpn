/// The app's data, in three documents:
///
/// * [Profile]: how configs are built; shared in exported files. Its VLESS part belongs to
///   the selected deployment (see SavedCfAccount in cf_account.dart).
/// * [DeviceSettings]: this phone only (app mode, per-app, LAN sharing, theme, the selected
///   deployment…). Never exported.
/// * Secrets (Cloudflare accounts: tokens, UUIDs, deployments): encrypted storage, see AppState.
///
/// Every document is stored *sparse*: only values that differ from the defaults, so a
/// changed default reaches everyone who never touched that value. Reading always goes
/// through `fromJson`, which fills in defaults and ignores anything malformed.
library;

import 'dart:convert';

import '../services/masque.dart';
import '../services/warp.dart';

// region json helpers

String _str(Object? v, String def) => v is String ? v : def;

String _choice(Object? value, Set<String> choices, String fallback) =>
    value is String && choices.contains(value) ? value : fallback;

String? _strOrNull(Object? v) =>
    v is String && v.trim().isNotEmpty ? v.trim() : null;

bool _bool(Object? v, bool def) => v is bool ? v : def;

int _int(Object? v, int def) => v is num ? v.toInt() : def;

List<String> _strList(Object? v, List<String> def) => v is List
    ? v.map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList()
    : def;

List<int> _intList(Object? v, List<int> def) =>
    v is List ? v.whereType<num>().map((e) => e.toInt()).toList() : def;

Map<String, dynamic> _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : const {};

/// Reads [path] ("vless.ech.enabled") from nested maps.
Object? readPath(Map<String, dynamic> json, String path) {
  Object? node = json;
  for (final key in path.split('.')) {
    if (node is! Map) return null;
    node = node[key];
  }
  return node;
}

/// Returns a copy of [json] with [path] set to [value].
Map<String, dynamic> writePath(
  Map<String, dynamic> json,
  String path,
  Object? value,
) {
  final keys = path.split('.');
  Map<String, dynamic> write(Map<String, dynamic> node, int i) {
    final copy = Map<String, dynamic>.of(node);
    copy[keys[i]] = i == keys.length - 1
        ? value
        : write(_map(node[keys[i]]), i + 1);
    return copy;
  }

  return write(json, 0);
}

/// The parts of [json] that differ from [defaults] (objects compared field by field,
/// lists as a whole).
Map<String, dynamic> sparseDiff(
  Map<String, dynamic> json,
  Map<String, dynamic> defaults,
) {
  final out = <String, dynamic>{};
  for (final e in json.entries) {
    final def = defaults[e.key];
    if (e.value is Map && def is Map) {
      final nested = sparseDiff(_map(e.value), _map(def));
      if (nested.isNotEmpty) out[e.key] = nested;
    } else if (jsonEncode(e.value) != jsonEncode(def)) {
      out[e.key] = e.value;
    }
  }
  return out;
}

// endregion

// region building blocks

/// A `{min, max}` range: a fragment length, a delay in ms, a noise size…
class Range {
  final int min;
  final int max;
  const Range(this.min, this.max);
  const Range.single(int value) : min = value, max = value;

  static Range parse(Object? v, Range def) {
    if (v is! Map) return def;
    final min = _int(v['min'], def.min), max = _int(v['max'], def.max);
    return min <= max ? Range(min, max) : def;
  }

  static Range? parseOrNull(Object? v) =>
      v is Map ? parse(v, const Range(0, 0)) : null;

  static List<Range> parseList(Object? v, List<Range> def) => v is List
      ? v.whereType<Map>().map((e) => parse(e, const Range(0, 0))).toList()
      : def;

  Map<String, dynamic> toJson() => {'min': min, 'max': max};

  /// Xray's "1-5" / "3" notation.
  String get xray => min == max ? '$min' : '$min-$max';

  @override
  String toString() => min == max ? '$min' : '$min–$max';

  @override
  bool operator ==(Object other) =>
      other is Range && other.min == min && other.max == max;

  @override
  int get hashCode => Object.hash(min, max);
}

/// A DNS server that may be a DoH URL with a hostname, plus that host's own IPs so the
/// app never needs DNS to reach its DNS. Empty [bootstrapIps]: look the host up.
class DnsServer {
  final String server;
  final List<String> bootstrapIps;
  const DnsServer(this.server, [this.bootstrapIps = const []]);

  static DnsServer parse(Object? v, DnsServer def) {
    if (v is! Map) return def;
    return DnsServer(
      _str(v['server'], def.server),
      _strList(v['bootstrapIps'], const []),
    );
  }

  Map<String, dynamic> toJson() => {
    'server': server,
    'bootstrapIps': bootstrapIps,
  };
}

/// Which packets a fragment card splits: the TLS ClientHello or the first N packets.
enum FragmentPackets {
  tlsHello('tlsHello', 'tlshello'),
  first1('1-1', '1-1'),
  first2('1-2', '1-2'),
  first3('1-3', '1-3'),
  first5('1-5', '1-5');

  /// Stored value.
  final String json;

  /// Xray's `packets` value.
  final String xray;
  const FragmentPackets(this.json, this.xray);

  /// Shown as Xray's value, as in BPB's panel.
  String get label => xray;

  static FragmentPackets parse(Object? v) =>
      values.where((p) => p.json == v).firstOrNull ?? FragmentPackets.tlsHello;
}

/// One Xray finalmask "fragment" entry. [lengths]/[delays] apply to the 1st, 2nd…
/// fragment; the last one repeats.
class Fragment {
  final FragmentPackets packets;
  final List<Range> lengths;
  final List<Range> delays;
  final Range? maxSplit;

  const Fragment({
    this.packets = FragmentPackets.tlsHello,
    this.lengths = const [Range(100, 200)],
    this.delays = const [Range.single(1)],
    this.maxSplit,
  });

  static Fragment parse(Map v) => Fragment(
    packets: FragmentPackets.parse(v['packets']),
    lengths: Range.parseList(v['lengths'], const [Range(100, 200)]),
    delays: Range.parseList(v['delays'], const [Range.single(1)]),
    maxSplit: Range.parseOrNull(v['maxSplit']),
  );

  Map<String, dynamic> toJson() => {
    'packets': packets.json,
    'lengths': lengths.map((r) => r.toJson()).toList(),
    'delays': delays.map((r) => r.toJson()).toList(),
    'maxSplit': maxSplit?.toJson(),
  };
}

enum NoiseType {
  rand('Random'),
  str('String'),
  hex('Hex'),
  base64('Base64'),
  array('Array'),
  exp('Expression');

  final String label;
  const NoiseType(this.label);
}

/// One UDP noise entry, sent [count] times. The payload field depends on [type]:
/// `rand` → [size], `array` → [bytes], the others → [packet].
class UdpNoise {
  final NoiseType type;
  final Range? size;
  final List<int>? bytes;
  final String? packet;
  final int count;
  final Range delay;

  const UdpNoise({
    required this.type,
    this.size,
    this.bytes,
    this.packet,
    this.count = 1,
    this.delay = const Range(1, 5),
  });

  static UdpNoise parse(Map v) {
    final type = NoiseType.values.asNameMap()[v['type']] ?? NoiseType.rand;
    return UdpNoise(
      type: type,
      size: type == NoiseType.rand
          ? Range.parse(v['size'], const Range(50, 100))
          : null,
      bytes: type == NoiseType.array ? _intList(v['bytes'], const []) : null,
      packet: type != NoiseType.rand && type != NoiseType.array
          ? _str(v['packet'], '')
          : null,
      count: _int(v['count'], 1).clamp(1, 100),
      delay: Range.parse(v['delay'], const Range(1, 5)),
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type.name,
    if (type == NoiseType.rand) 'size': (size ?? const Range(50, 100)).toJson(),
    if (type == NoiseType.array) 'bytes': bytes ?? const [],
    if (type != NoiseType.rand && type != NoiseType.array)
      'packet': packet ?? '',
    'count': count,
    'delay': delay.toJson(),
  };
}

/// A group of routing rules: built-in [presets] that can be switched on, plus the
/// user's own [custom] domains, IPs and CIDRs.
class RuleGroup {
  final Map<String, bool> presets;

  /// Custom domains, and IPs / CIDRs (the sanction group has domains only).
  final List<String> domains;
  final List<String> ips;
  const RuleGroup(this.presets, {this.domains = const [], this.ips = const []});

  /// Only presets known to [defaults] are kept, each with its default when missing.
  static RuleGroup parse(Object? v, RuleGroup defaults) {
    final j = _map(v);
    final stored = _map(j['presets']);
    return RuleGroup(
      {
        for (final e in defaults.presets.entries)
          e.key: _bool(stored[e.key], e.value),
      },
      domains: _strList(j['domains'], const []),
      ips: _strList(j['ips'], const []),
    );
  }

  bool isOn(String preset) => presets[preset] ?? false;

  Map<String, dynamic> toJson() => {
    'presets': presets,
    'domains': domains,
    'ips': ips,
  };
}

// endregion

// region profile

class GeneralSettings {
  /// "localhost" (the system resolver) or an IP.
  final String localDns;

  /// An IP, or DoH; a DoH domain is resolved with the local DNS.
  final String antiSanctionDns;
  final bool enableFakeDns;
  final bool enableIpv6;

  const GeneralSettings({
    this.localDns = '8.8.8.8',
    this.antiSanctionDns = '178.22.122.100',
    this.enableFakeDns = false,
    this.enableIpv6 = false,
  });

  static GeneralSettings parse(Object? v) {
    final j = _map(v);
    const d = GeneralSettings();
    return GeneralSettings(
      localDns: _str(j['localDns'], d.localDns),
      antiSanctionDns: _str(
        j['antiSanctionDns'] is Map
            ? (j['antiSanctionDns'] as Map)['server']
            : j['antiSanctionDns'],
        d.antiSanctionDns,
      ),
      enableFakeDns: _bool(j['enableFakeDns'], d.enableFakeDns),
      enableIpv6: _bool(j['enableIpv6'], d.enableIpv6),
    );
  }

  Map<String, dynamic> toJson() => {
    'localDns': localDns,
    'antiSanctionDns': antiSanctionDns,
    'enableFakeDns': enableFakeDns,
    'enableIpv6': enableIpv6,
  };
}

/// A saved chain proxy (Settings → Chain proxies): a share link (vless://, vmess://, trojan://,
/// ss://, socks://, http:// or wireguard://, see ProxyUri) and its name. [id] keeps a selection
/// pointing at the right one when names repeat.
class ChainProxy {
  final String id;
  final String name;
  final String link;

  const ChainProxy({required this.id, required this.name, required this.link});

  static ChainProxy? parse(Object? v) {
    final j = _map(v);
    final id = _strOrNull(j['id']), link = _strOrNull(j['link']);
    if (id == null || link == null) return null;
    return ChainProxy(id: id, name: _strOrNull(j['name']) ?? id, link: link);
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'link': link};
}

class EchSettings {
  final bool enabled;

  /// The DNS server the ECH config is fetched from: an IP, or DoH with an IP host.
  final String dns;
  const EchSettings({this.enabled = false, this.dns = '8.8.8.8'});

  static EchSettings parse(Object? v) {
    final j = _map(v);
    const d = EchSettings();
    return EchSettings(
      enabled: _bool(j['enabled'], d.enabled),
      dns: _str(j['dns'], d.dns),
    );
  }

  Map<String, dynamic> toJson() => {'enabled': enabled, 'dns': dns};
}

class CustomCdnSettings {
  final bool enabled;
  final List<String> addresses;
  final String? host;
  final String? sni;
  const CustomCdnSettings({
    this.enabled = false,
    this.addresses = const [],
    this.host,
    this.sni,
  });

  static CustomCdnSettings parse(Object? v) {
    final j = _map(v);
    final addresses = _strList(j['addresses'], const []);
    return CustomCdnSettings(
      // Before the switch, the addresses alone turned it on.
      enabled: _bool(j['enabled'], addresses.isNotEmpty),
      addresses: addresses,
      host: _strOrNull(j['host']),
      sni: _strOrNull(j['sni']),
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'addresses': addresses,
    'host': host,
    'sni': sni,
  };
}

class VlessSettings {
  final DnsServer remoteDns;
  final List<int> ports;
  final List<String> cleanIps;
  final String tlsFingerprint;

  /// Seconds between Best Ping probes.
  final int speedTestInterval;
  final bool enableTcpFastOpen;
  final EchSettings ech;
  final CustomCdnSettings customCdn;

  /// "host:port" of a TLS TCP relay in front of Cloudflare; not used with fragment.
  final String? upstreamProxy;

  /// Used by the worker to reach Cloudflare-hosted sites; empty: its built-in default.
  /// Pushed to the worker's `pips` variable.
  final List<String> proxyIps;

  /// Site the worker shows to non-VPN visitors; null: 404. Pushed to the worker's
  /// `FALLBACK_URL` variable.
  final String? fallbackUrl;

  const VlessSettings({
    this.remoteDns = const DnsServer('https://8.8.8.8/dns-query'),
    this.ports = const [443],
    this.cleanIps = const ['104.17.148.22', '104.17.147.22'],
    this.tlsFingerprint = 'chrome',
    this.speedTestInterval = 60,
    this.enableTcpFastOpen = false,
    this.ech = const EchSettings(),
    this.customCdn = const CustomCdnSettings(),
    this.upstreamProxy,
    this.proxyIps = const [],
    this.fallbackUrl,
  });

  static VlessSettings parse(Object? v) {
    final j = _map(v);
    const d = VlessSettings();
    return VlessSettings(
      remoteDns: DnsServer.parse(j['remoteDns'], d.remoteDns),
      ports: _intList(j['ports'], d.ports),
      cleanIps: _strList(j['cleanIps'], d.cleanIps),
      tlsFingerprint: _str(j['tlsFingerprint'], d.tlsFingerprint),
      speedTestInterval: _int(j['speedTestInterval'], d.speedTestInterval),
      enableTcpFastOpen: _bool(j['enableTcpFastOpen'], d.enableTcpFastOpen),
      ech: EchSettings.parse(j['ech']),
      customCdn: CustomCdnSettings.parse(j['customCdn']),
      upstreamProxy: _strOrNull(j['upstreamProxy']),
      proxyIps: _strList(j['proxyIps'], d.proxyIps),
      fallbackUrl: _strOrNull(j['fallbackUrl']),
    );
  }

  Map<String, dynamic> toJson() => {
    'remoteDns': remoteDns.toJson(),
    'ports': ports,
    'cleanIps': cleanIps,
    'tlsFingerprint': tlsFingerprint,
    'speedTestInterval': speedTestInterval,
    'enableTcpFastOpen': enableTcpFastOpen,
    'ech': ech.toJson(),
    'customCdn': customCdn.toJson(),
    'upstreamProxy': upstreamProxy,
    'proxyIps': proxyIps,
    'fallbackUrl': fallbackUrl,
  };
}

class WarpSettings {
  /// IP of the DNS server used through WARP.
  final String remoteDns;
  final List<String> endpoints;
  final int keepAlive;
  final int speedTestInterval;
  final bool enableReservedBytes;

  /// Registered on first WARP connect (free); shared by every owner device.
  final WarpAccount? account;

  const WarpSettings({
    this.remoteDns = '1.1.1.1',
    // Set from the account's registration (see AppState.renewWarpAccount).
    this.endpoints = const [],
    this.keepAlive = 10,
    this.speedTestInterval = 30,
    this.enableReservedBytes = true,
    this.account,
  });

  static WarpSettings parse(Object? v) {
    final j = _map(v);
    const d = WarpSettings();
    return WarpSettings(
      remoteDns: _str(j['remoteDns'], d.remoteDns),
      endpoints: _strList(j['endpoints'], d.endpoints),
      keepAlive: _int(j['keepAlive'], d.keepAlive),
      speedTestInterval: _int(j['speedTestInterval'], d.speedTestInterval),
      enableReservedBytes: _bool(
        j['enableReservedBytes'],
        d.enableReservedBytes,
      ),
      account: j['account'] is Map
          ? WarpAccount.fromJson(_map(j['account']))
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'remoteDns': remoteDns,
    'endpoints': endpoints,
    'keepAlive': keepAlive,
    'speedTestInterval': speedTestInterval,
    'enableReservedBytes': enableReservedBytes,
    'account': account?.toJson(),
  };
}

/// The MASQUE type: WARP over CONNECT-IP (HTTP/2 or 3), with its own transport setting, account,
/// fragments and UDP noises (defaults like the profile's).
/// Serverless's own fragments and UDP noises (defaults like the profile's).
class ServerlessSettings {
  final List<Fragment> fragments;
  final List<UdpNoise> udpNoises;

  /// How often (seconds, random within the range) the UDP noises are sent again.
  final Range udpNoiseReset;

  const ServerlessSettings({
    this.fragments = const [Fragment()],
    this.udpNoises = Profile.defaultUdpNoises,
    this.udpNoiseReset = Profile.defaultUdpNoiseReset,
  });

  static ServerlessSettings parse(Object? v) {
    final j = _map(v);
    const d = ServerlessSettings();
    return ServerlessSettings(
      fragments: j['fragments'] is List
          ? (j['fragments'] as List)
                .whereType<Map>()
                .map(Fragment.parse)
                .toList()
          : d.fragments,
      udpNoises: j['udpNoises'] is List
          ? (j['udpNoises'] as List)
                .whereType<Map>()
                .map(UdpNoise.parse)
                .toList()
          : d.udpNoises,
      udpNoiseReset: Range.parse(j['udpNoiseReset'], d.udpNoiseReset),
    );
  }

  Map<String, dynamic> toJson() => {
    'fragments': fragments.map((f) => f.toJson()).toList(),
    'udpNoises': udpNoises.map((n) => n.toJson()).toList(),
    'udpNoiseReset': udpNoiseReset.toJson(),
  };
}

class MasqueSettings {
  /// Transport used by MASQUE: HTTP/2 over TCP or HTTP/3 over QUIC.
  final String transport;

  /// IP of the DNS server used through the tunnel.
  final String remoteDns;

  /// The TLS server name sent to the MASQUE endpoints.
  final String sni;
  final String tlsFingerprint;
  final List<String> endpoints;
  final int speedTestInterval;

  /// MASQUE H2 fragment settings.
  final List<Fragment> fragments;

  /// MASQUE H3 UDP noise settings and reset interval.
  final List<UdpNoise> udpNoises;
  final Range udpNoiseReset;

  /// Registered on first MASQUE connect (free); shared by every owner device.
  final MasqueAccount? account;

  static const defaultSni = 'speed.cloudflare.com';

  const MasqueSettings({
    this.transport = 'h2',
    this.remoteDns = '1.1.1.1',
    this.sni = defaultSni,
    this.tlsFingerprint = 'chrome',
    // Set from the account's enrollment (see AppState.renewMasqueAccount).
    this.endpoints = const [],
    this.speedTestInterval = 30,
    this.fragments = const [Fragment()],
    this.udpNoises = Profile.defaultUdpNoises,
    this.udpNoiseReset = Profile.defaultUdpNoiseReset,
    this.account,
  });

  static MasqueSettings parse(Object? v) {
    final j = _map(v);
    const d = MasqueSettings();
    return MasqueSettings(
      transport: j['transport'] == 'h3' ? 'h3' : d.transport,
      remoteDns: _str(j['remoteDns'], d.remoteDns),
      sni: _str(j['sni'], d.sni),
      tlsFingerprint: _str(j['tlsFingerprint'], d.tlsFingerprint),
      endpoints: _strList(j['endpoints'], d.endpoints),
      speedTestInterval: _int(j['speedTestInterval'], d.speedTestInterval),
      fragments: j['fragments'] is List
          ? (j['fragments'] as List)
                .whereType<Map>()
                .map(Fragment.parse)
                .toList()
          : d.fragments,
      udpNoises: j['udpNoises'] is List
          ? (j['udpNoises'] as List)
                .whereType<Map>()
                .map(UdpNoise.parse)
                .toList()
          : d.udpNoises,
      udpNoiseReset: Range.parse(j['udpNoiseReset'], d.udpNoiseReset),
      account: j['account'] is Map
          ? MasqueAccount.fromJson(_map(j['account']))
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'transport': transport,
    'remoteDns': remoteDns,
    'sni': sni,
    'tlsFingerprint': tlsFingerprint,
    'endpoints': endpoints,
    'speedTestInterval': speedTestInterval,
    'fragments': fragments.map((f) => f.toJson()).toList(),
    'udpNoises': udpNoises.map((n) => n.toJson()).toList(),
    'udpNoiseReset': udpNoiseReset.toJson(),
    'account': account?.toJson(),
  };
}

/// The Tor type's own bridges ("Custom bridges"). Private: left out of exported files.
class TorSettings {
  /// Bridge lines as given by bridges.torproject.org / @GetBridgesBot, without torrc's "Bridge".
  final List<String> bridges;

  const TorSettings({this.bridges = const []});

  /// Transports lyrebird provides.
  static const transports = {'webtunnel', 'obfs4', 'snowflake', 'meek_lite'};

  /// [line] without a leading "Bridge " and surrounding spaces.
  static String normalize(String line) =>
      line.trim().replaceFirst(RegExp(r'^bridge\s+', caseSensitive: false), '');

  /// Whether [line] is a bridge of a transport in [transports].
  static bool isBridge(String line) =>
      transports.contains(normalize(line).split(RegExp(r'\s+')).first);

  static TorSettings parse(Object? v) {
    final j = _map(v);
    return TorSettings(
      bridges: _strList(
        j['bridges'],
        const [],
      ).where(isBridge).map(normalize).toList(),
    );
  }

  Map<String, dynamic> toJson() => {'bridges': bridges};
}

/// Built-in routing presets, each with its default and how it behaves.
class RoutingPresets {
  /// Direct, resolved with the local DNS, matched by domain and IP; BitTorrent by protocol.
  static const bypass = {
    'iran': false,
    'china': false,
    'russia': false,
    'bittorrent': false,
  };

  /// Direct, resolved with the anti-sanction DNS, matched by domain only.
  static const sanctionBypass = {
    'openAi': false,
    'googleAi': false,
    'microsoft': false,
    'oracle': false,
    'docker': false,
    'adobe': false,
    'epicGames': false,
    'intel': false,
    'amd': false,
    'nvidia': false,
    'asus': false,
    'hp': false,
    'lenovo': false,
  };

  static const block = {
    'ads': false,
    'porn': false,
    'malware': false,
    'phishing': false,
    'cryptominers': false,
    'quic': false,
  };
}

class RoutingSettings {
  final RuleGroup bypass;
  final RuleGroup sanctionBypass;
  final RuleGroup block;

  const RoutingSettings({
    this.bypass = const RuleGroup(RoutingPresets.bypass),
    this.sanctionBypass = const RuleGroup(RoutingPresets.sanctionBypass),
    this.block = const RuleGroup(RoutingPresets.block),
  });

  static RoutingSettings parse(Object? v) {
    final j = _map(v);
    const d = RoutingSettings();
    return RoutingSettings(
      bypass: RuleGroup.parse(j['bypass'], d.bypass),
      sanctionBypass: RuleGroup.parse(j['sanctionBypass'], d.sanctionBypass),
      block: RuleGroup.parse(j['block'], d.block),
    );
  }

  Map<String, dynamic> toJson() => {
    'bypass': bypass.toJson(),
    'sanctionBypass': sanctionBypass.toJson(),
    'block': block.toJson(),
  };
}

/// How configs are built; exported. [vless] is the selected deployment's (see AppState.profile).
class Profile {
  static const schemaVersion = 1;

  final GeneralSettings general;
  final VlessSettings vless;
  final WarpSettings warp;
  final MasqueSettings masque;
  final ServerlessSettings serverless;
  final TorSettings tor;

  /// The saved chain proxies (Settings → Chain proxies); which one a connection uses is the
  /// device's choice (DeviceSettings.exitChains).
  final List<ChainProxy> chains;

  /// Used by Worker's Fragment mode.
  final List<Fragment> fragments;

  /// Used by WARP's obfuscated variants.
  final List<UdpNoise> udpNoises;

  /// How often (seconds, random within the range) the UDP noises are sent again.
  final Range udpNoiseReset;
  final RoutingSettings routing;

  static const defaultUdpNoises = [
    UdpNoise(type: NoiseType.rand, size: Range(50, 100), count: 5),
  ];
  static const defaultUdpNoiseReset = Range(30, 60);

  const Profile({
    this.general = const GeneralSettings(),
    this.vless = const VlessSettings(),
    this.warp = const WarpSettings(),
    this.masque = const MasqueSettings(),
    this.serverless = const ServerlessSettings(),
    this.tor = const TorSettings(),
    this.chains = const [],
    this.fragments = const [Fragment()],
    this.udpNoises = defaultUdpNoises,
    this.udpNoiseReset = defaultUdpNoiseReset,
    this.routing = const RoutingSettings(),
  });

  static Profile fromJson(Map<String, dynamic> j) => Profile(
    general: GeneralSettings.parse(j['general']),
    vless: VlessSettings.parse(j['vless']),
    warp: WarpSettings.parse(j['warp']),
    masque: MasqueSettings.parse(j['masque']),
    serverless: ServerlessSettings.parse(j['serverless']),
    tor: TorSettings.parse(j['tor']),
    chains: (j['chains'] as List? ?? const [])
        .map(ChainProxy.parse)
        .whereType<ChainProxy>()
        .toList(),
    fragments: j['fragments'] is List
        ? (j['fragments'] as List).whereType<Map>().map(Fragment.parse).toList()
        : const [Fragment()],
    udpNoises: j['udpNoises'] is List
        ? (j['udpNoises'] as List).whereType<Map>().map(UdpNoise.parse).toList()
        : const Profile().udpNoises,
    udpNoiseReset: Range.parse(j['udpNoiseReset'], defaultUdpNoiseReset),
    routing: RoutingSettings.parse(j['routing']),
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'general': general.toJson(),
    'vless': vless.toJson(),
    'warp': warp.toJson(),
    'masque': masque.toJson(),
    'serverless': serverless.toJson(),
    'tor': tor.toJson(),
    'chains': chains.map((c) => c.toJson()).toList(),
    'fragments': fragments.map((f) => f.toJson()).toList(),
    'udpNoises': udpNoises.map((n) => n.toJson()).toList(),
    'udpNoiseReset': udpNoiseReset.toJson(),
    'routing': routing.toJson(),
  };

  /// What's stored: only values that differ from the defaults.
  Map<String, dynamic> toSparseJson() => {
    'schemaVersion': schemaVersion,
    ...sparseDiff(toJson(), const Profile().toJson())..remove('schemaVersion'),
  };

  /// For exported files: everything except the private parts, the WARP and MASQUE accounts and
  /// Tor bridges. Chain proxies are included.
  Map<String, dynamic> toExportJson() {
    final json = toSparseJson();
    void drop(String section, String key) {
      final rest = {..._map(json[section])}..remove(key);
      if (rest.isEmpty) {
        json.remove(section);
      } else {
        json[section] = rest;
      }
    }

    drop('warp', 'account');
    drop('masque', 'account');
    drop('tor', 'bridges');
    return json;
  }

  /// [other] with this profile's private parts (see [toExportJson]), e.g. after an import.
  Profile keepingPrivate(Profile other) => other
      .updated('warp.account', warp.account?.toJson())
      .updated('masque.account', masque.account?.toJson())
      .updated('tor.bridges', tor.bridges);

  /// A copy with [path] ("vless.ech.enabled") set to [value], re-validated.
  Profile updated(String path, Object? value) =>
      Profile.fromJson(writePath(toJson(), path, value));
}

// endregion

// region device

enum AppMode { vpn, proxy }

enum PerAppMode { off, include, exclude }

/// Where traffic leaves for the internet, after the connection type's own outbound.
enum ExitNode {
  /// The connection itself: the worker (VLESS), WARP, or direct (Serverless).
  worker,

  /// A chain proxy from Settings → Chain proxies, dialed through the connection.
  chain,

  /// Psiphon, reaching its servers through the connection.
  psiphon,

  /// Tor, reaching its relays through the connection. TCP only.
  tor,
}

/// The Tor type's bridge choices: none ("direct", also how the Tor exit connects), Tor's built-in
/// bridges of a transport (pt_config.json in the Tor bundle), or the user's own (TorSettings).
const torBridges = {
  'direct': 'Direct',
  'snowflake': 'Snowflake',
  'obfs4': 'obfs4',
  'meek': 'meek',
  'custom': 'Custom bridges',
};

/// Exit regions offered for Psiphon and Tor (Psiphon's egress regions), by ISO code.
const exitRegions = {
  'AT': 'Austria',
  'AU': 'Australia',
  'BE': 'Belgium',
  'BG': 'Bulgaria',
  'CA': 'Canada',
  'CH': 'Switzerland',
  'CZ': 'Czechia',
  'DE': 'Germany',
  'DK': 'Denmark',
  'EE': 'Estonia',
  'ES': 'Spain',
  'FI': 'Finland',
  'FR': 'France',
  'GB': 'United Kingdom',
  'HR': 'Croatia',
  'HU': 'Hungary',
  'IE': 'Ireland',
  'IN': 'India',
  'IT': 'Italy',
  'JP': 'Japan',
  'LV': 'Latvia',
  'NL': 'Netherlands',
  'NO': 'Norway',
  'PL': 'Poland',
  'PT': 'Portugal',
  'RO': 'Romania',
  'RS': 'Serbia',
  'SE': 'Sweden',
  'SG': 'Singapore',
  'SK': 'Slovakia',
  'US': 'United States',
};

/// The deployment configs connect to (built from the selected one, see AppState.worker).
class ActiveWorker {
  final String accountId;

  /// Worker script / Pages project name.
  final String name;
  final WorkerType type;
  final String host;
  final String? customDomain;

  const ActiveWorker({
    required this.accountId,
    required this.name,
    required this.type,
    required this.host,
    this.customDomain,
  });

  /// Domains configs connect to: workers.dev / pages.dev first, then the custom domain.
  List<String> get domains => [host, ?customDomain];
}

/// Where the worker script runs.
enum WorkerType {
  workers('Workers'),
  pages('Pages');

  final String label;
  const WorkerType(this.label);
}

/// This phone only: never exported.
class DeviceSettings {
  static const schemaVersion = 1;

  final AppMode appMode;
  final String logLevel;
  final int mtu;
  final bool appendHttpProxy;
  final PerAppMode perAppMode;
  final List<String> perAppApps;
  final bool lanSharing;
  final String? lanUsername;
  final String? lanPassword;

  /// Connection type name (see ConnectionMode) and its mode choices.
  final String connectionType;

  /// Worker's and WARP's ConnectionVariant names.
  final String workerVariant;
  final String warpVariant;

  /// MASQUE's normal / obfuscated variant (Fragment with H2).
  final String masqueVariant;

  /// Serverless's ServerlessMode name.
  final String serverlessMode;

  /// Tor type: which bridges (a [torBridges] key).
  final String torBridge;

  /// The exit node of each connection type (ConnectionMode names); [exitNode] for the others.
  final ExitNode exitNode;
  final Map<String, ExitNode> exitNodes;

  /// The chain proxy (a ChainProxy id) each connection type exits through.
  final Map<String, String> exitChains;

  /// Psiphon / Tor exit region (an [exitRegions] key), or empty for any region.
  final String exitRegion;

  final String themeColor;
  final String themeMode;

  /// The selected deployment: `<account id>/<workers or pages>`; empty for the first one.
  final String deployment;

  /// The setup wizard was finished (whatever it skipped).
  final bool setupDone;

  const DeviceSettings({
    this.appMode = AppMode.vpn,
    this.logLevel = 'warning',
    this.mtu = 1500,
    this.appendHttpProxy = false,
    this.perAppMode = PerAppMode.off,
    this.perAppApps = const [],
    this.lanSharing = false,
    this.lanUsername,
    this.lanPassword,
    this.connectionType = 'worker',
    this.workerVariant = 'normal',
    this.warpVariant = 'normal',
    this.masqueVariant = 'normal',
    this.serverlessMode = 'fragment',
    this.torBridge = 'snowflake',
    this.exitNode = ExitNode.worker,
    this.exitNodes = const {},
    this.exitChains = const {},
    this.exitRegion = '',
    this.themeColor = 'blue',
    this.themeMode = 'system',
    this.deployment = '',
    this.setupDone = false,
  });

  static DeviceSettings fromJson(Map<String, dynamic> j) {
    const d = DeviceSettings();
    final perApp = _map(j['perAppProxy']);
    final lan = _map(j['lanSharing']);
    final connection = _map(j['connection']);
    final exit = _map(j['exit']);
    final theme = _map(j['theme']);
    final region = _str(exit['region'], d.exitRegion);
    final bridge = _str(connection['torBridge'], d.torBridge);
    // Older connection types that had a separate Fragment or WARP Pro mode.
    final type = _str(connection['type'], d.connectionType);
    String legacyVariant(String obfuscatedType, String obfuscatedVariant) =>
        type != obfuscatedType ? 'normal' : obfuscatedVariant;
    return DeviceSettings(
      appMode: AppMode.values.asNameMap()[j['appMode']] ?? d.appMode,
      logLevel: _str(j['logLevel'], d.logLevel),
      mtu: _int(j['mtu'], d.mtu),
      appendHttpProxy: _bool(j['appendHttpProxy'], d.appendHttpProxy),
      perAppMode: PerAppMode.values.asNameMap()[perApp['mode']] ?? d.perAppMode,
      perAppApps: _strList(perApp['apps'], d.perAppApps),
      lanSharing: _bool(lan['enabled'], d.lanSharing),
      lanUsername: _strOrNull(lan['username']),
      lanPassword: _strOrNull(lan['password']),
      connectionType: switch (type) {
        'normal' || 'fragment' => 'worker',
        'warpPro' => 'warp',
        _ => type,
      },
      workerVariant: _choice(
        _str(
          connection['workerVariant'],
          legacyVariant('fragment', 'fragment'),
        ),
        const {'normal', 'fragment', 'browserDialer'},
        d.workerVariant,
      ),
      warpVariant: _choice(
        _str(connection['warpVariant'], legacyVariant('warpPro', 'obfuscated')),
        const {'normal', 'obfuscated'},
        d.warpVariant,
      ),
      masqueVariant: _choice(connection['masqueVariant'], const {
        'normal',
        'obfuscated',
      }, d.masqueVariant),
      serverlessMode: _str(connection['serverlessMode'], d.serverlessMode),
      torBridge: torBridges.containsKey(bridge) ? bridge : d.torBridge,
      exitNode: ExitNode.values.asNameMap()[exit['node']] ?? d.exitNode,
      exitNodes: {
        for (final e in _map(exit['nodes']).entries)
          e.key: ?ExitNode.values.asNameMap()[e.value],
      },
      exitChains: {
        for (final e in _map(exit['chains']).entries)
          if (e.value is String) e.key: e.value as String,
      },
      exitRegion: exitRegions.containsKey(region) ? region : d.exitRegion,
      themeColor: _str(theme['color'], d.themeColor),
      themeMode: _str(theme['mode'], d.themeMode),
      deployment: _str(j['deployment'], d.deployment),
      setupDone: _bool(j['setupDone'], d.setupDone),
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'appMode': appMode.name,
    'logLevel': logLevel,
    'mtu': mtu,
    'appendHttpProxy': appendHttpProxy,
    'perAppProxy': {'mode': perAppMode.name, 'apps': perAppApps},
    'lanSharing': {
      'enabled': lanSharing,
      'username': lanUsername,
      'password': lanPassword,
    },
    'connection': {
      'type': connectionType,
      'workerVariant': workerVariant,
      'warpVariant': warpVariant,
      'masqueVariant': masqueVariant,
      'serverlessMode': serverlessMode,
      'torBridge': torBridge,
    },
    'exit': {
      'node': exitNode.name,
      'nodes': {for (final e in exitNodes.entries) e.key: e.value.name},
      'chains': exitChains,
      'region': exitRegion,
    },
    'theme': {'color': themeColor, 'mode': themeMode},
    'deployment': deployment,
    'setupDone': setupDone,
  };

  Map<String, dynamic> toSparseJson() => {
    'schemaVersion': schemaVersion,
    ...sparseDiff(toJson(), const DeviceSettings().toJson())
      ..remove('schemaVersion'),
  };

  /// The exit node chosen for a connection type ([mode]: a ConnectionMode name).
  ExitNode exitNodeFor(String mode) => exitNodes[mode] ?? exitNode;

  DeviceSettings updated(String path, Object? value) =>
      DeviceSettings.fromJson(writePath(toJson(), path, value));

  /// Login for the local proxy: only with LAN sharing on and both fields set.
  ({String user, String pass})? get lanAuth {
    final user = lanUsername, pass = lanPassword;
    if (!lanSharing || user == null || pass == null) return null;
    return (user: user, pass: pass);
  }
}

// endregion
