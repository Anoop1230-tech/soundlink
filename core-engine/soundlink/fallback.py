"""Fallbacks and testing (Phase 6).

QR fallback
    When sound doesn't work (very noisy room, broken speaker, deaf user...),
    the very same packet can be shown as QR codes and scanned with the camera.
    Each QR holds one transport chunk (same as one sound frame):

        "SL1:" + base64url(chunk)        chunk = transfer_id(2) | index(1) | total(1) | data

    Big packets become several QR codes that the sender shows one after the
    other; the scanner collects them in any order (transport.Reassembler).

TEST packets (type 0x70), to measure a real speaker + mic
    "SLT1" | profile u8 | index u16 | total u16 | size u16 | data(size)
    data = pn_bytes(0x5EED0000 + index, size) so the receiver knows exactly
    what should have arrived and can count wrong or missing packets.
"""

from __future__ import annotations

import base64
import struct
from dataclasses import dataclass, field

from . import transport
from .modem import PROFILES, pn_bytes

QR_PREFIX = "SL1:"
QR_CHUNK = 400  # data bytes per QR: small enough to scan quickly from a phone screen
TEST_TYPE = 0x70
TEST_MAGIC = b"SLT1"
PROFILE_IDS = {name: i for i, name in enumerate(PROFILES)}
_TEST = struct.Struct(">4sBHHH")


def to_qr_texts(packet: bytes, chunk: int = QR_CHUNK) -> list[str]:
    parts = transport.split(packet, frame_size=chunk + transport.CHUNK_HEADER.size)
    return [QR_PREFIX + base64.urlsafe_b64encode(p).decode().rstrip("=") for p in parts]


def from_qr_text(text: str) -> bytes:
    """Returns the chunk inside a SoundLink QR code, or raises ValueError."""
    text = text.strip()
    if not text.startswith(QR_PREFIX):
        raise ValueError("not a SoundLink QR code")
    body = text[len(QR_PREFIX) :]
    try:
        return base64.urlsafe_b64decode(body + "=" * (-len(body) % 4))
    except ValueError as exc:
        raise ValueError("damaged SoundLink QR code") from exc


def make_test_payload(profile: str, index: int, total: int, size: int) -> bytes:
    return _TEST.pack(TEST_MAGIC, PROFILE_IDS[profile], index, total, size) + pn_bytes(0x5EED0000 + index, size)


@dataclass
class SoundTestScore:
    """Receiver side of the sound test."""

    profile: str
    total: int = 0
    size: int = 0
    good: set[int] = field(default_factory=set)
    bad: int = 0  # arrived but data wrong (should never happen thanks to CRC + signature)
    quality: list[float] = field(default_factory=list)
    corrected: int = 0
    first: float | None = None
    last: float | None = None

    def add(self, payload: bytes, quality: float, corrected: int, t: float) -> bool:
        if len(payload) < _TEST.size:
            return False
        magic, pid, index, total, size = _TEST.unpack_from(payload)
        if magic != TEST_MAGIC or pid != PROFILE_IDS.get(self.profile, -1):
            return False
        self.total, self.size = total, size
        if payload[_TEST.size :] != pn_bytes(0x5EED0000 + index, size):
            self.bad += 1
            return True
        self.good.add(index)
        self.quality.append(quality)
        self.corrected += corrected
        self.first = t if self.first is None else self.first
        self.last = t
        return True

    @property
    def success(self) -> float:
        return len(self.good) / self.total if self.total else 0.0

    def summary(self) -> dict:
        q = sorted(self.quality)
        return {
            "profile": self.profile,
            "received": len(self.good),
            "sent": self.total,
            "success_pct": round(100 * self.success),
            "bytes_each": self.size,
            "median_quality": round(q[len(q) // 2], 2) if q else 0,
            "bytes_fixed": self.corrected,
            "bad": self.bad,
        }
