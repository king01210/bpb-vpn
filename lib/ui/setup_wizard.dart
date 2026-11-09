import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../models/cf_account.dart';
import '../models/settings.dart';
import '../services/cloudflare_api.dart';
import '../services/net_errors.dart';
import '../services/vpn_channel.dart';
import '../state/app_state.dart';
import 'cf_accounts_page.dart';

const _signUpUrl = 'https://dash.cloudflare.com/sign-up';

/// A checked API token: the token, its user's email and the accounts it can access.
typedef CheckedToken = ({String token, String email, List<CfAccount> accounts});

/// First-run setup, like BPB-Wizard's three steps: Cloudflare account → API token →
/// install the VPN worker. Shown instead of the home page until a worker is set up, and pushed
/// by Cloudflare accounts → Add account ([addingAccount]); every run deploys a fresh worker.
class SetupWizard extends StatefulWidget {
  final bool addingAccount;
  const SetupWizard({super.key, this.addingAccount = false});

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

enum _Step { account, token, install, done }

class _SetupWizardState extends State<SetupWizard> {
  _Step _step = _Step.account;

  /// Tapped "No" on step 1: sign-up page opened, waiting for the user to come back.
  bool _signingUp = false;

  CheckedToken? _token;

  /// Installing has started: no going back to the token.
  bool _installing = false;

  /// What the install step did, for the last page.
  Map<_Item, _Row> _results = const {};

  void _go(_Step step) => setState(() => _step = step);

  void _back() => switch (_step) {
    _Step.account => setState(() => _signingUp = false),
    _Step.token => _go(_Step.account),
    _Step.install => _installing ? null : _go(_Step.token),
    _Step.done => null,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stepNumber = _step.index + 1;
    final canGoBack = _step != _Step.done && !_installing && (_step != _Step.account || _signingUp);

    return PopScope(
      // System back goes to the previous step instead of closing the app.
      canPop: !canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_step != _Step.done) ...[
                  Text('Step $stepNumber of 3', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  _StepBar(current: _step.index),
                  const SizedBox(height: 24),
                ],
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(begin: const Offset(0.05, 0), end: Offset.zero).animate(animation),
                        child: child,
                      ),
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(_step),
                      child: switch (_step) {
                        _Step.account => _AccountStep(
                          signingUp: _signingUp,
                          onNo: () async {
                            setState(() => _signingUp = true);
                            await _openUrl(context, _signUpUrl);
                          },
                          onYes: () => _go(_Step.token),
                          onBack: _back,
                        ),
                        _Step.token => _TokenStep(
                          onBack: _back,
                          onNext: (token) {
                            _token = token;
                            _go(_Step.install);
                          },
                        ),
                        _Step.install => _InstallStep(
                          token: _token!,
                          addingAccount: widget.addingAccount,
                          onBack: _back,
                          onStarted: () => setState(() => _installing = true),
                          onDone: (rows) {
                            _results = rows;
                            _go(_Step.done);
                          },
                        ),
                        _Step.done => _DoneStep(rows: _results, addingAccount: widget.addingAccount),
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Three segments; the ones up to [current] are filled.
class _StepBar extends StatelessWidget {
  final int current;
  const _StepBar({required this.current});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              height: 6,
              decoration: BoxDecoration(
                color: i <= current ? scheme.primary : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Icon, title, body, then buttons pinned to the bottom.
class _StepLayout extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;
  final List<Widget> buttons;
  const _StepLayout({required this.icon, required this.title, required this.children, required this.buttons});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 40, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                DefaultTextStyle.merge(
                  style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: buttons),
      ],
    );
  }
}

/// "1. Do this" lines.
class _Instruction extends StatelessWidget {
  final int number;
  final InlineSpan text;
  const _Instruction(this.number, this.text);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: scheme.secondaryContainer,
            child: Text(
              '$number',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.onSecondaryContainer),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text.rich(text)),
        ],
      ),
    );
  }
}

TextSpan _bold(String text) => TextSpan(
  text: text,
  style: const TextStyle(fontWeight: FontWeight.w700),
);

Future<void> _openUrl(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  if (!await VpnChannel.openUrl(url)) {
    await Clipboard.setData(ClipboardData(text: url));
    messenger.showSnackBar(const SnackBar(content: Text('Link copied. Open it in your browser.')));
  }
}

// region step 1: account

class _AccountStep extends StatelessWidget {
  final bool signingUp;
  final VoidCallback onNo;
  final VoidCallback onYes;
  final VoidCallback onBack;
  const _AccountStep({required this.signingUp, required this.onNo, required this.onYes, required this.onBack});

  @override
  Widget build(BuildContext context) {
    if (signingUp) {
      return _StepLayout(
        icon: Symbols.person_add_rounded,
        title: 'Create your Cloudflare account',
        buttons: [
          TextButton(onPressed: onBack, child: const Text('Back')),
          const SizedBox(width: 12),
          // Takes the rest of the row, so the label stays on one line (and can't overflow).
          Expanded(
            child: FilledButton(onPressed: onYes, child: const Text("I've verified it")),
          ),
        ],
        children: [
          const _Instruction(1, TextSpan(text: 'Sign up on the Cloudflare page that just opened.')),
          const _Instruction(2, TextSpan(text: 'Open the email Cloudflare sends you and verify your address.')),
          const _Instruction(3, TextSpan(text: 'Come back here and continue.')),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => _openUrl(context, _signUpUrl),
            icon: const Icon(Symbols.open_in_new_rounded, size: 18),
            label: const Text('Open sign-up page again'),
          ),
        ],
      );
    }
    return _StepLayout(
      icon: Symbols.cloud_rounded,
      title: 'Welcome to BPB',
      buttons: [
        Expanded(
          child: OutlinedButton(onPressed: onNo, child: const Text('No, sign me up')),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(onPressed: onYes, child: const Text('Yes')),
        ),
      ],
      children: const [
        Text(
          "BPB runs your own private proxy server on Cloudflare's free plan. "
          'Setting it up takes three steps and a couple of minutes.',
        ),
        SizedBox(height: 24),
        Text('Do you have a Cloudflare account with a verified email?'),
      ],
    );
  }
}

// endregion

// region step 2: token

class _TokenStep extends StatefulWidget {
  final VoidCallback onBack;
  final void Function(CheckedToken token) onNext;
  const _TokenStep({required this.onBack, required this.onNext});

  @override
  State<_TokenStep> createState() => _TokenStepState();
}

class _TokenStepState extends State<_TokenStep> {
  final _token = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isNotEmpty) setState(() => _token.text = text);
  }

  Future<void> _next() async {
    if (_token.text.trim().isEmpty) return setState(() => _error = 'Paste your API token first');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.onNext(await AppScope.read(context).checkCfToken(_token.text));
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _StepLayout(
      icon: Symbols.key_rounded,
      title: 'Create an API token',
      buttons: [
        TextButton(onPressed: _busy ? null : widget.onBack, child: const Text('Back')),
        const Spacer(),
        FilledButton(
          onPressed: _busy ? null : _next,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Next'),
        ),
      ],
      children: [
        _Instruction(
          1,
          TextSpan(
            children: [
              const TextSpan(text: 'Tap '),
              _bold('Create token'),
              const TextSpan(text: ' below. The permissions are filled in for you.'),
            ],
          ),
        ),
        _Instruction(
          2,
          TextSpan(
            children: [
              const TextSpan(text: 'Log in if asked, scroll down and tap '),
              _bold('Continue to summary'),
              const TextSpan(text: '.'),
            ],
          ),
        ),
        _Instruction(
          3,
          TextSpan(
            children: [
              const TextSpan(text: 'Tap '),
              _bold('Create Token'),
              const TextSpan(text: ', then copy the token.'),
            ],
          ),
        ),
        const _Instruction(4, TextSpan(text: 'Come back and paste it here.')),
        const SizedBox(height: 4),
        FilledButton.tonalIcon(
          onPressed: () => openTokenPage(context),
          icon: const Icon(Symbols.open_in_new_rounded, size: 18),
          label: const Text('Create token'),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _token,
          enabled: !_busy,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Cloudflare API token',
            errorText: _error,
            errorMaxLines: 4,
            helperText: 'Stored only on this device.',
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Paste',
                  onPressed: _busy ? null : _paste,
                  icon: const Icon(Symbols.content_paste_rounded),
                ),
                IconButton(
                  tooltip: _obscure ? 'Show' : 'Hide',
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(_obscure ? Symbols.visibility_rounded : Symbols.visibility_off_rounded),
                ),
              ],
            ),
          ),
          onSubmitted: (_) => _next(),
        ),
      ],
    );
  }
}

// endregion

// region step 3: install

/// What the wizard installs, one after another.
enum _Item {
  workers('Workers deployment'),
  pages('Pages deployment'),
  warp('WARP registration'),
  masque('MASQUE registration');

  final String label;
  const _Item(this.label);
}

enum _Status { waiting, running, done, failed, skipped }

class _Row {
  _Status status = _Status.waiting;
  String? message;

  /// It failed to reach the server (Tor may help), rather than being refused.
  bool network = false;
}

/// The Tor bridges the build embedded for "Retry with Tor" (assets/tor/bridges.json, written by
/// scripts/fetch_tor_bridges.sh), or null without them. Only the wizard uses them.
Future<List<String>?> _embeddedBridges() async {
  try {
    final json = jsonDecode(await rootBundle.loadString('assets/tor/bridges.json')) as Map;
    final bridges = (json['bridges'] as List).whereType<String>().toList();
    return bridges.isEmpty ? null : bridges;
  } catch (_) {
    return null;
  }
}

class _InstallStep extends StatefulWidget {
  final CheckedToken token;
  final bool addingAccount;
  final VoidCallback onBack;

  /// Called once installing starts (no going back after that).
  final VoidCallback onStarted;

  /// Called when every item is done, or the failed ones were skipped.
  final void Function(Map<_Item, _Row> rows) onDone;
  const _InstallStep({
    required this.token,
    required this.addingAccount,
    required this.onBack,
    required this.onStarted,
    required this.onDone,
  });

  @override
  State<_InstallStep> createState() => _InstallStepState();
}

class _InstallStepState extends State<_InstallStep> {
  late CfAccount _account = widget.token.accounts.first;

  /// The account's UUID, in both deployments' ENV.
  final _uuid = generateUuid();

  /// What's deployed so far: the account is saved only once it has both.
  final _deployed = <WorkerType, Deployment>{};
  bool _saved = false;

  /// Adding an account only deploys; WARP and MASQUE belong to the device.
  late final _rows = {
    for (final i in _Item.values)
      if (!widget.addingAccount || i == _Item.workers || i == _Item.pages) i: _Row(),
  };
  bool _started = false;
  bool _busy = false;
  List<String>? _bridges;

  /// Tor's bootstrap progress while "Retry with Tor" connects.
  int? _torProgress;
  String? _torError;

  @override
  void initState() {
    super.initState();
    _embeddedBridges().then((b) {
      if (mounted) setState(() => _bridges = b);
    });
  }

  Iterable<_Item> get _failed => [
    for (final e in _rows.entries)
      if (e.value.status == _Status.failed) e.key,
  ];

  Future<void> _install(_Item item, {int? proxyPort}) async {
    final row = _rows[item]!;
    final state = AppScope.read(context);
    setState(() {
      row
        ..status = _Status.running
        ..message = null
        ..network = false;
    });
    try {
      switch (item) {
        case _Item.workers || _Item.pages:
          final type = item == _Item.workers ? WorkerType.workers : WorkerType.pages;
          _deployed[type] = await state.deployFresh(
            token: widget.token.token,
            accountId: _account.id,
            type: type,
            uuid: _uuid,
            proxyPort: proxyPort,
          );
        case _Item.warp:
          await state.renewWarpAccount(proxyPort: proxyPort);
        case _Item.masque:
          await state.renewMasqueAccount(proxyPort: proxyPort);
      }
      row.status = _Status.done;
    } catch (e) {
      row
        ..status = _Status.failed
        ..network = isNetworkError(e)
        ..message = isNetworkError(e) ? "Can't reach the server" : (e is StateError ? e.message : '$e');
    }
    if (mounted) setState(() {});
  }

  /// Installs [items] side by side; when nothing failed, moves on.
  Future<void> _run(Iterable<_Item> items, {int? proxyPort}) async {
    if (!_started) {
      _started = true;
      widget.onStarted();
      // First run: keep the wizard on screen until its last page, though things now exist.
      if (!widget.addingAccount) AppScope.read(context).setSetupInProgress(true);
    }
    setState(() => _busy = true);
    await Future.wait([for (final item in items.toList()) _install(item, proxyPort: proxyPort)]);
    if (!mounted) return;
    // The account is added only with both its workers deployed.
    if (!_saved && _deployed.length == WorkerType.values.length) {
      try {
        await AppScope.read(context).addCfAccount(
          token: widget.token.token,
          email: widget.token.email,
          account: _account,
          uuid: _uuid,
          deployments: _deployed.values.toList(),
        );
        _saved = true;
      } catch (e) {
        _rows[_Item.workers]!
          ..status = _Status.failed
          ..message = '$e';
      }
      if (!mounted) return;
    }
    setState(() => _busy = false);
    if (_failed.isEmpty) widget.onDone(_rows);
  }

  /// Starts Tor with the embedded bridges, then retries the failed items through it.
  Future<void> _retryWithTor() async {
    setState(() {
      _busy = true;
      _torProgress = 0;
      _torError = null;
    });
    try {
      final port = await VpnChannel.startSetupTor(_bridges!);
      var last = -1;
      var since = DateTime.now();
      while (true) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!mounted) return;
        final status = await VpnChannel.setupTorStatus();
        if (!status.running) throw StateError(status.error ?? 'Tor stopped');
        if (status.progress != last) {
          last = status.progress;
          since = DateTime.now();
        }
        setState(() => _torProgress = status.progress);
        if (status.progress >= 100) break;
        if (DateTime.now().difference(since) > const Duration(minutes: 2)) {
          throw StateError("Tor couldn't connect with the built-in bridges");
        }
      }
      setState(() => _torProgress = null);
      await _run(_failed, proxyPort: port);
    } catch (e) {
      if (mounted) {
        setState(() {
          _torError = e is StateError ? e.message : '$e';
          _torProgress = null;
          _busy = false;
        });
      }
    } finally {
      await VpnChannel.stopSetupTor();
    }
  }

  /// Skips what failed. Half a worker deployment isn't kept: what did deploy is deleted from
  /// Cloudflare again (best effort), and the account isn't added.
  Future<void> _skip() async {
    if (!_saved && _deployed.isNotEmpty) {
      setState(() => _busy = true);
      await AppScope.read(context)
          .deleteFresh(token: widget.token.token, accountId: _account.id, deployments: _deployed.values.toList())
          .catchError((_) {});
      _deployed.clear();
      if (!mounted) return;
      for (final item in [_Item.workers, _Item.pages]) {
        if (_rows[item]?.status == _Status.done) _rows[item]!.status = _Status.skipped;
      }
    }
    for (final item in _failed.toList()) {
      _rows[item]!.status = _Status.skipped;
    }
    widget.onDone(_rows);
  }

  @override
  void dispose() {
    VpnChannel.stopSetupTor();
    super.dispose();
  }

  Widget _rowTile(BuildContext context, _Item item, _Row row) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icon = switch (row.status) {
      _Status.waiting => Icon(Symbols.radio_button_unchecked_rounded, color: scheme.outline),
      _Status.running => const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
      _Status.done => const Icon(Symbols.check_circle_rounded, color: Colors.green, fill: 1),
      _Status.failed => Icon(Symbols.cancel_rounded, color: scheme.error, fill: 1),
      _Status.skipped => Icon(Symbols.do_not_disturb_on_rounded, color: scheme.outline),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          icon,
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.label, style: theme.textTheme.bodyLarge),
                if (row.message != null)
                  Text(row.message!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accounts = widget.token.accounts;
    final failed = _failed.toList();
    final offerTor = _bridges != null && failed.any((i) => _rows[i]!.network);
    final List<Widget> buttons;
    if (!_started) {
      buttons = [
        TextButton(onPressed: widget.onBack, child: const Text('Back')),
        const Spacer(),
        FilledButton.icon(
          onPressed: () => _run(_rows.keys),
          icon: const Icon(Symbols.cloud_upload_rounded),
          label: const Text('Install'),
        ),
      ];
    } else if (!_busy && failed.isNotEmpty) {
      // One set of choices for whatever failed.
      buttons = [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: TextButton(
                  onPressed: _skip,
                  child: const Text('Skip for now'),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (offerTor) ...[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _retryWithTor,
                        child: const Text('Retry with Tor'),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ] else
                    const Spacer(),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => _run(failed),
                      child: const Text('Retry'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ];
    } else {
      buttons = const [];
    }
    return _StepLayout(
      icon: Symbols.rocket_launch_rounded,
      title: widget.addingAccount ? 'Install your VPN worker' : 'Install BPB',
      buttons: buttons,
      children: [
        Text(
          widget.addingAccount
              ? 'Your proxy will be deployed to Cloudflare as a Worker and a Pages project.'
              : 'Your proxy will be deployed to Cloudflare as a Worker and a Pages project, '
                    'then WARP and MASQUE accounts are registered.',
        ),
        const SizedBox(height: 16),
        if (accounts.length > 1 && !_started) ...[
          DropdownMenu<CfAccount>(
            initialSelection: _account,
            expandedInsets: EdgeInsets.zero,
            label: const Text('Cloudflare account'),
            dropdownMenuEntries: [for (final a in accounts) DropdownMenuEntry(value: a, label: a.name)],
            onSelected: (a) {
              if (a != null) setState(() => _account = a);
            },
          ),
          const SizedBox(height: 8),
        ],
        for (final MapEntry(key: item, value: row) in _rows.entries) _rowTile(context, item, row),
        if (_torProgress case final progress?) ...[
          const SizedBox(height: 12),
          Text('Connecting through Tor… $progress%', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress / 100),
        ],
        if (_torError != null) ...[
          const SizedBox(height: 12),
          Text(_torError!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (!_busy && failed.any((i) => _rows[i]!.network)) ...[
          const SizedBox(height: 12),
          Text(
            "Some steps couldn't reach the server. Connect through another VPN or proxy and retry"
            '${offerTor ? ', retry through Tor' : ''}, or skip them and finish later from Settings.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (!_busy && failed.any((i) => (i == _Item.workers || i == _Item.pages) && !_rows[i]!.network)) ...[
          const SizedBox(height: 12),
          Text(
            'Workers could not be deployed. Please check your Cloudflare account or use another account.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }
}

// endregion

// region done

class _DoneStep extends StatelessWidget {
  final Map<_Item, _Row> rows;
  final bool addingAccount;
  const _DoneStep({required this.rows, required this.addingAccount});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    final theme = Theme.of(context);
    final skipped = [
      for (final e in rows.entries)
        if (e.value.status == _Status.skipped) e.key,
    ];
    final deploySkipped = skipped.any((i) => i == _Item.workers || i == _Item.pages);
    final registerSkipped = skipped.any((i) => i == _Item.warp || i == _Item.masque);
    return _StepLayout(
      icon: Symbols.check_circle_rounded,
      title: skipped.isEmpty ? "You're all set" : 'Almost done',
      buttons: [
        Expanded(
          child: addingAccount
              ? FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))
              : FilledButton(onPressed: state.finishSetup, child: const Text('Start using BPB')),
        ),
      ],
      children: [
        for (final MapEntry(key: item, value: row) in rows.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                row.status == _Status.done
                    ? const Icon(Symbols.check_circle_rounded, color: Colors.green, fill: 1)
                    : Icon(Symbols.do_not_disturb_on_rounded, color: theme.colorScheme.outline),
                const SizedBox(width: 16),
                Expanded(child: Text(row.status == _Status.done ? item.label : '${item.label} (skipped)')),
              ],
            ),
          ),
        if (skipped.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text("These protocols will be available once you finish setting them up:"),
          if (deploySkipped) const Text('• Worker: add a Cloudflare account in Settings → VLESS → Cloudflare accounts.'),
          if (registerSkipped) const Text('• WARP / MASQUE: Settings → Warp or Masque → Register.'),
          if (!addingAccount) const Text('Psiphon, Tor and Serverless work without them.'),
        ],
      ],
    );
  }
}

// endregion
