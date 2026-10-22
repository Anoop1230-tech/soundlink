/// Attendance, tickets, door unlock and login. Port of
/// core-engine/soundlink/access.py (see it for the wire formats).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Hmac, SecretKey;

import 'crypto.dart' as crypto;
import 'link.dart' show hexOf, bytesFromHex;
import 'packet.dart';
import 'payment.dart' show tagOf;

const int textMax = 40;
const int urlMax = 64;
const int windowS = 10;
const int windowsOk = 3;
const int nonceTtlS = 60;

class AccessError implements Exception {
  final String message;
  AccessError(this.message);
  @override
  String toString() => message;
}

List<int> _str8(String s, [int limit = textMax]) {
  final b = utf8.encode(s.trim());
  if (b.length > limit) throw ArgumentError('text is longer than $limit bytes');
  return [b.length, ...b];
}

(String, int) _readStr8(List<int> d, int i, [int limit = textMax]) {
  if (i >= d.length) throw PacketError('missing text');
  final n = d[i];
  if (n > limit || i + 1 + n > d.length) throw PacketError('bad text');
  try {
    return (utf8.decode(d.sublist(i + 1, i + 1 + n)), i + 1 + n);
  } on FormatException {
    throw PacketError('bad text');
  }
}

void _end(List<int> d, int i) {
  if (i != d.length) throw PacketError('extra bytes');
}

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
int _getU32(List<int> d, int i) => (d[i] << 24) | (d[i + 1] << 16) | (d[i + 2] << 8) | d[i + 3];

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var x = 0;
  for (var i = 0; i < a.length; i++) {
    x |= a[i] ^ b[i];
  }
  return x == 0;
}

Uint8List _signed(Packet p, int type, [int? kind]) {
  if (p.type != type) throw AccessError('wrong packet type');
  if (p.signer == null) throw AccessError('packet is not signed');
  if (kind == null) return p.payload;
  if (p.payload.isEmpty || p.payload[0] != kind) throw AccessError('wrong message kind');
  return p.payload.sublist(1);
}

Future<Uint8List> build(int type, List<int> body, crypto.Identity me) =>
    Packet(type, body).toBytes(signWith: me, compress: false);

int windowOf(int t) => t ~/ windowS;

// ================================================================ attendance

const beaconKind = 1, checkinKind = 2, ackKind = 3;

class Beacon {
  final int session, window;
  final Uint8List code;
  final String title;
  final Uint8List teacher;
  Beacon(this.session, this.window, this.code, this.title, this.teacher);
}

Beacon readBeacon(Packet p) {
  final b = _signed(p, PacketType.attendance, beaconKind);
  if (b.length < 17) throw PacketError('bad beacon');
  final (title, i) = _readStr8(b, 16);
  _end(b, i);
  return Beacon(_getU32(b, 0), _getU32(b, 4), b.sublist(8, 16), title, p.signer!);
}

Future<Uint8List> checkInPacket(Beacon b, String name, crypto.Identity me) async => build(
    PacketType.attendance,
    [checkinKind, ..._u32(b.session), ..._u32(b.window), ...b.code, ...await tagOf(b.teacher), ..._str8(name)],
    me);

/// Returns how many students are present.
Future<int> readAck(Packet p, crypto.Identity me, Beacon b) async {
  final d = _signed(p, PacketType.attendance, ackKind);
  if (d.length != 14) throw PacketError('bad ack');
  if (_getU32(d, 0) != b.session || !_eq(d.sublist(4, 12), await tagOf(me.publicKey)) || !_eq(p.signer!, b.teacher)) {
    throw AccessError('ack is for someone else');
  }
  return (d[12] << 8) | d[13];
}

class Attendee {
  final String key, name;
  final int time;
  Attendee(this.key, this.name, this.time);
  Map<String, dynamic> toJson() => {'key': key, 'name': name, 'time': time};
  static Attendee fromJson(Map<String, dynamic> j) => Attendee(j['key'], j['name'], j['time']);
}

class CheckInResult {
  final Attendee attendee;
  final Uint8List ack;
  final bool isNew;
  CheckInResult(this.attendee, this.ack, this.isNew);
}

/// Teacher side.
class ClassSession {
  final String title;
  final int session;
  final Uint8List secret;
  final int started;
  final List<Attendee> present = [];
  final List<String> problems = [];

  ClassSession(this.title, {int? session, List<int>? secret, int? started})
      : session = session ?? (crypto.randomBytes(4).fold<int>(0, (a, b) => (a << 8) | b)),
        secret = Uint8List.fromList(secret ?? crypto.randomBytes(16)),
        started = started ?? unixNow();

  Future<Uint8List> code(int window) async {
    final mac = await Hmac.sha256().calculateMac([...utf8.encode('SLATT1'), ..._u32(session), ..._u32(window)],
        secretKey: SecretKey(secret));
    return Uint8List.fromList(mac.bytes.sublist(0, 8));
  }

  Future<Uint8List> beacon(crypto.Identity me, {int? now}) async {
    final w = windowOf(now ?? unixNow());
    return build(PacketType.attendance, [beaconKind, ..._u32(session), ..._u32(w), ...await code(w), ..._str8(title)], me);
  }

  Future<CheckInResult> checkIn(Packet p, crypto.Identity me, {int? now}) async {
    now ??= unixNow();
    final b = _signed(p, PacketType.attendance, checkinKind);
    if (b.length < 25) throw PacketError('bad check-in');
    final (name, i) = _readStr8(b, 24);
    _end(b, i);
    final s = _getU32(b, 0), w = _getU32(b, 4);
    if (s != session || !_eq(b.sublist(16, 24), await tagOf(me.publicKey))) throw AccessError('check-in is for another class');
    final age = windowOf(now) - w;
    if (age < 0 || age >= windowsOk) throw AccessError('code is too old (heard more than 30 seconds ago)');
    if (!_eq(b.sublist(8, 16), await code(w))) throw AccessError('wrong code');
    final key = hexOf(p.signer!);
    final idx = present.indexWhere((a) => a.key == key);
    Attendee a;
    var isNew = true;
    if (idx >= 0) {
      isNew = false;
      a = present[idx];
      if (a.name != name.trim()) problems.add('one phone tried two names: ${a.name} / $name');
    } else {
      a = Attendee(key, name.trim(), now);
      present.add(a);
    }
    final ack = await build(PacketType.attendance,
        [ackKind, ..._u32(session), ...await tagOf(p.signer!), (present.length >> 8) & 0xFF, present.length & 0xFF], me);
    return CheckInResult(a, ack, isNew);
  }

  String csv() {
    String q(String s) => s.contains(RegExp(r'[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
    final lines = ['name,time,device'];
    for (final a in present) {
      final t = DateTime.fromMillisecondsSinceEpoch(a.time * 1000).toLocal().toString().substring(0, 19);
      lines.add('${q(a.name)},$t,${a.key.substring(0, 16)}');
    }
    return '${lines.join('\r\n')}\r\n';
  }
}

// ================================================================ tickets

const askKind = 1, issueKind = 2, gateKind = 3, showKind = 4, resultKind = 5;
const ticketOk = 0, ticketUsed = 1, ticketInvalid = 2, ticketExpired = 3, ticketWrongEvent = 4;
const ticketStatus = {
  0: 'welcome',
  1: 'already used',
  2: 'not a valid ticket',
  3: 'expired',
  4: 'ticket for another event',
};

class Ticket {
  final int event, number, validUntil;
  final String label;
  final Uint8List sig;
  Ticket(this.event, this.number, this.validUntil, this.label, List<int> sig) : sig = Uint8List.fromList(sig);

  List<int> fields() => [..._u32(event), ..._u32(number), ..._u32(validUntil), ..._str8(label)];
  Uint8List toBytes() => Uint8List.fromList([...fields(), ...sig]);

  static (Ticket, int) read(List<int> d, [int i = 0]) {
    if (d.length < i + 13) throw PacketError('bad ticket');
    final (label, j) = _readStr8(d, i + 12);
    if (d.length < j + 64) throw PacketError('bad ticket');
    return (Ticket(_getU32(d, i), _getU32(d, i + 4), _getU32(d, i + 8), label, d.sublist(j, j + 64)), j + 64);
  }

  Future<bool> verify(List<int> organizerPub, List<int> holderPub) =>
      crypto.verify(organizerPub, [...utf8.encode('SLTKT1'), ...holderPub, ...fields()], sig);
}

Future<Uint8List> askPacket(String name, crypto.Identity me) => build(PacketType.ticket, [askKind, ..._str8(name)], me);

/// Returns (ticket, organizer public key).
Future<(Ticket, Uint8List)> readIssue(Packet p, crypto.Identity me) async {
  final b = _signed(p, PacketType.ticket, issueKind);
  if (b.length < 8 || !_eq(b.sublist(0, 8), await tagOf(me.publicKey))) throw AccessError('ticket is for someone else');
  final (t, i) = Ticket.read(b, 8);
  _end(b, i);
  if (!await t.verify(p.signer!, me.publicKey)) throw AccessError('ticket signature is wrong');
  return (t, p.signer!);
}

/// Returns (event, nonce, gate public key).
(int, Uint8List, Uint8List) readGate(Packet p) {
  final b = _signed(p, PacketType.ticket, gateKind);
  if (b.length != 12) throw PacketError('bad gate challenge');
  return (_getU32(b, 0), b.sublist(4), p.signer!);
}

Future<Uint8List> showPacket(List<int> nonce, Ticket t, crypto.Identity me) =>
    build(PacketType.ticket, [showKind, ...nonce, ...t.toBytes()], me);

/// Returns (status, ticket number).
(int, int) readResult(Packet p, List<int> nonce, List<int> gatePub) {
  final b = _signed(p, PacketType.ticket, resultKind);
  if (b.length != 13 || !_eq(b.sublist(0, 8), nonce) || !_eq(p.signer!, gatePub)) throw AccessError('result is for someone else');
  return (b[8], _getU32(b, 9));
}

class GateResult {
  final int status;
  final Ticket ticket;
  final Uint8List result;
  GateResult(this.status, this.ticket, this.result);
}

/// Organizer side: issues tickets and runs the gate.
class Event {
  final String name;
  final int validUntil;
  final int event;
  final Map<String, Map<String, dynamic>> issued = {}; // holder key hex -> {number, label, name}
  final Map<String, int> used = {}; // ticket number -> time
  final Map<String, int> _gateNonces = {};

  Event(this.name, this.validUntil, {int? event})
      : event = event ?? crypto.randomBytes(4).fold<int>(0, (a, b) => (a << 8) | b);

  Future<(Ticket, Uint8List)> issue(Packet ask, crypto.Identity me, {String label = ''}) async {
    final b = _signed(ask, PacketType.ticket, askKind);
    final (name, i) = _readStr8(b, 0);
    _end(b, i);
    final holder = ask.signer!;
    final prev = issued[hexOf(holder)];
    final number = prev != null ? prev['number'] as int : issued.length + 1;
    var l = (label.isNotEmpty ? label : (name.isNotEmpty ? name : 'Ticket $number')).trim();
    while (utf8.encode(l).length > textMax) {
      l = l.substring(0, l.length - 1);
    }
    final unsigned = Ticket(event, number, validUntil, l, const []);
    final sig = await me.sign([...utf8.encode('SLTKT1'), ...holder, ...unsigned.fields()]);
    final t = Ticket(event, number, validUntil, l, sig);
    issued[hexOf(holder)] = {'number': number, 'label': l, 'name': name};
    return (t, await build(PacketType.ticket, [issueKind, ...await tagOf(holder), ...t.toBytes()], me));
  }

  Future<Uint8List> gate(crypto.Identity me, {int? now}) async {
    now ??= unixNow();
    _gateNonces.removeWhere((_, t) => now! - t > nonceTtlS);
    final nonce = crypto.randomBytes(8);
    _gateNonces[hexOf(nonce)] = now;
    return build(PacketType.ticket, [gateKind, ..._u32(event), ...nonce], me);
  }

  Future<GateResult> check(Packet show, crypto.Identity me, {int? now}) async {
    now ??= unixNow();
    final b = _signed(show, PacketType.ticket, showKind);
    if (b.length < 8) throw PacketError('bad ticket');
    final nonce = b.sublist(0, 8);
    final (t, i) = Ticket.read(b, 8);
    _end(b, i);
    if (_gateNonces.remove(hexOf(nonce)) == null) throw AccessError('answer to an old or unknown gate challenge');
    int status;
    if (t.event != event) {
      status = ticketWrongEvent;
    } else if (!await t.verify(me.publicKey, show.signer!)) {
      status = ticketInvalid;
    } else if (now > t.validUntil) {
      status = ticketExpired;
    } else if (used.containsKey('${t.number}')) {
      status = ticketUsed;
    } else {
      status = ticketOk;
      used['${t.number}'] = now;
    }
    final res = await build(PacketType.ticket, [resultKind, ...nonce, status, ..._u32(t.number)], me);
    return GateResult(status, t, res);
  }

  Map<String, dynamic> toJson() => {'name': name, 'valid_until': validUntil, 'event': event, 'issued': issued, 'used': used};

  static Event fromJson(Map<String, dynamic> j) {
    final e = Event(j['name'], j['valid_until'], event: j['event']);
    (j['issued'] as Map? ?? {}).forEach((k, v) => e.issued[k as String] = Map<String, dynamic>.from(v as Map));
    (j['used'] as Map? ?? {}).forEach((k, v) => e.used[k as String] = v as int);
    return e;
  }
}

/// A ticket kept on the holder's phone.
class HeldTicket {
  final Ticket ticket;
  final String organizer; // hex
  final String eventName;
  HeldTicket(this.ticket, this.organizer, this.eventName);
  Map<String, dynamic> toJson() => {'ticket': hexOf(ticket.toBytes()), 'organizer': organizer, 'event_name': eventName};
  static HeldTicket fromJson(Map<String, dynamic> j) =>
      HeldTicket(Ticket.read(bytesFromHex(j['ticket'])).$1, j['organizer'], j['event_name'] ?? '');
}

// ================================================================ door

const doorChallengeKind = 1, doorOpenKind = 2, doorResultKind = 3, doorEnrollKind = 4;
const doorOk = 0, doorDenied = 1, doorStale = 2;
const doorStatus = {0: 'door opened', 1: 'this phone is not allowed', 2: 'too slow, try again'};

/// Returns (nonce, door name, door public key).
(Uint8List, String, Uint8List) readDoorChallenge(Packet p) {
  final b = _signed(p, PacketType.doorUnlock, doorChallengeKind);
  if (b.length < 9) throw PacketError('bad door challenge');
  final (name, i) = _readStr8(b, 8);
  _end(b, i);
  return (b.sublist(0, 8), name, p.signer!);
}

Future<Uint8List> openPacket(List<int> nonce, List<int> doorPub, crypto.Identity me) async =>
    build(PacketType.doorUnlock, [doorOpenKind, ...await tagOf(doorPub), ...nonce], me);

Future<Uint8List> enrollPacket(List<int> doorPub, String name, crypto.Identity me) async =>
    build(PacketType.doorUnlock, [doorEnrollKind, ...await tagOf(doorPub), ..._str8(name)], me);

int readDoorResult(Packet p, List<int> nonce, List<int> doorPub) {
  final b = _signed(p, PacketType.doorUnlock, doorResultKind);
  if (b.length != 9 || !_eq(b.sublist(0, 8), nonce) || !_eq(p.signer!, doorPub)) throw AccessError('result is for someone else');
  return b[8];
}

class DoorLogEntry {
  final String who;
  final int status, time;
  DoorLogEntry(this.who, this.status, this.time);
  Map<String, dynamic> toJson() => {'who': who, 'status': status, 'time': time};
  static DoorLogEntry fromJson(Map<String, dynamic> j) => DoorLogEntry(j['who'], j['status'], j['time']);
}

/// Door side (a phone stuck next to the door, a laptop, or later an ESP32).
class Door {
  String name;
  final Map<String, String> allowed = {}; // key hex -> person
  final Map<String, int> _nonces = {};
  final List<DoorLogEntry> log = [];
  Door(this.name);

  Future<Uint8List> challenge(crypto.Identity me, {int? now}) async {
    now ??= unixNow();
    _nonces.removeWhere((_, t) => now! - t > nonceTtlS);
    final nonce = crypto.randomBytes(8);
    _nonces[hexOf(nonce)] = now;
    return build(PacketType.doorUnlock, [doorChallengeKind, ...nonce, ..._str8(name)], me);
  }

  /// Returns (status, result packet).
  Future<(int, Uint8List)> open(Packet p, crypto.Identity me, {int? now}) async {
    now ??= unixNow();
    final b = _signed(p, PacketType.doorUnlock, doorOpenKind);
    if (b.length != 16 || !_eq(b.sublist(0, 8), await tagOf(me.publicKey))) throw AccessError('message is for another door');
    final nonce = b.sublist(8);
    final t = _nonces.remove(hexOf(nonce));
    final key = hexOf(p.signer!);
    final status = (t == null || now - t > nonceTtlS) ? doorStale : (allowed.containsKey(key) ? doorOk : doorDenied);
    log.add(DoorLogEntry(allowed[key] ?? key.substring(0, 16), status, now));
    if (log.length > 100) log.removeAt(0);
    return (status, await build(PacketType.doorUnlock, [doorResultKind, ...nonce, status], me));
  }

  /// Returns (phone public key, name) for the owner to approve.
  Future<(Uint8List, String)> readEnroll(Packet p, crypto.Identity me) async {
    final b = _signed(p, PacketType.doorUnlock, doorEnrollKind);
    if (b.length < 9 || !_eq(b.sublist(0, 8), await tagOf(me.publicKey))) throw AccessError('enroll is for another door');
    final (n, i) = _readStr8(b, 8);
    _end(b, i);
    return (p.signer!, n);
  }

  Map<String, dynamic> toJson() => {'name': name, 'allowed': allowed, 'log': log.map((e) => e.toJson()).toList()};

  static Door fromJson(Map<String, dynamic> j) {
    final d = Door(j['name']);
    (j['allowed'] as Map? ?? {}).forEach((k, v) => d.allowed[k as String] = v as String);
    d.log.addAll(((j['log'] ?? []) as List).map((e) => DoorLogEntry.fromJson(e as Map<String, dynamic>)));
    return d;
  }
}

// ================================================================ login

class AuthChallenge {
  final Uint8List session;
  final int expires;
  final String site, user, url;
  final Uint8List sitePub;
  AuthChallenge(this.session, this.expires, this.site, this.user, this.url, this.sitePub);
}

AuthChallenge readAuthChallenge(Packet p) {
  final b = _signed(p, PacketType.authChallenge);
  if (b.length < 20) throw PacketError('bad login challenge');
  final (site, i) = _readStr8(b, 20);
  final (user, j) = _readStr8(b, i);
  final (url, k) = _readStr8(b, j, urlMax);
  _end(b, k);
  return AuthChallenge(b.sublist(0, 16), _getU32(b, 16), site, user, url, p.signer!);
}

Future<Uint8List> authResponsePacket(AuthChallenge ch, bool approve, crypto.Identity me) async =>
    build(PacketType.authResponse, [...ch.session, ...await tagOf(ch.sitePub), approve ? 1 : 0], me);
