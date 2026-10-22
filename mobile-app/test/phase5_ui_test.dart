import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundlink/engine/engine.dart';
import 'package:soundlink/ui/widgets.dart';

void main() {
  testWidgets('alert, sensor and file cards', (tester) async {
    final a = Alert('Flood warning', message: 'Go to the school', severity: 2, kind: 1, area: 'Ward 12');
    final s = SensorReport('BP meter', [(5, 121), (6, 79)], seq: 3);
    final f = FileOffer(fileLink, 5000, Uint8List(32), 'notes.pdf', url: 'http://192.168.1.5:9000/f/x/notes.pdf');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          ItemCard(type: PacketType.emergency, item: a, signer: '00' * 32, time: DateTime.now(), onTrust: () {}),
          ItemCard(type: PacketType.emergency, item: a, signer: '11' * 32, time: DateTime.now(), trusted: true),
          ItemCard(type: PacketType.sensor, item: s, time: DateTime.now()),
          ItemCard(type: PacketType.fileHandshake, item: f, time: DateTime.now()),
        ]),
      ),
    ));
    expect(find.text('DANGER: Flood warning'), findsNWidgets(2));
    expect(find.textContaining('NOT VERIFIED'), findsOneWidget);
    expect(find.textContaining('✔ VERIFIED'), findsOneWidget);
    expect(find.text('Trust sender'), findsOneWidget);
    expect(find.text('BP systolic: 121 mmHg'), findsOneWidget);
    expect(find.text('notes.pdf'), findsOneWidget);
    expect(find.textContaining('192.168.1.5'), findsOneWidget);
  });
}
