/// Reed-Solomon error correction, GF(2^8) with prim 0x11d, generator 2, fcr 0.
///
/// This is a direct port of the Python `reedsolo` library used by the core
/// engine, so both produce exactly the same parity bytes. Data is split into
/// 255-byte blocks (255 - nsym data bytes + nsym parity bytes each).
///
/// When a normal decode fails we retry with the least-confident bytes marked
/// as erasures, which lets RS fix up to 2x more errors (same as fec.py).
library;

import 'dart:typed_data';

const int rsBlock = 255;
const int _charac = 255;

class FecError implements Exception {
  final String message;
  FecError(this.message);
  @override
  String toString() => 'FecError: $message';
}

final Uint8List _exp = Uint8List(_charac * 2);
final Uint8List _log = Uint8List(_charac + 1);
bool _ready = false;

void _init() {
  if (_ready) return;
  var x = 1;
  for (var i = 0; i < _charac; i++) {
    _exp[i] = x;
    _log[x] = i;
    x <<= 1;
    if (x & 0x100 != 0) x ^= 0x11d;
  }
  for (var i = _charac; i < _charac * 2; i++) {
    _exp[i] = _exp[i - _charac];
  }
  _ready = true;
}

int _mul(int x, int y) => (x == 0 || y == 0) ? 0 : _exp[(_log[x] + _log[y]) % _charac];

int _div(int x, int y) {
  if (y == 0) throw FecError('division by zero');
  if (x == 0) return 0;
  return _exp[(_log[x] + _charac - _log[y]) % _charac];
}

int _pow(int x, int power) => _exp[(_log[x] * power) % _charac];

int _inverse(int x) => _exp[_charac - _log[x]];

List<int> _polyScale(List<int> p, int x) => [for (final c in p) _mul(c, x)];

List<int> _polyAdd(List<int> p, List<int> q) {
  final n = p.length > q.length ? p.length : q.length;
  final r = List<int>.filled(n, 0);
  for (var i = 0; i < p.length; i++) {
    r[i + n - p.length] = p[i];
  }
  for (var i = 0; i < q.length; i++) {
    r[i + n - q.length] ^= q[i];
  }
  return r;
}

List<int> _polyMul(List<int> p, List<int> q) {
  final r = List<int>.filled(p.length + q.length - 1, 0);
  for (var j = 0; j < q.length; j++) {
    if (q[j] == 0) continue;
    final lq = _log[q[j]];
    for (var i = 0; i < p.length; i++) {
      if (p[i] != 0) r[i + j] ^= _exp[_log[p[i]] + lq];
    }
  }
  return r;
}

int _polyEval(List<int> poly, int x) {
  var y = poly[0];
  for (var i = 1; i < poly.length; i++) {
    y = _mul(y, x) ^ poly[i];
  }
  return y;
}

final Map<int, List<int>> _genCache = {};

List<int> _generator(int nsym) => _genCache.putIfAbsent(nsym, () {
      var g = <int>[1];
      for (var i = 0; i < nsym; i++) {
        g = _polyMul(g, [1, _pow(2, i)]);
      }
      return g;
    });

int _ceilDiv(int a, int b) => (a + b - 1) ~/ b;

/// Length after encoding n bytes.
int encodedLen(int n, int nsym) => n + nsym * _ceilDiv(n, rsBlock - nsym);

List<int> _encodeBlock(List<int> msg, int nsym) {
  final gen = _generator(nsym);
  final out = List<int>.filled(msg.length + gen.length - 1, 0);
  out.setRange(0, msg.length, msg);
  for (var i = 0; i < msg.length; i++) {
    final coef = out[i];
    if (coef == 0) continue;
    final lcoef = _log[coef];
    for (var j = 1; j < gen.length; j++) {
      out[i + j] ^= _exp[lcoef + _log[gen[j]]];
    }
  }
  out.setRange(0, msg.length, msg);
  return out;
}

Uint8List rsEncode(List<int> data, int nsym) {
  _init();
  final out = BytesBuilder(copy: false);
  final k = rsBlock - nsym;
  for (var i = 0; i < data.length; i += k) {
    final end = i + k < data.length ? i + k : data.length;
    out.add(_encodeBlock(data.sublist(i, end), nsym));
  }
  return out.toBytes();
}

List<int> _syndromes(List<int> msg, int nsym) => [0, for (var i = 0; i < nsym; i++) _polyEval(msg, _pow(2, i))];

bool _allZero(List<int> s) => s.every((v) => v == 0);

List<int> _errataLocator(List<int> coefPos) {
  var loc = <int>[1];
  for (final i in coefPos) {
    loc = _polyMul(loc, _polyAdd([1], [_pow(2, i), 0]));
  }
  return loc;
}

List<int> _errorEvaluator(List<int> synd, List<int> errLoc, int nsym) {
  // (synd * errLoc) mod x^(nsym+1): keep the last nsym+1 coefficients.
  final prod = _polyMul(synd, errLoc);
  final keep = nsym + 1;
  return prod.length <= keep ? prod : prod.sublist(prod.length - keep);
}

List<int> _correctErrata(List<int> msgIn, List<int> synd, List<int> errPos) {
  final msg = List<int>.of(msgIn);
  final coefPos = [for (final p in errPos) msg.length - 1 - p];
  final errLoc = _errataLocator(coefPos);
  final errEval = _errorEvaluator(synd.reversed.toList(), errLoc, errLoc.length - 1).reversed.toList();

  final x = [for (final c in coefPos) _pow(2, -(_charac - c))];
  final e = List<int>.filled(msg.length, 0);
  for (var i = 0; i < x.length; i++) {
    final xiInv = _inverse(x[i]);
    var prime = 1;
    for (var j = 0; j < x.length; j++) {
      if (j != i) prime = _mul(prime, 1 ^ _mul(xiInv, x[j]));
    }
    if (prime == 0) throw FecError('could not find error locations');
    var y = _polyEval(errEval.reversed.toList(), xiInv);
    y = _mul(_pow(x[i], 1), y);
    e[errPos[i]] = _div(y, prime);
  }
  return _polyAdd(msg, e);
}

List<int> _errorLocator(List<int> synd, int nsym, int eraseCount) {
  var errLoc = <int>[1];
  var oldLoc = <int>[1];
  final shift = synd.length > nsym ? synd.length - nsym : 0;
  for (var i = 0; i < nsym - eraseCount; i++) {
    final k = i + shift;
    var delta = synd[k];
    for (var j = 1; j < errLoc.length; j++) {
      delta ^= _mul(errLoc[errLoc.length - 1 - j], synd[k - j]);
    }
    oldLoc = [...oldLoc, 0];
    if (delta != 0) {
      if (oldLoc.length > errLoc.length) {
        final newLoc = _polyScale(oldLoc, delta);
        oldLoc = _polyScale(errLoc, _inverse(delta));
        errLoc = newLoc;
      }
      errLoc = _polyAdd(errLoc, _polyScale(oldLoc, delta));
    }
  }
  var start = 0;
  while (start < errLoc.length && errLoc[start] == 0) {
    start++;
  }
  errLoc = errLoc.sublist(start);
  final errs = errLoc.length - 1;
  if ((errs - eraseCount) * 2 + eraseCount > nsym) throw FecError('too many errors to correct');
  return errLoc;
}

List<int> _findErrors(List<int> errLoc, int nmess) {
  final errs = errLoc.length - 1;
  final pos = <int>[];
  for (var i = 0; i < nmess; i++) {
    if (_polyEval(errLoc, _pow(2, i)) == 0) pos.add(nmess - 1 - i);
  }
  if (pos.length != errs) throw FecError('too many errors to correct');
  return pos;
}

List<int> _forneySyndromes(List<int> synd, List<int> pos, int nmess) {
  final f = synd.sublist(1);
  for (final p in pos) {
    final x = _pow(2, nmess - 1 - p);
    for (var j = 0; j < f.length - 1; j++) {
      f[j] = _mul(f[j], x) ^ f[j + 1];
    }
  }
  return f;
}

/// Returns (message, corrected count) for one block.
(List<int>, int) _correctBlock(List<int> block, int nsym, List<int> erasePos) {
  if (block.length > _charac) throw FecError('block too long');
  if (erasePos.length > nsym) throw FecError('too many erasures');
  final msg = List<int>.of(block);
  for (final p in erasePos) {
    msg[p] = 0;
  }
  var synd = _syndromes(msg, nsym);
  if (_allZero(synd)) return (msg.sublist(0, msg.length - nsym), erasePos.length);

  final fsynd = _forneySyndromes(synd, erasePos, msg.length);
  final errLoc = _errorLocator(fsynd, nsym, erasePos.length);
  final errPos = _findErrors(errLoc.reversed.toList(), msg.length);
  final all = [...erasePos, ...errPos];
  final fixed = _correctErrata(msg, synd, all);
  synd = _syndromes(fixed, nsym);
  if (!_allZero(synd)) throw FecError('could not correct message');
  return (fixed.sublist(0, fixed.length - nsym), all.length);
}

(List<int>, int) _decodeBlock(List<int> block, int nsym, List<double>? confidence) {
  try {
    return _correctBlock(block, nsym, const []);
  } on FecError {
    if (confidence == null) rethrow;
  } on RangeError {
    if (confidence == null) throw FecError('too many errors to correct');
  }
  final order = List<int>.generate(block.length, (i) => i)
    ..sort((a, b) {
      final c = confidence[a].compareTo(confidence[b]);
      return c != 0 ? c : a.compareTo(b); // stable, same order as Python's sorted()
    });
  // Never erase all parity bytes; keep some to check the result is real.
  final tries = <int>{nsym ~/ 4 < 1 ? 1 : nsym ~/ 4, nsym ~/ 2, (3 * nsym) ~/ 4}.toList()..sort();
  for (final k in tries) {
    try {
      return _correctBlock(block, nsym, order.sublist(0, k));
    } on FecError {
      continue;
    } on RangeError {
      continue;
    }
  }
  throw FecError('too many errors to correct');
}

/// Returns (original data, number of bytes that were corrected).
(Uint8List, int) rsDecode(List<int> data, int nsym, [List<double>? confidence]) {
  _init();
  if (confidence != null && confidence.length != data.length) {
    throw ArgumentError('confidence must have one value per byte');
  }
  final out = BytesBuilder(copy: false);
  var fixed = 0;
  for (var i = 0; i < data.length; i += rsBlock) {
    final end = i + rsBlock < data.length ? i + rsBlock : data.length;
    final (msg, n) = _decodeBlock(data.sublist(i, end), nsym, confidence?.sublist(i, end));
    out.add(msg);
    fixed += n;
  }
  return (out.toBytes(), fixed);
}
