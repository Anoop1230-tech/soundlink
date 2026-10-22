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
  });

  int get symbolLen => (symbolS * sampleRate).round();
  int get numTones => groups * tones;
  double get lowFreq => baseFreq;
  double get highFreq => baseFreq + spacing * (numTones - 1);
}

const Map<String, Profile> profiles = {
  'normal': Profile('normal', 'Normal (most reliable)',
      baseFreq: 1500, spacing: 62.5, groups: 4, symbolS: 0.048, nsym: 32),
  'fast': Profile('fast', 'Fast (quiet rooms)', baseFreq: 1500, spacing: 125, groups: 4, symbolS: 0.024, nsym: 32),
  'ultrasonic': Profile('ultrasonic', 'Ultrasonic (almost silent)',
      baseFreq: 18000, spacing: 62.5, groups: 2, symbolS: 0.048, nsym: 16),
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

class Modem {
  final Profile profile;
  final double volume;
  late final int L;
  late final Float64List freqs;
  late final List<Float64List> _tones;
  late final Float64List chirp;
  late final int gapLen;
  late final int tailLen;
  late final int _a0;
  late final int _a1;
  late final List<Float64List> _anaRe;
  late final List<Float64List> _anaIm;
  late final int lenSymbols;

  Modem(this.profile, {this.volume = 0.5}) {
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

    final n = (p.preambleS * sr).toInt();
    final f0 = p.lowFreq - p.spacing, f1 = p.highFreq + p.spacing;
    chirp = Float64List(n);
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

  // ---------- sending ----------

  int frameSymbols(int nbytes) => lenSymbols + _symbolsFor(fec.encodedLen(nbytes, profile.nsym), profile.groups);

  double frameDuration(int nbytes) =>
      (chirp.length + gapLen + frameSymbols(nbytes) * L + tailLen) / profile.sampleRate;

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

  Float32List encodeFrame(List<int> data) {
    if (data.isEmpty || data.length > maxFrameData) {
      throw ArgumentError('frame data must be 1..$maxFrameData bytes');
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
    final ds = p + mod.chirp.length + mod.gapLen;
    final x = _buf.view;
    if (x.length < ds + mod.lenSymbols * mod.L) return null;
    var (values, conf) = mod.demodulate(x, ds, mod.lenSymbols);
    const n = lenField + lenNsym;
    int length;
    try {
      final (lb, _) = fec.rsDecode(_valuesToBytes(values, n), lenNsym, _byteConfidence(conf, n));
      length = (lb[0] << 8) | lb[1];
    } on fec.FecError {
      return (null, skipOnFail);
    }
    if (length <= 0 || length > maxFrameData) return (null, skipOnFail);

    final bodyLen = fec.encodedLen(length, prof.nsym);
    final nb = _symbolsFor(bodyLen, prof.groups);
    final end = ds + (mod.lenSymbols + nb) * mod.L;
    if (x.length < end) return null;
    (values, conf) = mod.demodulate(x, ds + mod.lenSymbols * mod.L, nb);
    try {
      final (data, corrected) = fec.rsDecode(_valuesToBytes(values, bodyLen), prof.nsym, _byteConfidence(conf, bodyLen));
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
