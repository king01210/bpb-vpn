import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../services/vpn_channel.dart';
import '../state/app_state.dart';
import 'chip_menu.dart';

/// The logs of the current (or last) connection, refreshed live: Xray's (VPN), and Tor's /
/// Psiphon's when they ran, each as its program wrote it. Also the Xray log level.
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  static const _levels = {'none': 'None', 'error': 'Error', 'warning': 'Warning', 'info': 'Info', 'debug': 'Debug'};

  /// The logs, by the name the service uses.
  static const _logs = {'xray': 'VPN', 'tor': 'Tor', 'psiphon': 'Psiphon'};

  /// Most recent lines kept on screen.
  static const _maxLines = 1000;

  final _scroll = ScrollController();
  Timer? _poll;
  List<String> _lines = const [];

  /// The log on screen, and the logs with something in them (Xray's always shown).
  String _log = 'xray';
  List<String> _available = const ['xray'];

  /// Keep scrolling to new lines while the view is at the bottom.
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      _follow = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 24;
    });
    _load();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final String text;
    final Map<String, int> sizes;
    final log = _log;
    try {
      sizes = await VpnChannel.logSizes();
      text = await VpnChannel.readLog(log: log);
    } catch (_) {
      return;
    }
    if (!mounted || log != _log) return;
    final available = _logs.keys.where((l) => l == 'xray' || (sizes[l] ?? 0) > 0).toList();
    if (available.join() != _available.join()) setState(() => _available = available);
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.length == _lines.length && (lines.isEmpty || lines.last == _lines.last)) return;
    setState(() => _lines = lines.length > _maxLines ? lines.sublist(lines.length - _maxLines) : lines);
    if (_follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _lines.join('\n')));
    messenger.showSnackBar(const SnackBar(content: Text('Log copied')));
  }

  Future<void> _clear() async {
    await VpnChannel.clearLog();
    if (mounted) {
      setState(() {
        _lines = const [];
        _log = 'xray';
        _available = const ['xray'];
      });
    }
  }

  void _show(String log) {
    if (log == _log) return;
    setState(() {
      _log = log;
      _lines = const [];
      _follow = true;
    });
    _load();
  }

  /// Colour by level as each program writes it: Xray "[Warning]", Tor "[warn]", Psiphon
  /// "noticeType":"Warning"; and the app's own "[App]" lines.
  Color? _colorFor(String line, ColorScheme scheme) {
    if (line.contains('[Error]') || line.contains('[err]') || line.contains('"noticeType":"Error"')) {
      return scheme.error;
    }
    if (line.contains('[Warning]') ||
        line.contains('[warn]') ||
        line.contains('"noticeType":"Warning"') ||
        line.contains('"noticeType":"Alert"')) {
      return scheme.tertiary;
    }
    if (line.contains('[App]')) return scheme.primary;
    if (line.contains('[Debug]')) return scheme.onSurfaceVariant;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final level = state.device.logLevel;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            onPressed: _lines.isEmpty ? null : _copy,
            icon: const Icon(Symbols.content_copy_rounded),
          ),
          IconButton(
            tooltip: 'Clear',
            onPressed: _lines.isEmpty ? null : _clear,
            icon: const Icon(Symbols.delete_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          ListTile(
            leading: const Icon(Symbols.tune_rounded),
            title: const Text('Log level'),
            subtitle: Text(state.isConnected ? 'Changes apply when you reconnect.' : 'Applies to the next connection.'),
            trailing: ChipMenu(
              values: _levels.keys.toList(),
              selected: level,
              label: (v) => _levels[v] ?? v,
              onSelected: (v) => state.write('device.logLevel', v),
            ),
          ),
          if (_available.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: SegmentedButton<String>(
                segments: [for (final l in _available) ButtonSegment(value: l, label: Text(_logs[l]!))],
                selected: {_log},
                showSelectedIcon: false,
                onSelectionChanged: (s) => _show(s.first),
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: _lines.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _log != 'xray'
                            ? 'Nothing logged yet.'
                            : level == 'none'
                            ? 'Logging is off. Choose a log level, then connect.'
                            : 'No log yet. Connect to see what Xray reports.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      itemCount: _lines.length,
                      itemBuilder: (context, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          _lines[i],
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.35,
                            color: _colorFor(_lines[i], scheme),
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
