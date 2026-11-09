import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// The app's GPL-3.0 license, plus the third-party licenses of bundled packages.
class LicensePageView extends StatelessWidget {
  const LicensePageView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('License'),
        actions: [
          TextButton(
            onPressed: () => showLicensePage(context: context, applicationName: 'BPB'),
            child: const Text('Third-party'),
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: rootBundle.loadString('LICENSE'),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'BPB is free software: you can redistribute it and/or modify it under the terms of the '
                  'GNU General Public License as published by the Free Software Foundation, version 3. '
                  'It includes code adapted from BPB-Worker-Panel (GPL-3.0) and uses Xray-core.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const Divider(height: 32),
                SelectableText(snapshot.data!, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
              ],
            ),
          );
        },
      ),
    );
  }
}
