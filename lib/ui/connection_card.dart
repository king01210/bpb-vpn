import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/settings.dart';
import '../services/chain_proxy.dart';
import '../services/my_ip.dart';
import '../services/xray_config.dart';
import '../state/app_state.dart';
import 'chip_menu.dart';
import 'theme.dart';

/// The connection's settings, above the status card: its type and mode, and where traffic
/// leaves for the internet (the connection itself, the chain proxy, or Psiphon / Tor in a
/// chosen region).
class ConnectionCard extends StatelessWidget {
  const ConnectionCard({super.key});

  static const _rowAnimation = Duration(milliseconds: 250);

  /// What the exit carries: the worker relays only TCP, Tor too; WARP, MASQUE and Psiphon also
  /// UDP; the chain proxy depends on its protocol ([ChainInfo.carries]).
  static List<String> _transports(ExitNode node, ConnectionMode mode, {required ChainProxy? chain}) => switch (node) {
    ExitNode.worker => switch (mode) {
      ConnectionMode.worker => const ['TCP'],
      ConnectionMode.warp || ConnectionMode.masque => const ['TCP', 'UDP'],
      _ => const [],
    },
    ExitNode.chain => chain == null ? const [] : ChainInfo.of(chain.link)?.carries ?? const [],
    ExitNode.psiphon => const ['TCP', 'UDP'],
    ExitNode.tor => const ['TCP'],
  };

  static String _regionLabel(String code) =>
      code.isEmpty ? 'Fastest' : '${countryFlag(code)} ${exitRegions[code] ?? code}';

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final exit = state.exitNode;
    // The Psiphon and Tor types have no exit node to choose: only the region can change.
    final hasExitNode = state.mode != ConnectionMode.psiphon && state.mode != ConnectionMode.tor;
    final nodes = switch (state.mode) {
      ConnectionMode.serverless => [ExitNode.worker, ExitNode.psiphon, ExitNode.tor],
      // The chain proxy is an exit node once there's one the type can carry (Settings → Chain proxies).
      _ => [for (final n in ExitNode.values) if (n != ExitNode.chain || state.usableChains.isNotEmpty) n],
    };
    final chain = state.exitChain;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      shape: roundedShape(kCardRadius),
      color: scheme.surfaceContainer,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Row(icon: Symbols.category_rounded, label: 'Connection', selector: _TypeSelector()),
            // The variant (Worker, WARP, MASQUE), Serverless's mode or Tor's bridges.
            AnimatedSize(
              duration: _rowAnimation,
              curve: Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: state.hasModeOption
                  ? const _Row(icon: Symbols.tune_rounded, label: 'Mode', selector: _ModeSelector())
                  : const SizedBox(width: double.infinity),
            ),
            AnimatedSize(
              duration: _rowAnimation,
              curve: Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: hasExitNode
                  ? _Row(
                      icon: Symbols.exit_to_app_rounded,
                      label: 'Exit Node',
                      selector: ChipMenu(
                        values: nodes,
                        selected: exit,
                        label: (n) => switch (n) {
                          ExitNode.worker => 'Default',
                          ExitNode.chain => 'Chain proxy',
                          ExitNode.psiphon => 'Psiphon',
                          ExitNode.tor => 'Tor',
                        },
                        badges: (n) => _transports(n, state.mode, chain: chain),
                        onSelected: state.setExitNode,
                        enabled: !state.isBusy && nodes.length > 1,
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            AnimatedSize(
              duration: _rowAnimation,
              curve: Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: exit == ExitNode.psiphon || exit == ExitNode.tor
                  ? _Row(
                      icon: Symbols.location_on_rounded,
                      label: 'Region',
                      selector: ChipMenu(
                        values: ['', ...exitRegions.keys],
                        selected: state.device.exitRegion,
                        label: _regionLabel,
                        onSelected: state.setExitRegion,
                        enabled: !state.isBusy,
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            // The chain proxy this type exits through: names, with their tags in the open menu.
            AnimatedSize(
              duration: _rowAnimation,
              curve: Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: exit == ExitNode.chain && chain != null
                  ? _Row(
                      icon: Symbols.link_rounded,
                      label: 'Chain',
                      selector: ChipMenu(
                        values: state.usableChains,
                        selected: chain,
                        label: (c) => c.name,
                        subtitleBadges: (c) => ChainInfo.of(c.link)?.tags ?? const [],
                        onSelected: state.setExitChain,
                        enabled: !state.isBusy && state.usableChains.length > 1,
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Label ········ [chip ▾]".
class _Row extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget selector;
  const _Row({required this.icon, required this.label, required this.selector});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Icon(icon, size: 22, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(label, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const Spacer(),
          selector,
        ],
      ),
    );
  }
}

/// Connection types. Every type except Serverless connects with a best-ping config.
class _TypeSelector extends StatelessWidget {
  const _TypeSelector();

  static String _protocol(ConnectionMode m) => switch (m) {
    ConnectionMode.worker => 'VLESS',
    ConnectionMode.warp => 'Wireguard',
    // CONNECT-IP over HTTP/2 or 3: HTTPS either way.
    ConnectionMode.masque => 'HTTPS',
    ConnectionMode.serverless => 'Direct',
    // Psiphon's tunnels are all SSH based, under various obfuscation layers.
    ConnectionMode.psiphon => 'SSH',
    ConnectionMode.tor => 'Onion',
  };

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ChipMenu(
      // Only what's installed (see AppState.availableModes).
      values: state.availableModes,
      selected: state.mode,
      label: (m) => m.label,
      badges: (m) => [_protocol(m)],
      onSelected: state.setMode,
      enabled: !state.isBusy,
    );
  }
}

/// Serverless: Fragment or Domain Fronting. Tor: bridges. MASQUE: mode. Worker / WARP: variant.
class _ModeSelector extends StatelessWidget {
  const _ModeSelector();

  /// Domain Fronting needs its CA installed: until it exists, choosing it asks first.
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    if (state.mode == ConnectionMode.masque) {
      return ChipMenu(
        values: MasqueVariant.values,
        selected: state.masqueVariant,
        label: (v) => v.label(state.profile.masque.transport == 'h3'),
        onSelected: state.setMasqueVariant,
        enabled: !state.isBusy,
      );
    }
    if (state.mode == ConnectionMode.tor) {
      // Direct, Tor's built-in bridges of a transport, or the custom bridges from Settings → Tor.
      return ChipMenu(
        values: torBridges.keys.toList(),
        selected: state.device.torBridge,
        label: (v) {
          final count = state.profile.tor.bridges.length;
          return v == 'custom' && count > 0 ? 'Custom bridges ($count)' : torBridges[v] ?? v;
        },
        onSelected: state.setTorBridge,
        enabled: !state.isBusy,
      );
    }
    if (state.mode == ConnectionMode.serverless) {
      return ChipMenu(
        values: ServerlessMode.values,
        selected: state.serverlessMode,
        label: (v) => v.label,
        onSelected: state.setServerlessMode,
        enabled: !state.isBusy,
      );
    }
    return ChipMenu(
      values: ConnectionVariant.of(state.mode),
      selected: state.variant,
      label: (v) => v.label(state.mode),
      onSelected: state.setVariant,
      enabled: !state.isBusy,
    );
  }
}
