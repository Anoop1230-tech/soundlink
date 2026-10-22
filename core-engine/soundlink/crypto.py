"""Signing (Ed25519) and encryption (XChaCha20-Poly1305) helpers built on libsodium.

The same algorithms are used by the Flutter app (package:cryptography), so
packets made on a laptop can be read on a phone and the other way round.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import nacl.bindings as sodium
import nacl.pwhash
import nacl.utils
from nacl.exceptions import BadSignatureError, CryptoError
from nacl.signing import SigningKey, VerifyKey

PUBLIC_KEY_SIZE = 32
SIGNATURE_SIZE = 64
KEY_SIZE = sodium.crypto_aead_xchacha20poly1305_ietf_KEYBYTES
NONCE_SIZE = sodium.crypto_aead_xchacha20poly1305_ietf_NPUBBYTES
MAC_SIZE = sodium.crypto_aead_xchacha20poly1305_ietf_ABYTES

# PIN keys use Argon2id (t=2, m=16 MiB, p=1). 16 MiB keeps it fast on cheap
# phones. A short PIN is easy to brute force from a recording anyway, so PIN
# mode is only meant for low-value data like Wi-Fi sharing.
PIN_OPSLIMIT = 2
PIN_MEMLIMIT = 16 * 1024 * 1024
PIN_SALT = hashlib.sha256(b"soundlink-pin-v1").digest()[: nacl.pwhash.argon2id.SALTBYTES]


class Identity:
    """A device's signing key pair."""

    def __init__(self, signing_key: SigningKey):
        self._key = signing_key

    @classmethod
    def generate(cls) -> "Identity":
        return cls(SigningKey.generate())

    @classmethod
    def from_seed(cls, seed: bytes) -> "Identity":
        return cls(SigningKey(seed))

    @property
    def seed(self) -> bytes:
        return bytes(self._key)

    @property
    def public_key(self) -> bytes:
        return bytes(self._key.verify_key)

    def sign(self, data: bytes) -> bytes:
        return self._key.sign(data).signature

    def save(self, path: str | Path) -> None:
        # Prototype only: the seed is stored unencrypted. The app keeps it in Android Keystore.
        data = {"seed": self.seed.hex(), "public_key": self.public_key.hex()}
        Path(path).write_text(json.dumps(data, indent=2), encoding="utf-8")

    @classmethod
    def load(cls, path: str | Path) -> "Identity":
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        return cls.from_seed(bytes.fromhex(data["seed"]))


def fingerprint_hex(public_key: bytes) -> str:
    """Short id like "3fa9 01c2 77de 5b10" (same as the app shows)."""
    h = public_key[:8].hex()
    return " ".join(h[i : i + 4] for i in range(0, 16, 4))


def verify(public_key: bytes, data: bytes, signature: bytes) -> bool:
    try:
        VerifyKey(public_key).verify(data, signature)
        return True
    except (BadSignatureError, ValueError, TypeError):
        return False


def random_key() -> bytes:
    return nacl.utils.random(KEY_SIZE)


def key_from_pin(pin: str) -> bytes:
    return nacl.pwhash.argon2id.kdf(
        KEY_SIZE, pin.encode("utf-8"), PIN_SALT, opslimit=PIN_OPSLIMIT, memlimit=PIN_MEMLIMIT
    )


def encrypt(key: bytes, nonce: bytes, plaintext: bytes, aad: bytes = b"") -> bytes:
    """Returns ciphertext followed by a 16-byte MAC. The nonce is not included."""
    return sodium.crypto_aead_xchacha20poly1305_ietf_encrypt(plaintext, aad, nonce, key)


def decrypt(key: bytes, nonce: bytes, ciphertext: bytes, aad: bytes = b"") -> bytes:
    try:
        return sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(ciphertext, aad, nonce, key)
    except CryptoError as exc:
        raise ValueError("decryption failed (wrong key or data was changed)") from exc
