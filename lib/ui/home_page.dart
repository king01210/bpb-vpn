import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/settings.dart';
import '../state/app_state.dart';
import 'chip_menu.dart';
import 'config_view_page.dart';
import 'connection_card.dart';
import 'format.dart';
import 'log_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'status_card.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The status bar icon, tinted like the other icons.
            ImageIcon(
              const AssetImage('assets/icons/ic_stat_vpn.png'),
              size: 24,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 6),
            const Text('BPB', style: TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
        actions: [
          // VPN: the whole device; Proxy: only apps set to use the local SOCKS/HTTP proxy.
          ChipMenu(
            values: AppMode.values,
            selected: state.device.appMode,
            label: (v) => v == AppMode.proxy ? 'Proxy mode' : 'VPN mode',
            onSelected: state.setAppMode,
            enabled: !state.isBusy,
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Logs',
            icon: const Icon(Symbols.bug_report_rounded),
            onPressed: () =>
                Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const LogPage())),
          ),
          IconButton(
            tooltip: 'View config',
            icon: const Icon(Symbols.data_object_rounded),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const ConfigViewPage())),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Symbols.settings_rounded),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            children: [
              if (state.needsReconnect) const _ReconnectBanner(),
              const SizedBox(height: 12),
              const ConnectionCard(),
              const SizedBox(height: 12),
              const StatusCard(),
              const SizedBox(height: 12),
              const _TrafficRow(),
              const SizedBox(height: 12),
              // Worker requests only matter for the types that use the worker (Worker).
              if (state.worker != null && state.mode.needsWorker)
                const _UsageCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReconnectBanner extends StatelessWidget {
  const _ReconnectBanner();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      shape: roundedShape(kCardRadius),
      color: Theme.of(context).colorScheme.surfaceContainer,
      elevation: 0,
      child: ListTile(
        leading: Icon(
          Symbols.sync_rounded,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: const Text('Settings changed'),
        subtitle: const Text('Reconnect to apply them.'),
        trailing: FilledButton.tonal(
          onPressed: state.reconnect,
          child: const Text('Apply'),
        ),
      ),
    );
  }
}

const _tabular = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

/// Download and Upload cards (rate on top, session total below).
/// Always laid out so the connect button doesn't jump when the VPN connects.
class _TrafficRow extends StatelessWidget {
  const _TrafficRow();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _TrafficCard(
                  icon: Symbols.arrow_downward_rounded,
                  rate: state.downSpeed,
                  total: state.totalDown,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _TrafficCard(
                  icon: Symbols.arrow_upward_rounded,
                  rate: state.upSpeed,
                  total: state.totalUp,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TrafficCard extends StatelessWidget {
  final IconData icon;
  final int rate;
  final int total;
  const _TrafficCard({
    required this.icon,
    required this.rate,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Card(
      margin: EdgeInsets.zero,
      shape: roundedShape(kCardRadius),
      color: theme.colorScheme.surfaceContainer,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, weight: 600, color: muted),
                const SizedBox(width: 6),
                Text(
                  '${formatBytes(rate)}/s',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600).merge(_tabular),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const SizedBox(height: 2),
            Text(
              'Total ${formatBytes(total)}',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: muted)
                  .merge(_tabular),
            ),
          ],
        ),
      ),
    );
  }
}

/// Card with a title, a refresh button and a body, used by My IP and Usage.
class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool loading;
  final VoidCallback onRefresh;
  final List<Widget> children;
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.loading,
    required this.onRefresh,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      shape: roundedShape(kCardRadius),
      color: theme.colorScheme.surfaceContainer,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                IconButton(
                  tooltip: 'Refresh',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 24,
                    height: 24,
                  ),
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: loading ? null : onRefresh,
                  icon: loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Symbols.refresh_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
            // Padding(
            //   padding: const EdgeInsets.only(right: 0),
            // ),
          ],
        ),
      ),
    );
  }
}

/// Label on the left, [value] right-aligned.
class _KeyValue extends StatelessWidget {
  final String label;
  final Widget value;
  const _KeyValue(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Align(alignment: AlignmentDirectional.centerEnd, child: value),
        ),
      ],
    );
  }
}

class _UsageCard extends StatelessWidget {
  const _UsageCard();

  /// Workers free plan daily request limit (shared by the whole account).
  static const _limit = 100000;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final usage = state.usage;
    final style = theme.textTheme.bodyMedium?.merge(_tabular);
    return _InfoCard(
      icon: Symbols.data_usage_rounded,
      title: 'Request usage · last 24h',
      loading: state.loadingUsage,
      onRefresh: state.refreshUsage,
      children: [
        if (usage != null) ...[
          _KeyValue(
            'This worker',
            Text(
              formatCount(usage.worker),
              style: style?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 10),
          _AccountUsage(total: usage.total, limit: _limit),
        ] else if (state.usageError == null)
          Text(
            state.loadingUsage ? 'Loading…' : '—',
            style: theme.textTheme.bodyMedium,
          ),
        if (state.usageError != null)
          Padding(
            padding: EdgeInsets.only(top: usage != null ? 8 : 0),
            child: Text(
              state.usageError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

/// "12,345 · 12.3%" with a bar against the daily limit.
class _AccountUsage extends StatelessWidget {
  final int total;
  final int limit;
  const _AccountUsage({required this.total, required this.limit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ratio = total / limit;
    final style = theme.textTheme.bodyMedium?.merge(_tabular);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _KeyValue(
          'Account total',
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: formatCount(total),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(text: ' · ${(ratio * 100).toStringAsFixed(1)}%'),
              ],
            ),
            style: style,
          ),
        ),
        const SizedBox(height: 10),
        LinearProgressIndicator(
          value: ratio.clamp(0.0, 1.0),
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
          color: ratio >= 0.9 ? theme.colorScheme.error : null,
        ),
      ],
    );
  }
}
