// Checks the Dart engine against data made by the Python engine
// (core-engine/tools/make_fixtures.py), so phone <-> laptop really works.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundlink/engine/engine.dart';

final vectors = jsonDecode(File('test/fixtures/vectors.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  test('crc16 matches', () {
    final v = vectors['crc16'];
    expect(crc16(bytesFromHex(v['data'])), v['crc']);
  });

  test('reed-solomon parity bytes match reedsolo', () {
    for (final v in vectors['reed_solomon'] as List) {
      final data = bytesFromHex(v['data']);
      final enc = rsEncode(data, v['nsym']);
      expect(hexOf(enc), v['encoded'], reason: 'nsym=${v['nsym']} len=${data.length}');
      expect(rsDecode(enc, v['nsym']).$1, data);
    }
  });

  test('PIN key matches Argon2id from libsodium', () async {
    final v = vectors['pin'];
    expect(hexOf(await keyFromPin(v['pin'])), v['key']);
  });

  test('identity from seed matches', () async {
    final v = vectors['identity'];
    final me = await Identity.fromSeed(bytesFromHex(v['seed']));
    expect(hexOf(me.publicKey), v['public_key']);
  });

  test('Python packets can be read', () async {
    final p = vectors['packets'] as Map<String, dynamic>;
    final key = bytesFromHex(vectors['pin']['key']);
    final pub = vectors['identity']['public_key'];

    final plain = await Packet.fromBytes(bytesFromHex(p['plain']));
    expect(utf8.decode(plain.payload), 'hello');
    expect(plain.msgId, 0x01020304);
    expect(plain.timestamp, 1800000000);

    expect(utf8.decode((await Packet.fromBytes(bytesFromHex(p['compressed']))).payload), 'abc' * 100);

    final signed = await Packet.fromBytes(bytesFromHex(p['signed']));
    expect(hexOf(signed.signer!), pub);
    expect(utf8.decode(signed.payload), 'pay 50');

    final sealed = await Packet.fromBytes(bytesFromHex(p['encrypted_signed']), key: key);
    expect(hexOf(sealed.signer!), pub);
    expect(Wifi.fromBytes(sealed.payload).ssid, 'Home WiFi');
    expect(() => Packet.fromBytes(bytesFromHex(p['encrypted_signed'])), throwsA(isA<PacketError>()));
  });

  test('Dart builds the same bytes as Python (deterministic packets)', () async {
    final p = vectors['packets'] as Map<String, dynamic>;
    final me = await Identity.fromSeed(bytesFromHex(vectors['identity']['seed']));
    final plain = Packet(PacketType.text, utf8.encode('hello'), msgId: 0x01020304, timestamp: 1800000000);
    expect(hexOf(await plain.toBytes()), p['plain']);
    final signed = Packet(PacketType.payment, utf8.encode('pay 50'), msgId: 0x01020304, timestamp: 1800000000);
    expect(hexOf(await signed.toBytes(signWith: me)), p['signed']);
  });

  test('module payloads match', () {
    final m = vectors['modules'] as Map<String, dynamic>;
    final c = m['contact']['value'];
    final contact = Contact(name: c['name'], phone: c['phone'], email: c['email'], org: c['org']);
    expect(hexOf(contact.toBytes()), m['contact']['hex']);
    expect(Contact.fromBytes(bytesFromHex(m['contact']['hex'])), contact);

    final w = m['wifi']['value'];
    final wifi = Wifi(w['ssid'], password: w['password'], security: WifiSecurity.values[w['security']], hidden: w['hidden']);
    expect(hexOf(wifi.toBytes()), m['wifi']['hex']);
    expect(Wifi.fromBytes(bytesFromHex(m['wifi']['hex'])), wifi);
    expect(wifi.toQrString(), m['wifi']['qr']);

    final o = m['offer']['value'];
    final offer = Offer(o['title'], shop: o['shop'], code: o['code'], expires: o['expires']);
    expect(hexOf(offer.toBytes()), m['offer']['hex']);
    expect(Offer.fromBytes(bytesFromHex(m['offer']['hex'])), offer);
  });

  group('Python WAV files decode on Dart', () {
    for (final v in vectors['wavs'] as List) {
      test(v['file'], () async {
        final (audio, rate) = decodeWav(File('test/fixtures/${v['file']}').readAsBytesSync());
        expect(rate, 48000);
        final key = v['pin'] == null ? null : await keyFromPin(v['pin']);
        final results = await decodeAudio(audio, profiles[v['profile']]!, key: key);
        expect(results, hasLength(1));
        final r = results.single;
        expect(r.error, isNull);
        expect(r.packet!.type, v['type']);
        expect(hexOf(r.packet!.payload), v['payload']);
        expect(r.packet!.signed, v['signed']);
        if (v['signed']) expect(hexOf(r.packet!.signer!), vectors['identity']['public_key']);
      });
    }
  });

  test('Dart sound -> WAV bytes -> Dart decode (what the laptop will hear)', () async {
    final me = await Identity.generate();
    final link = SoundLink(profiles['fast']!, identity: me);
    final audio = await link.encode(Packet(PacketType.contact, const Contact(name: 'Phone User').toBytes()));
    final (back, _) = decodeWav(encodeWav(audio, 48000));
    final r = (await decodeAudio(back, profiles['fast']!)).single;
    expect(Contact.fromBytes(r.packet!.payload).name, 'Phone User');
    // Save one so the Python side can check it too (see README).
    final out = Directory('build/interop')..createSync(recursive: true);
    File('${out.path}/dart_contact.wav').writeAsBytesSync(encodeWav(audio, 48000));
    File('${out.path}/dart_contact.json').writeAsStringSync(jsonEncode({'public_key': hexOf(me.publicKey)}));
    expect(Uint8List.fromList([1]).length, 1);
  });
}
