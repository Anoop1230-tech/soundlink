// End to end against a real SoundBank server. Skipped unless SOUNDBANK_URL is set:
//   python -m soundbank serve --port 8765        (in backend/)
//   SOUNDBANK_URL=http://127.0.0.1:8765 flutter test test/bank_e2e_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:soundlink/engine/engine.dart';
import 'package:soundlink/services/bank.dart';

final url = Platform.environment['SOUNDBANK_URL'];

class Person {
  final Identity id;
  final BankClient bank;
  late Wallet wallet;
  late Merchant shop;
  Person._(this.id, this.bank);

  static Future<Person> make(String name) async {
    final id = await Identity.generate();
    final p = Person._(id, BankClient(url!, id));
    await p.bank.register(name);
    final pub = bytesFromHex((await p.bank.info())['public_key']);
    p.wallet = Wallet(pub);
    p.shop = Merchant(pub);
    return p;
  }

  Future<void> load(int paise) async {
    final r = await bank.load(paise, wallet.state());
    await wallet.install(Cert.fromBytes(bytesFromHex(r['cert_hex'])), id.publicKey);
  }

  /// Plays the request and payment through sound (no noise) like the app does.
  Future<void> pay(Person merchant, int paise, {Wallet? using}) async {
    final link = SoundLink(profiles['fast']!);
    final req = merchant.shop.newRequest(paise, note: 'e2e');
    final heardReq = (await decodeAudio(link.encodeBytes(await requestPacket(req, merchant.id)), profiles['fast']!)).single;
    final raw = await (using ?? wallet).pay(heardReq.packet!, id);
    final heard = (await decodeAudio(link.encodeBytes(raw), profiles['fast']!)).single;
    await merchant.shop.accept(heard.packet!, merchant.id, heard.data);
  }

  Future<List<SyncResult>> sync() async {
    final todo = shop.unsynced;
    final (res, _) = await bank.sync([for (final p in todo) p.raw]);
    for (final p in todo) {
      p.synced = true;
    }
    return res;
  }
}

void main() {
  test('website login by sound against the real server', () async {
    final phone = await Identity.generate();
    final base = Uri.parse(url!);
    Future<(int, Map<String, dynamic>)> postJson(Uri u, Map<String, dynamic> body) async {
      final r = await http.post(u, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
      return (r.statusCode, jsonDecode(r.body) as Map<String, dynamic>);
    }

    final (_, start) = await postJson(base.resolve('/site/start'), {'user': 'dart${unixNow()}', 'profile': 'fast'});
    final wav = await http.get(base.resolve(start['sound'] as String));
    final (audio, _) = decodeWav(Uint8List.fromList(wav.bodyBytes));
    final heard = (await decodeAudio(audio, profiles['fast']!)).first;
    final ch = readAuthChallenge(heard.packet!);
    final resp = await authResponsePacket(ch, true, phone);
    final (code, _) = await postJson(Uri.parse(ch.url), {'response': hexOf(resp)});
    expect(code, 200);
    final st = await http.get(base.resolve('/site/status/${start['session']}'));
    expect(jsonDecode(st.body)['status'], 'approved');
  }, skip: url == null ? 'set SOUNDBANK_URL to run' : false, timeout: const Timeout(Duration(minutes: 2)));

  test('phone wallet against the real bank', () async {
    final asha = await Person.make('Asha (dart)');
    final chai = await Person.make('Chai (dart)');
    final books = await Person.make('Books (dart)');

    await asha.load(30000);
    expect(asha.wallet.balance, 30000);
    expect((await asha.bank.account())['online'], 70000);

    await asha.pay(chai, 2000);
    final r1 = await chai.sync();
    expect(r1.single.status, 'settled');
    expect((await chai.bank.account())['online'], 102000);

    // Cheat: copy the wallet before a payment and spend the same money again elsewhere.
    final copy = Wallet.fromJson(asha.wallet.toJson());
    await asha.pay(chai, 28000);
    await asha.pay(books, 28000, using: copy);
    expect((await chai.sync()).single.status, 'settled');
    final r2 = await books.sync();
    expect(r2.single.status, 'settled_fraud');
    expect((await books.bank.account())['online'], 128000); // shop still gets paid

    final a = await asha.bank.account();
    expect(a['frozen'], isTrue);
    expect(a['online'], 70000 - 28000);
    await expectLater(asha.bank.load(100, asha.wallet.state()), throwsA(isA<BankException>()));
  }, skip: url == null ? 'set SOUNDBANK_URL to run' : false, timeout: const Timeout(Duration(minutes: 2)));
}
