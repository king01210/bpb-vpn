import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/settings.dart';
import 'chain_proxy.dart';
import 'domain_fronting_v23.dart';
import 'masque.dart';
import 'proxy_uri.dart';
import 'public_dns.dart';
import 'warp.dart';

const _unsafeCipherSuites =
    'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA:TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA:TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256:TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256';

/// How traffic reaches the internet.
enum ConnectionMode {
  /// VLESS over WebSocket + TLS through the worker; see [ConnectionVariant].
  worker('Worker'),

  /// WireGuard to Cloudflare WARP (no worker); see [ConnectionVariant].
  warp('WARP'),

  /// Cloudflare WARP over MASQUE (CONNECT-IP over HTTP/2 or 3), with its own account; see
  /// [MasqueVariant].
  masque('MASQUE'),

  /// No worker: everything exits through Psiphon, which connects to its servers directly.
  psiphon('Psiphon'),

  /// No worker: everything (TCP) exits through Tor, which connects through built-in bridges.
  tor('Tor'),

  /// No worker: direct connections with TLS fragmentation and UDP noise.
  serverless('Serverless');

  final String label;
  const ConnectionMode(this.label);

  bool get isWarp => this == warp;

  /// WARP over WireGuard or MASQUE: a tunnel of IP packets (UDP too) to Cloudflare, with an
  /// IP as remote DNS.
  bool get isWarpLike => this == warp || this == masque;

  /// Modes that connect through the deployed worker.
  bool get needsWorker => this == worker;

  /// Worker and WARP come in [ConnectionVariant]s.
  bool get hasVariants => this == worker || this == warp;
}

/// Worker: Normal, Fragment or Browser Dialer. WARP: Normal or Obfuscated.
enum ConnectionVariant {
  normal,
  fragment,
  obfuscated,
  browserDialer;

  /// The variants [mode] offers.
  static List<ConnectionVariant> of(ConnectionMode mode) =>
      mode == ConnectionMode.worker
      ? const [normal, fragment, browserDialer]
      : const [normal, obfuscated];

  String label(ConnectionMode mode) {
    if (mode == ConnectionMode.worker) {
      return switch (this) {
        normal => 'Normal',
        fragment => 'Fragment',
        browserDialer => 'Browser Dialer',
        obfuscated => 'Obfuscated',
      };
    }
    return switch (this) {
      normal => 'Normal',
      obfuscated => 'Obfuscated',
      fragment => 'Fragment',
      browserDialer => 'Browser Dialer',
    };
  }
}

/// MASQUE's home-page mode. Transport is chosen in MASQUE settings.
enum MasqueVariant {
  normal,
  obfuscated;

  String label(bool h3) => switch (this) {
    normal => 'Normal',
    obfuscated => h3 ? 'Obfuscated' : 'Fragment',
  };
}

/// Serverless configs: TLS fragmentation and UDP noise, or patterniha's MITM domain fronting
/// (browsers only: it decrypts their TLS with the app's own CA, see MitmCa).
enum ServerlessMode {
  fragment('Fragment'),
  domainFronting('Domain Fronting');

  final String label;
  const ServerlessMode(this.label);
}

class XrayBuild {
  final Map<String, dynamic> config;
  const XrayBuild(this.config);
}

typedef HostResolver = Future<List<String>> Function(
  String host, {
  required bool ipv6,
});

/// Builds Xray configs from the BPB settings, mirroring BPB-Worker-Panel's
/// src/cores/xray (configs.ts, outbounds.ts, dns.ts, routing.ts) but with a
/// TUN inbound for the Android VPN and VLESS as the only protocol.
class XrayConfigBuilder {
  /// Cloudflare TLS ports. Plain-HTTP ports aren't offered: Xray refuses VLESS without TLS.
  static const httpsPorts = [443, 8443, 2053, 2083, 2087, 2096];
  static const probeUrl = 'https://www.gstatic.com/generate_204';

  /// Direct internet check for the burst observatory (Cloudflare's captive-portal check).
  static const connectivityUrl = 'http://cp.cloudflare.com/generate_204';

  /// Recent pings averaged per outbound by the burst observatory.
  static const _probeSamples = 3;
  static const localProxyPort = 10808;

  /// Psiphon / Tor exit (see ExitProcess.kt): it dials its servers through the psiphon-in /
  /// tor-in inbound, and serves SOCKS5 for the exit outbound (Psiphon: TCP and UDP; Tor: TCP).
  static const exitUpstreamPort = 10828;
  static const exitPort = 10829;

  /// The exit process's DNS server, the remote DNS of the Psiphon / Tor types: Tor's DNSPort,
  /// or Psiphon's own resolver (psiphon/dns.go).
  static const exitDnsPort = 10830;

  final Profile profile;
  final DeviceSettings device;

  /// The worker to connect to and its VLESS UUID; null for WARP / Serverless only.
  final ActiveWorker? worker;
  final String? uuid;
  final HostResolver resolver;
  final Random _random;

  XrayConfigBuilder(
    this.profile,
    this.device, {
    this.worker,
    this.uuid,
    HostResolver? resolver,
    Random? random,
  }) : resolver = resolver ?? systemResolve,
       _random = random ?? Random();

  /// The exit for the connection being built (see [exitFor]).
  ExitNode _exit = ExitNode.worker;

  /// The connection type being built.
  ConnectionMode _mode = ConnectionMode.worker;

  /// Domain Fronting's config, parsed while building it.
  Map<String, dynamic>? _v23;

  /// Domain Fronting with a Psiphon / Tor exit: the regular config, the exit's connections fronted.
  bool get _frontedExit => _v23 != null && _chainedExit;

  /// Domain Fronting with an exit: the domains local-dns answers, which dns-out hands to the
  /// DNS module (see [_buildDns]).
  List<String> _localDnsDomains = const [];

  /// Anti-sanction DNS and rules: only with WARP / MASQUE / Serverless and the Default exit node
  /// (with Psiphon, Tor or a chain proxy those sites go through the exit like everything else).
  bool get _antiSanction =>
      (_mode.isWarpLike || _mode == ConnectionMode.serverless) &&
      _exit == ExitNode.worker;

  /// [address] (an IP, "[IPv6]" or a domain, optionally with a port) when IPv6 is on or it
  /// isn't an IPv6 address.
  bool _allowedAddress(String address) {
    if (_general.enableIpv6) return true;
    final host =
        RegExp(r'^\[([^\]]+)\]').firstMatch(address)?.group(1) ?? address;
    return InternetAddress.tryParse(host)?.type != InternetAddressType.IPv6;
  }

  /// WARP endpoints, without IPv6 ones when IPv6 is off.
  List<String> _warpEndpoints() {
    final endpoints = _warp.endpoints.where(_allowedAddress).toList();
    if (endpoints.isEmpty && _warp.endpoints.isNotEmpty) {
      throw StateError(
        'All WARP endpoints are IPv6: enable IPv6 or add an IPv4 endpoint.',
      );
    }
    return endpoints;
  }

  /// The exit node used with [mode] (chosen per connection type): Serverless has no chain
  /// proxy, the Psiphon and Tor types always exit through Psiphon / Tor, and without a chain
  /// proxy [mode] can carry ([chainFor]) there's no chain exit either.
  static ExitNode exitFor(
    ConnectionMode mode,
    DeviceSettings device,
    List<ChainProxy> chains,
  ) {
    if (mode == ConnectionMode.psiphon) return ExitNode.psiphon;
    if (mode == ConnectionMode.tor) return ExitNode.tor;
    final node = device.exitNodeFor(mode.name);
    if (node == ExitNode.chain &&
        (mode == ConnectionMode.serverless ||
            chainFor(mode, device, chains) == null)) {
      return ExitNode.worker;
    }
    return node;
  }

  /// The chain proxies a [mode] connection can carry (no WireGuard over the worker).
  static List<ChainProxy> chainsFor(
    ConnectionMode mode,
    List<ChainProxy> chains,
  ) => [
    for (final c in chains)
      if (ChainInfo.of(c.link)?.canChainOver(mode) ?? false) c,
  ];

  /// The chain proxy [mode] exits through: the one chosen for it, or else the first it can carry.
  static ChainProxy? chainFor(
    ConnectionMode mode,
    DeviceSettings device,
    List<ChainProxy> chains,
  ) {
    final usable = chainsFor(mode, chains);
    final id = device.exitChains[mode.name];
    return usable.where((c) => c.id == id).firstOrNull ?? usable.firstOrNull;
  }

  /// Psiphon config fields for the exit process (added to the app's psiphon_config.json), or
  /// null. Domain Fronting: only fronted meek, Psiphon's HTTPS-through-a-CDN protocol, the one
  /// the fronting can carry. Otherwise Psiphon picks its protocols itself, from its tactics
  /// (Conduit's too, where they enable it; not as an exit, which dials through an upstream proxy).
  static Map<String, dynamic>? psiphonConfigFor(
    ConnectionMode mode,
    DeviceSettings device,
  ) =>
      mode == ConnectionMode.serverless &&
          serverlessModeOf(device) == ServerlessMode.domainFronting &&
          exitFor(mode, device, const []) == ExitNode.psiphon
      ? const {
          'LimitTunnelProtocols': ['FRONTED-MEEK-OSSH'],
        }
      : null;

  static MasqueVariant masqueVariantOf(DeviceSettings device) =>
      MasqueVariant.values.asNameMap()[device.masqueVariant] ??
      MasqueVariant.normal;

  static ServerlessMode serverlessModeOf(DeviceSettings device) =>
      ServerlessMode.values.asNameMap()[device.serverlessMode] ??
      ServerlessMode.fragment;

  /// The Psiphon / Tor type: the exit process connects by itself (the app is outside the VPN),
  /// and the socks outbound to it is the "proxy".
  bool _exitType = false;

  /// Psiphon or Tor (as an exit or as the type).
  bool get _isExitProcess => _exit == ExitNode.psiphon || _exit == ExitNode.tor;

  /// An exit process behind the connection: it reaches its servers through the psiphon-in /
  /// tor-in inbound, and the exit outbound leads to it.
  bool get _chainedExit => _isExitProcess && !_exitType;

  /// Traffic leaves through the exit outbound: an exit process behind the connection, or the
  /// chain proxy.
  bool get _hasExit => _chainedExit || _exit == ExitNode.chain;

  /// Where the exit's own connections enter routing, to go through the connection: the exit
  /// process's inbound (psiphon-in / tor-in), or chain-in, the chain proxy's loopback.
  String get _exitInbound => '${_exit.name}-in';

  /// Exit name shown in the notification.
  static String exitLabel(ExitNode node) =>
      node == ExitNode.tor ? 'Tor' : 'Psiphon';

  GeneralSettings get _general => profile.general;
  VlessSettings get _vless => profile.vless;
  WarpSettings get _warp => profile.warp;
  MasqueSettings get _masque => profile.masque;

  /// WARP's or MASQUE's (see [ConnectionMode.isWarpLike]).
  String get _tunnelRemoteDns =>
      _mode == ConnectionMode.masque ? _masque.remoteDns : _warp.remoteDns;
  int get _tunnelSpeedTestInterval => _mode == ConnectionMode.masque
      ? _masque.speedTestInterval
      : _warp.speedTestInterval;

  /// Resolves [host] with the system resolver; returns an empty list on failure.
  static Future<List<String>> systemResolve(
    String host, {
    required bool ipv6,
  }) async {
    if (InternetAddress.tryParse(host) != null) return [host];
    try {
      final addrs = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 5));
      return addrs
          .where(
            (a) =>
                a.type == InternetAddressType.IPv4 ||
                (ipv6 && a.type == InternetAddressType.IPv6),
          )
          .map((a) => a.address)
          .toSet()
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// BPB's Upstream Proxy: a TLS TCP relay (host:port) in front of Cloudflare. Not used with fragment.
  ({String host, int port})? get _upstream {
    final match = RegExp(r'^(?:\[([^\]]+)\]|([^:]+)):(\d{1,5})$')
        .firstMatch(_vless.upstreamProxy ?? '');
    if (match == null) return null;
    // Bare IPv6 in the outbound's address (Xray reads it either way).
    final host = match.group(1) ?? match.group(2)!;
    return (host: host, port: int.parse(match.group(3)!));
  }

  List<String> _addressesFor(
    String domain,
    bool isFragment,
    // [List<String> resolved = const []],
  ) => {
    domain,
    // ...resolved,
    ..._vless.cleanIps.where(_allowedAddress),
    if (!isFragment && _vless.customCdn.enabled) ..._vless.customCdn.addresses,
  }.toList();

  // endregion

  // region top level builds

  /// Serverless, or a Best Ping balancer over every worker address/port (or WARP endpoint).
  /// [variant] picks Worker's and WARP's config.
  Future<XrayBuild> build(
    ConnectionMode mode, {
    ConnectionVariant variant = ConnectionVariant.normal,
  }) {
    _exit = exitFor(mode, device, profile.chains);
    _mode = mode;
    _v23 = null;
    _exitType = mode == ConnectionMode.psiphon || mode == ConnectionMode.tor;
    return _build(mode, variant);
  }

  Future<XrayBuild> _build(
    ConnectionMode mode,
    ConnectionVariant variant,
  ) async {
    if (mode == ConnectionMode.serverless) {
      return serverlessModeOf(device) == ServerlessMode.domainFronting
          ? _buildDomainFronting()
          : _buildServerless();
    }
    if (_exitType) {
      if (mode == ConnectionMode.tor &&
          device.torBridge == 'custom' &&
          profile.tor.bridges.isEmpty) {
        throw StateError('Add your bridges in Settings → Tor first.');
      }
      return _buildExitOnly();
    }
    if (mode == ConnectionMode.masque) {
      return _buildMasque(masqueVariantOf(device));
    }
    if (mode.isWarp) {
      return _buildWarp(variant == ConnectionVariant.obfuscated);
    }

    final p = worker;
    if (p == null || uuid == null) {
      throw StateError('Deploy or select a worker first');
    }
    final isFragment = variant == ConnectionVariant.fragment;
    final chain = _chainOutbounds();

    if (variant == ConnectionVariant.browserDialer) {
      return _buildBrowserDialer(p, chain);
    }
    return _buildBestPing(p, isFragment, chain);
  }

  /// One outbound to the worker's custom domain, else its workers.dev / pages.dev host
  /// (address = Host = SNI), on 443. The app's WebView opens
  /// its WebSocket (Xray's browser dialer, see BrowserDialer.kt), so the browser does the TLS
  /// and Xray's TLS settings would be ignored: none are set beyond the SNI.
  Future<XrayBuild> _buildBrowserDialer(
    ActiveWorker p,
    List<Map<String, dynamic>> chain,
  ) async {
    final host = p.customDomain ?? p.host;
    final proxy = {
      'protocol': 'vless',
      'settings': {
        'address': host,
        'port': 443,
        'id': uuid,
        'encryption': 'none',
      },
      'streamSettings': {
        'network': 'ws',
        'wsSettings': {'host': host, 'path': '${_wsPath()}?ed=2560'},
        'security': 'tls',
        'tlsSettings': {
          'serverName': host,
          'alpn': ['http/1.1'],
        },
        'sockopt': _sockopt(
          happyEyeballs: true,
          tcpFastOpen: _vless.enableTcpFastOpen,
          domainStrategy: 'UseIP',
        ),
      },
      'tag': 'proxy',
    };
    final config = await _buildConfig(
      outbounds: [...chain, proxy],
      isBalancer: false,
      outboundAddrs: const [],
    );
    return XrayBuild(config);
  }

  Future<XrayBuild> _buildBestPing(
    ActiveWorker p,
    bool isFragment,
    List<Map<String, dynamic>> chain,
  ) async {
    final proxies = <Map<String, dynamic>>[];
    var index = 1;

    final domain = p.domains.length == 1 ? p.domains[0] : p.domains[1];
    final addresses = _addressesFor(domain, isFragment);
    final ports = _vless.ports;
    final upstream = isFragment ? null : _upstream;

    if (upstream != null) {
      addresses.add(upstream.host);
      ports.add(upstream.port);
    }

    for (final port in ports) {
      for (final address in addresses) {
        if ((port == upstream?.port) ^ (address == upstream?.host)) continue;
        proxies.add(
          _wsOutbound('proxy-$index', address, port, domain, isFragment),
        );
        index++;
      }
    }

    if (proxies.isEmpty) {
      throw StateError(
        'No usable ports. Enable at least one TLS port in settings.',
      );
    }

    final config = await _buildConfig(
      outbounds: [...chain, ...proxies],
      isBalancer: true,
      // BPB's: the second address when there is one.
      balancerFallback: proxies.length > 1 ? 'proxy-2' : 'proxy-1',
      outboundAddrs: addresses,
    );
    return XrayBuild(config);
  }

  WarpAccount _warpAccount() {
    final account = _warp.account;
    if (account == null) {
      throw StateError('No WARP account yet. Register it in Settings → WARP.');
    }
    return account;
  }

  /// Port of BPB's getXrWarpConfigs, with the chain proxy (if set) dialed through WARP
  /// in place of BPB's WoW.
  Future<XrayBuild> _buildWarp(bool obfuscation) async {
    final account = _warpAccount();
    final endpoints = _warpEndpoints();
    if (endpoints.isEmpty) {
      throw StateError('Add at least one WARP endpoint in settings.');
    }
    final chain = _chainOutbounds();

    final proxies = <Map<String, dynamic>>[];
    for (var i = 0; i < endpoints.length; i++) {
      proxies.add(
        _retag(
          _warpOutbound(account, endpoints[i], obfuscation: obfuscation),
          'proxy-${i + 1}',
        ),
      );
    }
    final config = await _buildConfig(
      outbounds: [...chain, ...proxies],
      isBalancer: true,
      isWarp: true,
      outboundAddrs: endpoints.map(_endpointHost).toList(),
    );
    return XrayBuild(config);
  }

  /// MASQUE's endpoints (IPv6 ones dropped with IPv6 off), as WARP's.
  List<String> _masqueEndpoints() {
    final endpoints = _masque.endpoints.where(_allowedAddress).toList();
    if (endpoints.isEmpty) {
      throw StateError(
        _masque.endpoints.isEmpty
            ? 'Add at least one MASQUE endpoint in settings.'
            : 'All MASQUE endpoints are IPv6: enable IPv6 or add an IPv4 endpoint.',
      );
    }
    return endpoints;
  }

  /// Normal and obfuscation use every endpoint; obfuscation applies the configured H2 fragments
  /// or H3 noises.
  Future<XrayBuild> _buildMasque(MasqueVariant variant) async {
    final account = _masque.account;
    if (account == null) {
      throw StateError(
        'No MASQUE account yet. Register it in Settings → MASQUE.',
      );
    }
    final endpoints = _masqueEndpoints();
    final chain = _chainOutbounds();
    final h3 = _masque.transport == 'h3';
    final obfuscation = variant == MasqueVariant.obfuscated;

    final proxies = <Map<String, dynamic>>[];
    if (!obfuscation) {
      for (final endpoint in endpoints) {
        proxies.add(_masqueOutbound(account, endpoint, h3: h3));
      }
    } else if (!h3) {
      for (final endpoint in endpoints) {
        proxies.add(
          _masqueOutbound(account, endpoint, h3: false, fragment: true),
        );
      }
    } else {
      for (final endpoint in endpoints) {
        proxies.add(
          _masqueOutbound(
            account,
            endpoint,
            h3: true,
            noises: _udpNoises(_masque.udpNoises),
          ),
        );
      }
    }
    final tagged = [
      for (var i = 0; i < proxies.length; i++)
        _retag(proxies[i], 'proxy-${i + 1}'),
    ];
    final config = await _buildConfig(
      outbounds: [...chain, ...tagged],
      isBalancer: true,
      isWarp: true,
      outboundAddrs: endpoints.map(_endpointHost).toList(),
    );
    return XrayBuild(config);
  }

  static int _endpointPort(String endpoint) => Uri.http(endpoint).port;

  static String _endpointHost(String endpoint) => Uri.http(endpoint).host;

  Future<XrayBuild> _buildServerless() async {
    final config = await _buildConfig(
      outbounds: [
        _freedomOutbound('proxy', isFragment: true),
        _freedomOutbound('http-fragment', isFragment: true, packets: '1-1'),
        _freedomOutbound('udp-noise', isUdpNoise: true),
      ],
      isBalancer: false,
      isWorkerless: true,
      outboundAddrs: const [],
    );
    return XrayBuild(config);
  }

  /// patterniha's config ([domainFrontingV23]) as is, with the app's TUN and mixed inbounds
  /// (sniffing like its mixed-in), log level and traffic stats. Its TLS-decrypting inbounds
  /// read the CA from bpb-cert.crt / bpb-cert.key in Xray's certificate location.
  ///
  /// With a Psiphon / Tor exit, the fronting only connects the exit: the config is the regular
  /// one with that exit (your traffic follows the routing settings into it, never decrypted),
  /// plus v23's decrypting inbounds and fronting outbounds for the exit's own connections, and
  /// v23's fronted DoH as the remote DNS (see [_frontingRules], [_buildDns]).
  Future<XrayBuild> _buildDomainFronting() async {
    final v23 = _v23 = jsonDecode(domainFrontingV23) as Map<String, dynamic>;
    final inbounds = (v23['inbounds'] as List).cast<Map<String, dynamic>>();
    if (_chainedExit) {
      final outbounds = (v23['outbounds'] as List).cast<Map<String, dynamic>>();
      final config = await _buildConfig(
        outbounds: [
          for (final o in outbounds)
            if (_frontingOutbound.hasMatch(o['tag'] as String)) o,
        ],
        isBalancer: false,
        outboundAddrs: const [],
      );
      // The exit first: Xray's default for anything no rule takes.
      final all = (config['outbounds'] as List).cast<Map<String, dynamic>>();
      final exit = all.firstWhere((o) => o['tag'] == 'exit');
      config['outbounds'] = [exit, ...all.where((o) => o != exit)];
      config['inbounds'] = [
        ...config['inbounds'] as List,
        ...inbounds.where(
          (i) => (i['tag'] as String).startsWith('tls-decrypt-'),
        ),
      ];
      return XrayBuild(config);
    }

    final config = Map<String, dynamic>.of(v23)
      ..remove('remarks')
      ..remove('version');
    final mixed = inbounds.firstWhere((i) => i['tag'] == 'mixed-in');
    config['inbounds'] = [
      for (final inbound in _localInbounds(
        mixed['sniffing'] as Map<String, dynamic>,
      ))
        if (inbound['tag'] == 'mixed-in')
          {...inbound, 'streamSettings': mixed['streamSettings']}
        else
          inbound,
      ...inbounds.where((i) => i != mixed),
    ];
    config['log'] = {'loglevel': device.logLevel};
    (config['policy'] as Map<String, dynamic>)['system'] = _statsPolicy;
    config['stats'] = <String, dynamic>{};
    return XrayBuild(config);
  }

  /// v23's outbounds the exit's fronting uses (not its unused tls-repack-frommitm).
  static final _frontingOutbound = RegExp(
    r'^(redirect-out-|tls-repack-(?!frommitm$))',
  );

  /// Before the regular rules (limited to tun / mixed-in): v23's redirects to the decrypting
  /// inbounds, limited to the exit's inbound; the decrypted connections' rules as is; Xray's
  /// own lookups through v23's fronted DoH (its no-filter-dns rule); and the rest of the exit's
  /// own connections direct.
  List<Map<String, dynamic>> _frontingRules() {
    final v23Rules = (_v23!['routing']['rules'] as List)
        .cast<Map<String, dynamic>>();
    return [
      for (final r in v23Rules)
        if ((r['outboundTag'] as String).startsWith('redirect-out-'))
          {
            'inboundTag': [_exitInbound],
            ...r,
          },
      for (final r in v23Rules)
        if ((r['inboundTag'] as List?)?.any(
              (t) => (t as String).startsWith('tls-decrypt-'),
            ) ??
            false)
          r,
      {
        'inboundTag': ['no-filter-dns'],
        'outboundTag': 'tls-repack-dns',
      },
      {
        'inboundTag': [_exitInbound],
        'outboundTag': 'direct',
      },
    ];
  }

  /// Psiphon / Tor type: the proxy is a socks outbound to the exit process, which connects to
  /// its servers (Tor: its bridges) by itself, outside the VPN like the rest of the app.
  Future<XrayBuild> _buildExitOnly() async {
    final config = await _buildConfig(
      outbounds: [
        {
          'tag': 'proxy',
          'protocol': 'socks',
          'settings': {'address': '127.0.0.1', 'port': exitPort},
        },
      ],
      isBalancer: false,
      outboundAddrs: const [],
    );
    return XrayBuild(config);
  }

  // endregion

  // region config skeleton

  Future<Map<String, dynamic>> _buildConfig({
    required List<Map<String, dynamic>> outbounds,
    required bool isBalancer,
    String balancerFallback = 'proxy-1',
    bool isWorkerless = false,
    bool isWarp = false,
    required List<String> outboundAddrs,
    String? domainToStaticIPs,
  }) async {
    final sniffQuic = isWorkerless;
    // Serverless (both modes): always FakeDNS, like v23.
    final sniffFakeDns = isWorkerless || _frontedExit || _general.enableFakeDns;
    final sniffing = {
      'enabled': true,
      'destOverride': [
        'http',
        'tls',
        if (sniffQuic) 'quic',
        if (sniffFakeDns) 'fakedns',
      ],
      'routeOnly': true,
    };

    return _clean({
      'log': {'loglevel': device.logLevel},
      'dns': await _buildDns(
        outboundAddrs,
        isWorkerless,
        isWarp,
        domainToStaticIPs,
      ),
      'inbounds': [
        ..._localInbounds(sniffing),
        if (_chainedExit)
          {
            'tag': _exitInbound,
            'listen': '127.0.0.1',
            'port': exitUpstreamPort,
            'protocol': 'socks',
            'settings': {'auth': 'noauth', 'udp': false},
            // The fronting rules match the domains of the exit's connections.
            if (_frontedExit)
              'sniffing': {
                'enabled': true,
                'destOverride': ['tls'],
                'routeOnly': true,
              },
          },
      ],
      'outbounds': [
        ...outbounds,
        if (_chainedExit)
          {
            'tag': 'exit',
            'protocol': 'socks',
            'settings': {'address': '127.0.0.1', 'port': exitPort},
          },
        if (_frontedExit)
          {
            'tag': 'dns-out',
            'protocol': 'dns',
            // Your apps' queries straight to the exit's DNS; the local DNS's domains to the DNS
            // module (it only answers A / AAAA).
            'settings': {
              'network': 'udp',
              'address': '127.0.0.1',
              'port': exitDnsPort,
              'rules': [
                if (_localDnsDomains.isNotEmpty)
                  {
                    'action': 'hijack',
                    'qType': '1,28',
                    'domain': _localDnsDomains,
                  },
                {'action': 'direct'},
              ],
            },
          }
        else
          {
            'protocol': 'dns',
            'settings': {
              'rules': [
                {'action': 'hijack'},
              ],
            },
            'tag': 'dns-out',
          },
        {
          'protocol': 'freedom',
          'streamSettings': {
            'sockopt': {'domainStrategy': 'UseIP'},
          },
          'tag': 'direct',
        },
        {
          'protocol': 'blackhole',
          'settings': {
            'response': {'type': 'http'},
          },
          'tag': 'block',
        },
      ],
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': _buildRoutingRules(
          isBalancer: isBalancer,
          isWorkerless: isWorkerless,
          isWarp: isWarp,
        ),
        if (isBalancer)
          'balancers': [_balancer('all-proxies', 'proxy', balancerFallback)],
      },
      // Burst observatory instead of BPB's observatory: each outbound is pinged once per
      // interval at a random moment (no burst of simultaneous handshakes), and leastPing
      // picks the lowest average of the last [_probeSamples] pings rather than one probe.
      if (isBalancer)
        'burstObservatory': {
          'subjectSelector': ['proxy'],
          'pingConfig': {
            'destination': probeUrl,
            // Checked directly when a ping fails, so a dropped phone network doesn't
            // mark every outbound dead.
            'connectivity': connectivityUrl,
            'interval':
                '${isWarp ? _tunnelSpeedTestInterval : _vless.speedTestInterval}s',
            'sampling': _probeSamples,
            'timeout': '5s',
          },
        },
      'policy': {
        'levels': {
          '0': {
            'connIdle': 300,
            'handshake': 4,
            'uplinkOnly': 1,
            'downlinkOnly': 1,
          },
        },
        'system': _statsPolicy,
      },
      'stats': <String, dynamic>{},
    });
  }

  /// Per-outbound traffic counters, read by the app (TrafficMeter.kt).
  static const _statsPolicy = {
    'statsOutboundUplink': true,
    'statsOutboundDownlink': true,
  };

  /// The VPN device (not in proxy mode) and the local SOCKS/HTTP proxy.
  List<Map<String, dynamic>> _localInbounds(Map<String, dynamic> sniffing) => [
    // Proxy mode has no VPN device: only the mixed inbound below.
    if (device.appMode != AppMode.proxy)
      {
        'tag': 'tun',
        'protocol': 'tun',
        'settings': {'name': 'xray0', 'MTU': device.mtu},
        'sniffing': sniffing,
      },
    {
      // Lets the app reach its own worker API through the tunnel.
      'tag': 'mixed-in',
      'listen': device.lanSharing ? '0.0.0.0' : '127.0.0.1',
      'port': localProxyPort,
      'protocol': 'mixed',
      'settings': switch (device.lanAuth) {
        final auth? => {
          'auth': 'password',
          'accounts': [
            {'user': auth.user, 'pass': auth.pass},
          ],
          'udp': true,
        },
        null => {'auth': 'noauth', 'udp': true},
      },
      'sniffing': sniffing,
    },
  ];

  /// A leastPing balancer. Until the first pings are in (a few seconds after connecting) it
  /// picks nothing, so [fallback] takes its connections then: without one they'd take the default
  /// route, the first outbound, which is the chain proxy (exit) itself when there is one.
  Map<String, dynamic> _balancer(
    String tag,
    String selector,
    String fallback,
  ) => {
    'tag': tag,
    'selector': [selector],
    'strategy': {'type': 'leastPing'},
    'fallbackTag': fallback,
  };

  // endregion

  // region dns

  Future<Map<String, dynamic>> _buildDns(
    List<String> outboundAddrs,
    bool isWorkerless,
    bool isWarp,
    String? domainToStaticIPs,
  ) async {
    final ipv6 = _general.enableIpv6;
    // Serverless: always the system's resolver ("localhost", outside Xray's routing), like v23.
    final localDNS = _mode == ConnectionMode.serverless
        ? 'localhost'
        : _general.localDns;
    final hosts = <String, dynamic>{};
    final servers = <dynamic>[];
    final fakeDnsDomains = <String>[];

    // The remote DNS's host: a public one's IPs in hosts; any other is resolved with the local
    // DNS (see bypassDomains), like the anti-sanction DoH.
    String? unlistedDnsHost;
    if (!isWorkerless && !isWarp && !_exitType && !_frontedExit) {
      unlistedDnsHost = _addDnsHost(hosts, _vless.remoteDns.server, ipv6);
    }
    if (isWarp) unlistedDnsHost = _addDnsHost(hosts, _tunnelRemoteDns, ipv6);

    if (domainToStaticIPs != null) {
      final ips = await resolver(domainToStaticIPs, ipv6: ipv6);
      if (ips.isNotEmpty) hosts[domainToStaticIPs] = ips;
    }

    final skipFallback = !isWorkerless;
    if (isWorkerless) {
      // Serverless: Google's and Cloudflare's DoH, side by side so the parallel query races them.
      _serverlessDoh.forEach((host, ips) {
        hosts[host] = ips;
        servers.add(_dnsServer('https://$host/dns-query', tag: 'remote-dns'));
      });
    } else if (_frontedExit) {
      final v23 = _v23!['dns'] as Map<String, dynamic>;
      final doh = (v23['servers'] as List)
          .whereType<Map<String, dynamic>>()
          .firstWhere((s) => s['tag'] == 'no-filter-dns');
      // Xray's own lookups (the fronting, the exit's connections): your apps' queries go to the
      // exit's DNS through dns-out instead.
      servers.add({
        'address': doh['address'],
        'tag': 'no-filter-dns',
        'timeoutMs': doh['timeoutMs'],
      });
      final v23Hosts = v23['hosts'] as Map<String, dynamic>;
      for (final host in ['dns.redirect', 'fastly.redirect']) {
        hosts[host] = v23Hosts[host];
      }
    } else if (_exitType) {
      // The Psiphon / Tor types (no VLESS / WARP to go through) use the exit's own DNS server
      // on this phone: it takes the DNS module's tag ("dns", routed direct) rather than remote-dns.
      servers.add(_dnsServer('127.0.0.1', port: exitDnsPort));
    } else {
      servers.add(
        _dnsServer(
          isWarp ? _tunnelRemoteDns : _vless.remoteDns.server,
          tag: 'remote-dns',
        ),
      );
    }

    final geo = _geoAssets();
    final routing = profile.routing;

    for (final g in geo.where((g) => g.isBlock)) {
      hosts[g.geosite] = '#3';
    }
    for (final d in routing.block.domains) {
      hosts['domain:$d'] = '#3';
    }

    for (final g in geo.where(
      (g) => !g.isBlock && g.geoip != null && g.dns == _GeoDns.local,
    )) {
      servers.add(
        _dnsServer(
          localDNS,
          domains: [g.geosite],
          expectIPs: [g.geoip!],
          skipFallback: skipFallback,
        ),
      );
      fakeDnsDomains.add(g.geosite);
    }

    final sanctionDomains = [
      ...geo
          .where((g) => !g.isBlock && g.dns == _GeoDns.antiSanction)
          .map((g) => g.geosite),
      ...routing.sanctionBypass.domains.map((d) => 'domain:$d'),
    ];

    final bypassDomains = [
      ...geo
          .where((g) => !g.isBlock && g.geoip == null && g.dns == _GeoDns.local)
          .map((g) => g.geosite),
      ...routing.bypass.domains.map((d) => 'domain:$d'),
      ...outboundAddrs.where(_isDomain).map((d) => 'full:$d'),
      if (unlistedDnsHost != null) 'full:$unlistedDnsHost',
    ];

    if (_antiSanction && sanctionDomains.isNotEmpty) {
      final antiSanction = _general.antiSanctionDns;
      servers.add(
        _dnsServer(
          _xrayDns(antiSanction),
          domains: sanctionDomains,
          skipFallback: skipFallback,
          finalQuery: true,
        ),
      );
      // A DoH domain is resolved with the local DNS (BPB's buildDNS).
      final host = _dnsHost(antiSanction);
      if (_isDomain(host)) bypassDomains.add('full:$host');
    }

    if (isWorkerless) {
      for (final h
          in _serverlessDoh.values.expand((ips) => ips).where(_isDomain)) {
        bypassDomains.add('full:$h');
      }
    }

    // Your apps' queries for these go to the DNS module (the local DNS); v23's Fastly front
    // below is only Xray's own lookup.
    _localDnsDomains = _frontedExit
        ? [...fakeDnsDomains, ...bypassDomains]
        : const [];

    // v23's Fastly front (fastly.redirect's host), with the local DNS like v23.
    if (_frontedExit) {
      bypassDomains.add(
        'full:${(_v23!['dns']['hosts'] as Map)['fastly.redirect']}',
      );
    }

    if (bypassDomains.isNotEmpty) {
      servers.add(
        _dnsServer(
          localDNS,
          domains: bypassDomains,
          skipFallback: skipFallback,
        ),
      );
      fakeDnsDomains.addAll(bypassDomains);
    }

    // Domain Fronting with an exit: for the local DNS's domains, the only queries of your apps
    // dns-out hands to the DNS module; the rest get real answers from the exit's DNS.
    if (_general.enableFakeDns || isWorkerless || _frontedExit) {
      servers.insert(
        0,
        fakeDnsDomains.isEmpty
            ? 'fakedns'
            : _dnsServer(
                'fakedns',
                domains: fakeDnsDomains,
                skipFallback: false,
              ),
      );
    }

    return {
      if (hosts.isNotEmpty) 'hosts': hosts,
      'servers': servers,
      'queryStrategy': isWarp && !ipv6 ? 'UseIPv4' : 'UseIP',
      if (isWorkerless) 'enableParallelQuery': true,
      if (!_frontedExit) 'tag': 'dns',
    };
  }

  /// Serverless's DoH servers and their hosts entries (Cloudflare's: a domain, resolved with
  /// the local DNS).
  static const _serverlessDoh = {
    'dns.google': ['8.8.8.8', '8.8.4.4'],
    'cloudflare-dns.com': ['cloudflare.com'],
  };

  /// Maps a DNS [server]'s hostname to a public one's IPs from [publicDnsIps] (IPv6 ones only
  /// with IPv6 on). Returns the hostname when it's a domain not in the list, for the local DNS.
  String? _addDnsHost(Map<String, dynamic> hosts, String server, bool ipv6) {
    final host = _dnsHost(server);
    if (!_isDomain(host)) return null;
    final known = publicDnsIps[host];
    if (known == null) return host;
    hosts[host] = [
      for (final ip in known)
        if (ipv6 || !ip.contains(':')) ip,
    ];
    return null;
  }

  Map<String, dynamic> _dnsServer(
    String address, {
    int? port,
    List<String>? domains,
    List<String>? expectIPs,
    bool? skipFallback,
    bool? finalQuery,
    String? tag,
  }) => {
    'address': address,
    'port': port,
    'domains': domains,
    'expectIPs': expectIPs,
    'skipFallback': skipFallback,
    'finalQuery': finalQuery,
    'tag': tag,
  };

  // endregion

  // region routing

  List<Map<String, dynamic>> _buildRoutingRules({
    required bool isBalancer,
    required bool isWorkerless,
    required bool isWarp,
  }) {
    final rules = <Map<String, dynamic>>[
      if (_frontedExit) ..._frontingRules(),
      {
        'inboundTag': ['tun', 'mixed-in'],
        'port': 53,
        'outboundTag': 'dns-out',
        'type': 'field',
      },
    ];

    void add({
      List<String>? inboundTag,
      List<String>? domain,
      List<String>? ip,
      Object? port,
      String? network,
      List<String>? protocol,
      required String outbound,
      bool balancer = false,
    }) {
      rules.add({
        // Domain Fronting with an exit: the regular rules are for your traffic only, the exit's
        // and the decrypted connections have theirs before them (_frontingRules).
        'inboundTag':
            inboundTag ?? (_frontedExit ? const ['tun', 'mixed-in'] : null),
        'domain': domain,
        'ip': ip,
        'port': port,
        'network': network,
        'protocol': protocol,
        if (balancer) 'balancerTag': outbound else 'outboundTag': outbound,
        'type': 'field',
      });
    }

    final finalTag = isWorkerless ? 'direct' : 'proxy';
    final outTag = isBalancer ? 'all-proxies' : finalTag;
    final proxyTag = isBalancer ? 'all-proxies' : 'proxy';

    // Through the connection itself: the remote DNS over VLESS / WARP (also with a Psiphon / Tor
    // exit, like BPB with a chain proxy, since the connection is up first), and Psiphon / Tor
    // reaching their servers as an exit (Serverless: with fragment).
    if (!_exitType && !_frontedExit) {
      add(
        inboundTag: [if (_hasExit) _exitInbound, 'remote-dns'],
        outbound: proxyTag,
        balancer: isBalancer,
      );
    }
    // Domain Fronting with an exit: no DNS module tag (its local DNS is localhost, not routed).
    if (!_frontedExit) add(inboundTag: ['dns'], outbound: 'direct');
    add(domain: ['geosite:private'], outbound: 'direct');
    add(ip: ['geoip:private'], outbound: 'direct');
    // BitTorrent direct, matched by Xray's sniffers (TCP and uTP, whatever destOverride is), and
    // before the UDP block so its UDP (uTP, DHT) goes direct too.
    if (profile.routing.bypass.isOn('bittorrent')) {
      add(protocol: ['bittorrent'], outbound: 'direct');
    }

    // The worker and Tor only carry TCP (the worker also DNS); refuse other UDP so apps fall
    // back to TCP fast. Psiphon carries UDP (over its udpgw), and the chain proxy is the exit
    // for everything, UDP included.
    final tcpOnly =
        _exit == ExitNode.tor ||
        (!isWorkerless &&
            !isWarp &&
            _exit != ExitNode.psiphon &&
            _exit != ExitNode.chain);
    if (tcpOnly) {
      add(network: 'udp', outbound: 'block');
    } else if (profile.routing.block.isOn('quic')) {
      add(port: 443, network: 'udp', outbound: 'block');
    }

    final geo = _geoAssets();
    final routing = profile.routing;

    final blockDomains = [
      ...geo.where((g) => g.isBlock).map((g) => g.geosite),
      ...routing.block.domains.map((d) => 'domain:$d'),
    ];
    if (blockDomains.isNotEmpty) add(domain: blockDomains, outbound: 'block');

    final blockIps = [
      ...geo.where((g) => g.isBlock && g.geoip != null).map((g) => g.geoip!),
      ...routing.block.ips,
    ];
    if (blockIps.isNotEmpty) add(ip: blockIps, outbound: 'block');

    final bypassDomains = [
      ...geo
          .where((g) => !g.isBlock && g.dns != _GeoDns.antiSanction)
          .map((g) => g.geosite),
      ...routing.bypass.domains.map((d) => 'domain:$d'),
    ];
    if (bypassDomains.isNotEmpty) {
      add(domain: bypassDomains, outbound: 'direct');
    }

    final bypassIps = [
      ...geo.where((g) => !g.isBlock && g.geoip != null).map((g) => g.geoip!),
      ...routing.bypass.ips,
    ];
    if (bypassIps.isNotEmpty) add(ip: bypassIps, outbound: 'direct');

    // Sanction rules: also direct, but kept apart since they resolve via the anti-sanction DNS.
    final sanctionDomains = [
      ...geo.where((g) => g.dns == _GeoDns.antiSanction).map((g) => g.geosite),
      ...routing.sanctionBypass.domains.map((d) => 'domain:$d'),
    ];
    if (_antiSanction && sanctionDomains.isNotEmpty) {
      add(domain: sanctionDomains, outbound: 'direct');
    }

    // The catch-all only matches connections with an IP. One with just a domain (FakeDNS, the
    // local proxy's clients) that no domain rule took misses it, so IPIfNonMatch's second round
    // resolves the domain and the IP rules above get their turn. No network: TCP and UDP are all
    // there is, and where UDP isn't carried it's blocked above.
    const anyIp = ['0.0.0.0/0', '::/0'];

    if (_hasExit) {
      add(ip: anyIp, outbound: 'exit');
      return rules;
    }

    if (isWorkerless) {
      add(network: 'tcp', protocol: ['tls'], outbound: 'proxy');
      add(network: 'tcp', protocol: ['http'], outbound: 'http-fragment');
      add(network: 'udp', protocol: ['quic'], outbound: 'udp-noise');
      add(
        port: '443,2053,2083,2087,2096,8443',
        network: 'udp',
        outbound: 'udp-noise',
      );
    }

    add(ip: anyIp, outbound: outTag, balancer: isBalancer);
    return rules;
  }

  /// Tags from Chocolate4U/Iran-v2ray-rules (the bundled geosite.dat / geoip.dat), as in
  /// BPB's sing-box and Clash rules: its own `ir` and `nsfw` lists, and `category-ads-all`
  /// already includes Iranian ads. Keyed by the routing preset names in the profile.
  static const _bypassAssets = {
    'iran': _GeoAsset('geosite:ir', geoip: 'geoip:ir', dns: _GeoDns.local),
    'china': _GeoAsset('geosite:cn', geoip: 'geoip:cn', dns: _GeoDns.local),
    'russia': _GeoAsset(
      'geosite:category-ru',
      geoip: 'geoip:ru',
      dns: _GeoDns.local,
    ),
  };

  static const _sanctionAssets = {
    'openAi': _GeoAsset('geosite:openai', dns: _GeoDns.antiSanction),
    'googleAi': _GeoAsset('geosite:google-deepmind', dns: _GeoDns.antiSanction),
    'microsoft': _GeoAsset('geosite:microsoft', dns: _GeoDns.antiSanction),
    'oracle': _GeoAsset('geosite:oracle', dns: _GeoDns.antiSanction),
    'docker': _GeoAsset('geosite:docker', dns: _GeoDns.antiSanction),
    'adobe': _GeoAsset('geosite:adobe', dns: _GeoDns.antiSanction),
    'epicGames': _GeoAsset('geosite:epicgames', dns: _GeoDns.antiSanction),
    'intel': _GeoAsset('geosite:intel', dns: _GeoDns.antiSanction),
    'amd': _GeoAsset('geosite:amd', dns: _GeoDns.antiSanction),
    'nvidia': _GeoAsset('geosite:nvidia', dns: _GeoDns.antiSanction),
    'asus': _GeoAsset('geosite:asus', dns: _GeoDns.antiSanction),
    'hp': _GeoAsset('geosite:hp', dns: _GeoDns.antiSanction),
    'lenovo': _GeoAsset('geosite:lenovo', dns: _GeoDns.antiSanction),
  };

  // 'quic' is a block preset too, but it's a UDP 443 rule rather than a geo list.
  static const _blockAssets = {
    'ads': _GeoAsset('geosite:category-ads-all', isBlock: true),
    'porn': _GeoAsset('geosite:nsfw', isBlock: true),
    'malware': _GeoAsset(
      'geosite:malware',
      geoip: 'geoip:malware',
      isBlock: true,
    ),
    'phishing': _GeoAsset(
      'geosite:phishing',
      geoip: 'geoip:phishing',
      isBlock: true,
    ),
    'cryptominers': _GeoAsset('geosite:cryptominers', isBlock: true),
  };

  List<_GeoAsset> _geoAssets() {
    final r = profile.routing;
    List<_GeoAsset> on(RuleGroup group, Map<String, _GeoAsset> assets) => [
      for (final e in assets.entries)
        if (group.isOn(e.key)) e.value,
    ];
    return [
      ...on(r.block, _blockAssets),
      ...on(r.bypass, _bypassAssets),
      ...on(r.sanctionBypass, _sanctionAssets),
    ];
  }

  // endregion

  // region outbounds

  Map<String, dynamic> _wsOutbound(
    String tag,
    String address,
    int port,
    String domain,
    bool isFragment,
  ) {
    final cdn = _vless.customCdn;
    final isCustomCdn = cdn.enabled && cdn.addresses.contains(address);
    final host = isCustomCdn ? (cdn.host ?? domain) : domain;
    final sni = isCustomCdn ? (cdn.sni ?? domain) : _randomUpperCase(domain);
    final enableEch = _vless.ech.enabled && !isFragment;
    final unsafeFingerprint = _vless.tlsFingerprint == 'unsafe';

    return {
      'protocol': 'vless',
      'settings': {
        'address': address,
        'port': port,
        'id': uuid,
        'encryption': 'none',
      },
      'streamSettings': {
        'network': 'ws',
        'wsSettings': {'host': host, 'path': '${_wsPath()}?ed=2560'},
        'security': 'tls',
        'tlsSettings': {
          'serverName': sni,
          'fingerprint': _vless.tlsFingerprint,
          'alpn': ['http/1.1'],
          if (unsafeFingerprint) 'cipherSuites': _unsafeCipherSuites,
          if (enableEch) 'echConfigList': _echConfigList(_vless.ech),
          if (enableEch) 'echSockopt': {'dialerProxy': 'direct'},
        },
        if (_isDomain(address))
          'sockopt': _sockopt(
            happyEyeballs: true,
            tcpFastOpen: _vless.enableTcpFastOpen,
            domainStrategy: 'UseIP',
          ),
        if (isFragment) 'finalmask': _finalMask(fragment: true),
      },
      'tag': tag,
    };
  }

  /// `cloudflare-ech.com+udp://IP` for an IP (an IPv6 one in brackets), or the DoH URL as
  /// given in the ECH settings (BPB's buildTlsSettings).
  String _echConfigList(EchSettings ech) {
    final ip = InternetAddress.tryParse(ech.dns);
    final server = switch (ip?.type) {
      InternetAddressType.IPv4 => 'udp://${ech.dns}',
      InternetAddressType.IPv6 => 'udp://[${ech.dns}]',
      _ => ech.dns,
    };
    return 'cloudflare-ech.com+$server';
  }

  /// Port of BPB's buildWarpOutbound.
  Map<String, dynamic> _warpOutbound(
    WarpAccount account,
    String endpoint, {
    required bool obfuscation,
    List<Map<String, dynamic>>? noises,
  }) {
    final address = _endpointHost(endpoint);
    final isDomainAddr = _isDomain(address);

    return {
      'protocol': 'wireguard',
      'settings': {
        'address': ['172.16.0.2/32', account.ipv6],
        'mtu': 1280,
        'peers': [
          {
            'endpoint': endpoint,
            'publicKey': account.publicKey,
            'keepAlive': _warp.keepAlive,
          },
        ],
        'reserved': _warp.enableReservedBytes
            ? account.reserved
            : const [0, 0, 0],
        'secretKey': account.privateKey,
      },
      if (obfuscation || isDomainAddr)
        'streamSettings': {
          if (obfuscation || isDomainAddr)
            'finalmask': _finalMask(udpNoise: true, noises: noises),
          if (isDomainAddr) 'sockopt': _sockopt(domainStrategy: 'UseIP'),
        },
      'tag': 'proxy',
    };
  }

  /// Xray's masque outbound with WARP's credentials: H2 is TLS over TCP (fragmented with the
  /// configured MASQUE fragment settings), H3 QUIC over UDP (with [noises]).
  Map<String, dynamic> _masqueOutbound(
    MasqueAccount account,
    String endpoint, {
    required bool h3,
    bool fragment = false,
    List<Map<String, dynamic>>? noises,
  }) {
    final address = _endpointHost(endpoint);
    final port = _endpointPort(endpoint);
    final isDomainAddr = _isDomain(address);

    return {
      'protocol': 'masque',
      'settings': {'address': address, 'port': port},
      'streamSettings': {
        'network': 'masque',
        'security': 'tls',
        'tlsSettings': {
          'serverName': _masque.sni,
          'alpn': [h3 ? 'h3' : 'h2'],
          if (!h3) 'fingerprint': _masque.tlsFingerprint,
          if (!h3 && _masque.tlsFingerprint == 'unsafe')
            'cipherSuites': _unsafeCipherSuites,
        },
        'masqueSettings': {
          'warp': {
            'privateKey': account.privateKey,
            'publicKey': account.publicKey,
            'address': [account.ipv4, account.ipv6],
          },
        },
        if (isDomainAddr) 'sockopt': _sockopt(happyEyeballs: !h3, domainStrategy: 'UseIP'),
        if (fragment)
          'finalmask': _finalMask(fragment: true, fragments: _masque.fragments),
        if (noises != null)
          'finalmask': _finalMask(
            udpNoise: true,
            noises: noises,
            noiseReset: _masque.udpNoiseReset,
          ),
      },
      'tag': 'proxy',
    };
  }

  /// The link's certificate checks: pcs (pinned SHA-256 hashes) and vcn (names to verify the
  /// certificate by); Hysteria2 links carry the hash as pinSHA256.
  Map<String, dynamic> _pinning(ProxyUri p) => {
    'pinnedPeerCertSha256': ?(p['pcs'] ?? p['pinSHA256']),
    'verifyPeerCertByName': ?p['vcn'],
  };

  /// A Hysteria2 chain proxy (QUIC, so over WARP / MASQUE only), dialed through the connection.
  /// Port hopping (the link's mport) and salamander obfuscation go in finalmask.
  Map<String, dynamic> _hysteria2Chain(ProxyUri p) {
    final obfsPassword = p['obfs'] == 'salamander' ? p['obfs-password'] : null;
    // Xray applies the UDP masks in reverse, and udphop must be the one that dials: it goes last.
    final masks = [
      if (obfsPassword != null)
        {
          'type': 'salamander',
          'settings': {'password': obfsPassword},
        },
      if (p['mport'] case final ports?)
        {
          'type': 'udphop',
          // Like Hysteria: a new port and a new socket at each hop (every 30 s by default).
          'settings': {
            'mode': 'intervalRemote,intervalLocal',
            'remotePorts': ports,
          },
        },
    ];
    return {
      'protocol': 'hysteria',
      'settings': {'version': 2, 'address': p.server, 'port': p.port},
      'streamSettings': {
        'network': 'hysteria',
        'hysteriaSettings': {'version': 2, 'auth': p['auth']},
        'security': 'tls',
        'tlsSettings': {'serverName': p['sni'] ?? p.server, ..._pinning(p)},
        if (masks.isNotEmpty) 'finalmask': {'udp': masks},
        'sockopt': {'dialerProxy': 'exit-dialer'},
      },
      'tag': 'exit',
    };
  }

  /// A WireGuard chain proxy, dialed through the connection like WARP on WARP; its config's DNS
  /// servers resolve names inside the tunnel (remoteDNS, IPs only).
  Map<String, dynamic> _wireGuardChain(ProxyUri p) {
    List<String> list(String? v) => [
      for (final s in (v ?? '').split(','))
        if (s.trim().isNotEmpty) s.trim(),
    ];
    final reserved = list(p['reserved']).map(int.tryParse).nonNulls.toList();
    final allowedIPs = list(p['allowedips']);
    final dns = list(p['dns'])
        .where((ip) => InternetAddress.tryParse(ip) != null)
        .toList();
    return {
      'protocol': 'wireguard',
      'settings': {
        'secretKey': p['privateKey'],
        'address': list(p['address']),
        'peers': [
          {
            'publicKey': p['publickey'],
            'preSharedKey': ?p['presharedkey'],
            'endpoint':
                '${p.server.contains(':') ? '[${p.server}]' : p.server}:${p.port}',
            'keepAlive': ?int.tryParse(p['keepalive'] ?? ''),
            if (allowedIPs.isNotEmpty) 'allowedIPs': allowedIPs,
          },
        ],
        // Only the config's own: without one, Xray's default.
        'mtu': ?int.tryParse(p['mtu'] ?? ''),
        if (reserved.length == 3) 'reserved': reserved,
        if (dns.isNotEmpty) 'remoteDNS': dns,
      },
      'streamSettings': {
        'sockopt': {'dialerProxy': 'exit-dialer'},
      },
      'tag': 'exit',
    };
  }

  Map<String, dynamic> _freedomOutbound(
    String tag, {
    bool isFragment = false,
    bool isUdpNoise = false,
    String? packets,
  }) {
    return {
      'protocol': 'freedom',
      'streamSettings': {
        'sockopt': isFragment
            ? _sockopt(happyEyeballs: true, domainStrategy: 'UseIP')
            : _sockopt(
                domainStrategy: _general.enableIpv6 ? 'UseIPv4v6' : 'UseIPv4',
              ),
        'finalmask': _finalMask(
          fragment: isFragment,
          udpNoise: isUdpNoise,
          packets: packets,
          fragments: profile.serverless.fragments,
          noises: _udpNoises(profile.serverless.udpNoises),
          noiseReset: profile.serverless.udpNoiseReset,
        ),
      },
      'tag': tag,
    };
  }

  /// The chain proxy as the exit, dialed through the connection's balancer: dialerProxy takes an
  /// outbound, not a balancer, so it dials a loopback (exit-dialer) back into routing as
  /// chain-in, which goes through the connection like psiphon-in / tor-in. Empty without one.
  List<Map<String, dynamic>> _chainOutbounds() {
    final chain = _chainOutbound();
    if (chain == null) return const [];
    return [
      chain,
      {
        'protocol': 'loopback',
        'settings': {'inboundTag': _exitInbound},
        'tag': 'exit-dialer',
      },
    ];
  }

  /// The chain proxy chosen for this connection type, when it's the exit node.
  Map<String, dynamic>? _chainOutbound() {
    if (_exit != ExitNode.chain) return null;
    final chain = chainFor(_mode, device, profile.chains);
    if (chain == null) {
      throw StateError('Add a chain proxy in Settings → Chain proxies first.');
    }
    final ProxyUri p;
    try {
      p = ProxyUri.parse(chain.link);
    } on FormatException catch (e) {
      throw StateError('Invalid chain proxy ${chain.name}: ${e.message}');
    }
    if (p.protocol == 'wireguard') return _wireGuardChain(p);
    if (p.protocol == 'hysteria2') return _hysteria2Chain(p);

    final type = p['type'] ?? 'raw';
    final security = p['security'];
    final streamSettings = <String, dynamic>{
      'network': type,
      ..._transport(type, p),
      'security': security,
      if (security == 'tls')
        'tlsSettings': {
          'serverName': p['sni'] ?? p.server,
          'fingerprint': p['fp'],
          'alpn': p['alpn']?.split(','),
          ..._pinning(p),
        },
      if (security == 'reality')
        'realitySettings': {
          'serverName': p['sni'],
          'fingerprint': p['fp'],
          'publicKey': p['pbk'],
          'shortId': p['sid'],
          'spiderX': p['spx'],
          'show': false,
        },
      'sockopt': _sockopt(
        domainStrategy: 'UseIPv4',
        dialerProxy: 'exit-dialer',
      ),
    };
    final enableMux =
        !(security == 'reality' || type == 'grpc' || type == 'xhttp');

    final Map<String, dynamic> settings = switch (p.protocol) {
      'socks' || 'http' => {
        'address': p.server,
        'port': p.port,
        'user': p['user'],
        'pass': p['pass'],
      },
      'shadowsocks' => {
        'address': p.server,
        'port': p.port,
        'method': p['method'],
        'password': p['password'],
      },
      'vless' => {
        'address': p.server,
        'port': p.port,
        'id': p['uuid'],
        'encryption': p['encryption'] ?? 'none',
        'flow': p['flow'],
      },
      'vmess' => {
        'address': p.server,
        'port': p.port,
        'id': p['uuid'],
        'security': 'auto',
      },
      'trojan' => {
        'address': p.server,
        'port': p.port,
        'password': p['password'],
      },
      _ => throw StateError('Unsupported chain proxy protocol: ${p.protocol}'),
    };

    return {
      'protocol': p.protocol,
      if (enableMux)
        'mux': {
          'enabled': true,
          'concurrency': 8,
          'xudpConcurrency': 16,
          'xudpProxyUDP443': 'reject',
        },
      'settings': settings,
      'streamSettings': streamSettings,
      'tag': 'exit',
    };
  }

  Map<String, dynamic> _transport(String type, ProxyUri p) {
    final path = p['path'] ?? '/';
    final host = p['host'];
    switch (type) {
      case 'tcp':
      case 'raw':
        return {
          'rawSettings': {
            'header': p['headerType'] == 'http'
                ? {
                    'type': 'http',
                    'request': {
                      'headers': {
                        'Host': host?.split(','),
                        'Accept-Encoding': ['gzip, deflate'],
                        'Connection': ['keep-alive'],
                        'Pragma': 'no-cache',
                      },
                      'path': path.split(','),
                      'method': 'GET',
                      'version': '1.1',
                    },
                  }
                : {'type': 'none'},
          },
        };
      case 'ws':
        return {
          'wsSettings': {'host': host, 'path': path},
        };
      case 'httpupgrade':
        return {
          'httpupgradeSettings': {'host': host, 'path': path},
        };
      case 'grpc':
        return {
          'grpcSettings': {
            'authority': p['authority'],
            'multiMode': p['mode'] == 'multi',
            'serviceName': p['serviceName'],
          },
        };
      case 'xhttp':
        return {
          'xhttpSettings': {
            'host': host,
            'path': path,
            'mode': p['mode'] ?? 'auto',
          },
        };
      default:
        return {};
    }
  }

  Map<String, dynamic> _sockopt({
    bool happyEyeballs = false,
    bool tcpFastOpen = false,
    String? domainStrategy,
    String? dialerProxy,
  }) => {
    'domainStrategy': domainStrategy,
    'dialerProxy': dialerProxy,
    if (tcpFastOpen) 'tcpFastOpen': true,
    if (happyEyeballs)
      'happyEyeballs': {
        'tryDelayMs': 250,
        'prioritizeIPv6': false,
        'interleave': 2,
        'maxConcurrentTry': 4,
      },
  };

  /// [packets] replaces every fragment card's packets; [noises] replaces UDP noises from settings.
  /// [fragments] / [noiseReset]: the profile's unless given (MASQUE and Serverless have their own).
  Map<String, dynamic>? _finalMask({
    bool fragment = false,
    bool udpNoise = false,
    String? packets,
    List<Fragment>? fragments,
    List<Map<String, dynamic>>? noises,
    Range? noiseReset,
  }) {
    if (!fragment && !udpNoise) return null;
    return {
      if (fragment)
        'tcp': [
          for (final f in fragments ?? profile.fragments)
            {
              'type': 'fragment',
              'settings': {
                'packets': packets ?? f.packets.xray,
                'lengths': f.lengths.map((r) => r.xray).toList(),
                'delays': f.delays.map((r) => r.xray).toList(),
                if (f.maxSplit != null) 'maxSplit': f.maxSplit!.xray,
              },
            },
        ],
      if (udpNoise)
        'udp': [
          {
            'type': 'noise',
            'settings': {
              'reset': (noiseReset ?? profile.udpNoiseReset).xray,
              'noise': noises ?? _udpNoises(profile.udpNoises),
            },
          },
        ],
    };
  }

  List<Map<String, dynamic>> _udpNoises(List<UdpNoise> udpNoises) => [
    for (final n in udpNoises)
      for (var i = 0; i < n.count; i++)
        switch (n.type) {
          NoiseType.rand => {
            'rand': n.size!.xray,
            'randRange': '0-255',
            'delay': n.delay.xray,
          },
          NoiseType.array => {
            'type': 'array',
            'packet': n.bytes,
            'delay': n.delay.xray,
          },
          _ => {'type': n.type.name, 'packet': n.packet, 'delay': n.delay.xray},
        },
  ];

  Map<String, dynamic> _retag(
    Map<String, dynamic> outbound,
    String tag, {
    String? dialerProxy,
  }) {
    final copy = _deepCopy(outbound) as Map<String, dynamic>;
    copy['tag'] = tag;
    final sockopt = (copy['streamSettings'] as Map?)?['sockopt'];
    if (dialerProxy != null && sockopt is Map) {
      sockopt['dialerProxy'] = dialerProxy;
    }
    return copy;
  }

  // endregion

  // region helpers

  String _wsPath() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final length = 16 + _random.nextInt(17);
    return '/${List.generate(length, (_) => chars[_random.nextInt(chars.length)]).join()}';
  }

  String _randomUpperCase(String input) => input
      .split('')
      .map((c) => _random.nextBool() ? c.toUpperCase() : c)
      .join();

  static final _domainRegex = RegExp(
    r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
    caseSensitive: false,
  );

  static bool _isDomain(String value) => _domainRegex.hasMatch(value);

  /// Host part of a DNS setting, which may be a plain IP/host or a DoH / TCP URL.
  /// A DNS setting as Xray's DNS takes it: DoQ only exists as quic+local (sent directly).
  static String _xrayDns(String dns) =>
      dns.startsWith('quic://') ? 'quic+local://${dns.substring(7)}' : dns;

  static String _dnsHost(String dns) => dnsHostOf(dns);

  static dynamic _deepCopy(dynamic value) {
    if (value is Map) {
      return {for (final e in value.entries) '${e.key}': _deepCopy(e.value)};
    }
    if (value is List) return value.map(_deepCopy).toList();
    return value;
  }

  /// Drops null values recursively so the JSON matches what Xray expects.
  static Map<String, dynamic> _clean(Map<String, dynamic> map) {
    dynamic walk(dynamic v) {
      if (v is Map) {
        final out = <String, dynamic>{};
        for (final e in v.entries) {
          final w = walk(e.value);
          if (w != null) out['${e.key}'] = w;
        }
        return out;
      }
      if (v is List) return v.map(walk).where((e) => e != null).toList();
      return v;
    }

    return walk(map) as Map<String, dynamic>;
  }

  // endregion
}

enum _GeoDns { none, local, antiSanction }

class _GeoAsset {
  final String geosite;
  final String? geoip;
  final _GeoDns dns;
  final bool isBlock;

  const _GeoAsset(
    this.geosite, {
    this.geoip,
    this.dns = _GeoDns.none,
    this.isBlock = false,
  });
}
