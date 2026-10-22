/// Wallet (payer) + Merchant (shop) state and the bank connection.
///
/// The wallet is kept in secure storage and saved *before* a payment is
/// played, so a crash can't let the same money be spent twice.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/engine.dart';
import 'bank.dart';

class WalletStore extends ChangeNotifier {
  static const _walletKey = 'wallet_v1';
  static const _merchantKey = 'merchant_v1';

  final FlutterSecureStorage _secure;
  final SharedPreferences _prefs;
  final Identity identity;
  Wallet? wallet;
  Merchant? merchant;
  Map<String, dynamic>? account; // last reply from the bank
  String? lastError;
  bool busy = false;

  WalletStore._(this._secure, this._prefs, this.identity);

  static Future<WalletStore> open(Identity identity) async {
    final s = WalletStore._(const FlutterSecureStorage(), await SharedPreferences.getInstance(), identity);
    final w = await s._secure.read(key: _walletKey);
    if (w != null) s.wallet = Wallet.fromJson(jsonDecode(w) as Map<String, dynamic>);
    final m = await s._secure.read(key: _merchantKey);
    if (m != null) s.merchant = Merchant.fromJson(jsonDecode(m) as Map<String, dynamic>);
    final a = s._prefs.getString('bank_account');
    if (a != null) s.account = jsonDecode(a) as Map<String, dynamic>;
    return s;
  }

  // ---- settings ----

  String get bankUrl => _prefs.getString('bank_url') ?? '';
  String get bankPubHex => _prefs.getString('bank_pub') ?? '';
  String get name => _prefs.getString('bank_name') ?? '';
  bool get connected => bankPubHex.isNotEmpty && account != null;

  BankClient get bank {
    if (bankUrl.isEmpty) throw BankException('Set the bank address first');
    return BankClient(bankUrl, identity);
  }

  Future<void> saveWallet() async {
    if (wallet != null) await _secure.write(key: _walletKey, value: jsonEncode(wallet!.toJson()));
    notifyListeners();
  }

  Future<void> saveMerchant() async {
    if (merchant != null) await _secure.write(key: _merchantKey, value: jsonEncode(merchant!.toJson()));
    notifyListeners();
  }

  void _account(Map<String, dynamic> a) {
    account = a;
    _prefs.setString('bank_account', jsonEncode({...a}..remove('cert_hex')));
  }

  Future<T> _run<T>(Future<T> Function() fn) async {
    busy = true;
    lastError = null;
    notifyListeners();
    try {
      return await fn();
    } catch (e) {
      lastError = e.toString();
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Connect to a bank and create (or reuse) this device's account.
  Future<void> connect(String url, String name) => _run(() async {
        final client = BankClient(url.trim(), identity);
        final info = await client.info();
        final pub = info['public_key'] as String;
        if (bankPubHex.isNotEmpty && bankPubHex != pub) {
          final w = wallet;
          if (w != null && w.balance > 0) {
            throw BankException('This phone still has ${rupees(w.balance)} from another bank. Unload it there first.');
          }
          wallet = null;
          merchant = null;
          await _secure.delete(key: _walletKey);
          await _secure.delete(key: _merchantKey);
        }
        _account(await client.register(name.trim()));
        await _prefs.setString('bank_url', url.trim());
        await _prefs.setString('bank_pub', pub);
        await _prefs.setString('bank_name', name.trim());
        wallet ??= Wallet(bytesFromHex(pub));
        merchant ??= Merchant(bytesFromHex(pub));
        await saveWallet();
        await saveMerchant();
      });

  Future<void> refresh() => _run(() async => _account(await bank.account()));

  Future<void> load(int paise) => _run(() async {
        final w = wallet!;
        final r = await bank.load(paise, w.state());
        await w.install(Cert.fromBytes(bytesFromHex(r['cert_hex'] as String)), identity.publicKey);
        _account(r);
        await saveWallet();
      });

  Future<int> unload() => _run(() async {
        final w = wallet!;
        final r = await bank.unload(w.state());
        w.clear();
        _account(r);
        await saveWallet();
        return r['returned'] as int;
      });

  /// Send received payments to the bank. Returns (settled count, problems).
  Future<(int, List<String>)> sync() => _run(() async {
        final m = merchant!;
        final todo = m.unsynced;
        if (todo.isEmpty) {
          _account(await bank.account());
          return (0, <String>[]);
        }
        final (results, acc) = await bank.sync([for (final p in todo) p.raw]);
        final problems = <String>[];
        var ok = 0;
        for (var i = 0; i < todo.length && i < results.length; i++) {
          todo[i].synced = true;
          todo[i].status = results[i].status;
          if (results[i].status == 'settled' || results[i].status == 'duplicate') {
            ok++;
          } else if (results[i].status == 'settled_fraud') {
            ok++;
            problems.add('${rupees(todo[i].amount)}: paid, but the payer cheated (${results[i].reason})');
          } else {
            problems.add('${rupees(todo[i].amount)}: rejected (${results[i].reason})');
          }
        }
        _account(acc);
        await saveMerchant();
        return (ok, problems);
      });

  int get online => (account?['online'] as int?) ?? 0;
  bool get frozen => account?['frozen'] == true;
}
