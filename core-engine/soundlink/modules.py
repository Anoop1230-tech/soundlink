"""Payload formats for the app modules (Phase 2: contact, Wi-Fi, offer).

Sound is slow, so payloads are small binary TLV records instead of JSON:

    field = tag(1) | length(1) | value (UTF-8, max 255 bytes)

Unknown tags are skipped, so new fields can be added later without breaking
older apps. The Flutter app has the exact same format in lib/engine/modules.dart.

Wi-Fi payload starts with one extra byte before the fields:
    bit 7 = hidden network, bits 0-6 = security (0 open, 1 WPA/WPA2, 2 WPA3, 3 WEP)
"""

from __future__ import annotations

import time
from dataclasses import dataclass, fields
from enum import IntEnum

from .packet import PacketError, PacketType

MAX_FIELD = 255


def _encode_fields(items: list[tuple[int, bytes]]) -> bytes:
    out = bytearray()
    for tag, value in items:
        if len(value) > MAX_FIELD:
            raise ValueError(f"field {tag} is longer than {MAX_FIELD} bytes")
        out += bytes([tag, len(value)]) + value
    return bytes(out)


def _decode_fields(data: bytes) -> dict[int, bytes]:
    out: dict[int, bytes] = {}
    i = 0
    while i < len(data):
        if i + 2 > len(data):
            raise PacketError("broken field list")
        tag, n = data[i], data[i + 1]
        if i + 2 + n > len(data):
            raise PacketError("broken field list")
        out[tag] = data[i + 2 : i + 2 + n]
        i += 2 + n
    return out


def _text(value: str) -> bytes:
    return value.strip().encode("utf-8")


def _str(fields_: dict[int, bytes], tag: int) -> str:
    try:
        return fields_.get(tag, b"").decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PacketError("text field is not UTF-8") from exc


class _TextRecord:
    """Records whose fields are all optional strings, numbered by declaration order."""

    REQUIRED: str = ""

    def to_bytes(self) -> bytes:
        items = []
        for tag, f in enumerate(fields(self), start=1):
            value = getattr(self, f.name)
            if value:
                items.append((tag, _text(value)))
        if not getattr(self, self.REQUIRED).strip():
            raise ValueError(f"{self.REQUIRED} is required")
        return _encode_fields(items)

    @classmethod
    def from_bytes(cls, data: bytes):
        f = _decode_fields(data)
        obj = cls(**{fd.name: _str(f, tag) for tag, fd in enumerate(fields(cls), start=1)})
        if not getattr(obj, cls.REQUIRED):
            raise PacketError(f"{cls.REQUIRED} is missing")
        return obj


@dataclass
class Contact(_TextRecord):
    REQUIRED = "name"
    name: str = ""
    phone: str = ""
    email: str = ""
    org: str = ""
    title: str = ""
    url: str = ""
    note: str = ""

    def to_vcard(self) -> str:
        lines = ["BEGIN:VCARD", "VERSION:3.0", f"FN:{self.name}"]
        for prefix, value in (("TEL", self.phone), ("EMAIL", self.email), ("ORG", self.org),
                              ("TITLE", self.title), ("URL", self.url), ("NOTE", self.note)):
            if value:
                lines.append(f"{prefix}:{value}")
        return "\r\n".join(lines + ["END:VCARD"])


class WifiSecurity(IntEnum):
    OPEN = 0
    WPA = 1  # WPA / WPA2 personal
    WPA3 = 2
    WEP = 3


@dataclass
class Wifi:
    ssid: str
    password: str = ""
    security: WifiSecurity = WifiSecurity.WPA
    hidden: bool = False

    def to_bytes(self) -> bytes:
        if not self.ssid:
            raise ValueError("ssid is required")
        if self.security != WifiSecurity.OPEN and not self.password:
            raise ValueError("password is required for a secured network")
        head = int(self.security) | (0x80 if self.hidden else 0)
        items = [(1, self.ssid.encode("utf-8"))]
        if self.password:
            items.append((2, self.password.encode("utf-8")))
        return bytes([head]) + _encode_fields(items)

    @classmethod
    def from_bytes(cls, data: bytes) -> "Wifi":
        if not data:
            raise PacketError("empty Wi-Fi payload")
        try:
            security = WifiSecurity(data[0] & 0x7F)
        except ValueError as exc:
            raise PacketError("unknown Wi-Fi security type") from exc
        f = _decode_fields(data[1:])
        ssid = _str(f, 1)
        if not ssid:
            raise PacketError("ssid is missing")
        return cls(ssid, _str(f, 2), security, bool(data[0] & 0x80))

    def to_qr_string(self) -> str:
        """Standard Wi-Fi QR text, handy as a fallback."""
        kind = {WifiSecurity.OPEN: "nopass", WifiSecurity.WEP: "WEP"}.get(self.security, "WPA")

        def esc(s: str) -> str:
            return "".join("\\" + c if c in '\\;,:"' else c for c in s)

        hidden = "H:true;" if self.hidden else ""
        return f"WIFI:T:{kind};S:{esc(self.ssid)};P:{esc(self.password)};{hidden};"


@dataclass
class Offer:
    title: str
    shop: str = ""
    details: str = ""
    code: str = ""
    url: str = ""
    expires: int = 0  # unix time, 0 = never

    def to_bytes(self) -> bytes:
        if not self.title.strip():
            raise ValueError("title is required")
        items = [(1, _text(self.title))]
        for tag, value in ((2, self.shop), (3, self.details), (4, self.code), (5, self.url)):
            if value:
                items.append((tag, _text(value)))
        if self.expires:
            items.append((6, int(self.expires).to_bytes(4, "big")))
        return _encode_fields(items)

    @classmethod
    def from_bytes(cls, data: bytes) -> "Offer":
        f = _decode_fields(data)
        title = _str(f, 1)
        if not title:
            raise PacketError("title is missing")
        exp = f.get(6, b"")
        if exp and len(exp) != 4:
            raise PacketError("bad expiry")
        return cls(title, _str(f, 2), _str(f, 3), _str(f, 4), _str(f, 5), int.from_bytes(exp, "big"))

    def expired(self, now: float | None = None) -> bool:
        return bool(self.expires) and (time.time() if now is None else now) > self.expires


MODULES = {PacketType.CONTACT: Contact, PacketType.WIFI: Wifi, PacketType.OFFER: Offer}
TYPE_OF = {cls: t for t, cls in MODULES.items()}


def parse(packet_type: int, payload: bytes):
    """Returns a Contact / Wifi / Offer, a str for TEXT, or None for other types."""
    if packet_type == PacketType.TEXT:
        try:
            return payload.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise PacketError("text is not UTF-8") from exc
    cls = MODULES.get(packet_type)
    return cls.from_bytes(payload) if cls else None
