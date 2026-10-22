import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundlink/engine/engine.dart';
import 'package:soundlink/engine/transport.dart' as transport;

final rng = Random(42);

Uint8List randomData(int n) => Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));

/// Simple fake room: a little echo, gain, white noise at the given SNR, random lead-in.
Float64List room(Float32List audio, {double snrDb = 15}) {
  final x = Float64List(audio.length);
  for (var i = 0; i < audio.length; i++) {
    x[i] = audio[i] + (i >= 144 ? 0.5 * audio[i - 144] : 0) + (i >= 528 ? 0.3 * audio[i - 528] : 0);
  }
  var power = 0.0;
  for (final v in x) {
    power += v * v;
  }
  power /= x.length;
  final sigma = sqrt(power / pow(10, snrDb / 10));
  double gauss() => sqrt(-2 * log(1 - rng.nextDouble())) * cos(2 * pi * rng.nextDouble());
  final lead = 2000 + rng.nextInt(8000);
  final out = Float64List(lead + x.length + 9600);
  for (var i = 0; i < out.length; i++) {
    final j = i - lead;
    out[i] = (j >= 0 && j < x.length ? 0.3 * x[j] : 0) + 0.3 * sigma * gauss();
  }
  return out;
}

void main() {
  group('reed-solomon', () {
    test('fixes nsym/2 errors', () {
      final data = randomData(100);
      final coded = rsEncode(data, 16);
      for (final i in [0, 10, 20, 30, 40, 50, 60, 70]) {
        coded[i] ^= 0x5A;
      }
      final (out, fixed) = rsDecode(coded, 16);
      expect(out, data);
      expect(fixed, 8);
    });

    test('uses confidence to fix more errors', () {
      final data = randomData(100);
      final coded = rsEncode(data, 16);
      final bad = [for (var i = 0; i < 110; i += 10) i];
      for (final i in bad) {
        coded[i] ^= 0x33;
      }
      expect(() => rsDecode(coded, 16), throwsA(isA<FecError>()));
      final conf = [for (var i = 0; i < coded.length; i++) bad.contains(i) ? 0.5 : 5.0];
      expect(rsDecode(coded, 16, conf).$1, data);
    });

    test('multi block', () {
      final data = randomData(600);
      expect(rsEncode(data, 16).length, encodedLen(600, 16));
      expect(rsDecode(rsEncode(data, 16), 16).$1, data);
    });
  });

  group('packet', () {
    test('signed + encrypted round trip, tamper detection', () async {
      final me = await Identity.generate();
      final key = randomKey();
      final p = Packet(PacketType.ticket, utf8.encode('seat 12'));
      final data = await p.toBytes(signWith: me, key: key);
      final q = await Packet.fromBytes(data, key: key);
      expect(utf8.decode(q.payload), 'seat 12');
      expect(q.signer, me.publicKey);

      final bad = Uint8List.fromList(data)..[14] ^= 1;
      final body = bad.sublist(0, bad.length - 2);
      final c = crc16(body);
      bad[bad.length - 2] = c >> 8;
      bad[bad.length - 1] = c & 0xFF;
      expect(() => Packet.fromBytes(bad, key: key), throwsA(isA<PacketError>()));
      expect(() => Packet.fromBytes(data, key: randomKey()), throwsA(isA<PacketError>()));
    });

    test('compression only when it helps, and zip bombs are refused', () async {
      final long = Packet(PacketType.text, utf8.encode('a' * 500));
      final data = await long.toBytes();
      expect(data.length, lessThan(100));
      expect((await Packet.fromBytes(data)).payload.length, 500);
      expect(() => Packet(PacketType.text, Uint8List(maxPayload + 1)).toBytes(), throwsA(isA<PacketError>()));
    });

    test('replay guard', () async {
      final guard = ReplayGuard(windowS: 60);
      final p = await Packet.fromBytes(await Packet(PacketType.doorUnlock, [1], timestamp: 1000).toBytes());
      guard.check(p, now: 1010);
      expect(() => guard.check(p, now: 1011), throwsA(isA<PacketError>()));
      final old = await Packet.fromBytes(await Packet(PacketType.doorUnlock, [1], timestamp: 900).toBytes());
      expect(() => guard.check(old, now: 1010), throwsA(isA<PacketError>()));
    });
  });

  group('modem', () {
    for (final name in profiles.keys) {
      test('$name: clean and noisy room', () {
        final data = randomData(120);
        final m = Modem(profiles[name]!);
        final audio = m.encodeFrame(data);
        expect((audio.length / 48000 - m.frameDuration(120)).abs(), lessThan(0.01));
        final d = Demodulator(profiles[name]!);
        final frames = [...d.feed(room(audio, snrDb: 8)), ...d.flush()];
        expect(frames.map((f) => f.data).toList(), [data]);
      });
    }

    test('streaming in small mic-sized chunks, two frames', () {
      final msgs = [randomData(20), randomData(80)];
      final m = Modem(profiles['fast']!);
      final a = m.encodeFrame(msgs[0]), b = m.encodeFrame(msgs[1]);
      final joined = Float32List(a.length + 5000 + b.length)
        ..setRange(0, a.length, a)
        ..setRange(a.length + 5000, a.length + 5000 + b.length, b);
      final audio = room(joined, snrDb: 15);
      final d = Demodulator(profiles['fast']!);
      final got = <Uint8List>[];
      for (var i = 0; i < audio.length; i += 1024) {
        got.addAll(d.feed(audio.sublist(i, min(i + 1024, audio.length))).map((f) => f.data));
      }
      got.addAll(d.flush().map((f) => f.data));
      expect(got, msgs);
    });

    test('silence and noise give nothing', () {
      final d = Demodulator(profiles['normal']!);
      expect(d.feed(Float64List(48000)), isEmpty);
      final noise = Float64List.fromList(List.generate(3 * 48000, (_) => (rng.nextDouble() - 0.5) * 0.2));
      expect(d.feed(noise), isEmpty);
      expect(d.flush(), isEmpty);
    });
  });

  group('transport + link', () {
    test('split / join out of order with duplicates', () {
      final data = randomData(1000);
      final chunks = transport.split(data);
      expect(chunks, hasLength(5));
      final r = transport.Reassembler();
      final results = [for (final i in [3, 0, 0, 4, 1, 2]) r.add(chunks[i])];
      expect(results.sublist(0, 5), everyElement(isNull));
      expect(results.last, data);
      expect(chunks.map(r.add), everyElement(isNull));
    });

    test('PIN-locked Wi-Fi: locked first, opens with the PIN later', () async {
      final key = await keyFromPin('2580');
      final me = await Identity.generate();
      const w = Wifi('Office', password: 'correct horse battery');
      final sound = await SoundLink(profiles['fast']!, identity: me, key: key).encode(Packet(PacketType.wifi, w.toBytes()));
      final r = (await decodeAudio(room(sound), profiles['fast']!)).single;
      expect(r.locked, isTrue);
      final opened = await Packet.fromBytes(r.data, key: key);
      expect(Wifi.fromBytes(opened.payload), w);
    });

    test('multi-chunk signed contact through a noisy room', () async {
      final me = await Identity.generate();
      final c = Contact(name: 'Big Card', note: String.fromCharCodes(List.generate(250, (i) => 65 + i % 26)), url: 'https://example.com/${'x' * 200}');
      final sound = await SoundLink(profiles['fast']!, identity: me).encode(Packet(PacketType.contact, c.toBytes()), repeat: 2);
      final res = await decodeAudio(room(sound, snrDb: 12), profiles['fast']!, trusted: {hexOf(me.publicKey)});
      expect(res, hasLength(1)); // repeat is de-duplicated
      expect(Contact.fromBytes(res.single.packet!.payload), c);
    });

    test('untrusted sender is rejected', () async {
      final sound = await SoundLink(profiles['fast']!, identity: await Identity.generate())
          .encode(Packet(PacketType.doorUnlock, [1]));
      final r = (await decodeAudio(sound, profiles['fast']!, trusted: {'00'})).single;
      expect(r.error, contains('not trusted'));
    });
  });

  group('modules', () {
    test('contact, wifi, offer round trip and validation', () {
      const c = Contact(name: 'अनूप कुमार', phone: '+91 90000 00000', note: 'नमस्ते');
      expect(Contact.fromBytes(c.toBytes()), c);
      expect(c.toVcard(), contains('FN:अनूप कुमार'));
      expect(() => const Contact(name: ' ').toBytes(), throwsArgumentError);
      expect(Contact.fromBytes([...const Contact(name: 'A').toBytes(), 99, 2, 1, 2]).name, 'A');
      expect(() => Contact.fromBytes([1, 10, 65]), throwsA(isA<PacketError>()));

      const w = Wifi('Cafe', security: WifiSecurity.open);
      expect(Wifi.fromBytes(w.toBytes()), w);
      expect(() => const Wifi('Home').toBytes(), throwsArgumentError);

      const o = Offer('Free tea', expires: 2000000000);
      expect(Offer.fromBytes(o.toBytes()), o);
      expect(o.expired(1900000000), isFalse);
      expect(o.expired(2100000000), isTrue);
      expect(parsePayload(PacketType.payment, [0]), isNull);
    });
  });
}
