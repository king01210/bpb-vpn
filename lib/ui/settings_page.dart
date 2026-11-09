import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/settings.dart';
import '../models/theme_color.dart';
import '../services/updates.dart';
import '../services/vpn_channel.dart';
import '../services/xray_config.dart';
import '../state/app_state.dart';
import 'cf_accounts_page.dart';
import 'chain_proxies_page.dart';
import 'fragments_page.dart';
import 'license_page.dart';
import 'noises_page.dart';
import 'per_app_page.dart';
import 'prefs.dart';
import 'routing_page.dart';
import 'tor_bridges_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static const fingerprints = {
    'chrome': 'Chrome',
    'firefox': 'Firefox',
    'safari': 'Safari',
    'ios': 'iOS',
    'android': 'Android',
    'edge': 'Edge',
    '360': '360',
    'qq': 'QQ',
    'random': 'Random',
    'randomized': 'Randomized',
    'unsafe': 'Unsafe',
  };

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final p = state.profile;
    final d = state.device;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            tooltip: 'Reset settings',
            icon: const Icon(Symbols.settings_backup_restore_rounded),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Reset settings?'),
                  content: const Text(
                    'All proxy settings return to their defaults.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Reset'),
                    ),
                  ],
                ),
              );
              if (ok == true) state.resetSettings();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SectionHeader('Global'),
          SettingsCard(
            children: [
              ListTile(
                leading: const Icon(Symbols.link_rounded),
                title: const Text('Chain proxies'),
                subtitle: Text(switch (p.chains.length) {
                  0 => 'None added',
                  1 => '1 config',
                  final n => '$n configs',
                }),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ChainProxiesPage()),
                ),
              ),
              const TextPref(
                'general.localDns',
                'Local DNS',
                icon: Symbols.home_rounded,
                hint: 'IP, tcp://IP or localhost',
                help:
                    'Resolves outbound domains and bypass routing rules. '
                    'It can be an IP (UDP DNS), tcp://IP (TCP DNS) or localhost (use system DNS).',
                validator: validateLocalDns,
              ),
              const TextPref(
                'general.antiSanctionDns',
                'Anti-Sanction DNS',
                icon: Symbols.account_circle_off_rounded,
                help:
                    'Resolves the sanctioned domains so they work over a direct connection. '
                    'This only applies to Serverless, WARP and MASQUE connections when Exit node is set to Default. '
                    'It can be an IP (UDP DNS), tcp://host, quic://host or https://host/dns-query.',
                validator: validateSanctionDns,
              ),
              const SwitchPref(
                'general.enableFakeDns',
                'Fake DNS',
                icon: Symbols.dns_rounded,
                subtitle: 'Faster but may not work with some apps',
              ),
              const SwitchPref(
                'general.enableIpv6',
                'IPv6 connection',
                icon: Symbols.counter_6_rounded,
                subtitle: 'Enable it based on your ISP',
              ),
              const SwitchPref(
                'device.lanSharing.enabled',
                'Allow LAN connections',
                icon: Symbols.lan_rounded,
                subtitle: 'Enable a Socks or HTTP proxy on port 10808',
              ),
              if (d.lanSharing) ...[
                const TextPref(
                  'device.lanSharing.username',
                  'Proxy username',
                  icon: Symbols.person_rounded,
                  hint: 'Optional',
                  help:
                      'Set a username and password to only allow trusted devices. '
                      'Leave both empty for no login.',
                  allowEmpty: true,
                  validator: validateProxyUsername,
                ),
                const TextPref(
                  'device.lanSharing.password',
                  'Proxy password',
                  icon: Symbols.password_rounded,
                  hint: 'Optional',
                  help: 'Used only together with a username.',
                  allowEmpty: true,
                  secret: true,
                  validator: validateProxyPassword,
                ),
              ],
              FutureBuilder<bool>(
                future: VpnChannel.supportsAppendHttpProxy,
                builder: (context, snapshot) => snapshot.data == true
                    ? const SwitchPref(
                        'device.appendHttpProxy',
                        'Add HTTP proxy to VPN',
                        icon: Symbols.http_rounded,
                        subtitle: 'Use HTTP proxy directly for supported apps like browsers',
                      )
                    : const SizedBox.shrink(),
              ),
              const IntPref(
                'device.mtu',
                'VPN MTU',
                icon: Symbols.straighten_rounded,
                min: 1280,
                max: 9000,
              ),
              ListTile(
                leading: const Icon(Symbols.apps_rounded),
                title: const Text('Per-app proxy'),
                subtitle: Text(switch (d.perAppMode) {
                  PerAppMode.include =>
                    'Proxy selected apps (${d.perAppApps.length})',
                  PerAppMode.exclude =>
                    'Exclude selected apps (${d.perAppApps.length})',
                  PerAppMode.off => 'Proxy all apps',
                }),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const PerAppPage())),
              ),
            ],
          ),

          const SectionHeader('VLESS'),
          SettingsCard(
            children: [
              const _DeploymentTile(),
              const TextPref(
                'vless.remoteDns.server',
                'Remote DNS',
                icon: Symbols.outbound_rounded,
                help: 'Resolves foreign domains and can be a DoH or TCP DNS server.',
                validator: validateRemoteDns,
              ),
              const ListPref(
                'vless.cleanIps',
                'Clean IPs or domains',
                icon: Symbols.list_arrow_rounded,
                hint: 'www.speedtest.net\n104.16.1.1\n2606:4700::6810:84e5',
                help: 'Clean Cloudflare IPs or domains on your ISP.',
                itemValidator: validateHost,
              ),
              const MultiIntPref(
                'vless.ports',
                'Ports',
                XrayConfigBuilder.httpsPorts,
                icon: Symbols.numbers_rounded,
              ),
              const ChoicePref(
                'vless.tlsFingerprint',
                'TLS Fingerprint',
                fingerprints,
                icon: Symbols.fingerprint_rounded,
              ),
              if (state.worker != null) const _CustomDomainTile(),
              const SwitchPref(
                'vless.customCdn.enabled',
                'Custom CDN',
                icon: Symbols.cloud_rounded,
                subtitle: 'Enable for domain fronting',
              ),
              if (p.vless.customCdn.enabled) ...const [
                ListPref(
                  'vless.customCdn.addresses',
                  'Custom CDN addresses',
                  icon: Symbols.list_arrow_rounded,
                  hint: 'speedtest.net\n151.101.66.219\n2a04:4e42::731',
                  help: 'Used with the custom CDN host and SNI together.',
                  itemValidator: validateHost,
                ),
                TextPref(
                  'vless.customCdn.host',
                  'Custom CDN host',
                  icon: Symbols.host_rounded,
                  allowEmpty: true,
                  validator: validateHost,
                ),
                TextPref(
                  'vless.customCdn.sni',
                  'Custom CDN SNI',
                  icon: Symbols.host_rounded,
                  allowEmpty: true,
                  validator: validateHost,
                ),
              ],
              const SwitchPref(
                'vless.ech.enabled',
                'TLS ECH',
                icon: Symbols.encrypted_rounded,
                subtitle: 'Hide the real SNI',
              ),
              if (p.vless.ech.enabled)
                const TextPref(
                  'vless.ech.dns',
                  'ECH DNS server',
                  icon: Symbols.dns_rounded,
                  hint: '8.8.8.8 or https://8.8.8.8/dns-query',
                  help:
                      'DNS server the ECH config is fetched from, an IP or a DoH with an IP host. '
                      'DNS server should be reachable from your network and not blocked by your ISP.',
                  validator: validateEchDns,
                ),
              ListTile(
                leading: const Icon(Symbols.view_week_rounded),
                title: const Text('TCP Fragments'),
                subtitle: Text(_fragmentSummary(p.fragments)),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const FragmentsPage()),
                ),
              ),
              TextPref(
                'vless.upstreamProxy',
                'Upstream TCP Proxy',
                icon: Symbols.swap_vert_rounded,
                hint: 'host:port',
                help: 'Setup a upstream TCP proxy like SNI spoofing.',
                allowEmpty: true,
                validator: validateEndpoint,
              ),
              const ListPref(
                'vless.proxyIps',
                'Proxy IPs or domains',
                icon: Symbols.list_arrow_rounded,
                help:
                    'Used by the worker to connect to Cloudflare-hosted sites. Leave empty for its '
                    'built-in default. It is highly recommended to leave it empty, because Proxy IPs expire frequently '
                    'while the default IPs update regularly.',
                hint: 'proxyip.example.com\n94.1.2.3\n95.4.5.6:8443\n[2001:db8::1]\n[2001:db8::2]:8443',
                allowEmpty: true,
                itemValidator: validateHostPort,
              ),
              const SwitchPref(
                'vless.enableTcpFastOpen',
                'TCP Fast Open',
                icon: Symbols.bolt_rounded,
                subtitle: 'Enable with caution',
              ),
              const TextPref(
                'vless.fallbackUrl',
                'Fallback website',
                icon: Symbols.eyeglasses_rounded,
                hint: 'https://example.com',
                help: 'Non-VPN visitors to the worker see this website instead of a 404. ',
                allowEmpty: true,
                validator: validateHttpsUrl,
              ),
              const IntPref(
                'vless.speedTestInterval',
                'Speed test interval (s)',
                icon: Symbols.timer_rounded,
                help: 'Interval between ping attempts to automatically find the fastest server.',
                min: 10,
                max: 300,
                suffix: ' s',
              ),
            ],
          ),
          const SizedBox(height: 16),
          SettingsCard(children: [const _CloudflareAccountsTile()]),

          const SectionHeader('Warp'),
          SettingsCard(
            children: [
              const TextPref(
                'warp.remoteDns',
                'Remote DNS',
                icon: Symbols.outbound_rounded,
                hint: '1.1.1.1',
                help: 'It can be an IP (UDP DNS), tcp://host or https://host/dns-query.',
                validator: validateTunnelDns,
              ),
              const ListPref(
                'warp.endpoints',
                'Endpoints',
                icon: Symbols.list_arrow_rounded,
                hint: 'engage.cloudflareclient.com:2408\n162.159.192.1:2408\n[2606:4700:d0::a29f:c001]:2408',
                help: 'Cloudflare Warp endpoints.',
                allowEmpty: false,
                itemValidator: validateEndpoint,
              ),
              const SwitchPref(
                'warp.enableReservedBytes',
                'Reserved bytes',
                icon: Symbols.memory_rounded,
                subtitle: 'May help on some ISPs',
              ),
              ListTile(
                leading: const Icon(Symbols.graphic_eq_rounded),
                title: const Text('UDP Obfuscation'),
                subtitle: Text(
                  '${p.udpNoises.length} noise${p.udpNoises.length == 1 ? '' : 's'}',
                ),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const NoisesPage())),
              ),
              const IntPref(
                'warp.keepAlive',
                'Keep alive interval (s)',
                icon: Symbols.timer_rounded,
                help: 'Keep WARP connection alive. Set 0 to disable.',
                min: 0,
                max: 25,
                suffix: ' s',
              ),
              const IntPref(
                'warp.speedTestInterval',
                'Speed test interval (s)',
                icon: Symbols.timer_rounded,
                help: 'Interval between ping attempts to automatically find the fastest server.',
                min: 10,
                max: 300,
                suffix: ' s',
              ),
            ],
          ),
          const SizedBox(height: 16),
          SettingsCard(children: [const _WarpAccountTile()]),

          const SectionHeader('Masque'),
          SettingsCard(
            children: [
              const TextPref(
                'masque.remoteDns',
                'Remote DNS',
                icon: Symbols.outbound_rounded,
                hint: '1.1.1.1',
                help: 'It can be an IP (UDP DNS), tcp://host or https://host/dns-query.',
                validator: validateTunnelDns,
              ),
              const ListPref(
                'masque.endpoints',
                'Endpoints',
                icon: Symbols.list_arrow_rounded,
                hint: '162.159.198.1:443\n[2606:4700:103::1]:443',
                help: 'Each endpoint in a new line.',
                allowEmpty: false,
                itemValidator: validateEndpoint,
              ),
              const TextPref(
                'masque.sni',
                'SNI',
                icon: Symbols.host_rounded,
                hint: MasqueSettings.defaultSni,
                validator: validateHost,
              ),
              const ChoicePref('masque.transport', 'Transport', {
                'h2': 'H2 · TCP',
                'h3': 'H3 · QUIC',
              }, icon: Symbols.swap_horiz_rounded),
              if (p.masque.transport == 'h2')
                const ChoicePref(
                  'masque.tlsFingerprint',
                  'H2 Fingerprint',
                  fingerprints,
                  icon: Symbols.fingerprint_rounded,
                ),
              ListTile(
                leading: const Icon(Symbols.view_week_rounded),
                title: const Text('H2 TCP Fragments'),
                subtitle: Text(_fragmentSummary(p.masque.fragments)),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const FragmentsPage(section: 'masque.'),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Symbols.graphic_eq_rounded),
                title: const Text('H3 UDP Obfuscation'),
                subtitle: Text(
                  '${p.masque.udpNoises.length} noise${p.masque.udpNoises.length == 1 ? '' : 's'}',
                ),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NoisesPage(section: 'masque.'),
                  ),
                ),
              ),
              const IntPref(
                'masque.speedTestInterval',
                'Speed test interval (s)',
                icon: Symbols.timer_rounded,
                help: 'Interval between ping attempts to automatically find the fastest server.',
                min: 10,
                max: 300,
                suffix: ' s',
              ),
            ],
          ),
          const SizedBox(height: 16),
          SettingsCard(children: [const _MasqueAccountTile()]),

          const SectionHeader('Tor'),
          SettingsCard(
            children: [
              ListTile(
                leading: const Icon(Symbols.download_rounded),
                title: const Text('Get bridges'),
                subtitle: const Text('Fresh bridges from Tor'),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TorBridgesPage()),
                ),
              ),
              const ListPref(
                'tor.bridges',
                'Custom bridges',
                icon: Symbols.list_arrow_rounded,
                hint: 'webtunnel [2001:db8::1]:443 FINGERPRINT url=https://example.com/path ver=0.0.1',
                help:
                    'Used by the Tor Custom bridges mode. One bridge per line, as given by '
                    'bridges.torproject.org or @GetBridgesBot (webtunnel, obfs4, snowflake).',
                itemValidator: validateBridge,
                commaSeparated: false,
              ),
            ],
          ),

          const SectionHeader('Serverless'),
          SettingsCard(
            children: [
              ListTile(
                leading: const Icon(Symbols.view_week_rounded),
                title: const Text('TCP Fragments'),
                subtitle: Text(_fragmentSummary(p.serverless.fragments)),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const FragmentsPage(section: 'serverless.'),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Symbols.graphic_eq_rounded),
                title: const Text('UDP Obfuscation'),
                subtitle: Text(
                  '${p.serverless.udpNoises.length} noise${p.serverless.udpNoises.length == 1 ? '' : 's'}',
                ),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NoisesPage(section: 'serverless.'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SettingsCard(children: [const _MitmCaTile()]),

          const SectionHeader('Routing'),
          const SettingsCard(
            children: [
              _RulesTile(
                title: 'Bypass rules',
                icon: Symbols.alt_route_rounded,
                group: 'bypass',
                labels: RoutingPage.bypassLabels,
                domainHint: 'example.ir',
                ipHint:
                    '10.0.0.1/24\n192.178.24.110\n2a00:1450:400e:808::200e/128',
              ),
              _RulesTile(
                title: 'Sanction rules',
                icon: Symbols.alt_route_rounded,
                group: 'sanctionBypass',
                labels: RoutingPage.sanctionBypassLabels,
                domainHint: 'gemini.google.com',
                help: RoutingPage.sanctionHelp,
              ),
              _RulesTile(
                title: 'Block rules',
                icon: Symbols.do_not_disturb_on_rounded,
                group: 'block',
                labels: RoutingPage.blockLabels,
                domainHint: 'ads.example.com',
                ipHint: '10.10.34.34/24\n2001:4188:2:600:10:10:34:34/112',
              ),
              _GeoAssetsTile(),
            ],
          ),

          const SectionHeader('Import / Export'),
          const SettingsCard(
            children: [
              _ExportSettingsTile(download: false),
              _ImportSettingsTile(),
              _ExportSettingsTile(download: true),
            ],
          ),

          const SectionHeader('Appearance'),
          const SettingsCard(children: [_ThemeModeTile(), _ThemeColorTile()]),

          const SectionHeader('About'),
          SettingsCard(
            children: [
              const _VersionTile(),
              const _UpdateTile(),
              ListTile(
                leading: const Icon(Symbols.code_rounded),
                title: const Text('Source code'),
                subtitle: const Text(
                  sourceCodeUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Symbols.open_in_new_rounded, size: 20),
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  if (!await VpnChannel.openUrl(sourceCodeUrl)) {
                    await Clipboard.setData(
                      const ClipboardData(text: sourceCodeUrl),
                    );
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Link copied')),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Symbols.copyright_rounded),
                title: const Text('Open Source License'),
                subtitle: const Text('GNU GPL v3.0'),
                trailing: const Icon(Symbols.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LicensePageView()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Light / dark / follow the OS.
class _ThemeModeTile extends StatelessWidget {
  const _ThemeModeTile();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ValueListenableBuilder(
      valueListenable: state.themeMode,
      builder: (context, mode, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ListTile(
            leading: Icon(Symbols.contrast_rounded),
            title: Text('Theme mode'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Center(
              child: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ],
                selected: {mode},
                onSelectionChanged: (v) => state.setThemeMode(v.first),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Theme colour picker: a row of colour circles, the selected one checked.
class _ThemeColorTile extends StatelessWidget {
  const _ThemeColorTile();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder(
      valueListenable: state.themeColor,
      builder: (context, selected, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ListTile(
            leading: Icon(Symbols.palette_rounded),
            title: Text('Theme color'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 16, 16),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final c in ThemeColor.values)
                  Tooltip(
                    message: c.label,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => state.setThemeColor(c),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: c.seed,
                          // Ring around the selected colour.
                          border: Border.all(
                            color: c == selected
                                ? scheme.onSurface
                                : Colors.transparent,
                            width: 2.5,
                          ),
                        ),
                        child: c == selected
                            ? const Icon(
                                Symbols.check_rounded,
                                color: Colors.white,
                                size: 20,
                              )
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A routing group: the presets on and how many custom entries; opens its page.
class _RulesTile extends StatelessWidget {
  final String title;
  final IconData icon;
  final String group;
  final Map<String, String> labels;
  final String domainHint;

  /// Null for a group without custom IPs.
  final String? ipHint;
  final String? help;
  const _RulesTile({
    required this.title,
    required this.icon,
    required this.group,
    required this.labels,
    required this.domainHint,
    this.ipHint,
    this.help,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final enabled = [
      for (final e in labels.entries)
        if (state.readBool('routing.$group.presets.${e.key}')) e.value,
    ];
    final custom =
        state.readList('routing.$group.domains').length +
        (ipHint == null ? 0 : state.readList('routing.$group.ips').length);
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(
        [
          enabled.isEmpty ? 'No presets' : enabled.join(', '),
          if (custom > 0) '$custom custom',
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Symbols.chevron_right_rounded),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RoutingPage(
            title: title,
            group: group,
            labels: labels,
            domainHint: domainHint,
            ipHint: ipHint,
            help: help,
          ),
        ),
      ),
    );
  }
}

/// Custom domain row: tap to attach a domain while none is set; the trash icon detaches it.
class _CustomDomainTile extends StatefulWidget {
  const _CustomDomainTile();

  @override
  State<_CustomDomainTile> createState() => _CustomDomainTileState();
}

class _CustomDomainTileState extends State<_CustomDomainTile> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String success) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(success)));
    } on StateError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final state = AppScope.read(context);
    final domain = await showTextInputDialog(
      context,
      title: 'Add custom domain',
      hint: 'vpn.example.com',
      help:
          'The domain must be registered on the same Cloudflare account. '
          'Just add a desired subdomain which is not available on Cloudflare yet. '
          'BPB creates the DNS record and adds it to the worker.',
      validator: (v) => isDomain(v) ? null : 'Invalid domain',
    );
    if (domain == null || !mounted) return;
    await _run(
      () => state.setCustomDomain(domain.toLowerCase()),
      'Custom domain added',
    );
  }

  Future<void> _delete() async {
    final state = AppScope.read(context);
    final domain = state.worker!.customDomain ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete custom domain?'),
        content: Text(
          '$domain will be detached from the worker in Cloudflare. '
          'Configs fall back to the workers.dev address.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(state.removeCustomDomain, 'Custom domain deleted');
  }

  @override
  Widget build(BuildContext context) {
    final domain = AppScope.of(context).worker?.customDomain ?? '';
    return ListTile(
      leading: const Icon(Symbols.host_rounded),
      title: const Text('Custom domain'),
      subtitle: Text(domain.isEmpty ? 'Not set' : domain),
      onTap: _busy || domain.isNotEmpty ? null : _add,
      trailing: _busy
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : domain.isEmpty
          ? null
          : IconButton(
              tooltip: 'Delete custom domain',
              icon: const Icon(Symbols.delete_outline_rounded),
              onPressed: _delete,
            ),
    );
  }
}

/// Domain Fronting's CA (bpb-cert.crt / .key): created on this device on first install, then
/// handed to Android's certificate install (like [_WarpAccountTile]).
class _MitmCaTile extends StatefulWidget {
  const _MitmCaTile();

  @override
  State<_MitmCaTile> createState() => _MitmCaTileState();
}

class _MitmCaTileState extends State<_MitmCaTile> {
  late Future<bool> _created = AppScope.read(context).hasMitmCa();
  bool _busy = false;

  Future<void> _install() async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Symbols.verified_user_rounded, size: 36, weight: 600),
        title: const Text('Install certificate'),
        content: const Text(
          'Certificate will be saved to Downloads folder. Install it in Settings → '
          'Security → Encryption & credentials → Install a certificate → CA certificate.\n\n'
          'Never share BPB certificate files with anyone. Whoever has them can sniff your '
          'browser traffic.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final saved = await state.installMitmCa();
      if (saved != null) {
        messenger.showSnackBar(SnackBar(content: Text('Saved to $saved')));
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not install the certificate: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _created = state.hasMitmCa();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _created,
      builder: (context, snapshot) {
        final created = snapshot.data ?? false;
        return ListTile(
          leading: const Icon(Symbols.vpn_key_rounded),
          title: const Text('MITM certificate'),
          subtitle: Text(created ? 'Created' : 'Not created'),
          trailing: _busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : FilledButton.tonalIcon(
                  icon: const Icon(Symbols.security_rounded, size: 18),
                  label: const Text('Install'),
                  onPressed: _install,
                ),
        );
      },
    );
  }
}

/// Shows the registered WARP account and renews it (panel: "Renew Warp Accounts").
class _WarpAccountTile extends StatelessWidget {
  const _WarpAccountTile();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final registered = state.profile.warp.account != null;
    return ListTile(
      leading: const Icon(Symbols.vpn_key_rounded),
      title: const Text('WARP account'),
      subtitle: Text(registered ? 'Registered' : 'Not registered'),
      trailing: state.renewingWarp
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : FilledButton.tonalIcon(
              icon: const Icon(Symbols.autorenew_rounded, size: 18),
              label: Text(registered ? 'Renew' : 'Register'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                if (registered) {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Renew WARP account'),
                      content: const Text(
                        'Are you sure? A new account replaces the current one.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Renew'),
                        ),
                      ],
                    ),
                  );
                  if (ok != true) return;
                }
                try {
                  await state.renewWarpAccount();
                  messenger.showSnackBar(
                    const SnackBar(content: Text('WARP account updated')),
                  );
                } on StateError catch (e) {
                  messenger.showSnackBar(SnackBar(content: Text(e.message)));
                }
              },
            ),
    );
  }
}

/// Shows the registered MASQUE account and renews it, like [_WarpAccountTile].
class _MasqueAccountTile extends StatelessWidget {
  const _MasqueAccountTile();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final registered = state.profile.masque.account != null;
    return ListTile(
      leading: const Icon(Symbols.vpn_key_rounded),
      title: const Text('MASQUE account'),
      subtitle: Text(registered ? 'Registered' : 'Not registered'),
      trailing: state.renewingMasque
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : FilledButton.tonalIcon(
              icon: const Icon(Symbols.autorenew_rounded, size: 18),
              label: Text(registered ? 'Renew' : 'Register'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                if (registered) {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Renew MASQUE account'),
                      content: const Text(
                        'Are you sure? A new account replaces the current one.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Renew'),
                        ),
                      ],
                    ),
                  );
                  if (ok != true) return;
                }
                try {
                  await state.renewMasqueAccount();
                  messenger.showSnackBar(
                    const SnackBar(content: Text('MASQUE account updated')),
                  );
                } on StateError catch (e) {
                  messenger.showSnackBar(SnackBar(content: Text(e.message)));
                }
              },
            ),
    );
  }
}

/// "1 fragment", "3 fragments", like the noises' subtitles.
String _fragmentSummary(List<Fragment> fragments) =>
    '${fragments.length} fragment${fragments.length == 1 ? '' : 's'}';

/// Which of the selected account's deployments (Workers or Pages) Worker mode connects to; the
/// VLESS settings below are its own. The account is picked in Cloudflare accounts.
class _DeploymentTile extends StatelessWidget {
  const _DeploymentTile();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final s = state.selected;
    if (s == null) {
      return const ListTile(
        leading: Icon(Symbols.deployed_code_rounded),
        title: Text('Type'),
        subtitle: Text('None. Add a Cloudflare account below.'),
      );
    }
    final key = AppState.deploymentKey(s.account, s.deployment);
    final deploying = state.isDeploying(s.account, s.deployment);
    final error = state.deployErrors[key];
    // Proxy IPs and the fallback website deploy right away; only a failure stays on screen.
    final status = deploying
        ? 'Deploying…'
        : s.deployment.pending
        ? 'Not deployed${error != null ? ': $error' : ' yet'}'
        : null;
    final all = s.account.deployments;
    return ListTile(
      leading: const Icon(Symbols.deployed_code_rounded),
      title: const Text('Type'),
      subtitle: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: s.deployment.type.label),
            if (status != null)
              TextSpan(
                text: '\n$status',
                style: TextStyle(
                  color: deploying ? null : theme.colorScheme.error,
                ),
              ),
          ],
        ),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: deploying
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : s.deployment.pending
          ? IconButton(
              tooltip: 'Deploy again',
              icon: const Icon(Symbols.refresh_rounded),
              onPressed: () => state.redeploy(s.account, s.deployment.type),
            )
          : null,
      onTap: all.length < 2
          ? null
          : () async {
              final picked = await showDialog<WorkerType>(
                context: context,
                builder: (context) => SimpleDialog(
                  title: const Text('Type'),
                  children: [
                    RadioGroup<WorkerType>(
                      groupValue: s.deployment.type,
                      onChanged: (v) => Navigator.of(context).pop(v),
                      child: Column(
                        children: [
                          for (final d in all)
                            RadioListTile<WorkerType>(
                              value: d.type,
                              title: Text(d.type.label),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
              final d = picked == null ? null : s.account.deployment(picked);
              if (d != null) state.selectDeployment(s.account, d);
            },
    );
  }
}

/// Opens the Cloudflare accounts (like the WARP account tile in the WARP section).
class _CloudflareAccountsTile extends StatelessWidget {
  const _CloudflareAccountsTile();

  @override
  Widget build(BuildContext context) {
    final account = AppScope.of(context).selected?.account;
    return ListTile(
      leading: const Icon(Symbols.cloud_rounded),
      title: const Text('Cloudflare accounts'),
      subtitle: account == null
          ? null
          : Text(account.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Symbols.chevron_right_rounded),
      onTap: () =>
          Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const CfAccountsPage())),
    );
  }
}

const sourceCodeUrl = 'https://github.com/bia-pain-bache/BPB-VPN';

/// The installed app's version (pubspec.yaml's); opens the cores' versions.
class _VersionTile extends StatelessWidget {
  const _VersionTile();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: VpnChannel.appInfo().then((i) => i.version).catchError((_) => ''),
      builder: (context, snapshot) => ListTile(
        leading: const Icon(Symbols.info_rounded),
        title: const Text('Version'),
        subtitle: Text(snapshot.data ?? '…'),
        trailing: const Icon(Symbols.chevron_right_rounded),
        onTap: () =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const _VersionsPage())),
      ),
    );
  }
}

/// The cores' versions: Xray, Psiphon and Tor.
class _VersionsPage extends StatelessWidget {
  const _VersionsPage();

  /// The core's module version as its short commit, as Psiphon's own builds record it: Psiphon
  /// no longer tags releases, so it's a pseudo-version (v1.0.11-0.20261005170209-c4a09096ab40 →
  /// Commit c4a0909).
  static String _psiphon(String s) {
    final commit = RegExp(r'-([0-9a-f]{7})[0-9a-f]{5}$')
        .firstMatch(s)
        ?.group(1);
    return commit != null ? 'Commit $commit' : s.replaceFirst(RegExp('^v'), '');
  }

  /// "Tor version 0.4.8.17." → 0.4.8.17.
  static String _tor(String s) =>
      RegExp(r'Tor version (\S+?)\.?(\s|$)').firstMatch(s)?.group(1) ??
      s.split('\n').first;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Version')),
      body: FutureBuilder(
        future: VpnChannel.versions(),
        builder: (context, snapshot) {
          final v = snapshot.data;
          String shown(String Function(String) format, String? raw) =>
              switch (raw) {
                null => snapshot.hasError ? 'Unknown' : '…',
                '' => 'Unknown',
                final r => format(r),
              };
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              SettingsCard(
                children: [
                  ListTile(
                    leading: const Icon(Symbols.widgets_rounded),
                    title: const Text('Xray core · Mod'),
                    subtitle: Text(shown((s) => s, v?.xray)),
                  ),
                  ListTile(
                    leading: const Icon(Symbols.widgets_rounded),
                    title: const Text('Psiphon tunnel core · Mod'),
                    subtitle: Text(shown(_psiphon, v?.psiphon)),
                  ),
                  ListTile(
                    leading: const Icon(Symbols.widgets_rounded),
                    title: const Text('Tor Expert Bundle'),
                    subtitle: Text(shown(_tor, v?.tor)),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Checks GitHub for a newer release on request; the APK is downloaded in the browser.
class _UpdateTile extends StatefulWidget {
  const _UpdateTile();

  @override
  State<_UpdateTile> createState() => _UpdateTileState();
}

class _UpdateTileState extends State<_UpdateTile> {
  bool _checking = false;

  Future<void> _check() async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _checking = true);
    try {
      final update = await state.checkForUpdate();
      if (!mounted) return;
      if (update == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('BPB is up to date')),
        );
      } else {
        await _offer(update);
      }
    } on StateError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _offer(AppUpdate update) async {
    final download = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('BPB ${update.version} is available'),
        content: SingleChildScrollView(
          child: Text(
            update.notes.isEmpty ? 'No release notes.' : update.notes,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (download != true || !mounted) return;
    final url = update.apkUrl ?? update.pageUrl;
    final messenger = ScaffoldMessenger.of(context);
    if (!await VpnChannel.openUrl(url)) {
      await Clipboard.setData(ClipboardData(text: url));
      messenger.showSnackBar(
        const SnackBar(content: Text('Link copied. Open it in your browser.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Symbols.update_rounded),
      title: const Text('Check for updates'),
      subtitle: const Text('Latest release on GitHub'),
      trailing: _checking
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: _checking ? null : _check,
    );
  }
}

/// Downloads the latest geo assets (geoip.dat, geosite.dat) on request.
class _GeoAssetsTile extends StatefulWidget {
  const _GeoAssetsTile();

  @override
  State<_GeoAssetsTile> createState() => _GeoAssetsTileState();
}

class _GeoAssetsTileState extends State<_GeoAssetsTile> {
  bool _updating = false;

  Future<void> _update() async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _updating = true);
    try {
      await state.updateGeoAssets();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            state.isConnected
                ? 'Geo assets updated. Reconnect to use them.'
                : 'Geo assets updated',
          ),
        ),
      );
    } on StateError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Symbols.update_rounded),
      title: const Text('Update Geo assets'),
      subtitle: const Text('Latest Chocolate4U assets'),
      trailing: _updating
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: _updating ? null : _update,
    );
  }
}

/// Pretty JSON for display/copy.
String prettyJson(Object value) =>
    const JsonEncoder.withIndent('  ').convert(value);

/// Exports the profile (everything but the WARP account) as a JSON file: shared with an
/// app or saved to Downloads. Device settings and the worker are never included.
class _ExportSettingsTile extends StatelessWidget {
  /// Save to Downloads instead of opening the share sheet.
  final bool download;
  const _ExportSettingsTile({required this.download});

  Future<void> _export(BuildContext context) async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final name =
        'bpb-settings-${DateTime.now().toIso8601String().substring(0, 10)}.json';
    final content = state.exportSettingsFile();
    try {
      if (download) {
        final where = await VpnChannel.saveFile(name: name, content: content);
        if (where != null) {
          messenger.showSnackBar(SnackBar(content: Text('Saved to $where')));
        }
      } else {
        await VpnChannel.shareFile(
          name: name,
          content: content,
          title: 'Share settings',
        );
      }
    } on PlatformException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't export: ${e.message}")),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(download ? Symbols.download_rounded : Symbols.send_rounded),
    title: Text(download ? 'Export settings' : 'Share settings'),
    subtitle: Text(
      download
          ? 'Save settings file to Downloads'
          : 'Send settings file to other users',
    ),
    onTap: () => _export(context),
  );
}

/// Loads settings from a file made by "Share settings" or "Download settings".
class _ImportSettingsTile extends StatelessWidget {
  const _ImportSettingsTile();

  Future<void> _import(BuildContext context) async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final String? text;
    try {
      text = (await VpnChannel.pickFile())?.content;
    } on PlatformException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't read the file: ${e.message}")),
      );
      return;
    }
    if (text == null || !context.mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import settings?'),
        content: const Text(
          'Your settings are replaced with the ones in this file. '
          'Your WARP account, worker and this device\'s setup (per-app list, LAN sharing, theme…) stay as they are.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      state.importSettingsFile(text);
      messenger.showSnackBar(
        const SnackBar(content: Text('Settings imported')),
      );
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Symbols.upload_rounded),
    title: const Text('Import settings'),
    subtitle: const Text('Load settings from a file'),
    onTap: () => _import(context),
  );
}
