import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../state/app_state.dart';

/// Shows the generated Xray config for the current connection mode.
class ConfigViewPage extends StatefulWidget {
  const ConfigViewPage({super.key});

  @override
  State<ConfigViewPage> createState() => _ConfigViewPageState();
}

class _ConfigViewPageState extends State<ConfigViewPage> {
  Future<String>? _config;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _config ??= AppScope.of(context).buildConfig().then(
      (build) => const JsonEncoder.withIndent('  ').convert(build.config),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuration'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Symbols.content_copy_rounded),
            onPressed: () async {
              final text = await _config;
              if (text == null || !context.mounted) return;
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Config copied')));
            },
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _config,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('${snapshot.error}'),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              snapshot.data!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          );
        },
      ),
    );
  }
}
