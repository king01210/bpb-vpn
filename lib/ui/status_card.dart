import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/settings.dart';
import '../services/my_ip.dart';
import '../services/vpn_channel.dart';
import '../state/app_state.dart';
import 'format.dart';
import 'theme.dart';

/// Connected colour; stays green whatever theme colour is picked.
const _green = Color(0xFF1FA463);
const _tabular = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

// Layout constants: the power button is positioned from these.
const _pad = 20.0;
const _rowHeight = 124.0;
const _button = 116.0;
const _buttonTop = _pad + (_rowHeight - _button) / 2;

/// Home status card: state, power button, duration, ping and exit IPs (the connection's
/// settings are on the ConnectionCard above it).
class StatusCard extends StatefulWidget {
  const StatusCard({super.key});

  @override
  State<StatusCard> createState() => _StatusCardState();
}

class _StatusCardState extends State<StatusCard> {
  /// Ticks the connection duration.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && AppScope.read(context).isConnected) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed =
        state.status == VpnStatus.disconnected && state.error != null;
    final (title, subtitle) = switch (state.status) {
      // Psiphon / Tor say what they're doing: progress while connecting, or reconnecting.
      VpnStatus.connected => (
        'Connected',
        state.exitDetail ?? 'Tap to disconnect',
      ),
      VpnStatus.connecting => (
        'Connecting',
        state.exitDetail ?? 'Starting the tunnel…',
      ),
      VpnStatus.disconnecting => ('Disconnecting', 'Stopping the tunnel…'),
      VpnStatus.disconnected when failed => ('Connection failed', state.error!),
      VpnStatus.disconnected => ('Disconnected', 'Tap to connect'),
    };
    final titleColor = state.isConnected
        ? _green
        : (failed ? scheme.error : scheme.onSurface);
    final muted = scheme.onSurfaceVariant;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: scheme.surfaceContainer,
      elevation: 0,
      shape: roundedShape(kHeroRadius),
      child: Stack(
        // Let the button's shadow spill past the card edge instead of being cut off.
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.all(_pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title and hint on the left; space for the button on the right.
                SizedBox(
                  height: _rowHeight,
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: AlignmentDirectional.centerStart,
                              child: Text(
                                title,
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: titleColor,
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16 + _button),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _Metrics(),
              ],
            ),
          ),
          Positioned(
            right: _pad - 8,
            top: _buttonTop - 8,
            width: _button + 16,
            height: _button + 16,
            child: const _PowerButton(),
          ),
        ],
      ),
    );
  }
}

/// Duration, ping and the two exit IPs in a 2×2 grid.
class _Metrics extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final since = state.connectedAt;
    final ips = state.myIps;

    Widget ip(IpInfo? info) {
      final text = !state.isConnected
          ? '—'
          : ips == null
          ? (state.loadingIps ? '…' : '—')
          : info == null
          ? 'Unavailable'
          : info.country == null
          ? info.ip
          : '${countryFlag(info.country!)} ${info.ip}';
      return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
    }

    final refreshIps = state.isConnected ? state.refreshMyIps : null;
    final twoIps = state.mode.needsWorker && state.exitNode == ExitNode.worker;
    // This phone's LAN address (always shown); with LAN connections allowed, other
    // devices use it with port 10808 for the SOCKS/HTTP proxy.
    final lanIp = state.lanIp;
    final lan = _Metric(
      label: 'LAN IP',
      value: Text(lanIp ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis),
      tooltip: 'Tap to copy',
      onTap: lanIp == null
          ? null
          : () {
              Clipboard.setData(ClipboardData(text: lanIp));
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('Copied $lanIp')));
            },
    );
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _Metric(
                label: 'Duration',
                value: Text(
                  state.isConnected && since != null
                      ? formatDuration(DateTime.now().difference(since))
                      : '—',
                ),
              ),
            ),
            Expanded(
              child: _Metric(
                label: 'Ping',
                value: state.isConnected
                    ? const _PingButton()
                    : const Text('—'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // Through the worker alone, Cloudflare-hosted sites see the proxy IP and others the
        // worker's exit IP. WARP, Serverless and the chain / Psiphon exits have a single exit IP.
        Row(
          children: twoIps
              ? [
                  Expanded(
                    child: _Metric(
                      label: 'My IP',
                      value: ip(ips?.other),
                      onTap: refreshIps,
                    ),
                  ),
                  Expanded(
                    child: _Metric(
                      label: 'My IP Cloudflare',
                      value: ip(ips?.cloudflare),
                      onTap: refreshIps,
                    ),
                  ),
                ]
              : [
                  Expanded(
                    child: _Metric(
                      label: 'My IP',
                      value: ip(ips?.other ?? ips?.cloudflare),
                      onTap: refreshIps,
                    ),
                  ),
                  Expanded(child: lan),
                ],
        ),
        // Both target IPs fill the row, so the LAN IP gets its own.
        if (twoIps) ...[const SizedBox(height: 14), lan],
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final Widget value;

  /// Tap action (refresh the IPs, copy the proxy address) and its hint.
  final VoidCallback? onTap;
  final String tooltip;

  const _Metric({
    required this.label,
    required this.value,
    this.onTap,
    this.tooltip = 'Tap to refresh',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        DefaultTextStyle.merge(
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600)
              .merge(_tabular),
          child: SizedBox(
            height: 28,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: value,
            ),
          ),
        ),
      ],
    );
    if (onTap == null) {
      return Padding(padding: const EdgeInsets.only(right: 8), child: content);
    }
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: content,
        ),
      ),
    );
  }
}

/// Bold bolt that tests the ping; shows the result next to it once measured.
class _PingButton extends StatelessWidget {
  const _PingButton();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final ping = state.pingMs;
    final color = theme.colorScheme.primary;
    return Tooltip(
      message: 'Test ping',
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: state.pinging ? null : state.testPing,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 2, 8, 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state.pinging)
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: color,
                  ),
                )
              else
                Icon(
                  Symbols.electric_bolt_rounded,
                  size: 22,
                  weight: 700,
                  color: color,
                ),
              const SizedBox(width: 6),
              Text(
                state.pinging
                    ? 'Testing'
                    : ping == null
                    ? 'Test'
                    : (ping < 0 ? 'Timeout' : '$ping ms'),
                style: TextStyle(
                  color: ping != null && ping < 0
                      ? theme.colorScheme.error
                      : color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Big round power button. The icon points down while disconnected and flips up when
/// connecting/connected; it glows when connected and shows a spinning ring while busy.
class _PowerButton extends StatefulWidget {
  const _PowerButton();

  @override
  State<_PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<_PowerButton> {
  bool _pressed = false;

  /// Icon rotation in turns. It only ever grows by half a turn, so the icon always
  /// spins clockwise: down → up on connect, up → down on disconnect.
  double? _turns;
  bool? _up;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final busy = state.isBusy;
    final (Color fill, Color iconColor) = switch (state.status) {
      VpnStatus.connected => (_green, Colors.white),
      VpnStatus.disconnected => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      _ => (scheme.primary, scheme.onPrimary),
    };
    final up =
        state.status == VpnStatus.connected ||
        state.status == VpnStatus.connecting;
    if (_up == null) {
      _turns = up ? 0 : 0.5;
    } else if (_up != up) {
      _turns = _turns! + 0.5;
    }
    _up = up;
    const duration = Duration(milliseconds: 500);

    return Semantics(
      button: true,
      label: state.isConnected ? 'Disconnect' : 'Connect',
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (busy)
            Positioned.fill(
              child: CircularProgressIndicator(
                strokeWidth: 3,
                strokeCap: StrokeCap.round,
                color: fill,
              ),
            ),
          AnimatedScale(
            scale: _pressed ? 0.92 : 1,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              width: _button,
              height: _button,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // A slightly lighter top-left gives the button some depth.
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color.lerp(fill, Colors.white, 0.18)!, fill],
                ),
                boxShadow: [
                  // Coloured glow, stronger when connected.
                  BoxShadow(
                    color: fill.withValues(
                      alpha: state.isConnected ? 0.5 : 0.3,
                    ),
                    blurRadius: state.isConnected ? 32 : 24,
                    offset: const Offset(0, 10),
                  ),
                  // Tight contact shadow under the button.
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Material(
                type: MaterialType.transparency,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  // Always tappable: while connecting (Psiphon may search for a long time) it cancels.
                  onTap: state.toggle,
                  onHighlightChanged: (v) => setState(() => _pressed = v),
                  child: Center(
                    child: AnimatedRotation(
                      turns: _turns!,
                      duration: const Duration(milliseconds: 700),
                      curve: Curves.easeOutBack,
                      child: TweenAnimationBuilder<Color?>(
                        tween: ColorTween(end: iconColor),
                        duration: duration,
                        builder: (context, color, _) => Icon(
                          Symbols.power_settings_new_rounded,
                          size: 56,
                          weight: 600,
                          color: color,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
