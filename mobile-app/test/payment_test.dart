// Payment logic, checked against the Python engine (vectors.json) and on its own.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundlink/engine/engine.dart';

final pv = (jsonDecode(File('test/fixtures/vectors.json').readAsStringSync()) as Map<String, dynamic>)['payment']
    as Map<String, dynamic>;
final payerSeed = bytesFromHex((jsonDecode(File('test/fixtures/vectors.json').readAsStringSync()) as Map)['identity']['seed']);
const now = 1800000000;

class World {
  late Identity bank, payer, shop;
  late Wallet wallet;
  late Merchant merchant;

  static Future<World> make() async {
    final w = World();
    w.bank = await Identity.generate();
    w.payer = await Identity.generate();
    w.shop = await Identity.generate();
    w.wallet = Wallet(w.bank.publicKey);
    final cert = Cert(1, 100000, now + 86400,
        await w.bank.sign(Cert.message(w.payer.publicKey, 1, 100000, now + 86400)));
    await w.wallet.install(cert, w.payer.publicKey);
    w.merchant = Merchant(w.bank.publicKey);
    return w;
  }

  Future<(Uint8List, AcceptResult)> pay(int amount, {Wallet? using}) async {
    final req = merchant.newRequest(amount, note: 'tea', now: now);
    final reqPkt = await Packet.fromBytes(await requestPacket(req, shop));
    final raw = await (using ?? wallet).pay(reqPkt, payer, now: now);
    return (raw, await merchant.accept(await Packet.fromBytes(raw), shop, raw, now: now));
  }
}

void main() {
  group('matches Python', () {
    test('tag, certificate and receipt formats', () async {
      final payer = await Identity.fromSeed(payerSeed);
      expect(hexOf(await tagOf(payer.publicKey)), pv['tag_payer']);
      final cert = Cert.fromBytes(bytesFromHex(pv['cert']));
      expect(await cert.verify(bytesFromHex(pv['bank_pub']), payer.publicKey), isTrue);
      expect(hexOf(cert.toBytes()), pv['cert']);
    });

    test('Dart pays a Python request with the exact same bytes', () async {
      final payer = await Identity.fromSeed(payerSeed);
      final w = Wallet(bytesFromHex(pv['bank_pub']));
      await w.install(Cert.fromBytes(bytesFromHex(pv['cert'])), payer.publicKey);
      final req = await Packet.fromBytes(bytesFromHex(pv['request']));
      final raw = await w.pay(req, payer, now: pv['now']);
      // Packet header has a random id and the current time, so compare the payment itself.
      final mine = await Packet.fromBytes(raw);
      final theirs = await Packet.fromBytes(bytesFromHex(pv['payment']));
      expect(hexOf(mine.payload), hexOf(theirs.payload));
      expect(mine.signer, theirs.signer);
      // And the Python bank/merchant check accepts it:
      final p = await checkPaymentPacket(mine, bytesFromHex(pv['bank_pub']), now: pv['now']);
      expect(p.amount, 2550);
      expect(w.balance, 150000 - 2550);
      await w.acceptReceipt(await Packet.fromBytes(bytesFromHex(pv['receipt'])), payer);
      expect(w.pending, isEmpty);
    });

    test('Dart merchant accepts a Python payment and makes the same receipt', () async {
      final shop = await Identity.fromSeed(bytesFromHex(pv['shop_seed']));
      final m = Merchant(bytesFromHex(pv['bank_pub']));
      m.openRequests[pv['request_nonce']] = {'amount': 2550, 'note': '2 chai', 'time': pv['now']};
      final raw = bytesFromHex(pv['payment']);
      final r = await m.accept(await Packet.fromBytes(raw), shop, raw, now: pv['now']);
      expect(r.isNew, isTrue);
      expect(r.record.amount, 2550);
      expect(r.record.note, '2 chai');
      expect(hexOf(r.receipt.toBytes()), pv['receipt_payload']);
      final rc = await Packet.fromBytes(await m.receiptPacket(r.receipt, shop));
      expect(hexOf(rc.payload), pv['receipt_payload']);
      expect(hexOf(rc.signer!), pv['shop_pub']);
    });
  });

  group('payment rules', () {
    test('full flow, receipt, saved state', () async {
      final w = await World.make();
      final (raw, res) = await w.pay(2500);
      expect(res.isNew, isTrue);
      expect(w.wallet.balance, 97500);
      expect(raw.length, lessThan(236)); // one sound frame
      await w.wallet.acceptReceipt(await Packet.fromBytes(await w.merchant.receiptPacket(res.receipt, w.shop)), w.payer);
      expect(w.wallet.pending, isEmpty);

      final w2 = Wallet.fromJson(jsonDecode(jsonEncode(w.wallet.toJson())));
      expect(w2.balance, 97500);
      expect(w2.counter, 1);
      final m2 = Merchant.fromJson(jsonDecode(jsonEncode(w.merchant.toJson())));
      expect(m2.received.single.amount, 2500);
    });

    test('replayed payment: same receipt, no extra money', () async {
      final w = await World.make();
      final (raw, first) = await w.pay(500);
      final again = await w.merchant.accept(await Packet.fromBytes(raw), w.shop, raw, now: now);
      expect(again.isNew, isFalse);
      expect(again.receipt.toBytes(), first.receipt.toBytes());
      expect(w.merchant.received, hasLength(1));
    });

    test('copied wallet is caught by the same shop', () async {
      final w = await World.make();
      final backup = Wallet.fromJson(w.wallet.toJson());
      await w.pay(1000);
      await expectLater(w.pay(2000, using: backup), throwsA(isA<PaymentError>()));
    });

    test('not enough money, limits, empty wallet, wrong shop', () async {
      final w = await World.make();
      await w.pay(maxPayment);
      await w.pay(maxPayment);
      await expectLater(w.pay(1), throwsA(predicate((e) => e is PaymentError && e.message.contains('not enough'))));
      expect(() => w.merchant.newRequest(maxPayment + 1), throwsArgumentError);

      final empty = Wallet(w.bank.publicKey);
      final req = await Packet.fromBytes(await requestPacket(w.merchant.newRequest(100), w.shop));
      expect(() => empty.check(req), throwsA(isA<PaymentError>()));

      final w3 = await World.make();
      final r = w3.merchant.newRequest(500, now: now);
      final raw = await w3.wallet.pay(await Packet.fromBytes(await requestPacket(r, w3.shop)), w3.payer, now: now);
      await expectLater(w3.merchant.accept(await Packet.fromBytes(raw), await Identity.generate(), raw, now: now),
          throwsA(predicate((e) => e is PaymentError && e.message.contains('another merchant'))));
    });

    test('fake bank and stolen certificate are rejected', () async {
      final w = await World.make();
      final fakeBank = await Identity.generate();
      final fake = Wallet(fakeBank.publicKey);
      await fake.install(
          Cert(1, 50000, now + 100, await fakeBank.sign(Cert.message(w.payer.publicKey, 1, 50000, now + 100))),
          w.payer.publicKey);
      await expectLater(w.pay(500, using: fake), throwsA(isA<PaymentError>()));

      final r = w.merchant.newRequest(500, now: now);
      final raw = await w.wallet.pay(await Packet.fromBytes(await requestPacket(r, w.shop)), w.payer, now: now);
      final thief = await Identity.generate();
      final forged =
          await Packet(PacketType.payment, (await Packet.fromBytes(raw)).payload).toBytes(signWith: thief, compress: false);
      await expectLater(w.merchant.accept(await Packet.fromBytes(forged), w.shop, forged, now: now),
          throwsA(predicate((e) => e is PaymentError && e.message.contains('not from the bank'))));
    });

    test('payment goes through sound', () async {
      final w = await World.make();
      final req = w.merchant.newRequest(1000, note: 'chai', now: now);
      final link = SoundLink(profiles['fast']!);
      final heardReq = (await decodeAudio(link.encodeBytes(await requestPacket(req, w.shop)).map((e) => e.toDouble()).toList(),
              profiles['fast']!))
          .single;
      final raw = await w.wallet.pay(heardReq.packet!, w.payer, now: now);
      final heardPay = (await decodeAudio(link.encodeBytes(raw).map((e) => e.toDouble()).toList(), profiles['fast']!)).single;
      final res = await w.merchant.accept(heardPay.packet!, w.shop, heardPay.data, now: now);
      expect(res.record.amount, 1000);
    });
  });
}
