import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../services/tor_bridges.dart';
import '../state/app_state.dart';
import 'prefs.dart';

/// Settings → Tor → Get bridges: pick bridge types, get bridges from Tor Project, and
/// install them as custom bridges.
class TorBridgesPage extends StatefulWidget {
  const TorBridgesPage({super.key});

  @override
  State<TorBridgesPage> createState() => _TorBridgesPageState();
}

class _TorBridgesPageState extends State<TorBridgesPage> {
  final _types = <String>{'webtunnel', 'obfs4', 'snowflake'};
  bool _loading = false;
  List<String>? _bridges;
  String? _error;

  Future<void> _get() async {
    setState(() {
      _loading = true;
      _error = null;
      _bridges = null;
    });
    try {
      final types = TorBridgeFetcher.transports.keys.where(_types.contains).toList();
      final bridges = await AppScope.read(context).fetchTorBridges(types);
      if (mounted) setState(() => _bridges = bridges);
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _install() {
    final added = AppScope.read(context).installTorBridges(_bridges!);
    final skipped = _bridges!.length - added;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == 0
              ? 'These bridges are already installed'
              : 'Installed $added bridge${added == 1 ? '' : 's'}${skipped > 0 ? ' ($skipped already there)' : ''}',
        ),
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bridges = _bridges;
    return Scaffold(
      appBar: AppBar(title: const Text('Get bridges')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              'Fresh bridges from Tor Project specifically for Iran, handed out by its official bridge distributor.',
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SectionHeader('Bridge types'),
          SettingsCard(
            children: [
              for (final MapEntry(key: type, value: label) in TorBridgeFetcher.transports.entries)
                CheckboxListTile(
                  title: Text(label),
                  value: _types.contains(type),
                  onChanged: _loading
                      ? null
                      : (on) => setState(() => on == true ? _types.add(type) : _types.remove(type)),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: FilledButton.icon(
              icon: _loading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Symbols.download_rounded),
              label: Text(_loading ? 'Getting bridges…' : 'Get bridges'),
              onPressed: _loading || _types.isEmpty ? null : _get,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Text(_error!, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error)),
            ),
          if (bridges != null) ...[
            SectionHeader('${bridges.length} bridge${bridges.length == 1 ? '' : 's'}'),
            SettingsCard(
              children: [
                for (final line in bridges)
                  ListTile(
                    title: Text(line.split(' ').first),
                    subtitle: SelectableText(
                      line,
                      maxLines: 3,
                      style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: FilledButton.icon(
                icon: const Icon(Symbols.add_circle_rounded),
                label: const Text('Install'),
                onPressed: _install,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
