import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/cf_account.dart';
import '../services/cloudflare_api.dart';
import '../services/net_errors.dart';
import '../services/vpn_channel.dart';
import '../state/app_state.dart';
import 'prefs.dart';
import 'setup_wizard.dart';

/// The Cloudflare accounts on this device; tap one to use it. Adding one runs the setup wizard,
/// which deploys a fresh worker; Workers or Pages is picked in Settings → VLESS → Type.
class CfAccountsPage extends StatelessWidget {
  const CfAccountsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Cloudflare accounts')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const SetupWizard(addingAccount: true),
          ),
        ),
        icon: const Icon(Symbols.add_rounded),
        label: const Text('Add account'),
      ),
      // One settings card of accounts, like the Settings page.
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 96),
        children: [
          if (state.cfAccounts.isNotEmpty)
            SettingsCard(
              children: [
                for (final a in state.cfAccounts) _AccountTile(account: a),
              ],
            ),
        ],
      ),
    );
  }
}

class _AccountTile extends StatefulWidget {
  final SavedCfAccount account;
  const _AccountTile({required this.account});

  @override
  State<_AccountTile> createState() => _AccountTileState();
}

class _AccountTileState extends State<_AccountTile> {
  SavedCfAccount get account => widget.account;

  /// Cleaning up Cloudflare and removing the account.
  bool _removing = false;

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  /// Deletes the account's custom domains and workers from Cloudflare, then the account from
  /// the app. If Cloudflare can't be cleaned up, offers to remove it from the app anyway.
  Future<void> _remove() async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    if (!await _confirm(
      'Remove account?',
      'Custom domains and workers will be removed from the Cloudflare account ${account.label}, '
          'and then the account itself will be removed from the app.',
      'Remove',
    )) {
      return;
    }
    setState(() => _removing = true);
    try {
      await state.removeCfAccount(account);
      messenger.showSnackBar(const SnackBar(content: Text('Account removed')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _removing = false);
      final why = isNetworkError(e) ? "Can't reach Cloudflare." : (e is StateError ? e.message : '$e');
      if (await _confirm(
        "Couldn't clean up Cloudflare",
        '$why\n\nRemove the account from the app anyway? Its workers and custom domains stay in '
            'the Cloudflare account; delete them in the Cloudflare dashboard.',
        'Remove anyway',
      )) {
        await state.removeCfAccount(account, cleanUp: false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final outdated = account.deployments
        .where(AppState.updateAvailable)
        .toList();
    final busy = _removing || account.deployments.any((d) => state.isDeploying(account, d));
    final scheme = theme.colorScheme;
    final inUse = state.selected?.account.id == account.id;
    // The account in use has the checked radio.
    return ListTile(
      onTap: inUse || busy ? null : () => state.selectAccount(account),
      leading: Icon(
        inUse
            ? Symbols.radio_button_checked_rounded
            : Symbols.radio_button_unchecked_rounded,
        color: inUse ? scheme.primary : scheme.outline,
      ),
      title: Text(account.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: outdated.isEmpty
          ? null
          : Text(
              'Worker update available',
              style: TextStyle(color: scheme.primary),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (outdated.isNotEmpty)
            TextButton(
              onPressed: () {
                for (final d in outdated) {
                  state.redeploy(account, d.type);
                }
              },
              child: const Text('Update'),
            ),
          IconButton(
            tooltip: 'Remove account',
            icon: Icon(Symbols.delete_outline_rounded, color: scheme.error),
            onPressed: busy ? null : _remove,
          ),
        ],
      ),
    );
  }
}

/// Opens Cloudflare's token page with the needed permissions pre-filled.
Future<void> openTokenPage(BuildContext context) async {
  final url = CloudflareApi.tokenCreationUrl();
  final messenger = ScaffoldMessenger.of(context);
  if (!await VpnChannel.openUrl(url)) {
    await Clipboard.setData(ClipboardData(text: url));
    messenger.showSnackBar(
      const SnackBar(content: Text('Link copied. Open it in your browser.')),
    );
  }
}
