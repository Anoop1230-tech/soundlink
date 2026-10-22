/// Splits packets that are too big for one sound frame into chunks and joins them back.
///
/// Chunk = transfer_id(2) | index(1) | total(1) | data
library;

import 'dart:typed_data';

import 'crypto.dart' show randomBytes;
import 'modem.dart' show maxFrameData;

const int chunkHeader = 4;
const int chunkData = maxFrameData - chunkHeader;
const int maxChunks = 255;

List<Uint8List> split(List<int> data, {int? transferId}) {
  if (data.isEmpty) throw ArgumentError('nothing to send');
  final total = (data.length + chunkData - 1) ~/ chunkData;
  if (total > maxChunks) throw ArgumentError('data too large (${data.length} bytes)');
  transferId ??= (randomBytes(2)[0] << 8) | randomBytes(1)[0];
  return [
    for (var i = 0; i < total; i++)
      Uint8List.fromList([
        transferId >> 8,
        transferId & 0xFF,
        i,
        total,
        ...data.sublist(i * chunkData, (i + 1) * chunkData < data.length ? (i + 1) * chunkData : data.length),
      ]),
  ];
}

class _Transfer {
  final int total;
  final Map<int, Uint8List> parts = {};
  final DateTime started = DateTime.now();
  _Transfer(this.total);
}

class Reassembler {
  final Duration timeout;
  final Map<int, _Transfer> _open = {};
  final Map<int, DateTime> _done = {};

  Reassembler({this.timeout = const Duration(seconds: 60)});

  /// Returns the full data when the last missing chunk arrives, else null.
  Uint8List? add(List<int> chunk) {
    if (chunk.length <= chunkHeader) return null;
    final tid = (chunk[0] << 8) | chunk[1];
    final index = chunk[2], total = chunk[3];
    if (total == 0 || index >= total) return null;
    final now = DateTime.now();
    _open.removeWhere((_, t) => now.difference(t.started) > timeout);
    _done.removeWhere((_, t) => now.difference(t) > timeout);
    if (_done.containsKey(tid)) return null;

    var t = _open[tid];
    if (t == null || t.total != total) t = _open[tid] = _Transfer(total);
    t.parts[index] = Uint8List.fromList(chunk.sublist(chunkHeader));
    if (t.parts.length < total) return null;

    _open.remove(tid);
    _done[tid] = now;
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < total; i++) {
      out.add(t.parts[i]!);
    }
    return out.toBytes();
  }

  /// (received, total) of the biggest unfinished transfer, for a progress bar.
  (int, int)? get progress {
    if (_open.isEmpty) return null;
    final t = _open.values.reduce((a, b) => a.total >= b.total ? a : b);
    return (t.parts.length, t.total);
  }
}
