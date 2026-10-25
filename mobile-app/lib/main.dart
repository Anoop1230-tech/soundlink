import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/access_store.dart';
import 'services/audio.dart';
import 'services/store.dart';
import 'services/wallet_store.dart';
import 'ui/access_screen.dart';
import 'ui/fallback_screens.dart';
import 'ui/history_screen.dart';
import 'ui/receive_screen.dart';
import 'ui/send_screen.dart';
import 'ui/wallet_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var step = 'start';
  // Each step has a time limit so a step that never finishes shows up as an error
  // instead of leaving the phone on the splash screen.
  Future<T> run<T>(String name, Future<T> Function() f) {
    step = name;
    return f().timeout(const Duration(seconds: 20));
  }

  try {
    final store = await run('open app storage (AppStore)', AppStore.open);
    final wallet = await run('open wallet (WalletStore)', () => WalletStore.open(store.identity));
    final access = await run('open access storage (AccessStore)', AccessStore.open);
    runApp(SoundLinkApp(store: store, wallet: wallet, access: access));
  } catch (e, st) {
    runApp(StartupErrorApp(step: step, error: e, stack: st));
  }
}

/// Shown instead of the app when startup fails, so the error can be read on the phone.
class StartupErrorApp extends StatelessWidget {
  final String step;
  final Object error;
  final StackTrace stack;
  const StartupErrorApp({super.key, required this.step, required this.error, required this.stack});

  @override
  Widget build(BuildContext context) {
    final text = 'SoundLink could not start.\n\nStep: $step\n\nError: $error\n\n$stack';
    return MaterialApp(
      title: 'SoundLink',
      home: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('SoundLink: startup error')),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
          ),
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.copy),
            label: const Text('Copy error'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
              }
            },
          ),
        ),
      ),
    );
  }
}

class SoundLinkApp extends StatelessWidget {
  final AppStore store;
  final WalletStore wallet;
  final AccessStore access;
  const SoundLinkApp({super.key, required this.store, required this.wallet, required this.access});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SoundLink',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
        home: HomeScreen(store: store, wallet: wallet, access: access),
      );
}

class HomeScreen extends StatefulWidget {
  final AppStore store;
  final WalletStore wallet;
  final AccessStore access;
  const HomeScreen({super.key, required this.store, required this.wallet, required this.access});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final player = SoundPlayer();
  final listener = SoundListener();
  late final sender = Sender(widget.store, player, listener);
  late final accessDeps = AccessDeps(widget.store, widget.access, player, listener);
  int tab = 0;

  @override
  void dispose() {
    listener.dispose();
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      ReceiveScreen(store: widget.store, listener: listener),
      SendScreen(sender: sender),
      WalletScreen(store: widget.store, wallet: widget.wallet, player: player, listener: listener),
      AccessScreen(deps: accessDeps),
      HistoryScreen(store: widget.store),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('SoundLink'),
        actions: [
          FallbackButton(store: widget.store),
          IconButton(
            tooltip: 'Sound test (real phones)',
            icon: const Icon(Icons.speed),
            onPressed: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => SoundTestPage(store: widget.store, player: player, mainListener: listener))),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(store: widget.store)));
              if (listener.listening) {
                // Mode may have changed; restart with the new one.
                await listener.start(widget.store.profile);
              }
              setState(() {});
            },
          ),
        ],
      ),
      body: IndexedStack(index: tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.hearing), label: 'Receive'),
          NavigationDestination(icon: Icon(Icons.volume_up), label: 'Send'),
          NavigationDestination(icon: Icon(Icons.account_balance_wallet), label: 'Wallet'),
          NavigationDestination(icon: Icon(Icons.key), label: 'Access'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        ],
      ),
    );
  }
}
