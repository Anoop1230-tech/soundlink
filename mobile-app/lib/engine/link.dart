/// High-level API: packet -> sound -> packet.
library;

import 'dart:typed_data';

import 'crypto.dart';
import 'modem.dart';
import 'packet.dart';
import 'transport.dart' as transport;

/// Sender side.
class SoundLink {
  final Modem modem;
  final Identity? identity;
  final List<int>? key;

  SoundLink(Profile profile, {this.identity, this.key, double volume = 0.5})
      : modem = Modem(profile, volume: volume);

  int get sampleRate => modem.profile.sampleRate;

  Future<Float32List> encode(Packet packet, {bool sign = true, bool encrypt = true, int repeat = 1}) async {
    final data = await packet.toBytes(signWith: sign ? identity : null, key: encrypt ? key : null);
    return encodeBytes(data, repeat: repeat);
  }

  Float32List encodeBytes(List<int> data, {int repeat = 1}) {
    final frames = [for (final c in transport.split(data)) modem.encodeFrame(c)];
    final gap = (0.1 * sampleRate).toInt();
    final reps = repeat < 1 ? 1 : repeat;
    var total = 0;
    for (final f in frames) {
      total += f.length + gap;
    }
    final out = Float32List(total * reps);
    var pos = 0;
    for (var r = 0; r < reps; r++) {
      for (final f in frames) {
        out.setRange(pos, pos + f.length, f);
        pos += f.length + gap;
      }
    }
    return out;
  }
}

class Received {
  final Packet? packet;
  final String? error;
  final List<Frame> frames;
  final DateTime receivedAt;

  /// The raw packet, so it can be opened later (e.g. after asking for a PIN).
  final Uint8List data;
  final String profile;

  Received(this.packet, this.error, this.frames, this.data, this.profile) : receivedAt = DateTime.now();

  bool get ok => packet != null;

  /// Encrypted but we didn't have the key yet.
  bool get locked => packet == null && data.length > 2 && (data[2] & Flags.encrypted) != 0 && error!.contains('key needed');
}

/// Receiver side. Feed microphone audio, get packets back.
class Receiver {
  final Demodulator demod;
  List<int>? key;
  final Set<String>? trusted;
  final ReplayGuard? replayGuard;
  final transport.Reassembler _reassembler = transport.Reassembler();
  final List<Frame> _frames = [];

  /// trusted: hex public keys. If given, packets must be signed by one of them.
  Receiver(Profile profile, {this.key, this.trusted, this.replayGuard, double? threshold})
      : demod = Demodulator(profile, threshold: threshold);

  (int, int)? get progress => _reassembler.progress;

  Future<Received> _handle(Uint8List data) async {
    final frames = List<Frame>.of(_frames);
    _frames.clear();
    final name = demod.profile.name;
    try {
      final packet = await Packet.fromBytes(data, key: key);
      if (trusted != null && (packet.signer == null || !trusted!.contains(_hex(packet.signer!)))) {
        throw PacketError('sender is not trusted');
      }
      replayGuard?.check(packet);
      return Received(packet, null, frames, data, name);
    } on PacketError catch (e) {
      return Received(null, e.message, frames, data, name);
    }
  }

  Future<List<Received>> feed(List<double> samples) => _process(demod.feed(samples));

  Future<List<Received>> flush() => _process(demod.flush());

  Future<List<Received>> _process(List<Frame> frames) async {
    final out = <Received>[];
    for (final f in frames) {
      _frames.add(f);
      final data = _reassembler.add(f.data);
      if (data != null) out.add(await _handle(data));
    }
    return out;
  }
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

String hexOf(List<int> b) => _hex(b);

Uint8List bytesFromHex(String s) =>
    Uint8List.fromList([for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

/// Decode a whole recording at once.
Future<List<Received>> decodeAudio(List<double> audio, Profile profile, {List<int>? key, Set<String>? trusted}) async {
  final rx = Receiver(profile, key: key, trusted: trusted);
  return [...await rx.feed(audio), ...await rx.flush()];
}
