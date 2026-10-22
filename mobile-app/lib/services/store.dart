/// Identity (in Android Keystore-backed secure storage), settings and history.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/engine.dart';

class HistoryItem {
  final bool sent;
  final int type;
  final Uint8List payload;
  final String? signer; // hex public key
  final DateTime time;
  final String profile;

  HistoryItem({
    required this.sent,
    required this.type,
    required this.payload,
    this.signer,
    required this.time,
    required this.profile,
  });

  Object? get item {
    try {
      return parsePayload(type, payload);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'sent': sent,
        'type': type,
        'payload': base64Encode(payload),
        'signer': signer,
        'time': time.millisecondsSinceEpoch,
        'profile': profile,
      };

  static HistoryItem fromJson(Map<String, dynamic> j) => HistoryItem(
        sent: j['sent'] as bool,
        type: j['type'] as int,
        payload: base64Decode(j['payload'] as String),
        signer: j['signer'] as String?,
        time: DateTime.fromMillisecondsSinceEpoch(j['time'] as int),
        profile: j['profile'] as String? ?? 'normal',
      );
}

class AppStore extends ChangeNotifier {
  static const _seedKey = 'identity_seed_v1';
  static const _historyKey = 'history_v1';
  static const maxHistory = 100;

  final FlutterSecureStorage _secure;
  final SharedPreferences _prefs;
  late Identity identity;
  final List<HistoryItem> history = [];

  AppStore._(this._secure, this._prefs);

  static Future<AppStore> open() async {
    final s = AppStore._(const FlutterSecureStorage(), await SharedPreferences.getInstance());
    await s._loadIdentity();
    s._loadHistory();
    return s;
  }

  Future<void> _loadIdentity() async {
    final hex = await _secure.read(key: _seedKey);
    if (hex != null && hex.length == 64) {
      identity = await Identity.fromSeed(bytesFromHex(hex));
    } else {
      identity = await Identity.generate();
      await _secure.write(key: _seedKey, value: hexOf(identity.seed));
    }
  }

  void _loadHistory() {
    final raw = _prefs.getString(_historyKey);
    if (raw == null) return;
    try {
      history.addAll((jsonDecode(raw) as List).map((e) => HistoryItem.fromJson(e as Map<String, dynamic>)));
    } catch (_) {
      // Ignore a broken history instead of crashing the app.
    }
  }

  Future<void> addHistory(HistoryItem item) async {
    history.insert(0, item);
    if (history.length > maxHistory) history.removeRange(maxHistory, history.length);
    await _prefs.setString(_historyKey, jsonEncode(history.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  Future<void> clearHistory() async {
    history.clear();
    await _prefs.remove(_historyKey);
    notifyListeners();
  }

  // ---- settings ----

  String get profileName => _prefs.getString('profile') ?? 'normal';
  Profile get profile => profiles[profileName] ?? profiles['normal']!;
  set profileName(String v) {
    _prefs.setString('profile', v);
    notifyListeners();
  }

  double get volume => _prefs.getDouble('volume') ?? 0.6;
  set volume(double v) {
    _prefs.setDouble('volume', v);
    notifyListeners();
  }

  int get repeat => _prefs.getInt('repeat') ?? 2;
  set repeat(int v) {
    _prefs.setInt('repeat', v);
    notifyListeners();
  }

  /// Public keys (hex) of authorities whose emergency alerts are shown as VERIFIED.
  Map<String, String> get trusted {
    final raw = _prefs.getString('trusted_v1');
    if (raw == null) return {};
    return Map<String, String>.from(jsonDecode(raw) as Map);
  }

  Future<void> trust(String keyHex, String name) async {
    await _prefs.setString('trusted_v1', jsonEncode({...trusted, keyHex: name}));
    notifyListeners();
  }

  Future<void> untrust(String keyHex) async {
    await _prefs.setString('trusted_v1', jsonEncode({...trusted}..remove(keyHex)));
    notifyListeners();
  }

  bool isTrusted(String? keyHex) => keyHex != null && trusted.containsKey(keyHex);

  /// "My card" that is pre-filled on the contact screen.
  Contact? get myCard {
    final raw = _prefs.getString('my_card');
    if (raw == null) return null;
    return Contact.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  set myCard(Contact? c) {
    if (c == null) {
      _prefs.remove('my_card');
    } else {
      _prefs.setString('my_card', jsonEncode(c.toJson()));
    }
    notifyListeners();
  }
}
