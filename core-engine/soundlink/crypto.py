"""Signing (Ed25519) and encryption (XSalsa20-Poly1305) helpers built on libsodium."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import nacl.pwhash
import nacl.utils
from nacl.exceptions import BadSignatureError, CryptoError
from nacl.secret import SecretBox
from nacl.signing import SigningKey, VerifyKey

PUBLIC_KEY_SIZE = 32
SIGNATURE_SIZE = 64
KEY_SIZE = SecretBox.KEY_SIZE
NONCE_SIZE = SecretBox.NONCE_SIZE
MAC_SIZE = SecretBox.MACBYTES

# Fixed app-wide salt for PIN keys. A short PIN is easy to brute force from a
# recording, so PIN mode is only meant for low-value data like Wi-Fi sharing.
_PIN_SALT = hashlib.sha256(b"soundlink-pin-v1").digest()[: nacl.pwhash.argon2id.SALTBYTES]


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
    def public_key(self) -> bytes:
        return bytes(self._key.verify_key)

    def sign(self, data: bytes) -> bytes:
        return self._key.sign(data).signature

    def save(self, path: str | Path) -> None:
        # Prototype only: the seed is stored unencrypted. The app will use Android Keystore.
        data = {"seed": bytes(self._key).hex(), "public_key": self.public_key.hex()}
        Path(path).write_text(json.dumps(data, indent=2), encoding="utf-8")

    @classmethod
    def load(cls, path: str | Path) -> "Identity":
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        return cls.from_seed(bytes.fromhex(data["seed"]))


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
        KEY_SIZE,
        pin.encode("utf-8"),
        _PIN_SALT,
        opslimit=nacl.pwhash.argon2id.OPSLIMIT_INTERACTIVE,
        memlimit=nacl.pwhash.argon2id.MEMLIMIT_INTERACTIVE,
    )


def encrypt(key: bytes, nonce: bytes, plaintext: bytes) -> bytes:
    """Returns ciphertext with a 16-byte MAC. The nonce is not included."""
    return SecretBox(key).encrypt(plaintext, nonce).ciphertext


def decrypt(key: bytes, nonce: bytes, ciphertext: bytes) -> bytes:
    try:
        return SecretBox(key).decrypt(ciphertext, nonce)
    except CryptoError as exc:
        raise ValueError("decryption failed (wrong key or data was changed)") from exc
