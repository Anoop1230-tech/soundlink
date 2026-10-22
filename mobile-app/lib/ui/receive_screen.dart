import 'dart:async';

import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../services/actions.dart';
import '../services/audio.dart';
import '../services/store.dart';
import 'widgets.dart';

class ReceiveScreen extends StatefulWidget {
  final AppStore store;
  final SoundListener listener;
  const ReceiveScreen({super.key, required this.store, required this.listener});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final List<_Result> _results = [];
  StreamSubscription<Received>? _sub;
  StreamSubscription<double>? _levelSub;
  double _level = 0;
  String? _error;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.listener.packets.listen(_onPacket);
    _levelSub = widget.listener.level.listen((v) => setState(() => _level = v));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _levelSub?.cancel();
    super.dispose();
  }

  Future<void> _onPacket(Received r) async {
    // Payments are handled on the Wallet tab.
    final t = r.packet?.type ?? (r.data.length > 1 ? r.data[1] : -1);
    if (t == PacketType.paymentRequest || t == PacketType.payment || t == PacketType.paymentReceipt) return;
    if (r.ok) {
      await _accept(r.packet!, r.profile);
    } else if (r.locked) {
      setState(() => _results.insert(0, _Result.locked(r)));
    } else {
      setState(() => _results.insert(0, _Result.error(r.error ?? 'could not read packet')));
    }
  }

  Future<void> _accept(Packet p, String profile) async {
    Object? item;
    String? error;
    try {
      item = parsePayload(p.type, p.payload);
    } on PacketError catch (e) {
      error = 'Damaged ${PacketType.name(p.type)}: ${e.message}';
    }
    if (error != null) {
      setState(() => _results.insert(0, _Result.error(error!)));
      return;
    }
    final h = HistoryItem(
      sent: false,
      type: p.type,
      payload: p.payload,
      signer: p.signer == null ? null : hexOf(p.signer!),
      time: DateTime.now(),
      profile: profile,
    );
    await widget.store.addHistory(h);
    if (mounted) setState(() => _results.insert(0, _Result.ok(h, item)));
  }

  Future<void> _unlock(_Result r) async {
    final pin = await askPin(context, title: 'This item is locked');
    if (pin == null || pin.isEmpty) return;
    try {
      final p = await Packet.fromBytes(r.received!.data, key: await keyFromPin(pin));
      setState(() => _results.remove(r));
      await _accept(p, r.received!.profile);
    } on PacketError {
      if (mounted) showSnack(context, 'Wrong PIN');
    }
  }

  Future<void> _toggle() async {
    final l = widget.listener;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      if (l.listening) {
        await l.stop();
      } else {
        await l.start(widget.store.profile);
      }
    } catch (e) {
      _error = e.toString().replaceFirst('Bad state: ', '');
    }
    if (mounted) {
      setState(() {
        _starting = false;
        _level = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = widget.listener.listening;
    final progress = widget.listener.progress;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: Column(children: [
            const SizedBox(height: 16),
            SizedBox(
              width: 140,
              height: 140,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  backgroundColor: on ? theme.colorScheme.error : theme.colorScheme.primary,
                ),
                onPressed: _starting ? null : _toggle,
                child: Icon(on ? Icons.stop : Icons.hearing, size: 56, semanticLabel: on ? 'Stop listening' : 'Start listening'),
              ),
            ),
            const SizedBox(height: 16),
            Text(on ? 'Listening… hold the phones close' : 'Tap to listen', style: theme.textTheme.titleMedium),
            Text('Mode: ${widget.store.profile.label}', style: theme.textTheme.bodySmall),
            if (on) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: 220,
                child: Semantics(
                  label: 'Microphone level',
                  child: LinearProgressIndicator(value: _level.clamp(0, 1), minHeight: 6),
                ),
              ),
              if (_level < 0.002) Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Mic is very quiet', style: theme.textTheme.bodySmall),
              ),
            ],
            if (progress != null) ...[
              const SizedBox(height: 8),
              Text('Receiving part ${progress.$1} of ${progress.$2}…'),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
          ]),
        ),
        const SizedBox(height: 24),
        for (final r in _results) _resultCard(r),
      ],
    );
  }

  Widget _resultCard(_Result r) {
    if (r.history != null) {
      final h = r.history!;
      return ItemCard(type: h.type, item: r.item, signer: h.signer, time: h.time);
    }
    if (r.received != null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.lock),
          title: Text('Locked ${PacketType.name(r.received!.data[1]).toLowerCase()}'),
          subtitle: const Text('Ask the sender for the PIN'),
          trailing: FilledButton(onPressed: () => _unlock(r), child: const Text('Unlock')),
        ),
      );
    }
    return Card(
      child: ListTile(leading: const Icon(Icons.error_outline), title: const Text('Rejected'), subtitle: Text(r.error!)),
    );
  }
}

class _Result {
  final HistoryItem? history;
  final Object? item;
  final Received? received;
  final String? error;
  _Result.ok(this.history, this.item)
      : received = null,
        error = null;
  _Result.locked(this.received)
      : history = null,
        item = null,
        error = null;
  _Result.error(this.error)
      : history = null,
        item = null,
        received = null;
}
