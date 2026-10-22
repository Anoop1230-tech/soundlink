import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../engine/engine.dart';
import '../services/actions.dart';
import '../services/audio.dart';
import '../services/fallback.dart';
import '../services/store.dart';

/// App-bar button that opens "Other ways to send / receive".
class FallbackButton extends StatelessWidget {
  final AppStore store;
  const FallbackButton({super.key, required this.store});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Sound not working? QR / Bluetooth',
        icon: const Icon(Icons.qr_code_2),
        onPressed: () => showFallbackSheet(context, store),
      );
}

Future<void> showFallbackSheet(BuildContext context, AppStore store) {
  final hub = FallbackHub.instance;
  final last = hub.lastPacket;
  void go(Widget w) {
    Navigator.pop(context);
    Navigator.push(context, MaterialPageRoute(builder: (_) => w));
  }

  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('Same signed data, different way. The receiver checks it exactly like sound.'),
        ),
        ListTile(
          leading: const Icon(Icons.qr_code_scanner),
          title: const Text('Scan a QR code'),
          subtitle: const Text('Receive from a phone showing SoundLink QR codes'),
          onTap: () => go(const QrScanPage()),
        ),
        ListTile(
          leading: const Icon(Icons.qr_code_2),
          enabled: last != null,
          title: const Text('Show last sent as QR'),
          subtitle: Text(last == null ? 'Send something first' : '${last.length} bytes · ${_ago(hub.lastAt!)}'),
          onTap: () => go(QrShowPage(packet: last!)),
        ),
        ListTile(
          leading: const Icon(Icons.bluetooth),
          title: const Text('Bluetooth / Wi-Fi nearby'),
          subtitle: const Text('Send the last packet, or receive one'),
          onTap: () => go(NearbyPage(store: store)),
        ),
      ]),
    ),
  );
}

String _ago(DateTime t) {
  final s = DateTime.now().difference(t).inSeconds;
  return s < 60 ? '$s s ago' : '${s ~/ 60} min ago';
}

// ---------------------------------------------------------------- QR

class QrShowPage extends StatefulWidget {
  final Uint8List packet;
  const QrShowPage({super.key, required this.packet});
  @override
  State<QrShowPage> createState() => _QrShowPageState();
}

class _QrShowPageState extends State<QrShowPage> {
  late final List<String> texts = toQrTexts(widget.packet);
  int i = 0;
  Timer? t;

  @override
  void initState() {
    super.initState();
    // Several codes: cycle through them so the scanner collects them all.
    if (texts.length > 1) t = Timer.periodic(const Duration(milliseconds: 900), (_) => setState(() => i = (i + 1) % texts.length));
  }

  @override
  void dispose() {
    t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Show as QR')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(16),
              child: Semantics(
                label: 'SoundLink QR code ${i + 1} of ${texts.length}',
                child: QrImageView(data: texts[i], size: 300, errorCorrectionLevel: QrErrorCorrectLevel.M),
              ),
            ),
            const SizedBox(height: 16),
            Text(texts.length == 1 ? 'Scan with SoundLink' : 'Code ${i + 1} of ${texts.length} (changes by itself)',
                style: Theme.of(context).textTheme.titleMedium),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('On the other phone: tap the QR button at the top → Scan a QR code. Turn screen brightness up.',
                  textAlign: TextAlign.center),
            ),
          ]),
        ),
      );
}

class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});
  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final Set<String> seen = {};
  int got = 0, total = 0;
  String status = 'Point the camera at a SoundLink QR code';

  Future<void> _detect(BarcodeCapture c) async {
    for (final b in c.barcodes) {
      final v = b.rawValue;
      if (v == null || seen.contains(v)) continue;
      seen.add(v);
      Uint8List chunk;
      try {
        chunk = fromQrText(v);
      } on FormatException {
        setState(() => status = 'That is not a SoundLink QR code');
        continue;
      }
      if (chunk.length > 4) {
        total = chunk[3];
        got++;
      }
      final n = await FallbackHub.instance.inject(chunk);
      if (!mounted) return;
      if (got >= total && total > 0) {
        showSnack(context, n == 0 ? 'Received, but no screen is listening' : 'Received by QR');
        Navigator.pop(context);
        return;
      }
      setState(() => status = 'Got $got of $total codes… keep pointing');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan QR')),
        body: Column(children: [
          Expanded(child: MobileScanner(onDetect: _detect)),
          Padding(padding: const EdgeInsets.all(16), child: Text(status, textAlign: TextAlign.center)),
        ]),
      );
}

// ---------------------------------------------------------------- Bluetooth / Nearby

class NearbyPage extends StatefulWidget {
  final AppStore store;
  const NearbyPage({super.key, required this.store});
  @override
  State<NearbyPage> createState() => _NearbyPageState();
}

class _NearbyPageState extends State<NearbyPage> {
  NearbyLink? link;
  String status = '';

  Future<void> _start(bool sending) async {
    await link?.stop();
    if (!await nearbyPermissions()) {
      setState(() => status = 'Bluetooth / nearby devices permission is needed');
      return;
    }
    final l = link = NearbyLink('SoundLink ${widget.store.identity.fingerprint.substring(0, 4)}', (s) {
      if (mounted) setState(() => status = s);
    });
    if (sending) {
      await l.send(FallbackHub.instance.lastPacket!);
    } else {
      await l.receive((raw) async {
        await FallbackHub.instance.injectPacket(raw);
        if (mounted) setState(() => status = 'Received ${raw.length} bytes. Go back to see it.');
      });
    }
  }

  @override
  void dispose() {
    link?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = FallbackHub.instance.lastPacket;
    return Scaffold(
      appBar: AppBar(title: const Text('Bluetooth / Wi-Fi nearby')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Uses Google Nearby Connections (Bluetooth + Wi-Fi, no internet). Open this page on both phones: '
            'one taps Send, the other Receive.'),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: last == null ? null : () => _start(true),
          icon: const Icon(Icons.upload),
          label: Text(last == null ? 'Send (nothing sent yet)' : 'Send last packet (${last.length} bytes)'),
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(onPressed: () => _start(false), icon: const Icon(Icons.download), label: const Text('Receive')),
        if (status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 24), child: Text(status, textAlign: TextAlign.center)),
      ]),
    );
  }
}

// ---------------------------------------------------------------- real-device sound test

class SoundTestPage extends StatefulWidget {
  final AppStore store;
  final SoundPlayer player;
  final SoundListener mainListener;
  const SoundTestPage({super.key, required this.store, required this.player, required this.mainListener});
  @override
  State<SoundTestPage> createState() => _SoundTestPageState();
}

class _SoundTestPageState extends State<SoundTestPage> {
  final listener = SoundListener();
  final distance = TextEditingController(text: '30 cm');
  final note = TextEditingController();
  String mode = 'normal';
  int count = 10, size = 64;
  bool running = false, cancelled = false;
  String status = '';
  SoundTestScore? score;
  final List<String> rows = [];
  StreamSubscription<Received>? sub;

  @override
  void dispose() {
    cancelled = true;
    sub?.cancel();
    listener.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      running = true;
      cancelled = false;
    });
    await widget.mainListener.stop();
    final link = SoundLink(profiles[mode]!, identity: widget.store.identity, volume: widget.store.volume);
    final watch = Stopwatch()..start();
    for (var i = 0; i < count && !cancelled && mounted; i++) {
      setState(() => status = 'Playing test packet ${i + 1} of $count…');
      final raw = await Packet(testType, makeTestPayload(mode, i, count, size)).toBytes(signWith: widget.store.identity);
      await widget.player.play(link.encodeBytes(raw), link.sampleRate);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    final secs = watch.elapsedMilliseconds / 1000;
    setState(() {
      running = false;
      status = 'Done: $count × $size bytes in ${secs.toStringAsFixed(1)} s. Read the result on the other phone.';
    });
  }

  Future<void> _receive() async {
    final s = score = SoundTestScore(mode);
    setState(() {
      running = true;
      cancelled = false;
      status = 'Listening (${profiles[mode]!.label})… start sending on the other phone';
    });
    await widget.mainListener.stop();
    await sub?.cancel();
    sub = listener.packets.listen((r) {
      if (r.packet?.type != testType || r.frames.isEmpty) return;
      final f = r.frames.first;
      if (s.add(r.packet!.payload, f.quality, f.corrected)) setState(() {});
    });
    try {
      await listener.start(profiles[mode]!);
    } catch (e) {
      setState(() {
        running = false;
        status = '$e';
      });
      return;
    }
    final end = DateTime.now().add(const Duration(minutes: 5));
    while (!cancelled && mounted && DateTime.now().isBefore(end) && !(s.total > 0 && s.good.length + s.bad >= s.total)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    await listener.stop();
    await sub?.cancel();
    if (!mounted) return;
    rows.add(s.csvRow(distance.text.replaceAll(',', ' '), note.text.replaceAll('"', "'")));
    setState(() {
      running = false;
      status = 'Result saved below';
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = score;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sound test')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Measure how well sound works between two real phones. Both pick the same mode; one sends, one receives. '
            'Try different distances and rooms, then copy the table for your report.'),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: mode,
          decoration: const InputDecoration(labelText: 'Mode', border: OutlineInputBorder()),
          items: [for (final p in profiles.values) DropdownMenuItem(value: p.name, child: Text(p.label))],
          onChanged: running ? null : (v) => setState(() => mode = v ?? 'normal'),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: count,
              decoration: const InputDecoration(labelText: 'Packets', border: OutlineInputBorder()),
              items: const [5, 10, 20].map((v) => DropdownMenuItem(value: v, child: Text('$v'))).toList(),
              onChanged: running ? null : (v) => count = v ?? 10,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: size,
              decoration: const InputDecoration(labelText: 'Bytes each', border: OutlineInputBorder()),
              items: const [16, 64, 120].map((v) => DropdownMenuItem(value: v, child: Text('$v'))).toList(),
              onChanged: running ? null : (v) => size = v ?? 64,
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: distance, decoration: const InputDecoration(labelText: 'Distance', border: OutlineInputBorder()))),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (room, noise)', border: OutlineInputBorder()))),
        ]),
        const SizedBox(height: 16),
        if (running)
          OutlinedButton.icon(onPressed: () => setState(() => cancelled = true), icon: const Icon(Icons.stop), label: const Text('Stop'))
        else
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: _send, icon: const Icon(Icons.volume_up), label: const Text('Send test'))),
            const SizedBox(width: 12),
            Expanded(child: FilledButton.tonalIcon(onPressed: _receive, icon: const Icon(Icons.hearing), label: const Text('Receive test'))),
          ]),
        if (status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(status, textAlign: TextAlign.center)),
        if (s != null && s.total > 0)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${s.successPct}% received', style: theme.textTheme.headlineSmall),
                Text('${s.good.length} of ${s.total} packets · ${s.size} bytes each'),
                Text('Signal quality (median): ${s.medianQuality.toStringAsFixed(1)} · bytes fixed by error correction: ${s.corrected}'),
                if (s.bad > 0) Text('${s.bad} damaged packets got through (should be 0)', style: TextStyle(color: theme.colorScheme.error)),
              ]),
            ),
          ),
        if (rows.isNotEmpty) ...[
          const Divider(height: 32),
          Row(children: [
            Expanded(child: Text('Results (${rows.length})', style: theme.textTheme.titleSmall)),
            TextButton.icon(
              onPressed: () => copyText(context, [testCsvHeader, ...rows].join('\n'), 'Results table (CSV)'),
              icon: const Icon(Icons.copy),
              label: const Text('Copy CSV'),
            ),
          ]),
          for (final r in rows.reversed) Text(r, style: theme.textTheme.bodySmall),
        ],
      ]),
    );
  }
}
