// Smoke test: the main screens build and switch without crashing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundlink/engine/engine.dart';
import 'package:soundlink/ui/wallet_screen.dart' show parseRupees;
import 'package:soundlink/ui/widgets.dart';

void main() {
  testWidgets('item cards show the right actions', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          ItemCard(type: PacketType.contact, item: const Contact(name: 'Asha', phone: '123'), time: DateTime.now()),
          ItemCard(type: PacketType.wifi, item: const Wifi('Home', password: 'secret12'), time: DateTime.now()),
          ItemCard(type: PacketType.offer, item: const Offer('10% off', code: 'TEN'), time: DateTime.now()),
          ItemCard(type: PacketType.payment, item: null, time: DateTime.now()),
        ]),
      ),
    ));
    expect(find.text('Asha'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Code: TEN'), findsOneWidget);
    expect(find.text('PAYMENT'), findsOneWidget);
    expect(find.textContaining('secret12'), findsNothing); // password is not shown on screen
  });

  test('rupee amounts are parsed into paise', () {
    expect(parseRupees('25'), 2500);
    expect(parseRupees('12.5'), 1250);
    expect(parseRupees(' 0.05 '), 5);
    expect(parseRupees('0'), isNull);
    expect(parseRupees('-3'), isNull);
    expect(parseRupees('1.234'), isNull);
    expect(parseRupees('abc'), isNull);
  });
}
