import 'package:flutter/material.dart';

import 'services/audio.dart';
import 'services/store.dart';
import 'ui/history_screen.dart';
import 'ui/receive_screen.dart';
import 'ui/send_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await AppStore.open();
  runApp(SoundLinkApp(store: store));
}

class SoundLinkApp extends StatelessWidget {
  final AppStore store;
  const SoundLinkApp({super.key, required this.store});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SoundLink',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
        home: HomeScreen(store: store),
      );
}

class HomeScreen extends StatefulWidget {
  final AppStore store;
  const HomeScreen({super.key, required this.store});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final player = SoundPlayer();
  final listener = SoundListener();
  late final sender = Sender(widget.store, player, listener);
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
      HistoryScreen(store: widget.store),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('SoundLink'),
        actions: [
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
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        ],
      ),
    );
  }
}
