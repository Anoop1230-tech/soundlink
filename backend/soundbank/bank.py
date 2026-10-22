"""Bank rules: loading the offline wallet, settling payments, catching double spending."""

from __future__ import annotations

import hashlib
import sqlite3

from soundlink.crypto import Identity
from soundlink.packet import Packet, PacketError
from soundlink.payment import (
    CERT_DAYS,
    MAX_WALLET,
    Cert,
    PaymentError,
    check_payment_packet,
    tag,
)

SIGNUP_BONUS = 100_000  # Rs 1000 of demo money for every new account


class BankError(Exception):
    def __init__(self, status: int, message: str, commit: bool = False):
        super().__init__(message)
        self.status = status
        self.message = message
        self.commit = commit  # keep the changes made so far (e.g. freezing a cheater)


def _account(c: sqlite3.Connection, pub: str) -> sqlite3.Row:
    row = c.execute("SELECT * FROM accounts WHERE pub = ?", (pub,)).fetchone()
    if row is None:
        raise BankError(404, "account not found, register first")
    return row


def _add(c: sqlite3.Connection, pub: str, delta: int, kind: str, note: str, now: int) -> None:
    c.execute("UPDATE accounts SET online = online + ? WHERE pub = ?", (delta, pub))
    c.execute("INSERT INTO ledger (pub, delta, kind, note, time) VALUES (?, ?, ?, ?, ?)", (pub, delta, kind, note, now))


def current_cert(c: sqlite3.Connection, pub: str) -> sqlite3.Row | None:
    return c.execute(
        "SELECT * FROM certs WHERE pub = ? AND cap_spent IS NULL ORDER BY seq DESC LIMIT 1", (pub,)
    ).fetchone()


def register(c: sqlite3.Connection, pub: str, name: str, now: int) -> bool:
    if c.execute("SELECT 1 FROM accounts WHERE pub = ?", (pub,)).fetchone():
        c.execute("UPDATE accounts SET name = ? WHERE pub = ?", (name, pub))
        return False
    c.execute("INSERT INTO accounts (pub, name, online, created) VALUES (?, ?, 0, ?)", (pub, name, now))
    _add(c, pub, SIGNUP_BONUS, "signup", "demo money", now)
    return True


def _settled_total(c: sqlite3.Connection, pub: str, seq: int) -> int:
    row = c.execute("SELECT COALESCE(SUM(amount), 0) FROM payments WHERE wallet = ? AND seq = ?", (pub, seq)).fetchone()
    return int(row[0])


def _charge_fraud(c: sqlite3.Connection, pub: str, amount: int, reason: str, now: int) -> None:
    """Freeze the wallet and take what it owes from its online balance."""
    acc = _account(c, pub)
    take = min(max(acc["online"], 0), amount)
    if take:
        _add(c, pub, -take, "fraud_recovery", reason, now)
    c.execute("UPDATE accounts SET frozen = 1, debt = debt + ? WHERE pub = ?", (amount - take, pub))


def _overspend(c: sqlite3.Connection, cert: sqlite3.Row) -> int:
    allowed = cert["lim"] if cert["cap_spent"] is None else cert["cap_spent"]
    return max(0, _settled_total(c, cert["pub"], cert["seq"]) - allowed)


def _retire(c: sqlite3.Connection, pub: str, state: dict, now: int) -> int:
    """Close the current certificate with what the wallet says it spent. Returns money left in it."""
    cert = current_cert(c, pub)
    if cert is None:
        if state.get("seq", 0) != 0:
            raise BankError(409, "wallet state does not match the bank (unknown certificate)")
        return 0
    seq, counter, spent = (int(state.get(k, -1)) for k in ("seq", "counter", "spent"))
    if seq != cert["seq"]:
        raise BankError(409, "wallet state does not match the bank (old certificate)")
    if not (0 <= spent <= cert["lim"] and counter >= 0):
        raise BankError(400, "bad wallet state")
    settled = _settled_total(c, pub, seq)
    max_counter = c.execute(
        "SELECT COALESCE(MAX(counter), 0) FROM payments WHERE wallet = ? AND seq = ?", (pub, seq)
    ).fetchone()[0]
    if settled > spent or max_counter > counter:
        # Merchants already showed us more spending than the wallet admits.
        _charge_fraud(c, pub, settled - spent if settled > spent else 0, "wallet reported less than it spent", now)
        c.execute("UPDATE certs SET cap_spent = ?, cap_counter = ? WHERE pub = ? AND seq = ?",
                  (settled, max_counter, pub, seq))
        raise BankError(409, "wallet reported less spending than merchants did; account frozen", commit=True)
    c.execute("UPDATE certs SET cap_spent = ?, cap_counter = ? WHERE pub = ? AND seq = ?", (spent, counter, pub, seq))
    return cert["lim"] - spent


def load(c: sqlite3.Connection, bank: Identity, pub: str, amount: int, state: dict, now: int) -> Cert:
    """Move money from online balance into a new offline certificate (amount can be 0 to just renew)."""
    acc = _account(c, pub)
    if acc["frozen"]:
        raise BankError(403, "account is frozen because of double spending")
    if amount < 0:
        raise BankError(400, "amount must not be negative")
    cert = current_cert(c, pub)
    left = (cert["lim"] - int(state.get("spent", 0))) if cert else 0
    if left + amount > MAX_WALLET:
        raise BankError(400, f"offline wallet can hold at most Rs {MAX_WALLET // 100}")
    if amount > acc["online"]:
        raise BankError(400, "not enough online balance")
    left = _retire(c, pub, state, now)
    limit = left + amount
    seq = (c.execute("SELECT COALESCE(MAX(seq), 0) FROM certs WHERE pub = ?", (pub,)).fetchone()[0]) + 1
    new = Cert.issue(bank, bytes.fromhex(pub), seq, limit, now + CERT_DAYS * 86400)
    c.execute("INSERT INTO certs (pub, seq, lim, valid_until, issued) VALUES (?, ?, ?, ?, ?)",
              (pub, seq, limit, new.valid_until, now))
    if amount:
        _add(c, pub, -amount, "load", f"to offline wallet #{seq}", now)
    return new


def unload(c: sqlite3.Connection, pub: str, state: dict, now: int) -> int:
    """Move what's left in the offline wallet back to the online balance."""
    _account(c, pub)
    left = _retire(c, pub, state, now)
    if left:
        _add(c, pub, left, "unload", "from offline wallet", now)
    return left


def settle(c: sqlite3.Connection, bank: Identity, merchant: str, raw_hex: str, now: int) -> dict:
    """Settle one payment heard by the merchant. Never raises; returns a status."""
    try:
        raw = bytes.fromhex(raw_hex)
        packet = Packet.from_bytes(raw)
        p = check_payment_packet(packet, bank.public_key)
    except (ValueError, PacketError, PaymentError) as exc:
        return {"status": "rejected", "reason": str(exc)}
    if p.merchant_tag != tag(bytes.fromhex(merchant)):
        return {"status": "rejected", "reason": "payment is for another merchant"}
    wallet = packet.signer.hex()
    cert = c.execute("SELECT * FROM certs WHERE pub = ? AND seq = ?", (wallet, p.cert.seq)).fetchone()
    if cert is None or cert["lim"] != p.cert.limit:
        return {"status": "rejected", "reason": "certificate unknown to the bank"}
    info = {"amount": p.amount, "wallet": wallet, "counter": p.counter, "seq": p.cert.seq}

    digest = hashlib.sha256(raw).hexdigest()
    if c.execute("SELECT 1 FROM payments WHERE digest = ?", (digest,)).fetchone():
        return {"status": "duplicate", **info}

    reasons = []
    others = c.execute("SELECT * FROM payments WHERE wallet = ? AND seq = ?", (wallet, p.cert.seq)).fetchall()
    for o in others:
        if o["counter"] == p.counter:
            reasons.append("same payment number used twice")
        elif o["counter"] < p.counter and p.spent_after - p.amount < o["spent_after"]:
            reasons.append("totals don't add up")
        elif o["counter"] > p.counter and o["spent_after"] - o["amount"] < p.spent_after:
            reasons.append("totals don't add up")
    if cert["cap_spent"] is not None and (p.spent_after > cert["cap_spent"] or p.counter > cert["cap_counter"]):
        reasons.append("payment made after the wallet was closed")

    before = _overspend(c, cert)
    c.execute(
        "INSERT INTO payments (wallet, seq, counter, amount, spent_after, merchant, digest, raw, fraud, received)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (wallet, p.cert.seq, p.counter, p.amount, p.spent_after, merchant, digest, raw, int(bool(reasons)), now),
    )
    # The merchant checked everything it could offline, so the bank pays it either way.
    payer_name = c.execute("SELECT name FROM accounts WHERE pub = ?", (wallet,)).fetchone()
    _add(c, merchant, p.amount, "received", f"from {payer_name['name'] if payer_name else wallet[:16]}", now)

    lost = _overspend(c, cert) - before
    if reasons or lost:
        _charge_fraud(c, wallet, lost, "; ".join(sorted(set(reasons))) or "spent more than loaded", now)
        return {"status": "settled_fraud", "reason": "; ".join(sorted(set(reasons))) or "overspent", **info}
    return {"status": "settled", **info}


def account_view(c: sqlite3.Connection, pub: str) -> dict:
    acc = _account(c, pub)
    cert = current_cert(c, pub)
    history = c.execute(
        "SELECT delta, kind, note, time FROM ledger WHERE pub = ? ORDER BY id DESC LIMIT 30", (pub,)
    ).fetchall()
    return {
        "name": acc["name"],
        "online": acc["online"],
        "frozen": bool(acc["frozen"]),
        "debt": acc["debt"],
        "cert": None if cert is None else {"seq": cert["seq"], "limit": cert["lim"], "valid_until": cert["valid_until"]},
        "history": [dict(h) for h in history],
    }
