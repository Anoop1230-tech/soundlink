/// QR fallback and sound-test packets. Port of core-engine/soundlink/fallback.py.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'modem.dart' show pnBytes, profiles;
import 'transport.dart' as transport;

const qrPrefix = 'SL1:';
const qrChunk = 400;
const testType = 0x70;
final List<String> profileOrder = profiles.keys.toList(); // normal, fast, ultrasonic, turbo (same as Python)

List<String> toQrTexts(List<int> packet, {int chunk = qrChunk}) => [
      for (final p in transport.split(packet, frameSize: chunk + transport.chunkHeader))
        qrPrefix + base64Url.encode(p).replaceAll('=', ''),
    ];

/// The chunk inside a SoundLink QR code. Throws FormatException otherwise.
Uint8List fromQrText(String text) {
  final t = text.trim();
  if (!t.startsWith(qrPrefix)) throw const FormatException('not a SoundLink QR code');
  final body = t.substring(qrPrefix.length);
  return base64Url.decode(body + '=' * ((4 - body.length % 4) % 4));
}

Uint8List makeTestPayload(String profile, int index, int total, int size) {
  final b = BytesBuilder()
    ..add(utf8.encode('SLT1'))
    ..addByte(profileOrder.indexOf(profile))
    ..add([index >> 8, index & 0xFF, total >> 8, total & 0xFF, size >> 8, size & 0xFF])
    ..add(pnBytes(0x5EED0000 + index, size));
  return b.toBytes();
}

class SoundTestScore {
  final String profile;
  int total = 0, size = 0, bad = 0, corrected = 0;
  final Set<int> good = {};
  final List<double> quality = [];
  DateTime? first, last;
  SoundTestScore(this.profile);

  bool add(List<int> p, double q, int fixed) {
    if (p.length < 11 || utf8.decode(p.sublist(0, 4), allowMalformed: true) != 'SLT1') return false;
    if (p[4] != profileOrder.indexOf(profile)) return false;
    final index = (p[5] << 8) | p[6];
    total = (p[7] << 8) | p[8];
    size = (p[9] << 8) | p[10];
    final want = pnBytes(0x5EED0000 + index, size);
    final got = p.sublist(11);
    var same = got.length == want.length;
    for (var i = 0; same && i < got.length; i++) {
      same = got[i] == want[i];
    }
    if (!same) {
      bad++;
      return true;
    }
    good.add(index);
    quality.add(q);
    corrected += fixed;
    first ??= DateTime.now();
    last = DateTime.now();
    return true;
  }

  int get successPct => total == 0 ? 0 : (100 * good.length / total).round();

  double get medianQuality {
    if (quality.isEmpty) return 0;
    final q = List<double>.of(quality)..sort();
    return q[q.length ~/ 2];
  }

  String csvRow(String distance, String note) =>
      '$profile,$distance,${good.length},$total,$successPct,$size,${medianQuality.toStringAsFixed(2)},$corrected,$bad,"$note"';
}

const testCsvHeader = 'mode,distance,received,sent,success_pct,bytes_each,median_quality,bytes_fixed,bad,note';
