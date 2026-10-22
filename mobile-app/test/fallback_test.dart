import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundlink/engine/engine.dart';

final fb = (jsonDecode(File('test/fixtures/vectors.json').readAsStringSync()) as Map)['fallback'] as Map<String, dynamic>;

void main() {
  test('QR texts are the same as Python and decode to the packet', () async {
    final pkt = bytesFromHex(fb['qr_packet']);
    // transfer id is random, so compare after the 2-byte id
    final mine = toQrTexts(pkt).map((t) => fromQrText(t).sublist(2)).toList();
    final theirs = (fb['qr_texts'] as List).map((t) => fromQrText(t as String).sublist(2)).toList();
    expect(mine, theirs);

    final rx = Receiver(profiles['normal']!);
    final r = await rx.feedChunk(fromQrText(fb['qr_texts'][0]));
    expect(utf8.decode(r.single.packet!.payload), 'pay 50');
  });

  test('multi-QR in any order with repeats', () async {
    final texts = (fb['qr_big_texts'] as List).cast<String>();
    expect(texts.length, greaterThan(2));
    final rx = Receiver(profiles['normal']!);
    final out = <Received>[];
    for (final t in [...texts.reversed, texts.first]) {
      out.addAll(await rx.feedChunk(fromQrText(t)));
    }
    expect(out.single.packet!.payload.length, 1024);
    expect(() => fromQrText('https://example.com'), throwsFormatException);
  });

  test('test payload and score match Python', () async {
    expect(hexOf(makeTestPayload('turbo', 5, 10, 32)), fb['test_payload']);
    final s = SoundTestScore('turbo');
    expect(s.add(makeTestPayload('turbo', 5, 10, 32), 1.5, 2), isTrue);
    expect(s.add(makeTestPayload('fast', 1, 10, 32), 1.5, 0), isFalse);
    final broken = makeTestPayload('turbo', 6, 10, 32)..[20] ^= 1;
    expect(s.add(broken, 1, 0), isTrue);
    expect((s.good.length, s.total, s.bad, s.successPct), (1, 10, 1, 10));
    expect(s.csvRow('1 m', 'desk').split(',').first, 'turbo');
  });
}
