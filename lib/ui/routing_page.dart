import 'package:flutter/material.dart';

import 'prefs.dart';

/// One routing group: its built-in presets (`routing.<group>.presets.<name>`), then its custom
/// domains (`routing.<group>.domains`) and, unless [ipHint] is null, IPs (`routing.<group>.ips`).
class RoutingPage extends StatelessWidget {
  final String title;

  /// "bypass", "sanctionBypass" or "block".
  final String group;
  final Map<String, String> labels;
  final String domainHint;

  /// Null for a group without custom IPs (sanction rules: domains only).
  final String? ipHint;

  /// Shown at the top of the page, or null.
  final String? help;
  const RoutingPage({
    super.key,
    required this.title,
    required this.group,
    required this.labels,
    required this.domainHint,
    this.ipHint,
    this.help,
  });

  /// When the sanction rules apply (see XrayConfigBuilder._antiSanction).
  static const sanctionHelp =
      'These rules only apply to Serverless, WARP and MASQUE connections when Exit node is set to Default.';

  /// Direct connection, resolved with the local DNS.
  static const bypassLabels = {'iran': 'Iran', 'china': 'China', 'russia': 'Russia', 'bittorrent': 'BitTorrent'};

  /// Direct connection, resolved with the anti-sanction DNS.
  static const sanctionBypassLabels = {
    'openAi': 'ChatGPT',
    'googleAi': 'Google AIs',
    'microsoft': 'Microsoft',
    'oracle': 'Oracle',
    'docker': 'Docker',
    'adobe': 'Adobe',
    'epicGames': 'Epic Games',
    'intel': 'Intel',
    'amd': 'AMD',
    'nvidia': 'Nvidia',
    'asus': 'Asus',
    'hp': 'HP',
    'lenovo': 'Lenovo',
  };

  static const blockLabels = {
    'ads': 'Ads',
    'porn': 'Porn',
    'malware': 'Malware',
    'phishing': 'Phishing',
    'cryptominers': 'Cryptominers',
    'quic': 'QUIC',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          if (help != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text(
                help!,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          const SectionHeader('Presets'),
          SettingsCard(
            children: [
              for (final e in labels.entries)
                SwitchPref(
                  'routing.$group.presets.${e.key}',
                  e.value,
                  subtitle: e.key == 'quic' ? 'VLESS always blocks UDP, this only applies to other protocols' : null,
                ),
            ],
          ),
          const SectionHeader('Manual'),
          SettingsCard(
            children: [
              ListPref('routing.$group.domains', 'Domains', hint: domainHint, itemValidator: validateDomain),
              if (ipHint != null)
                ListPref('routing.$group.ips', 'IPs or CIDRs', hint: ipHint, itemValidator: validateIpOrCidr),
            ],
          ),
        ],
      ),
    );
  }
}
