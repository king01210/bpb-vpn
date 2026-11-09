import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../services/vpn_channel.dart';
import '../models/settings.dart';
import '../state/app_state.dart';

class PerAppPage extends StatefulWidget {
  const PerAppPage({super.key});

  @override
  State<PerAppPage> createState() => _PerAppPageState();
}

class _PerAppPageState extends State<PerAppPage> {
  late final Future<List<InstalledApp>> _apps = VpnChannel.installedApps();
  String _query = '';
  bool _showSystem = false;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final mode = state.device.perAppMode;
    final selected = state.device.perAppApps.toSet();

    void toggle(String pkg, bool on) {
      final next = {...selected};
      on ? next.add(pkg) : next.remove(pkg);
      state.write('device.perAppProxy.apps', next.toList());
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Per-app proxy'),
        actions: [
          IconButton(
            tooltip: _showSystem ? 'Hide system apps' : 'Show system apps',
            icon: Icon(_showSystem ? Symbols.android_rounded : Symbols.apps_rounded),
            onPressed: () => setState(() => _showSystem = !_showSystem),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: DropdownMenu<PerAppMode>(
              initialSelection: mode,
              expandedInsets: EdgeInsets.zero,
              dropdownMenuEntries: const [
                DropdownMenuEntry(value: PerAppMode.off, label: 'Proxy all apps'),
                DropdownMenuEntry(value: PerAppMode.include, label: 'Proxy selected apps'),
                DropdownMenuEntry(value: PerAppMode.exclude, label: 'Exclude selected apps'),
              ],
              onSelected: (v) {
                if (v != null) state.write('device.perAppProxy.mode', v.name);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Symbols.search_rounded),
                hintText: 'Search apps',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.toLowerCase()),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<List<InstalledApp>>(
              future: _apps,
              builder: (context, snapshot) {
                if (snapshot.hasError) return Center(child: Text('Could not list apps: ${snapshot.error}'));
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                final apps =
                    snapshot.data!
                        .where((a) => _showSystem || !a.isSystem || selected.contains(a.packageName))
                        .where(
                          (a) =>
                              _query.isEmpty ||
                              a.label.toLowerCase().contains(_query) ||
                              a.packageName.toLowerCase().contains(_query),
                        )
                        .toList()
                      // Selected apps first.
                      ..sort((a, b) {
                        final sa = selected.contains(a.packageName) ? 0 : 1;
                        final sb = selected.contains(b.packageName) ? 0 : 1;
                        return sa != sb ? sa - sb : a.label.toLowerCase().compareTo(b.label.toLowerCase());
                      });
                return Opacity(
                  opacity: mode == PerAppMode.off ? 0.5 : 1,
                  child: ListView.builder(
                    itemCount: apps.length,
                    itemBuilder: (context, i) {
                      final app = apps[i];
                      return CheckboxListTile(
                        secondary: app.icon == null
                            ? const Icon(Symbols.android_rounded, size: 40)
                            : Image.memory(app.icon!, width: 40, height: 40, gaplessPlayback: true),
                        title: Text(app.label),
                        subtitle: Text(app.packageName, maxLines: 1, overflow: TextOverflow.ellipsis),
                        value: selected.contains(app.packageName),
                        onChanged: mode == PerAppMode.off ? null : (v) => toggle(app.packageName, v ?? false),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
