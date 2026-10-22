/// Files on the phone: save a received offer, and share a big file over Wi-Fi.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../engine/engine.dart';

const int maxDownload = 200 * 1024 * 1024;

Future<Directory> receivedFolder() async {
  final d = Directory('${(await getApplicationDocumentsDirectory()).path}/received');
  await d.create(recursive: true);
  return d;
}

/// Downloads (link) or unpacks (inline) the file, checks size + sha256, saves it.
Future<File> saveOffer(FileOffer offer) async {
  Uint8List data;
  if (offer.mode == fileInline) {
    data = await offer.check(offer.data);
  } else {
    if (offer.size > maxDownload) throw PacketError('file is too big');
    final res = await http.get(Uri.parse(offer.url)).timeout(const Duration(minutes: 2));
    if (res.statusCode != 200) throw PacketError('download failed (${res.statusCode}). Is the sender still sharing?');
    data = await offer.check(res.bodyBytes);
  }
  final dir = await receivedFolder();
  final name = safeName(offer.name);
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name, ext = dot > 0 ? name.substring(dot) : '';
  var f = File('${dir.path}/$name');
  for (var n = 1; await f.exists(); n++) {
    f = File('${dir.path}/$stem ($n)$ext');
  }
  return f.writeAsBytes(data, flush: true);
}

/// The phone's address on the local Wi-Fi, or null if not on one.
Future<String?> localIp() async {
  for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in ni.addresses) {
      if (!a.isLoopback && (a.address.startsWith('192.168.') || a.address.startsWith('10.') || a.address.startsWith('172.'))) {
        return a.address;
      }
    }
  }
  return null;
}

/// Serves one file at a random path until stopped or the time runs out.
class FileShare {
  final String name;
  final Uint8List data;
  final String token = hexOf(randomBytes(16));
  final String host;
  late final HttpServer _server;
  Timer? _timer;
  int downloads = 0;

  FileShare._(this.name, this.data, this.host);

  static Future<FileShare> start(String name, Uint8List data, {Duration timeout = const Duration(minutes: 10)}) async {
    final ip = await localIp();
    if (ip == null) throw StateError('Connect to Wi-Fi (or turn on hotspot) to share big files');
    final s = FileShare._(safeName(name), data, ip);
    s._server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    s._server.listen(s._handle);
    s._timer = Timer(timeout, s.stop);
    return s;
  }

  String get url => 'http://$host:${_server.port}/f/$token/${Uri.encodeComponent(name)}';

  Future<FileOffer> offer(String mime) async =>
      FileOffer(fileLink, data.length, await sha256Of(data), name, mime: mime, url: url);

  void _handle(HttpRequest r) {
    if (r.method != 'GET' || r.uri.path != '/f/$token/${Uri.encodeComponent(name)}') {
      r.response.statusCode = 404;
      r.response.close();
      return;
    }
    downloads++;
    r.response.headers.contentLength = data.length;
    r.response.add(data);
    r.response.close();
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _server.close(force: true);
  }
}

String mimeOf(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return const {
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'png': 'image/png',
        'gif': 'image/gif',
        'pdf': 'application/pdf',
        'txt': 'text/plain',
        'mp3': 'audio/mpeg',
        'mp4': 'video/mp4',
        'zip': 'application/zip',
        'apk': 'application/vnd.android.package-archive',
        'doc': 'application/msword',
        'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      }[ext] ??
      'application/octet-stream';
}
