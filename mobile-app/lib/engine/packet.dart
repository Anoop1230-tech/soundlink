/// SoundLink packet format (same as core-engine/soundlink/packet.py).
///
///     | ver(1) | type(1) | flags(1) | msg_id(4) | timestamp(4) |   header, 11 bytes
///     | body (N)                                              |   maybe compressed / encrypted
///     | signer public key(32) | signature(64)                 |   only if SIGNED
///     | crc16(2)                                              |
library;

import 'dart:io' show RawZLibFilter;
import 'dart:typed_data';

import 'crc.dart';
import 'crypto.dart' as crypto;

const int packetVersion = 1;
const int headerSize = 11;
const int nonceExtraSize = 8;
const int sigBlockSize = crypto.publicKeySize + crypto.signatureSize;
const int crcSize = 2;
const int maxPayload = 4096;

class PacketError implements Exception {
  final String message;
  PacketError(this.message);
  @override
  String toString() => message;
}

abstract final class PacketType {
  static const text = 0x00;
  static const paymentRequest = 0x01;
  static const payment = 0x02;
  static const paymentReceipt = 0x03;
  static const wifi = 0x10;
  static const contact = 0x11;
  static const fileHandshake = 0x12;
  static const attendance = 0x20;
  static const ticket = 0x21;
  static const doorUnlock = 0x22;
  static const authChallenge = 0x30;
  static const authResponse = 0x31;
  static const emergency = 0x40;
  static const offer = 0x50;
  static const sensor = 0x60;

  static const names = {
    text: 'TEXT',
    paymentRequest: 'PAYMENT_REQUEST',
    payment: 'PAYMENT',
    paymentReceipt: 'PAYMENT_RECEIPT',
    wifi: 'WIFI',
    contact: 'CONTACT',
    fileHandshake: 'FILE_HANDSHAKE',
    attendance: 'ATTENDANCE',
    ticket: 'TICKET',
    doorUnlock: 'DOOR_UNLOCK',
    authChallenge: 'AUTH_CHALLENGE',
    authResponse: 'AUTH_RESPONSE',
    emergency: 'EMERGENCY',
    offer: 'OFFER',
    sensor: 'SENSOR',
  };

  static String name(int t) => names[t] ?? '0x${t.toRadixString(16)}';
}

abstract final class Flags {
  static const none = 0;
  static const compressed = 0x01;
  static const encrypted = 0x02;
  static const signed = 0x04;
  static const known = compressed | encrypted | signed;
}

int unixNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Uint8List _nonce(List<int> header, List<int> extra) {
  final n = Uint8List(crypto.nonceSize);
  n.setRange(0, headerSize, header);
  n.setRange(headerSize, headerSize + nonceExtraSize, extra);
  return n;
}

Uint8List _compress(List<int> data) {
  final f = RawZLibFilter.deflateFilter(level: 9, raw: true);
  f.process(data, 0, data.length);
  final out = BytesBuilder(copy: false);
  List<int>? chunk;
  while ((chunk = f.processed(flush: true, end: true)) != null) {
    out.add(chunk!);
  }
  return out.toBytes();
}

/// Inflates, but stops as soon as the output gets bigger than [maxPayload]
/// so a tiny "zip bomb" packet can't eat the phone's memory.
Uint8List _decompress(List<int> data) {
  final f = RawZLibFilter.inflateFilter(raw: true);
  final out = BytesBuilder(copy: false);
  try {
    f.process(data, 0, data.length);
    List<int>? chunk;
    while ((chunk = f.processed(flush: true, end: true)) != null) {
      out.add(chunk!);
      if (out.length > maxPayload) throw PacketError('payload too large');
    }
  } on PacketError {
    rethrow;
  } catch (_) {
    throw PacketError('bad compressed data');
  }
  return out.toBytes();
}

class Packet {
  final int type;
  final Uint8List payload;
  final int msgId;
  final int timestamp;

  /// Filled in when a packet is built or parsed.
  int flags;
  Uint8List? signer;

  Packet(this.type, List<int> payload, {int? msgId, int? timestamp, this.flags = Flags.none, this.signer})
      : payload = Uint8List.fromList(payload),
        msgId = msgId ?? _randomU32(),
        timestamp = timestamp ?? unixNow();

  static int _randomU32() {
    final b = crypto.randomBytes(4);
    return ByteData.sublistView(b).getUint32(0);
  }

  bool get signed => signer != null;
  bool get encrypted => flags & Flags.encrypted != 0;

  Future<Uint8List> toBytes({crypto.Identity? signWith, List<int>? key, bool compress = true}) async {
    if (payload.length > maxPayload) throw PacketError('payload is larger than $maxPayload bytes');

    var f = Flags.none;
    List<int> body = payload;
    if (compress && body.isNotEmpty) {
      final packed = _compress(body);
      if (packed.length < body.length) {
        body = packed;
        f |= Flags.compressed;
      }
    }
    if (key != null) f |= Flags.encrypted;
    if (signWith != null) f |= Flags.signed;

    final header = ByteData(headerSize)
      ..setUint8(0, packetVersion)
      ..setUint8(1, type)
      ..setUint8(2, f)
      ..setUint32(3, msgId)
      ..setUint32(7, timestamp);
    final headerBytes = header.buffer.asUint8List();

    if (key != null) {
      final extra = crypto.randomBytes(nonceExtraSize);
      body = [...extra, ...await crypto.encrypt(key, _nonce(headerBytes, extra), body, aad: headerBytes)];
    }

    final data = BytesBuilder()
      ..add(headerBytes)
      ..add(body);
    if (signWith != null) {
      data.add(signWith.publicKey);
      data.add(await signWith.sign(data.toBytes()));
    }
    final crc = crc16(data.toBytes());
    data
      ..addByte(crc >> 8)
      ..addByte(crc & 0xFF);

    flags = f;
    signer = signWith?.publicKey;
    return data.toBytes();
  }

  static Future<Packet> fromBytes(List<int> raw, {List<int>? key}) async {
    if (raw.length < headerSize + crcSize) throw PacketError('packet too short');
    final data = Uint8List.fromList(raw.sublist(0, raw.length - crcSize));
    final crc = (raw[raw.length - 2] << 8) | raw[raw.length - 1];
    if (crc16(data) != crc) throw PacketError('checksum mismatch');

    final h = ByteData.sublistView(data, 0, headerSize);
    final version = h.getUint8(0);
    final type = h.getUint8(1);
    final flags = h.getUint8(2);
    final msgId = h.getUint32(3);
    final timestamp = h.getUint32(7);
    if (version != packetVersion) throw PacketError('unsupported version $version');
    if (flags & ~Flags.known != 0) throw PacketError('unknown flags');

    final header = data.sublist(0, headerSize);
    var body = data.sublist(headerSize);
    Uint8List? signer;
    if (flags & Flags.signed != 0) {
      if (body.length < sigBlockSize) throw PacketError('packet too short for signature');
      final sigStart = data.length - crypto.signatureSize;
      signer = data.sublist(sigStart - crypto.publicKeySize, sigStart);
      final ok = await crypto.verify(signer, data.sublist(0, sigStart), data.sublist(sigStart));
      if (!ok) throw PacketError('bad signature');
      body = body.sublist(0, body.length - sigBlockSize);
    }

    if (flags & Flags.encrypted != 0) {
      if (key == null) throw PacketError('packet is encrypted, key needed');
      if (body.length < nonceExtraSize + crypto.macSize) throw PacketError('encrypted body too short');
      final extra = body.sublist(0, nonceExtraSize);
      try {
        body = await crypto.decrypt(key, _nonce(header, extra), body.sublist(nonceExtraSize), aad: header);
      } on crypto.DecryptError catch (e) {
        throw PacketError(e.toString());
      }
    }

    if (flags & Flags.compressed != 0) {
      body = _decompress(body);
    } else if (body.length > maxPayload) {
      throw PacketError('payload too large');
    }
    return Packet(type, body, msgId: msgId, timestamp: timestamp, flags: flags, signer: signer);
  }
}

/// Rejects packets that are too old, from the future, or already seen.
///
/// Anyone nearby can record the sound and play it again, so every receiver
/// that acts on a packet (payment, door unlock, attendance) should use this.
class ReplayGuard {
  final int windowS;
  final Map<String, int> _seen = {};

  ReplayGuard({this.windowS = 120});

  void check(Packet packet, {int? now}) {
    now ??= unixNow();
    if ((now - packet.timestamp).abs() > windowS) throw PacketError('packet expired or clock is wrong');
    final k = '${packet.signer?.join(',') ?? ''}:${packet.msgId}';
    if (_seen.containsKey(k)) throw PacketError('replayed packet');
    _seen.removeWhere((_, t) => now! - t > windowS);
    _seen[k] = packet.timestamp;
  }
}
