/// Offline payments with dummy money. Port of core-engine/soundlink/payment.py
/// (see that file for the full explanation and wire formats).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;

import 'crypto.dart' as crypto;
import 'link.dart' show hexOf, bytesFromHex;
import 'packet.dart';

const int maxPayment = 50000; // Rs 500 per offline payment
const int maxWallet = 200000; // Rs 2000 in the offline wallet
const int noteMax = 40;
const int requestTtlS = 600;

const int certSize = 12 + crypto.signatureSize; // 76
const int paymentSize = certSize + 28; // 104
const int receiptSize = 28;

class PaymentError implements Exception {
  final String message;
  PaymentError(this.message);
  @override
  String toString() => message;
}

String rupees(int paise) => 'Rs ${paise ~/ 100}.${(paise % 100).toString().padLeft(2, '0')}';

Future<Uint8List> tagOf(List<int> publicKey) async {
  final h = await Sha256().hash([...utf8.encode('SLTAG'), ...publicKey]);
  return Uint8List.fromList(h.bytes.sublist(0, 8));
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _u32s(List<int> values) {
  final b = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    b.setUint32(i * 4, values[i]);
  }
  return b.buffer.asUint8List();
}

// ---------------------------------------------------------------- formats

class Cert {
  final int seq, limit, validUntil;
  final Uint8List bankSig;
  Cert(this.seq, this.limit, this.validUntil, List<int> bankSig) : bankSig = Uint8List.fromList(bankSig);

  static List<int> message(List<int> walletPub, int seq, int limit, int validUntil) =>
      [...utf8.encode('SLCERT1'), ...walletPub, ..._u32s([seq, limit, validUntil])];

  Future<bool> verify(List<int> bankPub, List<int> walletPub) =>
      crypto.verify(bankPub, message(walletPub, seq, limit, validUntil), bankSig);

  Uint8List toBytes() => Uint8List.fromList([..._u32s([seq, limit, validUntil]), ...bankSig]);

  static Cert fromBytes(List<int> data) {
    if (data.length != certSize) throw PacketError('bad certificate size');
    final b = ByteData.sublistView(Uint8List.fromList(data));
    return Cert(b.getUint32(0), b.getUint32(4), b.getUint32(8), data.sublist(12));
  }
}

class PaymentRequest {
  final int amount;
  final Uint8List nonce;
  final String note;
  PaymentRequest(this.amount, List<int> nonce, [this.note = '']) : nonce = Uint8List.fromList(nonce);

  Uint8List toBytes() {
    final n = utf8.encode(note.trim());
    if (n.length > noteMax) throw ArgumentError('note is longer than $noteMax bytes');
    if (amount <= 0 || amount > maxPayment) throw ArgumentError('amount must be between 1 paisa and ${rupees(maxPayment)}');
    return Uint8List.fromList([..._u32s([amount]), ...nonce, ...n]);
  }

  static PaymentRequest fromBytes(List<int> data) {
    if (data.length < 12 || data.length > 12 + noteMax) throw PacketError('bad payment request');
    final amount = ByteData.sublistView(Uint8List.fromList(data)).getUint32(0);
    try {
      return PaymentRequest(amount, data.sublist(4, 12), utf8.decode(data.sublist(12)));
    } on FormatException {
      throw PacketError('bad note');
    }
  }
}

class Payment {
  final Cert cert;
  final Uint8List merchantTag;
  final int amount, counter, spentAfter;
  final Uint8List nonce;
  Payment(this.cert, this.merchantTag, this.amount, this.counter, this.spentAfter, this.nonce);

  Uint8List toBytes() =>
      Uint8List.fromList([...cert.toBytes(), ...merchantTag, ..._u32s([amount, counter, spentAfter]), ...nonce]);

  static Payment fromBytes(List<int> data) {
    if (data.length != paymentSize) throw PacketError('bad payment size');
    final cert = Cert.fromBytes(data.sublist(0, certSize));
    final b = ByteData.sublistView(Uint8List.fromList(data), certSize);
    return Payment(
      cert,
      Uint8List.fromList(data.sublist(certSize, certSize + 8)),
      b.getUint32(8),
      b.getUint32(12),
      b.getUint32(16),
      Uint8List.fromList(data.sublist(certSize + 20)),
    );
  }
}

class Receipt {
  final Uint8List walletTag;
  final int seq, counter, amount;
  final Uint8List nonce;
  Receipt(this.walletTag, this.seq, this.counter, this.amount, this.nonce);

  Uint8List toBytes() => Uint8List.fromList([...walletTag, ..._u32s([seq, counter, amount]), ...nonce]);

  static Receipt fromBytes(List<int> data) {
    if (data.length != receiptSize) throw PacketError('bad receipt size');
    final b = ByteData.sublistView(Uint8List.fromList(data));
    return Receipt(Uint8List.fromList(data.sublist(0, 8)), b.getUint32(8), b.getUint32(12), b.getUint32(16),
        Uint8List.fromList(data.sublist(20)));
  }
}

Future<Payment> checkPaymentPacket(Packet packet, List<int> bankPub, {int? now}) async {
  if (packet.type != PacketType.payment) throw PaymentError('not a payment');
  if (packet.signer == null) throw PaymentError('payment is not signed');
  final p = Payment.fromBytes(packet.payload);
  if (!await p.cert.verify(bankPub, packet.signer!)) throw PaymentError('wallet certificate is not from the bank');
  if (p.amount <= 0 || p.amount > maxPayment) throw PaymentError('amount is above the offline limit');
  if (p.counter == 0 || p.spentAfter < p.amount || p.spentAfter > p.cert.limit) {
    throw PaymentError('payment is more than the wallet holds');
  }
  if (now != null && now > p.cert.validUntil) throw PaymentError('wallet certificate has expired');
  return p;
}

// ---------------------------------------------------------------- payer

class PendingPayment {
  final int counter, amount, time;
  final String note, merchant;
  PendingPayment(this.counter, this.amount, this.note, this.merchant, this.time);
  Map<String, dynamic> toJson() => {'counter': counter, 'amount': amount, 'note': note, 'merchant': merchant, 'time': time};
  static PendingPayment fromJson(Map<String, dynamic> j) =>
      PendingPayment(j['counter'], j['amount'], j['note'] ?? '', j['merchant'], j['time']);
}

/// Payer side. Save (toJson) after every change, before playing a payment.
class Wallet {
  final Uint8List bankPub;
  Cert? cert;
  int counter = 0;
  int spent = 0;
  Uint8List lastPayment = Uint8List(0);
  String lastMerchant = '';
  final List<PendingPayment> pending = [];

  Wallet(List<int> bankPub) : bankPub = Uint8List.fromList(bankPub);

  int get balance => cert == null ? 0 : cert!.limit - spent;

  Future<void> install(Cert c, List<int> walletPub) async {
    if (!await c.verify(bankPub, walletPub)) throw PaymentError('certificate is not from the bank');
    cert = c;
    counter = 0;
    spent = 0;
    lastPayment = Uint8List(0);
    lastMerchant = '';
  }

  void clear() {
    cert = null;
    counter = 0;
    spent = 0;
    lastPayment = Uint8List(0);
    lastMerchant = '';
  }

  Map<String, int> state() => {'seq': cert?.seq ?? 0, 'counter': counter, 'spent': spent};

  /// Checks a request and returns it, without spending anything (to show "Pay Rs X?").
  PaymentRequest check(Packet request, {int? now}) {
    now ??= unixNow();
    if (request.type != PacketType.paymentRequest || request.signer == null) {
      throw PaymentError('not a signed payment request');
    }
    final req = PaymentRequest.fromBytes(request.payload);
    final c = cert;
    if (c == null) throw PaymentError('wallet is empty, load money first');
    if (now > c.validUntil) throw PaymentError('wallet certificate expired, sync with the bank');
    if (req.amount <= 0 || req.amount > maxPayment) throw PaymentError('offline payments are limited to ${rupees(maxPayment)}');
    if (req.amount > balance) throw PaymentError('not enough money (${rupees(balance)} left)');
    return req;
  }

  /// Builds the signed payment and marks the money as spent. Save the wallet
  /// before playing the returned bytes.
  Future<Uint8List> pay(Packet request, crypto.Identity me, {int? now}) async {
    now ??= unixNow();
    final req = check(request, now: now);
    final payment = Payment(cert!, await tagOf(request.signer!), req.amount, counter + 1, spent + req.amount, req.nonce);
    final raw = await Packet(PacketType.payment, payment.toBytes()).toBytes(signWith: me, compress: false);
    counter = payment.counter;
    spent = payment.spentAfter;
    lastPayment = raw;
    lastMerchant = hexOf(request.signer!);
    pending.add(PendingPayment(payment.counter, req.amount, req.note, lastMerchant, now));
    return raw;
  }

  Future<Receipt> acceptReceipt(Packet packet, crypto.Identity me) async {
    if (packet.type != PacketType.paymentReceipt || packet.signer == null) throw PaymentError('not a signed receipt');
    final r = Receipt.fromBytes(packet.payload);
    if (!_eq(r.walletTag, await tagOf(me.publicKey)) || cert == null || r.seq != cert!.seq) {
      throw PaymentError('receipt is for another wallet');
    }
    final signer = hexOf(packet.signer!);
    final i = pending.indexWhere((p) => p.counter == r.counter && p.merchant == signer);
    if (i < 0 || pending[i].amount != r.amount) throw PaymentError('receipt does not match a payment');
    pending.removeAt(i);
    return r;
  }

  Map<String, dynamic> toJson() => {
        'bank_pub': hexOf(bankPub),
        'cert': cert == null ? null : hexOf(cert!.toBytes()),
        'counter': counter,
        'spent': spent,
        'last_payment': hexOf(lastPayment),
        'last_merchant': lastMerchant,
        'pending': pending.map((p) => p.toJson()).toList(),
      };

  static Wallet fromJson(Map<String, dynamic> j) {
    final w = Wallet(bytesFromHex(j['bank_pub']));
    if (j['cert'] != null) w.cert = Cert.fromBytes(bytesFromHex(j['cert']));
    w.counter = j['counter'] ?? 0;
    w.spent = j['spent'] ?? 0;
    w.lastPayment = bytesFromHex(j['last_payment'] ?? '');
    w.lastMerchant = j['last_merchant'] ?? '';
    w.pending.addAll(((j['pending'] ?? []) as List).map((e) => PendingPayment.fromJson(e as Map<String, dynamic>)));
    return w;
  }
}

// ---------------------------------------------------------------- merchant

class ReceivedPayment {
  final Uint8List raw;
  final String wallet; // hex
  final int seq, counter, amount, spentAfter, time;
  final String note;
  bool synced;
  String? status; // from the bank after sync

  ReceivedPayment(this.raw, this.wallet, this.seq, this.counter, this.amount, this.spentAfter, this.time, this.note,
      {this.synced = false, this.status});

  Map<String, dynamic> toJson() => {
        'raw': hexOf(raw),
        'wallet': wallet,
        'seq': seq,
        'counter': counter,
        'amount': amount,
        'spent_after': spentAfter,
        'time': time,
        'note': note,
        'synced': synced,
        'status': status,
      };

  static ReceivedPayment fromJson(Map<String, dynamic> j) => ReceivedPayment(bytesFromHex(j['raw']), j['wallet'], j['seq'],
      j['counter'], j['amount'], j['spent_after'], j['time'], j['note'] ?? '',
      synced: j['synced'] ?? false, status: j['status']);
}

class AcceptResult {
  final ReceivedPayment record;
  final Receipt receipt;
  final bool isNew;
  AcceptResult(this.record, this.receipt, this.isNew);
}

class Merchant {
  final Uint8List bankPub;
  final Map<String, Map<String, dynamic>> openRequests = {}; // nonce hex -> {amount, note, time}
  final List<ReceivedPayment> received = [];

  Merchant(List<int> bankPub) : bankPub = Uint8List.fromList(bankPub);

  PaymentRequest newRequest(int amount, {String note = '', int? now}) {
    now ??= unixNow();
    final req = PaymentRequest(amount, crypto.randomBytes(8), note);
    req.toBytes(); // validates
    _expire(now);
    openRequests[hexOf(req.nonce)] = {'amount': amount, 'note': note, 'time': now};
    return req;
  }

  void _expire(int now) => openRequests.removeWhere((_, v) => now - (v['time'] as int) > requestTtlS);

  Future<AcceptResult> accept(Packet packet, crypto.Identity me, Uint8List raw, {int? now}) async {
    now ??= unixNow();
    final p = await checkPaymentPacket(packet, bankPub, now: now);
    if (!_eq(p.merchantTag, await tagOf(me.publicKey))) throw PaymentError('payment is for another merchant');
    final wallet = hexOf(packet.signer!);
    final receipt = Receipt(await tagOf(packet.signer!), p.cert.seq, p.counter, p.amount, p.nonce);

    for (final r in received) {
      if (r.wallet != wallet || r.seq != p.cert.seq) continue;
      if (r.counter == p.counter) {
        if (_eq(r.raw, raw)) return AcceptResult(r, receipt, false);
        throw PaymentError('double spending: this wallet already used that payment number');
      }
      final (loSpent, hiSpent, hiAmount) =
          r.counter < p.counter ? (r.spentAfter, p.spentAfter, p.amount) : (p.spentAfter, r.spentAfter, r.amount);
      if (hiSpent - hiAmount < loSpent) throw PaymentError("double spending: wallet totals don't add up");
    }

    _expire(now);
    final key = hexOf(p.nonce);
    final req = openRequests[key];
    if (req == null) throw PaymentError('no open request for this payment (old or for someone else)');
    if (req['amount'] != p.amount) throw PaymentError('paid amount does not match the request');
    openRequests.remove(key);
    final rec = ReceivedPayment(raw, wallet, p.cert.seq, p.counter, p.amount, p.spentAfter, now, req['note'] ?? '');
    received.add(rec);
    return AcceptResult(rec, receipt, true);
  }

  Future<Uint8List> receiptPacket(Receipt r, crypto.Identity me) =>
      Packet(PacketType.paymentReceipt, r.toBytes()).toBytes(signWith: me, compress: false);

  List<ReceivedPayment> get unsynced => received.where((r) => !r.synced).toList();

  Map<String, dynamic> toJson() => {
        'bank_pub': hexOf(bankPub),
        'open_requests': openRequests,
        'received': received.map((r) => r.toJson()).toList(),
      };

  static Merchant fromJson(Map<String, dynamic> j) {
    final m = Merchant(bytesFromHex(j['bank_pub']));
    (j['open_requests'] as Map? ?? {}).forEach((k, v) => m.openRequests[k as String] = Map<String, dynamic>.from(v as Map));
    m.received.addAll(((j['received'] ?? []) as List).map((e) => ReceivedPayment.fromJson(e as Map<String, dynamic>)));
    return m;
  }
}

Future<Uint8List> requestPacket(PaymentRequest req, crypto.Identity me) =>
    Packet(PacketType.paymentRequest, req.toBytes()).toBytes(signWith: me, compress: false);
