// Separate file: widget tests block real HTTP, this one needs it.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:soundlink/engine/engine.dart';
import 'package:soundlink/services/files.dart';

void main() {
  test('phone file share serves exactly one file and the offer checks it', () async {
    final data = Uint8List.fromList(utf8.encode('hello from the phone ' * 500));
    FileShare share;
    try {
      share = await FileShare.start('../evil/notes.txt', data);
    } on StateError {
      markTestSkipped('no Wi-Fi address on this machine');
      return;
    }
    try {
      final offer = await FileOffer.fromBytes((await share.offer('text/plain')).toBytes());
      expect(offer.name, 'notes.txt');
      final got = await http.get(Uri.parse(offer.url.replaceFirst(share.host, '127.0.0.1')));
      expect(await offer.check(got.bodyBytes), data);
      expect(share.downloads, 1);
      final wrong = await http.get(Uri.parse(offer.url.replaceFirst(share.host, '127.0.0.1').replaceFirst(share.token, '0' * 32)));
      expect(wrong.statusCode, 404);
    } finally {
      await share.stop();
    }
  });
}
