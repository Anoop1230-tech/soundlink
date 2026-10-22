import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../services/store.dart';
import 'widgets.dart';

class HistoryScreen extends StatelessWidget {
  final AppStore store;
  const HistoryScreen({super.key, required this.store});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          if (store.history.isEmpty) {
            return const Center(child: Text('Nothing sent or received yet'));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final h in store.history)
                ItemCard(
                  type: h.type,
                  item: h.item,
                  signer: h.signer,
                  time: h.time,
                  sent: h.sent,
                  trusted: store.isTrusted(h.signer),
                  onTrust: h.signer == null ? null : () => trustSender(context, store, h.signer!),
                ),
            ],
          );
        },
      );
}

class SettingsScreen extends StatelessWidget {
  final AppStore store;
  const SettingsScreen({super.key, required this.store});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListenableBuilder(
          listenable: store,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Sound mode', style: Theme.of(context).textTheme.titleMedium),
              const Text('Both phones must use the same mode.'),
              RadioGroup<String>(
                groupValue: store.profileName,
                onChanged: (v) => store.profileName = v ?? 'normal',
                child: Column(children: [
                  for (final p in profiles.values)
                    RadioListTile<String>(
                      value: p.name,
                      title: Text(p.label),
                      subtitle: Text('${(p.lowFreq / 1000).toStringAsFixed(1)}-${(p.highFreq / 1000).toStringAsFixed(1)} kHz'),
                    ),
                ]),
              ),
              const Divider(),
              Text('Volume: ${(store.volume * 100).round()}%', style: Theme.of(context).textTheme.titleMedium),
              Slider(
                value: store.volume,
                min: 0.1,
                max: 1.0,
                divisions: 9,
                label: '${(store.volume * 100).round()}%',
                onChanged: (v) => store.volume = v,
              ),
              Text('Play each message ${store.repeat}x', style: Theme.of(context).textTheme.titleMedium),
              const Text('Repeating helps in noisy places. The receiver ignores copies.'),
              Slider(
                value: store.repeat.toDouble(),
                min: 1,
                max: 4,
                divisions: 3,
                label: '${store.repeat}x',
                onChanged: (v) => store.repeat = v.round(),
              ),
              const Divider(),
              Text('Trusted alert senders', style: Theme.of(context).textTheme.titleMedium),
              const Text('Emergency alerts from these devices are shown as VERIFIED.'),
              if (store.trusted.isEmpty) const Text('None yet. Tap "Trust sender" on an alert from an official source.'),
              for (final e in store.trusted.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.verified_user),
                  title: Text(e.value),
                  subtitle: Text(fingerprintOf(bytesFromHex(e.key))),
                  trailing: IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: () => store.untrust(e.key)),
                ),
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.fingerprint),
                title: const Text('My device ID'),
                subtitle: Text(store.identity.fingerprint),
              ),
              const Text(
                'Everything you send is signed with this device\'s key, which never leaves the phone. '
                'Receivers see this ID so they know who sent it.',
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: store.history.isEmpty
                    ? null
                    : () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Clear history?'),
                            content: const Text('This removes everything you sent and received from this phone.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
                            ],
                          ),
                        );
                        if (ok == true) await store.clearHistory();
                      },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Clear history'),
              ),
            ],
          ),
        ),
      );
}
