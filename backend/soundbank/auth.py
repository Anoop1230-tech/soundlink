"""Every request is signed by the device key, so there are no passwords.

Headers:
    X-Key    hex public key (32 bytes)
    X-Time   unix time
    X-Nonce  16 random hex characters (two equal requests in the same second differ)
    X-Sig    hex Ed25519 signature of
             "SLAPI1\\n" + METHOD + "\\n" + PATH + "\\n" + X-Time + "\\n" + X-Nonce + "\\n" + sha256(body).hex()

A signature can be used only once and only within 5 minutes, so a recorded
request can't be sent again.
"""

from __future__ import annotations

import hashlib
import os

from fastapi import HTTPException, Request

from soundlink import crypto

MAX_SKEW_S = 300


def message(method: str, path: str, ts: str, nonce: str, body: bytes) -> bytes:
    return f"SLAPI1\n{method.upper()}\n{path}\n{ts}\n{nonce}\n{hashlib.sha256(body).hexdigest()}".encode()


def sign_headers(identity: crypto.Identity, method: str, path: str, body: bytes, ts: int,
                 nonce: str | None = None) -> dict[str, str]:
    nonce = nonce or os.urandom(8).hex()
    sig = identity.sign(message(method, path, str(ts), nonce, body))
    return {"X-Key": identity.public_key.hex(), "X-Time": str(ts), "X-Nonce": nonce, "X-Sig": sig.hex()}


async def verify_request(request: Request, db, now: int) -> str:
    """Returns the caller's hex public key or raises 401."""
    key, ts, nonce, sig = (request.headers.get(h, "") for h in ("X-Key", "X-Time", "X-Nonce", "X-Sig"))
    try:
        pub, sig_b, t = bytes.fromhex(key), bytes.fromhex(sig), int(ts)
    except ValueError:
        raise HTTPException(401, "missing or bad signature headers") from None
    if len(pub) != 32 or len(sig_b) != 64 or not 8 <= len(nonce) <= 64:
        raise HTTPException(401, "missing or bad signature headers")
    if abs(now - t) > MAX_SKEW_S:
        raise HTTPException(401, "request time is too far from server time (check the phone clock)")
    body = await request.body()
    if not crypto.verify(pub, message(request.method, request.url.path, ts, nonce, body), sig_b):
        raise HTTPException(401, "bad signature")
    with db.tx() as c:
        c.execute("DELETE FROM seen_sigs WHERE time < ?", (now - 2 * MAX_SKEW_S,))
        if c.execute("SELECT 1 FROM seen_sigs WHERE sig = ?", (sig,)).fetchone():
            raise HTTPException(401, "request was already used")
        c.execute("INSERT INTO seen_sigs (sig, time) VALUES (?, ?)", (sig, now))
    return pub.hex()
