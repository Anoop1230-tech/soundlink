/// Talks to the SoundBank demo server (backend/). Every request is signed
/// with the device key (same scheme as backend/soundbank/auth.py).
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:http/http.dart' as http;

import '../engine/engine.dart';

class BankException implements Exception {
  final String message;
  BankException(this.message);
  @override
  String toString() => message;
}

class SyncResult {
  final String status; // settled, duplicate, settled_fraud, rejected
  final String? reason;
  SyncResult(this.status, this.reason);
}

class BankClient {
  final Uri base;
  final Identity identity;
  final http.Client _http;

  BankClient(String url, this.identity, {http.Client? client})
      : base = Uri.parse(url.endsWith('/') ? url.substring(0, url.length - 1) : url),
        _http = client ?? http.Client();

  Future<Map<String, dynamic>> _call(String method, String path, [Map<String, dynamic>? body]) async {
    final bytes = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    final ts = unixNow().toString();
    final nonce = hexOf(randomBytes(8));
    final hash = hexOf((await Sha256().hash(bytes)).bytes);
    final msg = utf8.encode('SLAPI1\n$method\n$path\n$ts\n$nonce\n$hash');
    final headers = {
      'X-Key': hexOf(identity.publicKey),
      'X-Time': ts,
      'X-Nonce': nonce,
      'X-Sig': hexOf(await identity.sign(msg)),
      if (body != null) 'Content-Type': 'application/json',
    };
    final uri = base.replace(path: '${base.path}$path');
    http.Response r;
    try {
      r = method == 'GET'
          ? await _http.get(uri, headers: headers).timeout(const Duration(seconds: 15))
          : await _http.post(uri, headers: headers, body: bytes).timeout(const Duration(seconds: 15));
    } catch (e) {
      throw BankException('Cannot reach the bank at $base. Check the address and Wi-Fi.');
    }
    Map<String, dynamic> data;
    try {
      data = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw BankException('Bank sent a bad reply (${r.statusCode})');
    }
    if (r.statusCode >= 400) throw BankException(data['detail']?.toString() ?? 'error ${r.statusCode}');
    return data;
  }

  Future<Map<String, dynamic>> info() async {
    try {
      final r = await _http.get(base.replace(path: '${base.path}/bank')).timeout(const Duration(seconds: 10));
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw BankException('Cannot reach the bank at $base. Check the address and Wi-Fi.');
    }
  }

  Future<Map<String, dynamic>> register(String name) => _call('POST', '/register', {'name': name});
  Future<Map<String, dynamic>> account() => _call('GET', '/account');
  Future<Map<String, dynamic>> load(int amount, Map<String, int> state) =>
      _call('POST', '/wallet/load', {'amount': amount, 'state': state});
  Future<Map<String, dynamic>> unload(Map<String, int> state) => _call('POST', '/wallet/unload', {'state': state});

  Future<(List<SyncResult>, Map<String, dynamic>)> sync(List<List<int>> payments) async {
    final r = await _call('POST', '/merchant/sync', {'payments': payments.map(hexOf).toList()});
    final results = [
      for (final x in r['results'] as List) SyncResult(x['status'] as String, x['reason'] as String?),
    ];
    return (results, r);
  }
}
