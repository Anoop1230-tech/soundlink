/// Emergency alerts, sensor reports and file offers.
/// Port of core-engine/soundlink/extras.py (see it for the wire formats).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;

import 'packet.dart';

const int extraTextMax = 40;
const int messageMax = 400;
const int fileUrlMax = 200;
const int inlineMax = maxPayload - 120;

List<int> _s8(String s, [int limit = extraTextMax]) {
  final b = utf8.encode(s.trim());
  if (b.length > limit) throw ArgumentError('text is longer than $limit bytes');
  return [b.length, ...b];
}

(String, int) _r8(List<int> d, int i, [int limit = extraTextMax]) {
  if (i >= d.length || d[i] > limit || i + 1 + d[i] > d.length) throw PacketError('bad text');
  try {
    return (utf8.decode(d.sublist(i + 1, i + 1 + d[i])), i + 1 + d[i]);
  } on FormatException {
    throw PacketError('bad text');
  }
}

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
int _g32(List<int> d, int i) => (d[i] << 24) | (d[i + 1] << 16) | (d[i + 2] << 8) | d[i + 3];

// ---------------------------------------------------------------- alerts

const severityNames = {0: 'Info', 1: 'Warning', 2: 'DANGER'};
const alertKinds = {
  0: 'General',
  1: 'Flood',
  2: 'Fire',
  3: 'Earthquake',
  4: 'Cyclone / storm',
  5: 'Medical',
  6: 'Police / safety',
  7: 'Evacuate',
  8: 'All clear',
};

class Alert {
  final String title, message, area;
  final int severity, kind, issued, expires;

  Alert(this.title, {this.message = '', this.severity = 1, this.kind = 0, this.area = '', int? issued, this.expires = 0})
      : issued = issued ?? unixNow();

  Uint8List toBytes() {
    if (title.trim().isEmpty) throw ArgumentError('title is required');
    if (!severityNames.containsKey(severity) || !alertKinds.containsKey(kind)) throw ArgumentError('unknown severity or kind');
    final msg = utf8.encode(message.trim());
    if (msg.length > messageMax) throw ArgumentError('message is longer than $messageMax bytes');
    return Uint8List.fromList([severity, kind, ..._u32(issued), ..._u32(expires), ..._s8(area), ..._s8(title), ...msg]);
  }

  static Alert fromBytes(List<int> d) {
    if (d.length < 12) throw PacketError('bad alert');
    final sev = d[0], kind = d[1];
    if (!severityNames.containsKey(sev) || !alertKinds.containsKey(kind)) throw PacketError('bad alert');
    final (area, i) = _r8(d, 10);
    final (title, j) = _r8(d, i);
    if (title.isEmpty || d.length - j > messageMax) throw PacketError('bad alert');
    String msg;
    try {
      msg = utf8.decode(d.sublist(j));
    } on FormatException {
      throw PacketError('bad alert');
    }
    return Alert(title, message: msg, severity: sev, kind: kind, area: area, issued: _g32(d, 2), expires: _g32(d, 6));
  }

  bool expired([int? now]) => expires != 0 && (now ?? unixNow()) > expires;
}

// ---------------------------------------------------------------- sensors

const sensorKinds = {
  1: ('Temperature', '°C'),
  2: ('Humidity', '%'),
  3: ('Heart rate', 'bpm'),
  4: ('SpO2', '%'),
  5: ('BP systolic', 'mmHg'),
  6: ('BP diastolic', 'mmHg'),
  7: ('Glucose', 'mg/dL'),
  8: ('Battery', '%'),
  9: ('PM2.5', 'µg/m³'),
  10: ('Weight', 'kg'),
  11: ('Door open', ''),
  12: ('Value', ''),
};
const maxReadings = 16;

class SensorReport {
  final String name;
  final List<(int, double)> readings;
  final int seq;
  SensorReport(this.name, this.readings, {this.seq = 0});

  Uint8List toBytes() {
    if (readings.isEmpty || readings.length > maxReadings) throw ArgumentError('1..$maxReadings readings');
    final out = <int>[..._u32(seq), ..._s8(name), readings.length];
    for (final (kind, value) in readings) {
      if (!sensorKinds.containsKey(kind)) throw ArgumentError('unknown sensor kind $kind');
      final v = (value * 100).round() & 0xFFFFFFFF;
      out..add(kind)..addAll(_u32(v));
    }
    return Uint8List.fromList(out);
  }

  static SensorReport fromBytes(List<int> d) {
    if (d.length < 6) throw PacketError('bad sensor report');
    final (name, i0) = _r8(d, 4);
    if (i0 >= d.length) throw PacketError('bad sensor report');
    final n = d[i0];
    final i = i0 + 1;
    if (n == 0 || n > maxReadings || d.length != i + 5 * n) throw PacketError('bad sensor report');
    final r = <(int, double)>[];
    for (var k = 0; k < n; k++) {
      final kind = d[i + 5 * k];
      if (!sensorKinds.containsKey(kind)) throw PacketError('unknown sensor kind');
      var v = _g32(d, i + 5 * k + 1);
      if (v >= 0x80000000) v -= 0x100000000;
      r.add((kind, v / 100));
    }
    return SensorReport(name, r, seq: _g32(d, 0));
  }

  List<String> describe() => [
        for (final (k, v) in readings)
          '${sensorKinds[k]!.$1}: ${v == v.roundToDouble() ? v.toInt() : v} ${sensorKinds[k]!.$2}'.trimRight(),
      ];
}

// ---------------------------------------------------------------- files

const fileLink = 1, fileInline = 2;

Future<Uint8List> sha256Of(List<int> data) async => Uint8List.fromList((await Sha256().hash(data)).bytes);

String safeName(String name) {
  var base = name.replaceAll('\\', '/').split('/').last.trim();
  base = base.split('').where((c) => RegExp(r'[\p{L}\p{N} ._\-()]', unicode: true).hasMatch(c)).join();
  while (base.startsWith('.')) {
    base = base.substring(1);
  }
  if (base.isEmpty) base = 'file';
  while (utf8.encode(base).length > extraTextMax) {
    final dot = base.lastIndexOf('.');
    if (dot > 0) {
      base = base.substring(0, dot - 1) + base.substring(dot);
    } else {
      base = base.substring(0, base.length - 1);
    }
  }
  return base;
}

class FileOffer {
  final int mode, size;
  final Uint8List sha256;
  final String name, mime, url;
  final Uint8List data;

  FileOffer(this.mode, this.size, this.sha256, String name, {this.mime = 'application/octet-stream', this.url = '', List<int>? data})
      : name = safeName(name),
        data = Uint8List.fromList(data ?? const []);

  static Future<FileOffer> inline(String name, List<int> data, {String mime = 'application/octet-stream'}) async {
    if (data.length > inlineMax) throw ArgumentError('inline files can be at most $inlineMax bytes');
    return FileOffer(fileInline, data.length, await sha256Of(data), name, mime: mime, data: data);
  }

  Uint8List toBytes() {
    final head = [mode, ..._u32(size), ...sha256, ..._s8(name), ..._s8(mime)];
    if (mode == fileLink) {
      if (!(url.startsWith('http://') || url.startsWith('https://'))) throw ArgumentError('url must be http(s)');
      return Uint8List.fromList([...head, ..._s8(url, fileUrlMax)]);
    }
    return Uint8List.fromList([...head, ...data]);
  }

  /// Quick parse for showing the offer (no checksum check; use [fromBytes] or [check] before saving).
  static FileOffer parse(List<int> d) {
    if (d.length < 39) throw PacketError('bad file offer');
    final mode = d[0], size = _g32(d, 1);
    final sha = Uint8List.fromList(d.sublist(5, 37));
    final (name, i) = _r8(d, 37);
    final (mime, j) = _r8(d, i);
    if (mode == fileLink) {
      final (url, k) = _r8(d, j, fileUrlMax);
      if (k != d.length || !(url.startsWith('http://') || url.startsWith('https://'))) throw PacketError('bad file offer');
      return FileOffer(mode, size, sha, name, mime: mime, url: url);
    }
    if (mode == fileInline) return FileOffer(mode, size, sha, name, mime: mime, data: d.sublist(j));
    throw PacketError('bad file offer');
  }

  static Future<FileOffer> fromBytes(List<int> d) async {
    if (d.length < 39) throw PacketError('bad file offer');
    final mode = d[0], size = _g32(d, 1);
    final sha = Uint8List.fromList(d.sublist(5, 37));
    final (name, i) = _r8(d, 37);
    final (mime, j) = _r8(d, i);
    if (mode == fileLink) {
      final (url, k) = _r8(d, j, fileUrlMax);
      if (k != d.length || !(url.startsWith('http://') || url.startsWith('https://'))) throw PacketError('bad file offer');
      return FileOffer(mode, size, sha, name, mime: mime, url: url);
    }
    if (mode == fileInline) {
      final data = d.sublist(j);
      if (data.length != size || !_same(await sha256Of(data), sha)) throw PacketError('file is damaged');
      return FileOffer(mode, size, sha, name, mime: mime, data: data);
    }
    throw PacketError('bad file offer');
  }

  /// Verify downloaded bytes against the signed size and checksum.
  Future<Uint8List> check(List<int> got) async {
    if (got.length != size || !_same(await sha256Of(got), sha256)) {
      throw PacketError('downloaded file does not match (wrong size or checksum)');
    }
    return Uint8List.fromList(got);
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
