import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:soundlink/engine/engine.dart';
import 'package:soundlink/services/fallback.dart';
import 'package:soundlink/ui/fallback_screens.dart';

class FakeSink implements ChunkSink {
  @override
  bool listening;
  final rx = Receiver(profiles['normal']!);
  final List<Received> got = [];
  FakeSink(this.listening);
  @override
  Future<void> injectChunk(Uint8List chunk) async => got.addAll(await rx.feedChunk(chunk));
}

void main() {
  test('hub sends QR / Bluetooth data to listening screens, else to the main one', () async {
    final me = await Identity.generate();
    final raw = await Packet(PacketType.text, 'hello by QR'.codeUnits).toBytes(signWith: me);
    final main = FakeSink(false), flow = FakeSink(true);
    final hub = FallbackHub.instance
      ..register(main)
      ..register(flow);
    for (final t in toQrTexts(raw)) {
      expect(await hub.inject(fromQrText(t)), 1);
    }
    expect(flow.got.single.packet!.signer, me.publicKey);
    expect(main.got, isEmpty);

    flow.listening = false;
    await hub.injectPacket(raw); // Bluetooth path: whole packet at once
    expect(main.got.single.ok, isTrue);
    hub
      ..unregister(main)
      ..unregister(flow);

    hub.remember(raw);
    expect(hub.lastPacket, raw);
  });

  testWidgets('QR page cycles through codes for big packets', (tester) async {
    final big = Uint8List.fromList(List.generate(1200, (i) => i % 251));
    await tester.pumpWidget(MaterialApp(home: QrShowPage(packet: big)));
    expect(find.byType(QrImageView), findsOneWidget);
    expect(toQrTexts(big).length, 3);
    expect(find.textContaining('Code 1 of 3'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 950));
    expect(find.textContaining('Code 2 of 3'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // dispose, stops the timer
  });
}
