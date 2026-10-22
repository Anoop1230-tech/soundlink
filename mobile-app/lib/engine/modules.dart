/// Payload formats for the app modules (same as core-engine/soundlink/modules.py).
///
///     field = tag(1) | length(1) | value (UTF-8, max 255 bytes)
///
/// Unknown tags are skipped so new fields can be added later.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'extras.dart';
import 'packet.dart';

const int maxField = 255;

Uint8List _encodeFields(List<(int, List<int>)> items) {
  final out = BytesBuilder();
  for (final (tag, value) in items) {
    if (value.length > maxField) throw ArgumentError('field $tag is longer than $maxField bytes');
    out
      ..addByte(tag)
      ..addByte(value.length)
      ..add(value);
  }
  return out.toBytes();
}

Map<int, Uint8List> _decodeFields(List<int> data) {
  final out = <int, Uint8List>{};
  var i = 0;
  while (i < data.length) {
    if (i + 2 > data.length) throw PacketError('broken field list');
    final tag = data[i], n = data[i + 1];
    if (i + 2 + n > data.length) throw PacketError('broken field list');
    out[tag] = Uint8List.fromList(data.sublist(i + 2, i + 2 + n));
    i += 2 + n;
  }
  return out;
}

String _str(Map<int, Uint8List> f, int tag) {
  try {
    return utf8.decode(f[tag] ?? const []);
  } on FormatException {
    throw PacketError('text field is not UTF-8');
  }
}

List<int> _text(String s) => utf8.encode(s.trim());

class Contact {
  final String name, phone, email, org, title, url, note;

  const Contact({
    required this.name,
    this.phone = '',
    this.email = '',
    this.org = '',
    this.title = '',
    this.url = '',
    this.note = '',
  });

  List<String> get _values => [name, phone, email, org, title, url, note];

  Uint8List toBytes() {
    if (name.trim().isEmpty) throw ArgumentError('name is required');
    final v = _values;
    return _encodeFields([
      for (var i = 0; i < v.length; i++)
        if (v[i].isNotEmpty) (i + 1, _text(v[i])),
    ]);
  }

  static Contact fromBytes(List<int> data) {
    final f = _decodeFields(data);
    final c = Contact(
      name: _str(f, 1),
      phone: _str(f, 2),
      email: _str(f, 3),
      org: _str(f, 4),
      title: _str(f, 5),
      url: _str(f, 6),
      note: _str(f, 7),
    );
    if (c.name.isEmpty) throw PacketError('name is missing');
    return c;
  }

  String toVcard() {
    final lines = ['BEGIN:VCARD', 'VERSION:3.0', 'FN:$name'];
    for (final (prefix, value) in [
      ('TEL', phone),
      ('EMAIL', email),
      ('ORG', org),
      ('TITLE', title),
      ('URL', url),
      ('NOTE', note),
    ]) {
      if (value.isNotEmpty) lines.add('$prefix:$value');
    }
    return [...lines, 'END:VCARD'].join('\r\n');
  }

  Map<String, String> toJson() =>
      {'name': name, 'phone': phone, 'email': email, 'org': org, 'title': title, 'url': url, 'note': note};

  static Contact fromJson(Map<String, dynamic> j) => Contact(
        name: j['name'] ?? '',
        phone: j['phone'] ?? '',
        email: j['email'] ?? '',
        org: j['org'] ?? '',
        title: j['title'] ?? '',
        url: j['url'] ?? '',
        note: j['note'] ?? '',
      );

  @override
  bool operator ==(Object other) => other is Contact && _listEq(other._values, _values);
  @override
  int get hashCode => Object.hashAll(_values);
  @override
  String toString() => 'Contact($name${phone.isEmpty ? '' : ', $phone'})';
}

bool _listEq(List a, List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

enum WifiSecurity {
  open('Open (no password)'),
  wpa('WPA / WPA2'),
  wpa3('WPA3'),
  wep('WEP (old)');

  final String label;
  const WifiSecurity(this.label);
}

class Wifi {
  final String ssid, password;
  final WifiSecurity security;
  final bool hidden;

  const Wifi(this.ssid, {this.password = '', this.security = WifiSecurity.wpa, this.hidden = false});

  Uint8List toBytes() {
    if (ssid.isEmpty) throw ArgumentError('ssid is required');
    if (security != WifiSecurity.open && password.isEmpty) {
      throw ArgumentError('password is required for a secured network');
    }
    final head = security.index | (hidden ? 0x80 : 0);
    return Uint8List.fromList([
      head,
      ..._encodeFields([
        (1, utf8.encode(ssid)),
        if (password.isNotEmpty) (2, utf8.encode(password)),
      ]),
    ]);
  }

  static Wifi fromBytes(List<int> data) {
    if (data.isEmpty) throw PacketError('empty Wi-Fi payload');
    final s = data[0] & 0x7F;
    if (s >= WifiSecurity.values.length) throw PacketError('unknown Wi-Fi security type');
    final f = _decodeFields(data.sublist(1));
    final ssid = _str(f, 1);
    if (ssid.isEmpty) throw PacketError('ssid is missing');
    return Wifi(ssid, password: _str(f, 2), security: WifiSecurity.values[s], hidden: data[0] & 0x80 != 0);
  }

  /// Standard Wi-Fi QR text.
  String toQrString() {
    final kind = switch (security) {
      WifiSecurity.open => 'nopass',
      WifiSecurity.wep => 'WEP',
      _ => 'WPA',
    };
    String esc(String s) => s.split('').map((c) => r'\;,:"'.contains(c) ? '\\$c' : c).join();
    final h = hidden ? 'H:true;' : '';
    return 'WIFI:T:$kind;S:${esc(ssid)};P:${esc(password)};$h;';
  }

  @override
  bool operator ==(Object other) =>
      other is Wifi &&
      other.ssid == ssid &&
      other.password == password &&
      other.security == security &&
      other.hidden == hidden;
  @override
  int get hashCode => Object.hash(ssid, password, security, hidden);
  @override
  String toString() => 'Wifi($ssid, ${security.name}${hidden ? ', hidden' : ''})';
}

class Offer {
  final String title, shop, details, code, url;

  /// Unix time, 0 = never.
  final int expires;

  const Offer(this.title, {this.shop = '', this.details = '', this.code = '', this.url = '', this.expires = 0});

  Uint8List toBytes() {
    if (title.trim().isEmpty) throw ArgumentError('title is required');
    final exp = ByteData(4)..setUint32(0, expires);
    return _encodeFields([
      (1, _text(title)),
      if (shop.isNotEmpty) (2, _text(shop)),
      if (details.isNotEmpty) (3, _text(details)),
      if (code.isNotEmpty) (4, _text(code)),
      if (url.isNotEmpty) (5, _text(url)),
      if (expires != 0) (6, exp.buffer.asUint8List()),
    ]);
  }

  static Offer fromBytes(List<int> data) {
    final f = _decodeFields(data);
    final title = _str(f, 1);
    if (title.isEmpty) throw PacketError('title is missing');
    final e = f[6];
    if (e != null && e.isNotEmpty && e.length != 4) throw PacketError('bad expiry');
    final expires = (e == null || e.isEmpty) ? 0 : ByteData.sublistView(e).getUint32(0);
    return Offer(title, shop: _str(f, 2), details: _str(f, 3), code: _str(f, 4), url: _str(f, 5), expires: expires);
  }

  bool expired([int? now]) => expires != 0 && (now ?? unixNow()) > expires;

  @override
  bool operator ==(Object other) =>
      other is Offer &&
      other.title == title &&
      other.shop == shop &&
      other.details == details &&
      other.code == code &&
      other.url == url &&
      other.expires == expires;
  @override
  int get hashCode => Object.hash(title, shop, details, code, url, expires);
  @override
  String toString() => 'Offer($title${shop.isEmpty ? '' : ' @ $shop'})';
}

/// Returns a Contact / Wifi / Offer / Alert / SensorReport / FileOffer, a String for TEXT, or null for other types.
Object? parsePayload(int type, List<int> payload) {
  switch (type) {
    case PacketType.text:
      try {
        return utf8.decode(payload);
      } on FormatException {
        throw PacketError('text is not UTF-8');
      }
    case PacketType.contact:
      return Contact.fromBytes(payload);
    case PacketType.wifi:
      return Wifi.fromBytes(payload);
    case PacketType.offer:
      return Offer.fromBytes(payload);
    case PacketType.emergency:
      return Alert.fromBytes(payload);
    case PacketType.sensor:
      return SensorReport.fromBytes(payload);
    case PacketType.fileHandshake:
      return FileOffer.parse(payload);
  }
  return null;
}
