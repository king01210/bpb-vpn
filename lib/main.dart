import 'package:flutter/material.dart';

import 'state/app_state.dart';
import 'ui/home_page.dart';
import 'ui/setup_wizard.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.init();
  runApp(BpbApp(state: state));
}

class BpbApp extends StatelessWidget {
  final AppState state;
  const BpbApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      // Rebuilds only when the theme colour or mode changes (picked in Settings).
      child: ListenableBuilder(
        listenable: Listenable.merge([state.themeColor, state.themeMode]),
        builder: (context, _) => MaterialApp(
          title: 'BPB',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light, state.themeColor.value),
          darkTheme: buildTheme(Brightness.dark, state.themeColor.value),
          themeMode: state.themeMode.value,
          home: const _Root(),
        ),
      ),
    );
  }
}

/// The setup wizard until a VPN worker is set up, then the home page.
class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final needsSetup = AppScope.of(context).needsSetup;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: needsSetup ? const SetupWizard(key: ValueKey('setup')) : const HomePage(key: ValueKey('home')),
    );
  }
}
