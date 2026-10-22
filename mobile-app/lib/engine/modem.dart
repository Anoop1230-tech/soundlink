/// Sound modem: bytes <-> audio. Port of core-engine/soundlink/modem.py.
///
/// Multi-tone FSK: the band is split into `groups`, each group plays one of
/// 16 tones per symbol (4 bits per group). One frame on air:
///
///     [chirp preamble] [gap] [length block] [data block] [tail]
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'fec.dart' as fec;

const int tones = 16;
const int lenField = 2;
const int lenNsym = 6;
const int lenNsymDefault = lenNsym;
const int maxFrameData = 240;
const double skipFront = 0.20;
const double skipBack = 0.10;
const double fadeFrac = 0.05;
const double tailS = 0.05;
const int filterTaps = 255;

class Profile {
  final String name;
  final String label;
  final double baseFreq;
  final double spacing;
  final int groups;
  final double symbolS;
  final int nsym;
  final double preambleS;
  final double gapS;
  final int sampleRate;
  final double threshold;

  /// OFDM-DQPSK settings (null for MFSK profiles). See modem.py.
  final int? firstBin;
  final int carriers;
  final int fft;
  final int cp;
  final int maxFrame;

  const Profile(
    this.name,
    this.label, {
    required this.baseFreq,
    required this.spacing,
    required this.groups,
    required this.symbolS,
    required this.nsym,
    this.preambleS = 0.16,
    this.gapS = 0.03,
    this.sampleRate = 48000,
    this.threshold = 0.3,
    this.maxFrame = maxFrameData,
  })  : firstBin = null,
        carriers = 0,
        fft = 0,
        cp = 0;

  const Profile.ofdm(
    this.name,
    this.label, {
    required int this.firstBin,
    required this.carriers,
    this.fft = 1024,
    this.cp = 768,
    required this.nsym,
    this.preambleS = 0.16,
    this.gapS = 0.03,
    this.sampleRate = 48000,
    this.threshold = 0.3,
    this.maxFrame = 960,
  })  : baseFreq = 0,
        spacing = sampleRate / fft,
        groups = 0,
        symbolS = (fft + cp) / sampleRate;

  bool get isOfdm => firstBin != null;
  int get symbolLen => isOfdm ? fft + cp : (symbolS * sampleRate).round();
  int get numTones => groups * tones;
  int get bytesPerSymbol => carriers ~/ 4;
  double get lowFreq => isOfdm ? firstBin! * spacing : baseFreq;
  double get highFreq => isOfdm ? (firstBin! + carriers - 1) * spacing : baseFreq + spacing * (numTones - 1);
}

const Map<String, Profile> profiles = {
  'normal': Profile('normal', 'Normal (most reliable)',
      baseFreq: 1500, spacing: 62.5, groups: 4, symbolS: 0.048, nsym: 32),
  'fast': Profile('fast', 'Fast (quiet rooms)', baseFreq: 1500, spacing: 125, groups: 4, symbolS: 0.024, nsym: 32),
  'ultrasonic': Profile('ultrasonic', 'Ultrasonic (almost silent)',
      baseFreq: 18000, spacing: 62.5, groups: 2, symbolS: 0.048, nsym: 16),
  'turbo': Profile.ofdm('turbo', 'Turbo (10x faster, phones close)', firstBin: 43, carriers: 96, cp: 768, nsym: 64),
};

class Frame {
  final Uint8List data;
  final int start;
  final double score;
  final double quality;
  final int corrected;
  Frame(this.data, this.start, this.score, this.quality, this.corrected);
}

int _symbolsFor(int nbytes, int groups) => (nbytes * 2 + groups - 1) ~/ groups;

/// Bytes -> list of nibble values, padded to a whole number of symbols.
List<int> _bytesToValues(List<int> data, int groups) {
  final v = <int>[];
  for (final b in data) {
    v
      ..add(b >> 4)
      ..add(b & 0x0F);
  }
  while (v.length % groups != 0) {
    v.add(0);
  }
  return v;
}

Uint8List _valuesToBytes(List<int> values, int nbytes) {
  final out = Uint8List(nbytes);
  for (var i = 0; i < nbytes; i++) {
    out[i] = (values[2 * i] << 4) | values[2 * i + 1];
  }
  return out;
}

List<double> _byteConfidence(List<double> conf, int nbytes) =>
    [for (var i = 0; i < nbytes; i++) math.min(conf[2 * i], conf[2 * i + 1])];

/// Shift the value->tone mapping every symbol and group (see modem.py).
int _rotate(int value, int symbol, int group, int direction) =>
    (value + direction * (7 * symbol + 5 * group)) % tones;

List<double> _linspace(double a, double b, int n) =>
    n == 1 ? [a] : [for (var i = 0; i < n; i++) a + (b - a) * i / (n - 1)];

double _sinc(double x) => x == 0 ? 1.0 : math.sin(math.pi * x) / (math.pi * x);

Float64List _bandpassTaps(double low, double high, int sr) {
  const n = filterTaps;
  final taps = Float64List(n);
  for (var k = 0; k < n; k++) {
    final m = k - (n - 1) / 2;
    double lp(double fc) => 2 * fc / sr * _sinc(2 * fc / sr * m);
    final w = 0.42 - 0.5 * math.cos(2 * math.pi * k / (n - 1)) + 0.08 * math.cos(4 * math.pi * k / (n - 1));
    taps[k] = (lp(high) - lp(low)) * w;
  }
  return taps;
}

/// Streaming FIR band-pass filter.
class BandFilter {
  final Float64List taps;
  Float64List _state;

  BandFilter(Profile p)
      : taps = _bandpassTaps(
          math.max(50.0, p.lowFreq - 4 * p.spacing),
          math.min(p.sampleRate / 2 - 100, p.highFreq + 4 * p.spacing),
          p.sampleRate,
        ),
        _state = Float64List(filterTaps - 1);

  Float64List process(List<double> x) {
    final s = _state.length;
    final joined = Float64List(s + x.length)
      ..setRange(0, s, _state)
      ..setRange(s, s + x.length, x);
    _state = Float64List.sublistView(joined, joined.length - s);
    _state = Float64List.fromList(_state);
    final out = Float64List(x.length);
    final n = taps.length;
    for (var i = 0; i < x.length; i++) {
      var acc = 0.0;
      for (var j = 0; j < n; j++) {
        acc += joined[i + j] * taps[n - 1 - j];
      }
      out[i] = acc;
    }
    return out;
  }
}

/// Common interface for both modulations.
abstract class Modem {
  Profile get profile;
  double get volume;
  int get L;
  Float64List get chirp;
  int get gapLen;
  int get tailLen;
  int get leadLen;
  int get lenNsym;
  int get lenSymbols;
  int blockSymbols(int nbytes);
  Float32List encodeFrame(List<int> data);

  /// Demodulate [nbytes] bytes starting at sample [start]: (bytes, per-byte confidence).
  (Uint8List, List<double>) demodBlock(Float64List x, int start, int nbytes);

  int frameSymbols(int nbytes) => lenSymbols + blockSymbols(fec.encodedLen(nbytes, profile.nsym));
  double frameDuration(int nbytes) =>
      (chirp.length + gapLen + leadLen + frameSymbols(nbytes) * L + tailLen) / profile.sampleRate;

  factory Modem(Profile p, {double volume = 0.5}) => p.isOfdm ? OfdmModem(p, volume: volume) : FskModem(p, volume: volume);
}

Float64List makeChirp(Profile p) {
  final sr = p.sampleRate;
  final n = (p.preambleS * sr).toInt();
  final f0 = p.lowFreq - p.spacing, f1 = p.highFreq + p.spacing;
  final chirp = Float64List(n);
  for (var i = 0; i < n; i++) {
    final t = i / sr;
    chirp[i] = math.sin(2 * math.pi * (f0 * t + (f1 - f0) / (2 * p.preambleS) * t * t));
  }
  final taper = math.max(1, n ~/ 20);
  final tu = _linspace(0, 1, taper), td = _linspace(1, 0, taper);
  for (var i = 0; i < taper; i++) {
    chirp[i] *= tu[i];
    chirp[n - taper + i] *= td[i];
  }
  return chirp;
}

class FskModem implements Modem {
  @override
  final Profile profile;
  @override
  final double volume;
  @override
  late final int L;
  late final Float64List freqs;
  late final List<Float64List> _tones;
  @override
  late final Float64List chirp;
  @override
  late final int gapLen;
  @override
  late final int tailLen;
  @override
  int get leadLen => 0;
  @override
  int get lenNsym => lenNsymDefault;
  late final int _a0;
  late final int _a1;
  late final List<Float64List> _anaRe;
  late final List<Float64List> _anaIm;
  @override
  late final int lenSymbols;

  FskModem(this.profile, {this.volume = 0.5}) {
    if (!(volume > 0 && volume <= 1)) throw ArgumentError('volume must be in (0, 1]');
    final p = profile;
    final sr = p.sampleRate;
    L = p.symbolLen;
    if (p.highFreq + 2 * p.spacing >= sr / 2) throw ArgumentError('profile frequencies are above Nyquist');

    freqs = Float64List.fromList([for (var i = 0; i < p.numTones; i++) p.baseFreq + p.spacing * i]);
    final fade = math.max(1, (fadeFrac * L).toInt());
    final env = Float64List(L)..fillRange(0, L, 1.0);
    final up = _linspace(0, 1, fade), down = _linspace(1, 0, fade);
    for (var i = 0; i < fade; i++) {
      env[i] = up[i];
      env[L - fade + i] = down[i];
    }
    _tones = [
      for (final f in freqs)
        Float64List.fromList([for (var i = 0; i < L; i++) math.sin(2 * math.pi * f * (i / sr)) * env[i]]),
    ];

    chirp = makeChirp(p);
    gapLen = (p.gapS * sr).toInt();
    tailLen = (tailS * sr).toInt();

    _a0 = (skipFront * L).toInt();
    _a1 = L - (skipBack * L).toInt();
    final m = _a1 - _a0;
    final window = [for (var k = 0; k < m; k++) m == 1 ? 1.0 : 0.5 - 0.5 * math.cos(2 * math.pi * k / (m - 1))];
    _anaRe = [];
    _anaIm = [];
    for (final f in freqs) {
      final re = Float64List(m), im = Float64List(m);
      for (var k = 0; k < m; k++) {
        final ph = -2 * math.pi * f * (_a0 + k) / sr;
        re[k] = math.cos(ph) * window[k];
        im[k] = math.sin(ph) * window[k];
      }
      _anaRe.add(re);
      _anaIm.add(im);
    }
    lenSymbols = _symbolsFor(lenField + lenNsym, p.groups);
  }

  @override
  int blockSymbols(int nbytes) => _symbolsFor(nbytes, profile.groups);

  @override
  int frameSymbols(int nbytes) => lenSymbols + blockSymbols(fec.encodedLen(nbytes, profile.nsym));

  @override
  double frameDuration(int nbytes) =>
      (chirp.length + gapLen + frameSymbols(nbytes) * L + tailLen) / profile.sampleRate;

  @override
  (Uint8List, List<double>) demodBlock(Float64List x, int start, int nbytes) {
    final (values, conf) = demodulate(x, start, blockSymbols(nbytes));
    return (_valuesToBytes(values, nbytes), _byteConfidence(conf, nbytes));
  }

  void _writeSymbols(Float32List out, int offset, List<int> values) {
    final g = profile.groups;
    final count = values.length ~/ g;
    for (var s = 0; s < count; s++) {
      for (var group = 0; group < g; group++) {
        final tone = _tones[group * tones + _rotate(values[s * g + group], s, group, 1)];
        final base = offset + s * L;
        for (var i = 0; i < L; i++) {
          out[base + i] += tone[i] / g * volume;
        }
      }
    }
  }

  @override
  Float32List encodeFrame(List<int> data) {
    if (data.isEmpty || data.length > profile.maxFrame) {
      throw ArgumentError('frame data must be 1..${profile.maxFrame} bytes');
    }
    final g = profile.groups;
    final lenBlock = fec.rsEncode([data.length >> 8, data.length & 0xFF], lenNsym);
    final body = fec.rsEncode(data, profile.nsym);
    final lv = _bytesToValues(lenBlock, g), bv = _bytesToValues(body, g);
    final total = chirp.length + gapLen + (lv.length ~/ g + bv.length ~/ g) * L + tailLen;
    final out = Float32List(total);
    for (var i = 0; i < chirp.length; i++) {
      out[i] = chirp[i] * volume;
    }
    var pos = chirp.length + gapLen;
    // Each block is modulated on its own so its tone rotation starts at 0.
    _writeSymbols(out, pos, lv);
    pos += lv.length ~/ g * L;
    _writeSymbols(out, pos, bv);
    return out;
  }

  // ---------- receiving ----------

  /// Returns (values, confidence), flattened symbol by symbol, group by group.
  (List<int>, List<double>) demodulate(Float64List x, int start, int count) {
    final g = profile.groups;
    final m = _a1 - _a0;
    final values = List<int>.filled(count * g, 0);
    final conf = List<double>.filled(count * g, 0);
    final mags = Float64List(tones);
    for (var s = 0; s < count; s++) {
      final base = start + s * L + _a0;
      for (var group = 0; group < g; group++) {
        for (var t = 0; t < tones; t++) {
          final re = _anaRe[group * tones + t], im = _anaIm[group * tones + t];
          var sr = 0.0, si = 0.0;
          for (var k = 0; k < m; k++) {
            final v = x[base + k];
            sr += v * re[k];
            si += v * im[k];
          }
          mags[t] = math.sqrt(sr * sr + si * si);
        }
        var best = 0;
        for (var t = 1; t < tones; t++) {
          if (mags[t] > mags[best]) best = t;
        }
        var second = -1.0;
        for (var t = 0; t < tones; t++) {
          if (t != best && mags[t] > second) second = mags[t];
        }
        values[s * g + group] = _rotate(best, s, group, -1);
        conf[s * g + group] = mags[best] / (second + 1e-12);
      }
    }
    return (values, conf);
  }
}

// ---------- OFDM-DQPSK (turbo) ----------

const gray = [0, 1, 3, 2];
const refSeed = 0x51D0F00D;
const whitenSeed = 0x0BADC0DE;
const ofdmRms = 0.30;
const guard = 64;

/// xorshift32, the same in Python, Dart and C.
Uint8List pnBytes(int seed, int n) {
  final out = Uint8List(n);
  var x = seed & 0xFFFFFFFF;
  for (var i = 0; i < n; i++) {
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    out[i] = x & 0xFF;
  }
  return out;
}

class OfdmModem implements Modem {
  @override
  final Profile profile;
  @override
  final double volume;
  @override
  late final int L;
  @override
  late final Float64List chirp;
  @override
  late final int gapLen;
  @override
  late final int tailLen;
  @override
  late final int leadLen;
  @override
  late final int lenNsym;
  @override
  late final int lenSymbols;
  late final List<int> ref;
  late final Float64List _cos; // cos(2*pi*j/fft)
  late final Float64List _sin;

  OfdmModem(this.profile, {this.volume = 0.5}) {
    final p = profile;
    if (!(volume > 0 && volume <= 1)) throw ArgumentError('volume must be in (0, 1]');
    if (p.carriers % 4 != 0 || p.cp <= guard || p.highFreq + 2 * p.spacing >= p.sampleRate / 2) {
      throw ArgumentError('bad OFDM profile');
    }
    L = p.fft + p.cp;
    chirp = makeChirp(p);
    gapLen = (p.gapS * p.sampleRate).toInt();
    tailLen = (tailS * p.sampleRate).toInt();
    leadLen = L;
    lenNsym = p.bytesPerSymbol - lenField;
    ref = [for (final b in pnBytes(refSeed, p.carriers)) b & 3];
    _cos = Float64List(p.fft);
    _sin = Float64List(p.fft);
    for (var j = 0; j < p.fft; j++) {
      _cos[j] = math.cos(2 * math.pi * j / p.fft);
      _sin[j] = math.sin(2 * math.pi * j / p.fft);
    }
    lenSymbols = blockSymbols(lenField + lenNsym);
  }

  @override
  int blockSymbols(int nbytes) => (nbytes + profile.bytesPerSymbol - 1) ~/ profile.bytesPerSymbol;

  @override
  int frameSymbols(int nbytes) => lenSymbols + blockSymbols(fec.encodedLen(nbytes, profile.nsym));

  @override
  double frameDuration(int nbytes) =>
      (chirp.length + gapLen + leadLen + frameSymbols(nbytes) * L + tailLen) / profile.sampleRate;

  List<List<int>> _blockPhases(List<int> data, List<int> phases) {
    final k = profile.carriers;
    final w = pnBytes(whitenSeed, data.length);
    final dib = <int>[];
    for (var i = 0; i < data.length; i++) {
      final b = data[i] ^ w[i];
      dib..add((b >> 6) & 3)..add((b >> 4) & 3)..add((b >> 2) & 3)..add(b & 3);
    }
    while (dib.length % k != 0) {
      dib.add(0);
    }
    final out = <List<int>>[];
    var ph = phases;
    for (var s = 0; s < dib.length; s += k) {
      ph = [for (var c = 0; c < k; c++) (ph[c] + gray[dib[s + c]]) % 4];
      out.add(ph);
    }
    return out;
  }

  /// x[n] = sum_c cos(2*pi*bin_c*n/fft + pi/2*phase_c), n = -cp .. fft-1.
  void _symbol(List<int> phases, Float64List out, int offset) {
    final p = profile, n0 = p.fft;
    for (var c = 0; c < p.carriers; c++) {
      final bin = p.firstBin! + c;
      // cos(a + q*pi/2) = cos(a), -sin(a), -cos(a), sin(a) for q = 0..3
      final q = phases[c];
      for (var i = 0; i < L; i++) {
        final j = ((i - p.cp) * bin) % n0;
        final idx = j < 0 ? j + n0 : j;
        out[offset + i] += switch (q) { 0 => _cos[idx], 1 => -_sin[idx], 2 => -_cos[idx], _ => _sin[idx] };
      }
    }
  }

  @override
  Float32List encodeFrame(List<int> data) {
    final p = profile;
    if (data.isEmpty || data.length > p.maxFrame) throw ArgumentError('frame data must be 1..${p.maxFrame} bytes');
    final lenBlock = fec.rsEncode([data.length >> 8, data.length & 0xFF], lenNsym);
    final body = fec.rsEncode(data, p.nsym);
    final phases = <List<int>>[ref];
    phases.addAll(_blockPhases(lenBlock, phases.last));
    phases.addAll(_blockPhases(body, phases.last));
    final sig = Float64List(phases.length * L);
    for (var s = 0; s < phases.length; s++) {
      _symbol(phases[s], sig, s * L);
    }
    var pow = 0.0;
    for (final v in sig) {
      pow += v * v;
    }
    final scale = ofdmRms / math.sqrt(pow / sig.length);
    final out = Float32List(chirp.length + gapLen + sig.length + tailLen);
    for (var i = 0; i < chirp.length; i++) {
      out[i] = chirp[i] * volume;
    }
    final o = chirp.length + gapLen;
    for (var i = 0; i < sig.length; i++) {
      out[o + i] = (sig[i] * scale).clamp(-1.0, 1.0) * volume;
    }
    return out;
  }

  /// Spectrum of one symbol at the data bins, corrected to symbol-start phase.
  (Float64List, Float64List) _spectrum(Float64List x, int symStart) {
    final p = profile;
    final off = p.cp - guard;
    final re = Float64List(p.fft), im = Float64List(p.fft);
    re.setRange(0, p.fft, x, symStart + off);
    _fft(re, im, false);
    final yr = Float64List(p.carriers), yi = Float64List(p.carriers);
    for (var c = 0; c < p.carriers; c++) {
      final bin = p.firstBin! + c;
      // multiply by exp(2j*pi*bin*(off-cp)/fft)
      final a = 2 * math.pi * bin * (off - p.cp) / p.fft;
      final cr = math.cos(a), ci = math.sin(a);
      yr[c] = re[bin] * cr - im[bin] * ci;
      yi[c] = re[bin] * ci + im[bin] * cr;
    }
    return (yr, yi);
  }

  @override
  (Uint8List, List<double>) demodBlock(Float64List x, int start, int nbytes) {
    final p = profile, k = p.carriers;
    final count = blockSymbols(nbytes);
    var (pr, pi) = _spectrum(x, start - L);
    final dib = <int>[];
    final conf = <double>[];
    for (var s = 0; s < count; s++) {
      final (cr, ci) = _spectrum(x, start + s * L);
      final zr = Float64List(k), zi = Float64List(k), mag = Float64List(k);
      for (var c = 0; c < k; c++) {
        zr[c] = cr[c] * pr[c] + ci[c] * pi[c];
        zi[c] = ci[c] * pr[c] - cr[c] * pi[c];
        mag[c] = math.sqrt(zr[c] * zr[c] + zi[c] * zi[c]);
      }
      final sorted = List<double>.of(mag)..sort();
      final med = sorted.length.isOdd ? sorted[k ~/ 2] : (sorted[k ~/ 2 - 1] + sorted[k ~/ 2]) / 2;
      for (var c = 0; c < k; c++) {
        final ang = math.atan2(zi[c], zr[c]);
        var q = (ang / (math.pi / 2)).round() % 4;
        if (q < 0) q += 4;
        var e = ang - q * math.pi / 2;
        e = math.atan2(math.sin(e), math.cos(e)).abs();
        final rel = math.min(1.0, mag[c] / (med + 1e-12));
        dib.add(gray[q]);
        conf.add(((math.pi / 4 - e) / (math.pi / 4)) * rel);
      }
      pr = cr;
      pi = ci;
    }
    final w = pnBytes(whitenSeed, nbytes);
    final out = Uint8List(nbytes);
    final bc = <double>[];
    for (var i = 0; i < nbytes; i++) {
      out[i] = ((dib[4 * i] << 6) | (dib[4 * i + 1] << 4) | (dib[4 * i + 2] << 2) | dib[4 * i + 3]) ^ w[i];
      bc.add(1.0 + [conf[4 * i], conf[4 * i + 1], conf[4 * i + 2], conf[4 * i + 3]].reduce(math.min));
    }
    return (out, bc);
  }
}

// ---------- FFT-based cross-correlation ----------

void _fft(Float64List re, Float64List im, bool inverse) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      var t = re[i];
      re[i] = re[j];
      re[j] = t;
      t = im[i];
      im[i] = im[j];
      im[j] = t;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = 2 * math.pi / len * (inverse ? 1 : -1);
    final wr = math.cos(ang), wi = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var k = 0; k < len ~/ 2; k++) {
        final a = i + k, b = a + len ~/ 2;
        final xr = re[b] * cr - im[b] * ci;
        final xi = re[b] * ci + im[b] * cr;
        re[b] = re[a] - xr;
        im[b] = im[a] - xi;
        re[a] += xr;
        im[a] += xi;
        final nr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = nr;
      }
    }
  }
  if (inverse) {
    for (var i = 0; i < n; i++) {
      re[i] /= n;
      im[i] /= n;
    }
  }
}

class _Correlator {
  final Float64List template;
  final Map<int, (Float64List, Float64List)> _cache = {};
  _Correlator(this.template);

  /// r[k] = sum(x[k+j] * template[j]) for every full overlap.
  Float64List run(Float64List x, int len) {
    final m = template.length;
    final n = len + m - 1;
    var nfft = 1;
    while (nfft < n) {
      nfft <<= 1;
    }
    final (tr, ti) = _cache.putIfAbsent(nfft, () {
      final r = Float64List(nfft)..setRange(0, m, template);
      final i = Float64List(nfft);
      _fft(r, i, false);
      return (r, i);
    });
    final re = Float64List(nfft)..setRange(0, len, x);
    final im = Float64List(nfft);
    _fft(re, im, false);
    for (var k = 0; k < nfft; k++) {
      // X * conj(T)
      final a = re[k], b = im[k];
      re[k] = a * tr[k] + b * ti[k];
      im[k] = b * tr[k] - a * ti[k];
    }
    _fft(re, im, true);
    return Float64List.sublistView(re, 0, len - m + 1);
  }
}

/// Growable sample buffer that can drop from the front cheaply.
class _Buffer {
  Float64List _data = Float64List(1 << 16);
  int _start = 0;
  int _end = 0;

  int get length => _end - _start;

  Float64List get view => Float64List.sublistView(_data, _start, _end);

  void add(Float64List x) {
    if (_end + x.length > _data.length) {
      final need = length + x.length;
      var cap = _data.length;
      while (cap < need * 2) {
        cap <<= 1;
      }
      final next = cap == _data.length ? _data : Float64List(cap);
      next.setRange(0, length, _data, _start);
      _data = next;
      _end = length;
      _start = 0;
    }
    _data.setRange(_end, _end + x.length, x);
    _end += x.length;
  }

  void drop(int n) => _start += n.clamp(0, length);
}

/// Streaming receiver. Feed it audio in any chunk size; it returns decoded frames.
class Demodulator {
  final Modem modem;
  final Profile profile;
  final double threshold;
  final BandFilter filter;
  final _Buffer _buf = _Buffer();
  int offset = 0;
  int errors = 0;
  (int, double)? _pending;
  late final int _lookahead;
  late final double _chirpNorm;
  late final _Correlator _corr;

  Demodulator(Profile p, {double? threshold})
      : modem = Modem(p),
        profile = p,
        threshold = threshold ?? p.threshold,
        filter = BandFilter(p) {
    _lookahead = (0.005 * p.sampleRate).toInt();
    var s = 0.0;
    for (final v in modem.chirp) {
      s += v * v;
    }
    _chirpNorm = math.sqrt(s);
    _corr = _Correlator(modem.chirp);
  }

  void _drop(int n) {
    final k = n.clamp(0, _buf.length);
    _buf.drop(k);
    offset += k;
  }

  (int, double)? _findPreamble() {
    final m = modem.chirp.length;
    final len = _buf.length;
    if (len < m + _lookahead) return null;
    final x = _buf.view;
    final corr = _corr.run(x, len);
    final nn = corr.length;
    // Running energy of each m-sample window.
    final csum = Float64List(len + 1);
    for (var i = 0; i < len; i++) {
      csum[i + 1] = csum[i] + x[i] * x[i];
    }
    double norm(int k) => corr[k] / (math.sqrt(math.max(csum[k + m] - csum[k], 0)) * _chirpNorm + 1e-9);

    var i = -1;
    for (var k = 0; k < nn; k++) {
      if (norm(k) > threshold) {
        i = k;
        break;
      }
    }
    if (i < 0) {
      _drop(nn - _lookahead);
      return null;
    }
    if (i + _lookahead >= nn) {
      _drop(i);
      return null;
    }
    var p = i;
    var best = norm(i);
    for (var k = i + 1; k < i + _lookahead; k++) {
      final v = norm(k);
      if (v > best) {
        best = v;
        p = k;
      }
    }
    return (p, best);
  }

  /// null = need more audio. Otherwise (frame or null on failure, samples consumed).
  (Frame?, int)? _tryDecode(int p, double score) {
    final mod = modem, prof = profile;
    final skipOnFail = p + mod.chirp.length;
    final ds = p + mod.chirp.length + mod.gapLen + mod.leadLen;
    final x = _buf.view;
    if (x.length < ds + mod.lenSymbols * mod.L) return null;
    final n = lenField + mod.lenNsym;
    int length;
    try {
      final (raw, conf) = mod.demodBlock(x, ds, n);
      final (lb, _) = fec.rsDecode(raw, mod.lenNsym, conf);
      length = (lb[0] << 8) | lb[1];
    } on fec.FecError {
      return (null, skipOnFail);
    }
    if (length <= 0 || length > prof.maxFrame) return (null, skipOnFail);

    final bodyLen = fec.encodedLen(length, prof.nsym);
    final nb = mod.blockSymbols(bodyLen);
    final end = ds + (mod.lenSymbols + nb) * mod.L;
    if (x.length < end) return null;
    final (raw, conf) = mod.demodBlock(x, ds + mod.lenSymbols * mod.L, bodyLen);
    try {
      final (data, corrected) = fec.rsDecode(raw, prof.nsym, conf);
      final sorted = List<double>.of(conf)..sort();
      final mid = sorted.length ~/ 2;
      final quality = sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
      return (Frame(data, offset + p, score, quality, corrected), end);
    } on fec.FecError {
      return (null, skipOnFail);
    }
  }

  List<Frame> feed(List<double> samples) {
    _buf.add(filter.process(samples));
    final frames = <Frame>[];
    while (true) {
      if (_pending == null) {
        _pending = _findPreamble();
        if (_pending == null) break;
      }
      final (p, score) = _pending!;
      final result = _tryDecode(p, score);
      if (result == null) break;
      final (frame, consumed) = result;
      _pending = null;
      if (frame == null) {
        errors++;
      } else {
        frames.add(frame);
      }
      _drop(consumed);
    }
    return frames;
  }

  /// Push silence through so the last frame in the buffer gets decoded.
  List<Frame> flush() => feed(Float64List(modem.chirp.length + filter.taps.length));
}
