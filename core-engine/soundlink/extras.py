"""Phase 5 payloads: emergency alerts, sensor readings and file offers.

Text fields are str8 (length u8 + UTF-8) unless noted.

EMERGENCY (0x40), signed by the authority that sends it
    severity u8 | kind u8 | issued u32 | expires u32 | area str8 | title str8 | message (rest, UTF-8, max 400 bytes)
    Phones show "VERIFIED" only if the signer is in their list of trusted
    authorities; anyone can play sound, so unsigned / unknown alerts are
    shown with a clear warning instead of being hidden.

SENSOR (0x60), signed by the device
    seq u32 | name str8 | count u8 | count x (kind u8 | value i32, value = reading x 100)
    The seq number lets a receiver drop repeats and notice missed readings.

FILE_HANDSHAKE (0x12), signed by the sender
    mode u8 (1 = link, 2 = inline) | size u32 | sha256(32) | name str8 | mime str8
    link:   url str8 (up to 200 bytes)  -> receiver downloads over the local Wi-Fi
    inline: the file itself (rest)      -> whole file sent through sound (small files)
    The receiver checks sha256 before saving, so a wrong or changed file is refused.
"""

from __future__ import annotations

import hashlib
import struct
import time
from dataclasses import dataclass, field

from .packet import MAX_PAYLOAD, PacketError

TEXT_MAX = 40
MESSAGE_MAX = 400
URL_MAX = 200
INLINE_MAX = MAX_PAYLOAD - 120


def _str8(s: str, limit: int = TEXT_MAX) -> bytes:
    b = s.strip().encode("utf-8")
    if len(b) > limit:
        raise ValueError(f"text is longer than {limit} bytes")
    return bytes([len(b)]) + b


def _read_str8(d: bytes, i: int, limit: int = TEXT_MAX) -> tuple[str, int]:
    if i >= len(d) or d[i] > limit or i + 1 + d[i] > len(d):
        raise PacketError("bad text")
    try:
        return d[i + 1 : i + 1 + d[i]].decode("utf-8"), i + 1 + d[i]
    except UnicodeDecodeError as exc:
        raise PacketError("bad text") from exc


# ---------------------------------------------------------------- alerts

SEVERITY = {0: "Info", 1: "Warning", 2: "DANGER"}
ALERT_KIND = {0: "General", 1: "Flood", 2: "Fire", 3: "Earthquake", 4: "Cyclone / storm", 5: "Medical",
              6: "Police / safety", 7: "Evacuate", 8: "All clear"}
_ALERT = struct.Struct(">BBII")


@dataclass(frozen=True)
class Alert:
    title: str
    message: str = ""
    severity: int = 1
    kind: int = 0
    area: str = ""
    issued: int = field(default_factory=lambda: int(time.time()))
    expires: int = 0  # 0 = no end

    def to_bytes(self) -> bytes:
        if not self.title.strip():
            raise ValueError("title is required")
        if self.severity not in SEVERITY or self.kind not in ALERT_KIND:
            raise ValueError("unknown severity or kind")
        msg = self.message.strip().encode("utf-8")
        if len(msg) > MESSAGE_MAX:
            raise ValueError(f"message is longer than {MESSAGE_MAX} bytes")
        return _ALERT.pack(self.severity, self.kind, self.issued, self.expires) + _str8(self.area) + _str8(self.title) + msg

    @classmethod
    def from_bytes(cls, d: bytes) -> "Alert":
        if len(d) < _ALERT.size + 2:
            raise PacketError("bad alert")
        sev, kind, issued, expires = _ALERT.unpack_from(d)
        if sev not in SEVERITY or kind not in ALERT_KIND:
            raise PacketError("bad alert")
        area, i = _read_str8(d, _ALERT.size)
        title, i = _read_str8(d, i)
        if not title or len(d) - i > MESSAGE_MAX:
            raise PacketError("bad alert")
        try:
            msg = d[i:].decode("utf-8")
        except UnicodeDecodeError as exc:
            raise PacketError("bad alert") from exc
        return cls(title, msg, sev, kind, area, issued, expires)

    def expired(self, now: float | None = None) -> bool:
        return bool(self.expires) and (time.time() if now is None else now) > self.expires


# ---------------------------------------------------------------- sensors

SENSOR_KIND = {
    1: ("Temperature", "°C"), 2: ("Humidity", "%"), 3: ("Heart rate", "bpm"), 4: ("SpO2", "%"),
    5: ("BP systolic", "mmHg"), 6: ("BP diastolic", "mmHg"), 7: ("Glucose", "mg/dL"), 8: ("Battery", "%"),
    9: ("PM2.5", "µg/m³"), 10: ("Weight", "kg"), 11: ("Door open", ""), 12: ("Value", ""),
}
MAX_READINGS = 16


@dataclass(frozen=True)
class SensorReport:
    name: str
    readings: tuple[tuple[int, float], ...]  # (kind, value)
    seq: int = 0

    def to_bytes(self) -> bytes:
        if not 0 < len(self.readings) <= MAX_READINGS:
            raise ValueError(f"1..{MAX_READINGS} readings")
        out = struct.pack(">I", self.seq) + _str8(self.name) + bytes([len(self.readings)])
        for kind, value in self.readings:
            if kind not in SENSOR_KIND:
                raise ValueError(f"unknown sensor kind {kind}")
            out += struct.pack(">Bi", kind, round(value * 100))
        return out

    @classmethod
    def from_bytes(cls, d: bytes) -> "SensorReport":
        if len(d) < 6:
            raise PacketError("bad sensor report")
        seq = struct.unpack_from(">I", d)[0]
        name, i = _read_str8(d, 4)
        if i >= len(d):
            raise PacketError("bad sensor report")
        n = d[i]
        i += 1
        if not 0 < n <= MAX_READINGS or len(d) != i + 5 * n:
            raise PacketError("bad sensor report")
        readings = []
        for k in range(n):
            kind, v = struct.unpack_from(">Bi", d, i + 5 * k)
            if kind not in SENSOR_KIND:
                raise PacketError("unknown sensor kind")
            readings.append((kind, v / 100))
        return cls(name, tuple(readings), seq)

    def describe(self) -> list[str]:
        out = []
        for kind, value in self.readings:
            label, unit = SENSOR_KIND[kind]
            v = f"{value:g}"
            out.append(f"{label}: {v} {unit}".rstrip())
        return out


# ---------------------------------------------------------------- files

FILE_LINK, FILE_INLINE = 1, 2
_FILE = struct.Struct(">BI32s")


@dataclass(frozen=True)
class FileOffer:
    mode: int
    size: int
    sha256: bytes
    name: str
    mime: str = "application/octet-stream"
    url: str = ""
    data: bytes = b""

    @classmethod
    def inline(cls, name: str, data: bytes, mime: str = "application/octet-stream") -> "FileOffer":
        if len(data) > INLINE_MAX:
            raise ValueError(f"inline files can be at most {INLINE_MAX} bytes; use a link")
        return cls(FILE_INLINE, len(data), hashlib.sha256(data).digest(), name, mime, data=data)

    @classmethod
    def link(cls, name: str, size: int, sha256: bytes, url: str, mime: str = "application/octet-stream") -> "FileOffer":
        return cls(FILE_LINK, size, sha256, name, mime, url=url)

    def to_bytes(self) -> bytes:
        head = _FILE.pack(self.mode, self.size, self.sha256) + _str8(safe_name(self.name)) + _str8(self.mime)
        if self.mode == FILE_LINK:
            if not self.url.startswith(("http://", "https://")):
                raise ValueError("url must be http(s)")
            return head + _str8(self.url, URL_MAX)
        if self.mode == FILE_INLINE:
            return head + self.data
        raise ValueError("bad mode")

    @classmethod
    def from_bytes(cls, d: bytes) -> "FileOffer":
        if len(d) < _FILE.size + 2:
            raise PacketError("bad file offer")
        mode, size, sha = _FILE.unpack_from(d)
        name, i = _read_str8(d, _FILE.size)
        mime, i = _read_str8(d, i)
        if mode == FILE_LINK:
            url, j = _read_str8(d, i, URL_MAX)
            if j != len(d) or not url.startswith(("http://", "https://")):
                raise PacketError("bad file offer")
            return cls(mode, size, sha, safe_name(name), mime, url=url)
        if mode == FILE_INLINE:
            data = d[i:]
            if len(data) != size or hashlib.sha256(data).digest() != sha:
                raise PacketError("file is damaged")
            return cls(mode, size, sha, safe_name(name), mime, data=data)
        raise PacketError("bad file offer")

    def check(self, data: bytes) -> bytes:
        """Verify downloaded data; returns it or raises."""
        if len(data) != self.size or hashlib.sha256(data).digest() != self.sha256:
            raise PacketError("downloaded file does not match (wrong size or checksum)")
        return data


def safe_name(name: str) -> str:
    """Strip folders and odd characters so a file name can't escape the download folder."""
    base = name.replace("\\", "/").split("/")[-1].strip()
    base = "".join(c for c in base if c.isalnum() or c in " ._-()")
    base = base.lstrip(".") or "file"
    while len(base.encode("utf-8")) > TEXT_MAX:
        stem, dot, ext = base.rpartition(".")
        base = (stem[:-1] + dot + ext) if dot and stem else base[:-1]
    return base


def guess_mime(name: str) -> str:
    import mimetypes

    return mimetypes.guess_type(name)[0] or "application/octet-stream"
