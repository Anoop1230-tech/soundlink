// Turbo (OFDM) modem, alerts, sensors and file offers vs the Python engine.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundlink/engine/engine.dart';

final v = jsonDecode(File('test/fixtures/vectors.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  final turbo = profiles['turbo']!;

  test('pn sequence and first OFDM samples match Python', () {
    expect(hexOf(pnBytes(refSeed, 16)), v['ofdm']['pn_ref']);
    expect(hexOf(pnBytes(whitenSeed, 16)), v['ofdm']['pn_white']);
    final mine = Modem(turbo, volume: 0.5).encodeFrame(utf8.encode('hi'));
    final theirs = (v['ofdm']['frame_head'] as List).cast<num>();
    for (var i = 0; i < theirs.length; i++) {
      expect(mine[7680 + i], closeTo(theirs[i].toDouble(), 1e-4), reason: 'sample ${7680 + i}');
    }
  });

  test('turbo round trip in Dart, clean and noisy, multi-chunk', () async {
    final rng = Random(5);
    final data = Uint8List.fromList(List.generate(2000, (_) => rng.nextInt(256)));
    final sound = SoundLink(turbo).encodeBytes(await Packet(PacketType.text, data).toBytes(compress: false));
    expect(sound.length / 48000, lessThan(10));
    final x = Float64List(sound.length + 9000);
    final sigma = 0.3 * sqrt(sound.fold<double>(0, (a, s) => a + s * s) / sound.length / pow(10, 2.0));
    for (var i = 0; i < x.length; i++) {
      final j = i - 4000;
      final s = j >= 0 && j < sound.length ? sound[j] + (j >= 144 ? 0.5 * sound[j - 144] : 0) : 0.0;
      x[i] = 0.3 * s + sigma * sqrt(-2 * log(1 - rng.nextDouble())) * cos(2 * pi * rng.nextDouble());
    }
    final r = await decodeAudio(x, turbo);
    expect(r.single.packet!.payload, data);
  });

  test('alert, sensor and file payloads match Python', () async {
    final e = v['extras'];
    final a = Alert.fromBytes(bytesFromHex(e['alert']));
    expect(a.title, 'Flood warning');
    expect(a.message, contains('बाढ़'));
    expect(hexOf(Alert(a.title, message: a.message, severity: 2, kind: 1, area: 'Ward 12', issued: 1800000000, expires: 1800003600).toBytes()),
        e['alert']);

    final s = SensorReport.fromBytes(bytesFromHex(e['sensor']));
    expect(s.seq, 7);
    expect(s.readings.last, (1, -4.25));
    expect(hexOf(s.toBytes()), e['sensor']);
    expect(s.describe()[2], 'Heart rate: 72.5 bpm');

    final f = await FileOffer.fromBytes(bytesFromHex(e['file_link']));
    expect(f.url, 'http://192.168.1.5:8123/f/abc/notes.pdf');
    expect(hexOf(f.toBytes()), e['file_link']);
    final i = await FileOffer.fromBytes(bytesFromHex(e['file_inline']));
    expect(utf8.decode(i.data), 'hello file');
    expect(hexOf((await FileOffer.inline('hi.txt', utf8.encode('hello file'), mime: 'text/plain')).toBytes()), e['file_inline']);
    await expectLater(i.check(utf8.encode('hello fila')), throwsA(isA<PacketError>()));
  });

  test('safe file names', () {
    expect(safeName('../../etc/passwd'), 'passwd');
    expect(safeName(r'C:\Users\x\.bashrc'), 'bashrc');
    expect(safeName(''), 'file');
    final long = safeName('${'a' * 100}.pdf');
    expect(utf8.encode(long).length, lessThanOrEqualTo(40));
    expect(long.endsWith('.pdf'), isTrue);
  });
}
