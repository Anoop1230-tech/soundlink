import 'dart:async';

import 'package:flutter/material.dart';

import '../engine/engine.dart';
import '../services/actions.dart';
import '../services/audio.dart';
import '../services/store.dart';
import '../services/wallet_store.dart';
import 'fallback_screens.dart';

/// "12.50" -> 1250 paise. Returns null if it isn't a valid amount.
int? parseRupees(String s) {
  final m = RegExp(r'^\s*(\d{1,6})(?:\.(\d{1,2}))?\s*$').firstMatch(s);
  if (m == null) return null;
  final paise = int.parse(m[1]!) * 100 + int.parse((m[2] ?? '0').padRight(2, '0'));
  return paise > 0 ? paise : null;
}

/// Listen until a packet of one of [types] arrives, or timeout / cancel.
Future<Received?> waitForPacket(
  SoundListener l,
  Profile profile,
  Set<int> types,
  Duration timeout,
  bool Function() cancelled, {
  void Function(Received)? onOther,
}) async {
  final done = Completer<Received?>();
  final sub = l.packets.listen((r) {
    if (done.isCompleted) return;
    if (r.ok && types.contains(r.packet!.type)) {
      done.complete(r);
    } else {
      onOther?.call(r);
    }
  });
  try {
    await l.start(profile);
  } catch (e) {
    await sub.cancel();
    rethrow;
  }
  final timer = Timer(timeout, () => done.isCompleted ? null : done.complete(null));
  final poll = Timer.periodic(const Duration(milliseconds: 200), (_) {
    if (cancelled() && !done.isCompleted) done.complete(null);
  });
  final r = await done.future;
  timer.cancel();
  poll.cancel();
  await sub.cancel();
  await l.stop();
  return r;
}

class WalletScreen extends StatelessWidget {
  final AppStore store;
  final WalletStore wallet;
  final SoundPlayer player;
  final SoundListener listener;
  const WalletScreen({super.key, required this.store, required this.wallet, required this.player, required this.listener});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: wallet,
        builder: (context, _) => wallet.connected ? _main(context) : _ConnectForm(wallet: wallet),
      );

  Widget _main(BuildContext context) {
    final theme = Theme.of(context);
    final w = wallet.wallet!;
    final m = wallet.merchant!;
    final unsynced = m.unsynced;
    final cert = w.cert;
    final expired = cert != null && unixNow() > cert.validUntil;

    Future<void> guard(Future<void> Function() fn) async {
      try {
        await fn();
      } catch (e) {
        if (context.mounted) showSnack(context, e.toString());
      }
    }

    return RefreshIndicator(
      onRefresh: () => guard(wallet.refresh),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: theme.colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Offline wallet', style: theme.textTheme.titleMedium),
                Text(rupees(w.balance), style: theme.textTheme.displaySmall),
                if (expired) Text('Expired: go online and load (even Rs 0) to renew', style: TextStyle(color: theme.colorScheme.error)),
                if (cert != null && !expired)
                  Text('Valid till ${DateTime.fromMillisecondsSinceEpoch(cert.validUntil * 1000).toLocal().toString().substring(0, 10)}'
                      ' · ${w.counter} payments'),
                const SizedBox(height: 8),
                Text('Bank (online): ${rupees(wallet.online)}${wallet.frozen ? '  ·  FROZEN' : ''}'),
                if (wallet.frozen)
                  Text('This account was frozen because the same money was spent twice.',
                      style: TextStyle(color: theme.colorScheme.error)),
                const Text('Demo money only', style: TextStyle(fontStyle: FontStyle.italic)),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: w.balance == 0 || expired
                    ? null
                    : () => Navigator.push(context, MaterialPageRoute(builder: (_) => PayPage(screen: this))),
                icon: const Icon(Icons.payments),
                label: const Text('Pay'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RequestPage(screen: this))),
                icon: const Icon(Icons.storefront),
                label: const Text('Request money'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Text('Online (needs the bank)', style: theme.textTheme.titleSmall),
          Wrap(spacing: 8, children: [
            OutlinedButton.icon(
              onPressed: wallet.busy || wallet.frozen ? null : () => _askLoad(context, guard),
              icon: const Icon(Icons.add),
              label: const Text('Load'),
            ),
            OutlinedButton.icon(
              onPressed: wallet.busy || cert == null
                  ? null
                  : () => guard(() async {
                        final back = await wallet.unload();
                        if (context.mounted) showSnack(context, 'Moved ${rupees(back)} back to the bank');
                      }),
              icon: const Icon(Icons.remove),
              label: const Text('Unload'),
            ),
            OutlinedButton.icon(
              onPressed: wallet.busy
                  ? null
                  : () => guard(() async {
                        final (ok, problems) = await wallet.sync();
                        if (!context.mounted) return;
                        showSnack(context, problems.isEmpty ? 'Synced: $ok payment(s) settled' : problems.join('\n'));
                      }),
              icon: const Icon(Icons.sync),
              label: Text(unsynced.isEmpty ? 'Sync' : 'Sync (${unsynced.length})'),
            ),
          ]),
          if (wallet.busy) const LinearProgressIndicator(),
          if (unsynced.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${rupees(unsynced.fold(0, (s, p) => s + p.amount))} received offline, not in the bank yet.'),
            ),
          const Divider(height: 32),
          Text('Received payments', style: theme.textTheme.titleSmall),
          if (m.received.isEmpty) const Text('None yet'),
          for (final p in m.received.reversed.take(20))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(p.status == 'settled_fraud' || p.status == 'rejected' ? Icons.warning_amber : Icons.call_received),
              title: Text('${rupees(p.amount)}${p.note.isEmpty ? '' : ' · ${p.note}'}'),
              subtitle: Text('From ${fingerprintOf(bytesFromHex(p.wallet))} · ${p.synced ? p.status ?? 'synced' : 'waiting to sync'}'),
            ),
          if (w.pending.isNotEmpty) ...[
            const Divider(height: 32),
            Text('Paid, no receipt heard', style: theme.textTheme.titleSmall),
            for (final p in w.pending)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.hourglass_bottom),
                title: Text('${rupees(p.amount)}${p.note.isEmpty ? '' : ' · ${p.note}'}'),
                subtitle: const Text('The money has left your wallet. The shop can still claim it.'),
              ),
          ],
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.account_balance),
            title: Text(wallet.name),
            subtitle: Text(wallet.bankUrl),
            trailing: TextButton(onPressed: () => _changeBank(context), child: const Text('Change')),
          ),
        ],
      ),
    );
  }

  Future<void> _askLoad(BuildContext context, Future<void> Function(Future<void> Function()) guard) async {
    final ctrl = TextEditingController();
    final amount = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Load offline wallet'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Bank balance: ${rupees(wallet.online)}\nWallet can hold up to ${rupees(maxWallet)}.'),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount in Rs', prefixText: 'Rs '),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final v = parseRupees(ctrl.text);
              if (v != null) Navigator.pop(ctx, v);
            },
            child: const Text('Load'),
          ),
        ],
      ),
    );
    if (amount == null) return;
    await guard(() async {
      await wallet.load(amount);
      if (context.mounted) showSnack(context, 'Wallet now holds ${rupees(wallet.wallet!.balance)}');
    });
  }

  void _changeBank(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: const Text('Bank')), body: _ConnectForm(wallet: wallet))));
}

class _ConnectForm extends StatefulWidget {
  final WalletStore wallet;
  const _ConnectForm({required this.wallet});
  @override
  State<_ConnectForm> createState() => _ConnectFormState();
}

class _ConnectFormState extends State<_ConnectForm> {
  late final url = TextEditingController(text: widget.wallet.bankUrl.isEmpty ? 'http://192.168.1.10:8000' : widget.wallet.bankUrl);
  late final name = TextEditingController(text: widget.wallet.name);

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Offline payments', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'Pay and get paid by sound, without internet. You need the internet only to load money and to sync.\n\n'
            'Start the demo bank on a laptop:  python -m soundbank serve\n'
            'Then enter the laptop\'s Wi-Fi address below. This is demo money only.',
          ),
          const SizedBox(height: 16),
          TextField(controller: url, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Bank address', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Your name or shop name', border: OutlineInputBorder())),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: widget.wallet.busy
                ? null
                : () async {
                    if (name.text.trim().isEmpty) {
                      showSnack(context, 'Enter a name');
                      return;
                    }
                    try {
                      await widget.wallet.connect(url.text, name.text);
                      if (context.mounted && Navigator.canPop(context)) Navigator.pop(context);
                    } catch (e) {
                      if (context.mounted) showSnack(context, e.toString());
                    }
                  },
            child: Text(widget.wallet.busy ? 'Connecting…' : 'Connect'),
          ),
        ],
      );
}

/// Shared layout for the two sound flows.
abstract class _FlowState<T extends StatefulWidget> extends State<T> {
  String status = '';
  IconData icon = Icons.hearing;
  bool finished = false;
  bool cancelled = false;
  final listener = SoundListener();

  WalletScreen get screen;

  void set(String s, {IconData? i, bool done = false}) {
    if (!mounted) return;
    setState(() {
      status = s;
      if (i != null) icon = i;
      finished = done;
    });
  }

  @override
  void dispose() {
    cancelled = true;
    listener.dispose();
    super.dispose();
  }

  Widget flowBody(String title, List<Widget> extra) => Scaffold(
        appBar: AppBar(title: Text(title), actions: [FallbackButton(store: screen.store)]),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Icon(icon, size: 72, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(status, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 24),
            ...extra,
            if (!finished) const LinearProgressIndicator(),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: () => Navigator.pop(context), child: Text(finished ? 'Done' : 'Cancel')),
          ]),
        ),
      );
}

class PayPage extends StatefulWidget {
  final WalletScreen screen;
  const PayPage({super.key, required this.screen});
  @override
  State<PayPage> createState() => _PayPageState();
}

class _PayPageState extends _FlowState<PayPage> {
  @override
  WalletScreen get screen => widget.screen;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final ws = screen.wallet, me = screen.store.identity, profile = screen.store.profile;
    final w = ws.wallet!;
    try {
      await screen.listener.stop();
      set('Listening for the shop\'s payment request…\nHold your phone near the shop\'s phone.');
      final r = await waitForPacket(listener, profile, {PacketType.paymentRequest}, const Duration(minutes: 2), () => cancelled);
      if (r == null) return set(cancelled ? 'Cancelled' : 'No request heard', i: Icons.hearing_disabled, done: true);
      final req = w.check(r.packet!);
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text('Pay ${rupees(req.amount)}?'),
          content: Text('${req.note.isEmpty ? '' : '"${req.note}"\n'}To shop ${fingerprintOf(r.packet!.signer!)}\n'
              'Wallet after paying: ${rupees(w.balance - req.amount)}'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Pay')),
          ],
        ),
      );
      if (ok != true) return set('Not paid', i: Icons.block, done: true);

      final raw = await w.pay(r.packet!, me);
      await ws.saveWallet(); // the money is spent from here on, even if the app dies
      final link = SoundLink(profile, volume: screen.store.volume);
      for (var attempt = 1; attempt <= 3 && !cancelled; attempt++) {
        set(attempt == 1 ? 'Sending payment…' : 'No receipt yet, sending again ($attempt/3)…', i: Icons.volume_up);
        await screen.player.playPacket(link, raw);
        set('Waiting for the receipt…', i: Icons.hearing);
        final rc = await waitForPacket(listener, profile, {PacketType.paymentReceipt}, const Duration(seconds: 12), () => cancelled);
        if (rc == null) continue;
        try {
          await w.acceptReceipt(rc.packet!, me);
          await ws.saveWallet();
          return set('Paid ${rupees(req.amount)}\nReceipt received. Wallet: ${rupees(w.balance)}', i: Icons.check_circle, done: true);
        } on PaymentError {
          continue;
        }
      }
      set('Paid ${rupees(req.amount)}, but no receipt was heard.\nThe shop can still claim it; ask them to check.',
          i: Icons.info_outline, done: true);
    } catch (e) {
      set('$e', i: Icons.error_outline, done: true);
    }
  }

  @override
  Widget build(BuildContext context) => flowBody('Pay', const []);
}

class RequestPage extends StatefulWidget {
  final WalletScreen screen;
  const RequestPage({super.key, required this.screen});
  @override
  State<RequestPage> createState() => _RequestPageState();
}

class _RequestPageState extends _FlowState<RequestPage> {
  final amount = TextEditingController();
  final note = TextEditingController();
  bool started = false;

  @override
  WalletScreen get screen => widget.screen;

  Future<void> _start() async {
    final paise = parseRupees(amount.text);
    if (paise == null || paise > maxPayment) {
      showSnack(context, 'Enter an amount up to ${rupees(maxPayment)}');
      return;
    }
    setState(() => started = true);
    final ws = screen.wallet, me = screen.store.identity, profile = screen.store.profile;
    final m = ws.merchant!;
    try {
      await screen.listener.stop();
      final req = m.newRequest(paise, note: note.text);
      await ws.saveMerchant();
      final link = SoundLink(profile, volume: screen.store.volume);
      final reqRaw = await requestPacket(req, me);
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      var round = 0;
      while (!cancelled && DateTime.now().isBefore(deadline)) {
        if (round++ % 3 == 0) {
          set('Asking for ${rupees(paise)}…', i: Icons.volume_up);
          await screen.player.playPacket(link, reqRaw, repeat: 2);
        }
        set('Waiting for payment of ${rupees(paise)}…', i: Icons.hearing);
        String? problem;
        final r = await waitForPacket(listener, profile, {PacketType.payment}, const Duration(seconds: 15), () => cancelled);
        if (r == null) continue;
        AcceptResult res;
        try {
          res = await m.accept(r.packet!, me, r.data);
        } on PaymentError catch (e) {
          problem = e.message;
          set('Payment refused: $problem\nStill waiting…', i: Icons.warning_amber);
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        await ws.saveMerchant();
        set('Got ${rupees(res.record.amount)}! Sending receipt…', i: Icons.volume_up);
        await screen.player.playPacket(link, await m.receiptPacket(res.receipt, me), repeat: 2);
        return set('Received ${rupees(res.record.amount)} from ${fingerprintOf(bytesFromHex(res.record.wallet))}\n'
            'Sync when online to move it to the bank.', i: Icons.check_circle, done: true);
      }
      set(cancelled ? 'Cancelled' : 'No payment received', i: Icons.hearing_disabled, done: true);
    } catch (e) {
      set('$e', i: Icons.error_outline, done: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (started) return flowBody('Request money', const []);
    return Scaffold(
      appBar: AppBar(title: const Text('Request money'), actions: [FallbackButton(store: screen.store)]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: 'Amount (max ${rupees(maxPayment)})', prefixText: 'Rs ', border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: note,
          maxLength: noteMax,
          decoration: const InputDecoration(labelText: 'Note (e.g. 2 chai)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: _start, icon: const Icon(Icons.volume_up), label: const Text('Ask for payment')),
        const SizedBox(height: 12),
        const Text('The customer opens Wallet → Pay and holds their phone near yours. Works without internet.'),
      ]),
    );
  }
}
