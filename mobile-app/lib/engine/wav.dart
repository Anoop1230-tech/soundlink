/// 16-bit mono WAV read/write, and PCM16 helpers for the mic stream.
library;

import 'dart:typed_data';

Uint8List encodeWav(Float32List audio, int sampleRate) {
  final n = audio.length;
  final b = ByteData(44 + n * 2);
  void str(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = (audio[i].clamp(-1.0, 1.0) * 32767).truncate();
    b.setInt16(44 + i * 2, v, Endian.little);
  }
  return b.buffer.asUint8List();
}

/// Returns (mono samples in -1..1, sample rate). Only 16-bit PCM.
(Float64List, int) decodeWav(Uint8List bytes) {
  final b = ByteData.sublistView(bytes);
  String tag(int off) => String.fromCharCodes(bytes.sublist(off, off + 4));
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') throw const FormatException('not a WAV file');
  var off = 12;
  int? rate, channels, bits;
  while (off + 8 <= bytes.length) {
    final id = tag(off);
    final size = b.getUint32(off + 4, Endian.little);
    final body = off + 8;
    if (id == 'fmt ') {
      channels = b.getUint16(body + 2, Endian.little);
      rate = b.getUint32(body + 4, Endian.little);
      bits = b.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (rate == null || channels == null || bits != 16) throw const FormatException('only 16-bit WAV is supported');
      final frames = size ~/ (2 * channels);
      final out = Float64List(frames);
      for (var i = 0; i < frames; i++) {
        var s = 0;
        for (var c = 0; c < channels; c++) {
          s += b.getInt16(body + (i * channels + c) * 2, Endian.little);
        }
        out[i] = s / channels / 32768.0;
      }
      return (out, rate);
    }
    off = body + size + (size & 1);
  }
  throw const FormatException('WAV has no data');
}

/// Turns little-endian PCM16 byte chunks (from the mic) into samples.
/// Keeps an odd leftover byte for the next chunk.
class Pcm16Decoder {
  int? _carry;

  Float64List convert(Uint8List chunk) {
    final bytes = _carry == null ? chunk : Uint8List.fromList([_carry!, ...chunk]);
    final n = bytes.length ~/ 2;
    _carry = bytes.length.isOdd ? bytes.last : null;
    final b = ByteData.sublistView(bytes);
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      out[i] = b.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }
}
