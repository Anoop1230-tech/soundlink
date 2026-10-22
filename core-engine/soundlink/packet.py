"""SoundLink packet format.

Every feature (payment, Wi-Fi share, attendance, ...) sends the same packet:

    | ver(1) | type(1) | flags(1) | msg_id(4) | timestamp(4) |   header, 11 bytes
    | body (N)                                              |   payload, maybe compressed / encrypted
    | signer public key(32) | signature(64)                 |   only if SIGNED
    | crc16(2)                                              |

- Compression: raw DEFLATE, only used when it makes the payload smaller.
- Encryption: XChaCha20-Poly1305. Body = nonce_extra(8) + ciphertext + MAC(16).
  The 24-byte nonce is header(11) + nonce_extra(8) + 5 zero bytes, and the
  header is also authenticated, so changing the header breaks decryption.
  Only 8 random bytes go on air instead of 24, because sound is slow.
- Signature: Ed25519 over header + body + signer public key.
"""

from __future__ import annotations

import os
import struct
import time
import zlib
from dataclasses import dataclass, field
from enum import IntEnum, IntFlag

from . import crypto
from .crc import crc16

VERSION = 1
HEADER = struct.Struct(">BBBII")
HEADER_SIZE = HEADER.size
NONCE_EXTRA_SIZE = 8
SIG_BLOCK_SIZE = crypto.PUBLIC_KEY_SIZE + crypto.SIGNATURE_SIZE
CRC_SIZE = 2
MAX_PAYLOAD = 4096


class PacketError(ValueError):
    pass


class PacketType(IntEnum):
    TEXT = 0x00
    PAYMENT_REQUEST = 0x01
    PAYMENT = 0x02
    PAYMENT_RECEIPT = 0x03
    WIFI = 0x10
    CONTACT = 0x11
    FILE_HANDSHAKE = 0x12
    ATTENDANCE = 0x20
    TICKET = 0x21
    DOOR_UNLOCK = 0x22
    AUTH_CHALLENGE = 0x30
    AUTH_RESPONSE = 0x31
    EMERGENCY = 0x40
    OFFER = 0x50
    SENSOR = 0x60


class Flags(IntFlag):
    NONE = 0
    COMPRESSED = 0x01
    ENCRYPTED = 0x02
    SIGNED = 0x04


KNOWN_FLAGS = Flags.COMPRESSED | Flags.ENCRYPTED | Flags.SIGNED


def _nonce(header: bytes, extra: bytes) -> bytes:
    return (header + extra).ljust(crypto.NONCE_SIZE, b"\x00")


def _compress(data: bytes) -> bytes:
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()


def _decompress(data: bytes) -> bytes:
    d = zlib.decompressobj(-15)
    try:
        out = d.decompress(data, MAX_PAYLOAD + 1)
    except zlib.error as exc:
        raise PacketError("bad compressed data") from exc
    if len(out) > MAX_PAYLOAD or d.unconsumed_tail:
        raise PacketError("payload too large")
    return out


@dataclass
class Packet:
    type: int
    payload: bytes = b""
    msg_id: int = field(default_factory=lambda: int.from_bytes(os.urandom(4), "big"))
    timestamp: int = field(default_factory=lambda: int(time.time()))
    # Filled in when a packet is parsed:
    flags: Flags = Flags.NONE
    signer: bytes | None = None

    @property
    def signed(self) -> bool:
        return self.signer is not None

    def to_bytes(
        self,
        sign_with: crypto.Identity | None = None,
        key: bytes | None = None,
        compress: bool = True,
    ) -> bytes:
        if len(self.payload) > MAX_PAYLOAD:
            raise PacketError(f"payload is larger than {MAX_PAYLOAD} bytes")

        flags = Flags.NONE
        body = bytes(self.payload)
        if compress and body:
            packed = _compress(body)
            if len(packed) < len(body):
                body = packed
                flags |= Flags.COMPRESSED
        if key is not None:
            flags |= Flags.ENCRYPTED
        if sign_with is not None:
            flags |= Flags.SIGNED

        header = HEADER.pack(VERSION, int(self.type), int(flags), self.msg_id, self.timestamp)
        if key is not None:
            extra = os.urandom(NONCE_EXTRA_SIZE)
            body = extra + crypto.encrypt(key, _nonce(header, extra), body, aad=header)

        data = header + body
        if sign_with is not None:
            data += sign_with.public_key
            data += sign_with.sign(data)

        self.flags = flags
        self.signer = sign_with.public_key if sign_with else None
        return data + crc16(data).to_bytes(CRC_SIZE, "big")

    @classmethod
    def from_bytes(cls, data: bytes, key: bytes | None = None) -> "Packet":
        if len(data) < HEADER_SIZE + CRC_SIZE:
            raise PacketError("packet too short")
        data, crc = data[:-CRC_SIZE], int.from_bytes(data[-CRC_SIZE:], "big")
        if crc16(data) != crc:
            raise PacketError("checksum mismatch")

        version, ptype, flags, msg_id, timestamp = HEADER.unpack_from(data)
        if version != VERSION:
            raise PacketError(f"unsupported version {version}")
        flags = Flags(flags)
        if flags & ~KNOWN_FLAGS:
            raise PacketError("unknown flags")

        header = data[:HEADER_SIZE]
        body = data[HEADER_SIZE:]
        signer = None
        if flags & Flags.SIGNED:
            if len(body) < SIG_BLOCK_SIZE:
                raise PacketError("packet too short for signature")
            signature = data[-crypto.SIGNATURE_SIZE :]
            signer = data[-SIG_BLOCK_SIZE : -crypto.SIGNATURE_SIZE]
            if not crypto.verify(signer, data[: -crypto.SIGNATURE_SIZE], signature):
                raise PacketError("bad signature")
            body = body[:-SIG_BLOCK_SIZE]

        if flags & Flags.ENCRYPTED:
            if key is None:
                raise PacketError("packet is encrypted, key needed")
            if len(body) < NONCE_EXTRA_SIZE + crypto.MAC_SIZE:
                raise PacketError("encrypted body too short")
            extra, ciphertext = body[:NONCE_EXTRA_SIZE], body[NONCE_EXTRA_SIZE:]
            try:
                body = crypto.decrypt(key, _nonce(header, extra), ciphertext, aad=header)
            except ValueError as exc:
                raise PacketError(str(exc)) from exc

        if flags & Flags.COMPRESSED:
            body = _decompress(body)
        elif len(body) > MAX_PAYLOAD:
            raise PacketError("payload too large")

        try:
            ptype = PacketType(ptype)
        except ValueError:
            pass  # keep unknown types as plain ints so newer senders still work
        return cls(ptype, body, msg_id, timestamp, flags, signer)


class ReplayGuard:
    """Rejects packets that are too old, from the future, or already seen.

    Anyone nearby can record the sound and play it again, so every receiver
    that acts on a packet (payment, door unlock, attendance) should use this.
    """

    def __init__(self, window_s: int = 120):
        self.window_s = window_s
        self._seen: dict[tuple[bytes, int], int] = {}

    def check(self, packet: Packet, now: float | None = None) -> None:
        now = int(time.time() if now is None else now)
        if abs(now - packet.timestamp) > self.window_s:
            raise PacketError("packet expired or clock is wrong")
        key = (packet.signer or b"", packet.msg_id)
        if key in self._seen:
            raise PacketError("replayed packet")
        self._seen = {k: t for k, t in self._seen.items() if now - t <= self.window_s}
        self._seen[key] = packet.timestamp
