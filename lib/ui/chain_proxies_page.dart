import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/settings.dart';
import '../services/chain_proxy.dart';
import '../services/vpn_channel.dart';
import '../state/app_state.dart';
import 'chip_menu.dart';
import 'prefs.dart';

/// Settings → Chain proxies: the saved configs a connection can exit through (picked per
/// connection type on the home page). Added from the clipboard, a QR code or a WireGuard file.
class ChainProxiesPage extends StatelessWidget {
  const ChainProxiesPage({super.key});

  /// Adds the chain proxies in [text], or says why there are none.
  static void _import(BuildContext context, String? text, {String? fileName}) {
    if (text == null || text.trim().isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final chains = parseChainProxies(text, fileName: fileName);
      AppScope.read(context).addChains(chains);
      messenger.showSnackBar(
        SnackBar(content: Text(chains.length == 1 ? 'Added ${chains.single.name}' : 'Added ${chains.length} configs')),
      );
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _add(BuildContext context) async {
    final source = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Symbols.content_paste_rounded),
              title: const Text('Import from clipboard'),
              subtitle: const Text('v2ray links or WireGuard configs'),
              onTap: () => Navigator.of(context).pop('clipboard'),
            ),
            ListTile(
              leading: const Icon(Symbols.qr_code_rounded),
              title: const Text('Scan QR code'),
              onTap: () => Navigator.of(context).pop('qr'),
            ),
            ListTile(
              leading: const Icon(Symbols.folder_rounded),
              title: const Text('Import WireGuard config file'),
              onTap: () => Navigator.of(context).pop('file'),
            ),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final String? text;
    String? fileName;
    try {
      switch (source) {
        case 'clipboard':
          text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        case 'qr':
          text = await navigator.push<String>(MaterialPageRoute(builder: (_) => const _QrScanPage()));
        default:
          final file = await VpnChannel.pickFile();
          text = file?.content;
          fileName = file?.name;
      }
    } on PlatformException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't read the file: ${e.message}")));
      return;
    }
    if (source == 'clipboard' && (text == null || text.trim().isEmpty)) {
      messenger.showSnackBar(const SnackBar(content: Text('The clipboard is empty')));
      return;
    }
    if (context.mounted) _import(context, text, fileName: fileName);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final chains = state.profile.chains;
    return Scaffold(
      appBar: AppBar(title: const Text('Chain proxies')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context),
        icon: const Icon(Symbols.add_rounded),
        label: const Text('Add config'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Text(
              'Traffic exits through the chain proxy when Chain proxy is selected as the exit node.\n'
              'WireGuard and Hysteria protocols work over WARP and MASQUE only.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          // A card per config.
          for (final c in chains)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SettingsCard(children: [_ChainTile(chain: c)]),
            ),
        ],
      ),
    );
  }
}

/// A chain proxy: its name, address and tags, and copy / QR / delete.
class _ChainTile extends StatelessWidget {
  final ChainProxy chain;
  const _ChainTile({required this.chain});

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: chain.link));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  void _showQr(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(chain.name),
      content: SizedBox(
        width: 260,
        height: 260,
        // Dark modules on white whatever the theme, so every scanner reads it.
        child: QrImageView(data: chain.link, backgroundColor: Colors.white, padding: const EdgeInsets.all(12)),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    ),
  );

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete config?'),
        content: Text('${chain.name} will be removed from the chain proxies.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true && context.mounted) AppScope.read(context).deleteChain(chain);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = ChainInfo.of(chain.link);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(chain.name, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  info?.address ?? 'Invalid link',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: info == null ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (info != null) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [for (final tag in info.tags) ChipMenu.badge(context, tag)],
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy link',
            icon: const Icon(Symbols.content_copy_rounded),
            onPressed: () => _copy(context),
          ),
          IconButton(
            tooltip: 'QR code',
            icon: const Icon(Symbols.qr_code_rounded),
            onPressed: () => _showQr(context),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Symbols.delete_rounded),
            onPressed: () => _delete(context),
          ),
        ],
      ),
    );
  }
}

/// The camera, until it sees a QR code; pops with its text.
class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan QR code')),
    body: MobileScanner(
      controller: _controller,
      onDetect: (capture) {
        final text = capture.barcodes.map((b) => b.rawValue).nonNulls.firstOrNull;
        if (_done || text == null) return;
        _done = true;
        Navigator.of(context).pop(text);
      },
    ),
  );
}
