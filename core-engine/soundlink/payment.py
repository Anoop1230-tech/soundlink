"""Offline payments with dummy money.

How it works:

1. Online, the payer loads money into the offline wallet. The bank signs a
   small certificate: "wallet <public key> may spend up to <limit> with
   certificate number <seq>, until <date>".
2. Offline, the merchant plays a signed PAYMENT_REQUEST (amount + random nonce).
3. The payer's phone checks it, adds 1 to its counter, adds the amount to
   "spent so far", saves that, then plays a PAYMENT signed by the wallet key.
   The payment carries the bank certificate, so the merchant can check
   everything offline with only the bank's public key.
4. The merchant plays back a signed RECEIPT.
5. Later, whoever gets internet syncs. The bank settles payments and looks
   for double spending: two payments with the same counter, or more spent
   than the certificate allows. The merchant still gets paid (the bank
   guarantees payments that passed the offline checks), and the cheating
   wallet is frozen and owes the difference.

All amounts are in paise (1 rupee = 100 paise) as unsigned 32-bit numbers.

Wire formats (big endian), each one is the body of a SoundLink packet:

    CERT (76)        seq u32 | limit u32 | valid_until u32 | bank_sig(64)
                     bank signs "SLCERT1" + wallet_pub + seq + limit + valid_until
    PAYMENT_REQUEST  amount u32 | nonce(8) | note (UTF-8, up to 40 bytes)
                     signed by the merchant (packet signature)
    PAYMENT (104)    cert(76) | merchant_tag(8) | amount u32 | counter u32
                     | spent_after u32 | nonce(8)
                     signed by the wallet; the packet signer must be the cert's wallet
    PAYMENT_RECEIPT  wallet_tag(8) | seq u32 | counter u32 | amount u32 | nonce(8)
                     signed by the merchant

tag(key) = sha256("SLTAG" + public key)[:8], a short id so we don't send
another 32-byte key over slow sound.
"""

from __future__ import annotations

import hashlib
import os
import struct
import time
from dataclasses import asdict, dataclass, field

from . import crypto
from .crypto import Identity
from .packet import Packet, PacketError, PacketType

MAX_PAYMENT = 50_000  # Rs 500 per offline payment
MAX_WALLET = 200_000  # Rs 2000 in the offline wallet
CERT_DAYS = 30
NOTE_MAX = 40
REQUEST_TTL_S = 600  # merchant waits up to 10 minutes for a payment

_CERT = struct.Struct(">III")
CERT_SIZE = _CERT.size + crypto.SIGNATURE_SIZE
_PAY = struct.Struct(">8sIII8s")
PAYMENT_SIZE = CERT_SIZE + _PAY.size
_REQ = struct.Struct(">I8s")
_RCPT = struct.Struct(">8sIII8s")


class PaymentError(ValueError):
    pass


def tag(public_key: bytes) -> bytes:
    return hashlib.sha256(b"SLTAG" + public_key).digest()[:8]


def rupees(paise: int) -> str:
    return f"Rs {paise // 100}.{paise % 100:02d}"


# ---------------------------------------------------------------- formats


@dataclass(frozen=True)
class Cert:
    seq: int
    limit: int
    valid_until: int
    bank_sig: bytes

    @staticmethod
    def message(wallet_pub: bytes, seq: int, limit: int, valid_until: int) -> bytes:
        return b"SLCERT1" + wallet_pub + _CERT.pack(seq, limit, valid_until)

    @classmethod
    def issue(cls, bank: Identity, wallet_pub: bytes, seq: int, limit: int, valid_until: int) -> "Cert":
        return cls(seq, limit, valid_until, bank.sign(cls.message(wallet_pub, seq, limit, valid_until)))

    def verify(self, bank_pub: bytes, wallet_pub: bytes) -> bool:
        msg = self.message(wallet_pub, self.seq, self.limit, self.valid_until)
        return crypto.verify(bank_pub, msg, self.bank_sig)

    def to_bytes(self) -> bytes:
        return _CERT.pack(self.seq, self.limit, self.valid_until) + self.bank_sig

    @classmethod
    def from_bytes(cls, data: bytes) -> "Cert":
        if len(data) != CERT_SIZE:
            raise PacketError("bad certificate size")
        seq, limit, until = _CERT.unpack_from(data)
        return cls(seq, limit, until, bytes(data[_CERT.size :]))


@dataclass(frozen=True)
class PaymentRequest:
    amount: int
    nonce: bytes
    note: str = ""

    def to_bytes(self) -> bytes:
        note = self.note.strip().encode("utf-8")
        if len(note) > NOTE_MAX:
            raise ValueError(f"note is longer than {NOTE_MAX} bytes")
        if not 0 < self.amount <= MAX_PAYMENT:
            raise ValueError(f"amount must be between 1 paisa and {rupees(MAX_PAYMENT)}")
        return _REQ.pack(self.amount, self.nonce) + note

    @classmethod
    def from_bytes(cls, data: bytes) -> "PaymentRequest":
        if len(data) < _REQ.size or len(data) > _REQ.size + NOTE_MAX:
            raise PacketError("bad payment request")
        amount, nonce = _REQ.unpack_from(data)
        try:
            note = data[_REQ.size :].decode("utf-8")
        except UnicodeDecodeError as exc:
            raise PacketError("bad note") from exc
        return cls(amount, nonce, note)


@dataclass(frozen=True)
class Payment:
    cert: Cert
    merchant_tag: bytes
    amount: int
    counter: int
    spent_after: int
    nonce: bytes

    def to_bytes(self) -> bytes:
        return self.cert.to_bytes() + _PAY.pack(self.merchant_tag, self.amount, self.counter, self.spent_after, self.nonce)

    @classmethod
    def from_bytes(cls, data: bytes) -> "Payment":
        if len(data) != PAYMENT_SIZE:
            raise PacketError("bad payment size")
        cert = Cert.from_bytes(data[:CERT_SIZE])
        mtag, amount, counter, spent, nonce = _PAY.unpack_from(data, CERT_SIZE)
        return cls(cert, mtag, amount, counter, spent, nonce)


@dataclass(frozen=True)
class Receipt:
    wallet_tag: bytes
    seq: int
    counter: int
    amount: int
    nonce: bytes

    def to_bytes(self) -> bytes:
        return _RCPT.pack(self.wallet_tag, self.seq, self.counter, self.amount, self.nonce)

    @classmethod
    def from_bytes(cls, data: bytes) -> "Receipt":
        if len(data) != _RCPT.size:
            raise PacketError("bad receipt size")
        return cls(*_RCPT.unpack(data))


def check_payment_packet(packet: Packet, bank_pub: bytes, now: float | None = None) -> Payment:
    """Checks that can be done by anyone with the bank key (merchant offline, bank online)."""
    if packet.type != PacketType.PAYMENT:
        raise PaymentError("not a payment")
    if packet.signer is None:
        raise PaymentError("payment is not signed")
    p = Payment.from_bytes(packet.payload)
    if not p.cert.verify(bank_pub, packet.signer):
        raise PaymentError("wallet certificate is not from the bank")
    if not 0 < p.amount <= MAX_PAYMENT:
        raise PaymentError("amount is above the offline limit")
    if p.counter == 0 or p.spent_after < p.amount or p.spent_after > p.cert.limit:
        raise PaymentError("payment is more than the wallet holds")
    if now is not None and now > p.cert.valid_until:
        raise PaymentError("wallet certificate has expired")
    return p


# ---------------------------------------------------------------- payer


@dataclass
class Wallet:
    """Payer side. Save it (to_dict) after every change, before playing a payment."""

    bank_pub: bytes
    cert: Cert | None = None
    counter: int = 0  # payments made with the current certificate
    spent: int = 0  # total spent with the current certificate
    last_payment: bytes = b""  # raw packet, so it can be played again
    last_merchant: bytes = b""
    pending: list[dict] = field(default_factory=list)  # payments without a receipt yet

    @property
    def balance(self) -> int:
        return 0 if self.cert is None else self.cert.limit - self.spent

    def install(self, cert: Cert, wallet_pub: bytes) -> None:
        """Use a new certificate from the bank (after load or unload)."""
        if not cert.verify(self.bank_pub, wallet_pub):
            raise PaymentError("certificate is not from the bank")
        self.cert, self.counter, self.spent = cert, 0, 0
        self.last_payment, self.last_merchant = b"", b""

    def state(self) -> dict:
        """What the wallet reports to the bank before load / unload."""
        return {"seq": self.cert.seq if self.cert else 0, "counter": self.counter, "spent": self.spent}

    def pay(self, request: Packet, me: Identity, now: float | None = None) -> bytes:
        now = time.time() if now is None else now
        if request.type != PacketType.PAYMENT_REQUEST or request.signer is None:
            raise PaymentError("not a signed payment request")
        req = PaymentRequest.from_bytes(request.payload)
        if self.cert is None:
            raise PaymentError("wallet is empty, load money first")
        if now > self.cert.valid_until:
            raise PaymentError("wallet certificate expired, sync with the bank")
        if not 0 < req.amount <= MAX_PAYMENT:
            raise PaymentError(f"offline payments are limited to {rupees(MAX_PAYMENT)}")
        if req.amount > self.balance:
            raise PaymentError(f"not enough money ({rupees(self.balance)} left)")

        payment = Payment(self.cert, tag(request.signer), req.amount, self.counter + 1, self.spent + req.amount, req.nonce)
        raw = Packet(PacketType.PAYMENT, payment.to_bytes()).to_bytes(sign_with=me, compress=False)
        # Commit before the sound is played, so the same money can never be used twice.
        self.counter, self.spent = payment.counter, payment.spent_after
        self.last_payment, self.last_merchant = raw, request.signer
        self.pending.append({"counter": payment.counter, "amount": req.amount, "note": req.note,
                             "merchant": request.signer.hex(), "time": int(now)})
        return raw

    def accept_receipt(self, packet: Packet, me: Identity) -> Receipt:
        if packet.type != PacketType.PAYMENT_RECEIPT or packet.signer is None:
            raise PaymentError("not a signed receipt")
        r = Receipt.from_bytes(packet.payload)
        if r.wallet_tag != tag(me.public_key) or self.cert is None or r.seq != self.cert.seq:
            raise PaymentError("receipt is for another wallet")
        match = [p for p in self.pending if p["counter"] == r.counter and p["merchant"] == packet.signer.hex()]
        if not match or match[0]["amount"] != r.amount:
            raise PaymentError("receipt does not match a payment")
        self.pending.remove(match[0])
        return r

    def to_dict(self) -> dict:
        return {
            "bank_pub": self.bank_pub.hex(),
            "cert": self.cert.to_bytes().hex() if self.cert else None,
            "counter": self.counter,
            "spent": self.spent,
            "last_payment": self.last_payment.hex(),
            "last_merchant": self.last_merchant.hex(),
            "pending": self.pending,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "Wallet":
        return cls(
            bytes.fromhex(d["bank_pub"]),
            Cert.from_bytes(bytes.fromhex(d["cert"])) if d.get("cert") else None,
            d.get("counter", 0),
            d.get("spent", 0),
            bytes.fromhex(d.get("last_payment", "")),
            bytes.fromhex(d.get("last_merchant", "")),
            list(d.get("pending", [])),
        )


# ---------------------------------------------------------------- merchant


@dataclass
class Received:
    raw: bytes
    wallet: bytes
    seq: int
    counter: int
    amount: int
    spent_after: int
    time: int
    note: str = ""
    synced: bool = False


@dataclass
class Merchant:
    """Merchant side: makes requests, checks payments offline, keeps them for sync."""

    bank_pub: bytes
    open_requests: dict[str, dict] = field(default_factory=dict)  # nonce hex -> {amount, note, time}
    received: list[Received] = field(default_factory=list)

    def new_request(self, amount: int, note: str = "", now: float | None = None) -> PaymentRequest:
        now = time.time() if now is None else now
        req = PaymentRequest(amount, os.urandom(8), note)
        req.to_bytes()  # validates
        self._expire(now)
        self.open_requests[req.nonce.hex()] = {"amount": amount, "note": note, "time": int(now)}
        return req

    def _expire(self, now: float) -> None:
        self.open_requests = {k: v for k, v in self.open_requests.items() if now - v["time"] <= REQUEST_TTL_S}

    def accept(self, packet: Packet, me: Identity, raw: bytes, now: float | None = None) -> tuple[Received, Receipt, bool]:
        """Returns (record, receipt to play, is_new). Raises PaymentError if the payment is bad.

        raw: the packet bytes exactly as heard; they are sent to the bank later.
        """
        now = time.time() if now is None else now
        p = check_payment_packet(packet, self.bank_pub, now)
        if p.merchant_tag != tag(me.public_key):
            raise PaymentError("payment is for another merchant")
        wallet = packet.signer
        receipt = Receipt(tag(wallet), p.cert.seq, p.counter, p.amount, p.nonce)

        same = [r for r in self.received if r.wallet == wallet and r.seq == p.cert.seq and r.counter == p.counter]
        if same:
            if same[0].raw == raw:
                return same[0], receipt, False  # payer played it again because the receipt was lost
            raise PaymentError("double spending: this wallet already used that payment number")
        # Payments from one wallet must add up: a later counter can't have spent less.
        for r in self.received:
            if r.wallet == wallet and r.seq == p.cert.seq:
                lo, hi = (r, p) if r.counter < p.counter else (p, r)
                lo_spent = lo.spent_after
                hi_spent, hi_amount = hi.spent_after, hi.amount
                if hi_spent - hi_amount < lo_spent:
                    raise PaymentError("double spending: wallet totals don't add up")

        self._expire(now)
        req = self.open_requests.get(p.nonce.hex())
        if req is None:
            raise PaymentError("no open request for this payment (old or for someone else)")
        if req["amount"] != p.amount:
            raise PaymentError("paid amount does not match the request")
        del self.open_requests[p.nonce.hex()]
        rec = Received(raw, wallet, p.cert.seq, p.counter, p.amount, p.spent_after, int(now), req["note"])
        self.received.append(rec)
        return rec, receipt, True

    def receipt_packet(self, receipt: Receipt, me: Identity) -> bytes:
        return Packet(PacketType.PAYMENT_RECEIPT, receipt.to_bytes()).to_bytes(sign_with=me, compress=False)

    @property
    def unsynced(self) -> list[Received]:
        return [r for r in self.received if not r.synced]

    def to_dict(self) -> dict:
        return {
            "bank_pub": self.bank_pub.hex(),
            "open_requests": self.open_requests,
            "received": [{**asdict(r), "raw": r.raw.hex(), "wallet": r.wallet.hex()} for r in self.received],
        }

    @classmethod
    def from_dict(cls, d: dict) -> "Merchant":
        rec = [
            Received(**{**r, "raw": bytes.fromhex(r["raw"]), "wallet": bytes.fromhex(r["wallet"])})
            for r in d.get("received", [])
        ]
        return cls(bytes.fromhex(d["bank_pub"]), dict(d.get("open_requests", {})), rec)


def request_packet(req: PaymentRequest, me: Identity) -> bytes:
    return Packet(PacketType.PAYMENT_REQUEST, req.to_bytes()).to_bytes(sign_with=me, compress=False)
