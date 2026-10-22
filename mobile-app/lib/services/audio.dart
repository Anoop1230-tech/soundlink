/// Speaker and microphone for the engine.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../engine/engine.dart';
import 'fallback.dart';

class SoundPlayer {
  final AudioPlayer _player = AudioPlayer();

  /// Plays the samples and completes when playback ends.
  Future<void> play(Float32List audio, int sampleRate) async {
    // A WAV file is the most reliable way to get exact 48 kHz PCM out of
    // Android without the player resampling or compressing it.
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/soundlink_out.wav');
    await file.writeAsBytes(encodeWav(audio, sampleRate), flush: true);
    final done = _player.onPlayerComplete.first;
    await _player.stop();
    await _player.play(DeviceFileSource(file.path, mimeType: 'audio/wav'), volume: 1.0);
    await done.timeout(Duration(milliseconds: (audio.length / sampleRate * 1000).round() + 3000), onTimeout: () {});
  }

  /// Plays a built packet and remembers it, so it can be shown as QR or sent by Bluetooth if sound fails.
  Future<void> playPacket(SoundLink link, List<int> raw, {int repeat = 1}) {
    FallbackHub.instance.remember(raw);
    return play(link.encodeBytes(raw, repeat: repeat), link.sampleRate);
  }

  Future<void> stop() => _player.stop();

  void dispose() => _player.dispose();
}

/// Listens on the mic and feeds the engine. Emits decoded packets.
class SoundListener implements ChunkSink {
  SoundListener() {
    FallbackHub.instance.register(this);
  }

  final AudioRecorder _rec = AudioRecorder();
  // Collects chunks that come by QR / Bluetooth (kept across mic restarts so a
  // multi-QR packet can be scanned slowly).
  final Receiver _chunkRx = Receiver(profiles['normal']!);
  StreamSubscription<Uint8List>? _sub;
  Receiver? _receiver;
  final _out = StreamController<Received>.broadcast();
  final _level = StreamController<double>.broadcast();

  Stream<Received> get packets => _out.stream;

  /// Peak input level 0..1, about 10 times a second.
  Stream<double> get level => _level.stream;

  @override
  bool get listening => _sub != null;

  (int, int)? get progress => _receiver?.progress;

  Future<bool> hasPermission() => _rec.hasPermission();

  Future<void> start(Profile profile) async {
    await stop();
    if (!await _rec.hasPermission()) throw StateError('Microphone permission was denied');
    final receiver = _receiver = Receiver(profile);
    final pcm = Pcm16Decoder();
    final stream = await _rec.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: profile.sampleRate,
      numChannels: 1,
      // Phone "voice" processing (echo cancel, noise suppression, auto gain)
      // treats our tones as noise and removes them, so ask for raw audio.
      autoGain: false,
      echoCancel: false,
      noiseSuppress: false,
      androidConfig: const AndroidRecordConfig(audioSource: AndroidAudioSource.unprocessed),
    ));
    // Process chunks one at a time, in order.
    var chain = Future<void>.value();
    _sub = stream.listen((chunk) {
      final samples = pcm.convert(chunk);
      var peak = 0.0;
      for (final s in samples) {
        final a = s.abs();
        if (a > peak) peak = a;
      }
      _level.add(peak);
      chain = chain.then((_) async {
        for (final r in await receiver.feed(samples)) {
          _out.add(r);
        }
      });
    });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    if (await _rec.isRecording()) await _rec.stop();
    final r = _receiver;
    _receiver = null;
    if (r != null) {
      for (final x in await r.flush()) {
        _out.add(x);
      }
    }
  }

  @override
  Future<void> injectChunk(Uint8List chunk) async {
    for (final r in await _chunkRx.feedChunk(chunk)) {
      if (!_out.isClosed) _out.add(r);
    }
  }

  /// (got, total) of a multi-QR packet being scanned.
  (int, int)? get chunkProgress => _chunkRx.progress;

  Future<void> dispose() async {
    FallbackHub.instance.unregister(this);
    await stop();
    await _rec.dispose();
    await _out.close();
    await _level.close();
  }
}
