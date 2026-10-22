"""Phase 4: attendance, tickets, door unlock and login, all by sound.

They share one idea: a *challenge* with a fresh random value is played, and
the answer is signed by the phone's key and must include that value. A
recording of an old answer is useless because the next challenge is
different. Every packet below is signed (packet signature) by the sender.

Text fields are "str8": length u8 + UTF-8 bytes (max 40 unless noted).
tag(key) = sha256("SLTAG" + public key)[:8].

ATTENDANCE (packet type 0x20), first byte = kind
    1 BEACON    teacher -> room   session u32 | window u32 | code(8) | title str8
    2 CHECKIN   student -> teacher session u32 | window u32 | code(8) | teacher_tag(8) | name str8
    3 ACK       teacher -> student session u32 | student_tag(8) | present u16
    window = unix_time // 10. code = HMAC-SHA256(secret, "SLATT1" + session + window)[:8]
    A check-in must carry a code from the last 30 seconds, so a code sent to a
    friend at home goes stale fast. One phone = one student.

TICKET (0x21)
    ticket      event u32 | number u32 | valid_until u32 | label str8 | organizer_sig(64)
                sig over "SLTKT1" + holder public key + the fields above
    1 ASK       holder -> organizer  name str8
    2 ISSUE     organizer -> holder  holder_tag(8) | ticket
    3 GATE      gate -> holder       event u32 | nonce(8)
    4 SHOW      holder -> gate       nonce(8) | ticket
    5 RESULT    gate -> holder       nonce(8) | status u8 | number u32
    The ticket is tied to the holder's phone key, so a screenshot or a copied
    file can't get in: the gate checks the SHOW packet is signed by that key.

DOOR (0x22)
    1 CHALLENGE door -> phone   nonce(8) | name str8
    2 OPEN      phone -> door   door_tag(8) | nonce(8)
    3 RESULT    door -> phone   nonce(8) | status u8
    4 ENROLL    phone -> door   door_tag(8) | name str8   (door owner approves)

LOGIN (0x30 challenge, 0x31 response)
    AUTH_CHALLENGE  site -> phone  session(16) | expires u32 | site str8 | user str8 | url str8(max 64)
    AUTH_RESPONSE   phone -> site  session(16) | site_tag(8) | approve u8
    The website plays the challenge from the laptop speaker; the phone sends the
    signed response to `url` over the internet (or by sound to an offline verifier).
"""

from __future__ import annotations

import csv
import hashlib
import hmac
import io
import os
import struct
import time
from dataclasses import dataclass, field

from . import crypto
from .crypto import Identity
from .packet import Packet, PacketError, PacketType
from .payment import tag

TEXT_MAX = 40
URL_MAX = 64
WINDOW_S = 10
WINDOWS_OK = 3  # current + 2 previous = up to 30 s old
NONCE_TTL_S = 60


class AccessError(ValueError):
    pass


def _str8(s: str, limit: int = TEXT_MAX) -> bytes:
    b = s.strip().encode("utf-8")
    if len(b) > limit:
        raise ValueError(f"text is longer than {limit} bytes")
    return bytes([len(b)]) + b


def _read_str8(data: bytes, i: int, limit: int = TEXT_MAX) -> tuple[str, int]:
    if i >= len(data):
        raise PacketError("missing text")
    n = data[i]
    if n > limit or i + 1 + n > len(data):
        raise PacketError("bad text")
    try:
        return data[i + 1 : i + 1 + n].decode("utf-8"), i + 1 + n
    except UnicodeDecodeError as exc:
        raise PacketError("bad text") from exc


def _end(data: bytes, i: int) -> None:
    if i != len(data):
        raise PacketError("extra bytes")


def _signed(packet: Packet, ptype: int, kind: int | None = None) -> bytes:
    if packet.type != ptype:
        raise AccessError("wrong packet type")
    if packet.signer is None:
        raise AccessError("packet is not signed")
    if kind is not None and (not packet.payload or packet.payload[0] != kind):
        raise AccessError("wrong message kind")
    return packet.payload if kind is None else packet.payload[1:]


def build(ptype: int, body: bytes, me: Identity) -> bytes:
    return Packet(ptype, body).to_bytes(sign_with=me, compress=False)


# ================================================================ attendance

BEACON, CHECKIN, ACK = 1, 2, 3
_ATT = struct.Struct(">II8s")


def window_of(t: float) -> int:
    return int(t) // WINDOW_S


@dataclass
class Attendee:
    key: str  # hex public key
    name: str
    time: int


@dataclass
class ClassSession:
    """Teacher side. Plays a beacon every 10 s and records check-ins."""

    title: str
    session: int = field(default_factory=lambda: int.from_bytes(os.urandom(4), "big"))
    secret: bytes = field(default_factory=lambda: os.urandom(16))
    started: int = field(default_factory=lambda: int(time.time()))
    present: list[Attendee] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)

    def code(self, window: int) -> bytes:
        return hmac.new(self.secret, b"SLATT1" + struct.pack(">II", self.session, window), hashlib.sha256).digest()[:8]

    def beacon(self, me: Identity, now: float | None = None) -> bytes:
        w = window_of(time.time() if now is None else now)
        body = bytes([BEACON]) + _ATT.pack(self.session, w, self.code(w)) + _str8(self.title)
        return build(PacketType.ATTENDANCE, body, me)

    def check_in(self, packet: Packet, me: Identity, now: float | None = None) -> tuple[Attendee, bytes, bool]:
        """Returns (attendee, ack packet to play, is_new). Raises AccessError."""
        now = time.time() if now is None else now
        body = _signed(packet, PacketType.ATTENDANCE, CHECKIN)
        if len(body) < _ATT.size + 8:
            raise PacketError("bad check-in")
        session, w, code = _ATT.unpack_from(body)
        teacher = body[_ATT.size : _ATT.size + 8]
        name, i = _read_str8(body, _ATT.size + 8)
        _end(body, i)
        if session != self.session or teacher != tag(me.public_key):
            raise AccessError("check-in is for another class")
        if not 0 <= window_of(now) - w < WINDOWS_OK:
            raise AccessError("code is too old (heard more than 30 seconds ago)")
        if not hmac.compare_digest(code, self.code(w)):
            raise AccessError("wrong code")
        key = packet.signer.hex()
        new = True
        found = [a for a in self.present if a.key == key]
        if found:
            new = False
            if found[0].name != name.strip():
                self.problems.append(f"one phone tried two names: {found[0].name} / {name}")
            a = found[0]
        else:
            a = Attendee(key, name.strip(), int(now))
            self.present.append(a)
        ack = bytes([ACK]) + struct.pack(">I8sH", self.session, tag(packet.signer), len(self.present))
        return a, build(PacketType.ATTENDANCE, ack, me), new

    def csv(self) -> str:
        out = io.StringIO()
        w = csv.writer(out)
        w.writerow(["name", "time", "device"])
        for a in self.present:
            w.writerow([a.name, time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(a.time)), a.key[:16]])
        return out.getvalue()


@dataclass(frozen=True)
class Beacon:
    session: int
    window: int
    code: bytes
    title: str
    teacher: bytes  # public key


def read_beacon(packet: Packet) -> Beacon:
    body = _signed(packet, PacketType.ATTENDANCE, BEACON)
    if len(body) < _ATT.size + 1:
        raise PacketError("bad beacon")
    s, w, c = _ATT.unpack_from(body)
    title, i = _read_str8(body, _ATT.size)
    _end(body, i)
    return Beacon(s, w, c, title, packet.signer)


def check_in_packet(beacon: Beacon, name: str, me: Identity) -> bytes:
    body = bytes([CHECKIN]) + _ATT.pack(beacon.session, beacon.window, beacon.code) + tag(beacon.teacher) + _str8(name)
    return build(PacketType.ATTENDANCE, body, me)


def read_ack(packet: Packet, me: Identity, beacon: Beacon) -> int:
    """Returns how many are present. Raises if the ack is not for us."""
    body = _signed(packet, PacketType.ATTENDANCE, ACK)
    if len(body) != 14:
        raise PacketError("bad ack")
    session, student, count = struct.unpack(">I8sH", body)
    if session != beacon.session or student != tag(me.public_key) or packet.signer != beacon.teacher:
        raise AccessError("ack is for someone else")
    return count


# ================================================================ tickets

ASK, ISSUE, GATE, SHOW, RESULT = 1, 2, 3, 4, 5
TICKET_OK, TICKET_USED, TICKET_INVALID, TICKET_EXPIRED, TICKET_WRONG_EVENT = 0, 1, 2, 3, 4
TICKET_STATUS = {0: "welcome", 1: "already used", 2: "not a valid ticket", 3: "expired", 4: "ticket for another event"}
_TKT = struct.Struct(">III")


@dataclass(frozen=True)
class Ticket:
    event: int
    number: int
    valid_until: int
    label: str
    sig: bytes

    def fields(self) -> bytes:
        return _TKT.pack(self.event, self.number, self.valid_until) + _str8(self.label)

    def to_bytes(self) -> bytes:
        return self.fields() + self.sig

    @classmethod
    def read(cls, data: bytes, i: int = 0) -> tuple["Ticket", int]:
        if len(data) < i + _TKT.size + 1:
            raise PacketError("bad ticket")
        event, number, until = _TKT.unpack_from(data, i)
        label, j = _read_str8(data, i + _TKT.size)
        if len(data) < j + 64:
            raise PacketError("bad ticket")
        return cls(event, number, until, label, bytes(data[j : j + 64])), j + 64

    def verify(self, organizer_pub: bytes, holder_pub: bytes) -> bool:
        return crypto.verify(organizer_pub, b"SLTKT1" + holder_pub + self.fields(), self.sig)


@dataclass
class Event:
    """Organizer side: issues tickets and runs the gate. Save it (to_dict) after changes."""

    name: str
    valid_until: int
    event: int = field(default_factory=lambda: int.from_bytes(os.urandom(4), "big"))
    issued: dict[str, dict] = field(default_factory=dict)  # holder key hex -> {number, label}
    used: dict[str, int] = field(default_factory=dict)  # ticket number (str) -> time
    gate_nonces: dict[str, int] = field(default_factory=dict)

    def issue(self, ask: Packet, me: Identity, label: str = "") -> tuple[Ticket, bytes]:
        body = _signed(ask, PacketType.TICKET, ASK)
        name, i = _read_str8(body, 0)
        _end(body, i)
        holder = ask.signer
        prev = self.issued.get(holder.hex())
        number = prev["number"] if prev else len(self.issued) + 1
        label = (label or name or f"Ticket {number}").strip()
        while len(label.encode("utf-8")) > TEXT_MAX:  # same rule as the app
            label = label[:-1]
        unsigned = Ticket(self.event, number, self.valid_until, label, b"")
        t = Ticket(self.event, number, self.valid_until, label, me.sign(b"SLTKT1" + holder + unsigned.fields()))
        self.issued[holder.hex()] = {"number": number, "label": label, "name": name}
        return t, build(PacketType.TICKET, bytes([ISSUE]) + tag(holder) + t.to_bytes(), me)

    def gate(self, me: Identity, now: float | None = None) -> bytes:
        now = int(time.time() if now is None else now)
        self.gate_nonces = {k: v for k, v in self.gate_nonces.items() if now - v <= NONCE_TTL_S}
        nonce = os.urandom(8)
        self.gate_nonces[nonce.hex()] = now
        return build(PacketType.TICKET, bytes([GATE]) + struct.pack(">I", self.event) + nonce, me)

    def check(self, show: Packet, me: Identity, now: float | None = None) -> tuple[int, Ticket | None, bytes]:
        """Returns (status, ticket, result packet to play)."""
        now = int(time.time() if now is None else now)
        body = _signed(show, PacketType.TICKET, SHOW)
        nonce = body[:8]
        if len(nonce) != 8:
            raise PacketError("bad ticket")
        t, i = Ticket.read(body, 8)
        _end(body, i)
        if self.gate_nonces.pop(nonce.hex(), None) is None:
            raise AccessError("answer to an old or unknown gate challenge")
        if t.event != self.event:
            status = TICKET_WRONG_EVENT
        elif not t.verify(me.public_key, show.signer):
            status = TICKET_INVALID
        elif now > t.valid_until:
            status = TICKET_EXPIRED
        elif str(t.number) in self.used:
            status = TICKET_USED
        else:
            status = TICKET_OK
            self.used[str(t.number)] = now
        result = build(PacketType.TICKET, bytes([RESULT]) + nonce + struct.pack(">BI", status, t.number), me)
        return status, t, result

    def to_dict(self) -> dict:
        return {"name": self.name, "valid_until": self.valid_until, "event": self.event,
                "issued": self.issued, "used": self.used}

    @classmethod
    def from_dict(cls, d: dict) -> "Event":
        return cls(d["name"], d["valid_until"], d["event"], dict(d.get("issued", {})), dict(d.get("used", {})))


def ask_packet(name: str, me: Identity) -> bytes:
    return build(PacketType.TICKET, bytes([ASK]) + _str8(name), me)


def read_issue(packet: Packet, me: Identity) -> tuple[Ticket, bytes]:
    """Returns (ticket, organizer public key)."""
    body = _signed(packet, PacketType.TICKET, ISSUE)
    if body[:8] != tag(me.public_key):
        raise AccessError("ticket is for someone else")
    t, i = Ticket.read(body, 8)
    _end(body, i)
    if not t.verify(packet.signer, me.public_key):
        raise AccessError("ticket signature is wrong")
    return t, packet.signer


def read_gate(packet: Packet) -> tuple[int, bytes, bytes]:
    """Returns (event, nonce, gate public key)."""
    body = _signed(packet, PacketType.TICKET, GATE)
    if len(body) != 12:
        raise PacketError("bad gate challenge")
    return struct.unpack(">I", body[:4])[0], body[4:], packet.signer


def show_packet(nonce: bytes, ticket: Ticket, me: Identity) -> bytes:
    return build(PacketType.TICKET, bytes([SHOW]) + nonce + ticket.to_bytes(), me)


def read_result(packet: Packet, nonce: bytes, gate_pub: bytes) -> tuple[int, int]:
    body = _signed(packet, PacketType.TICKET, RESULT)
    if len(body) != 13 or body[:8] != nonce or packet.signer != gate_pub:
        raise AccessError("result is for someone else")
    status, number = struct.unpack(">BI", body[8:])
    return status, number


# ================================================================ door

DOOR_CHALLENGE, DOOR_OPEN, DOOR_RESULT, DOOR_ENROLL = 1, 2, 3, 4
DOOR_OK, DOOR_DENIED, DOOR_STALE = 0, 1, 2
DOOR_STATUS = {0: "door opened", 1: "this phone is not allowed", 2: "too slow, try again"}


@dataclass
class Door:
    """Door side (a laptop, phone or later an ESP32)."""

    name: str
    allowed: dict[str, str] = field(default_factory=dict)  # key hex -> person name
    nonces: dict[str, int] = field(default_factory=dict)
    log: list[dict] = field(default_factory=list)

    def challenge(self, me: Identity, now: float | None = None) -> bytes:
        now = int(time.time() if now is None else now)
        self.nonces = {k: v for k, v in self.nonces.items() if now - v <= NONCE_TTL_S}
        nonce = os.urandom(8)
        self.nonces[nonce.hex()] = now
        return build(PacketType.DOOR_UNLOCK, bytes([DOOR_CHALLENGE]) + nonce + _str8(self.name), me)

    def open(self, packet: Packet, me: Identity, now: float | None = None) -> tuple[int, bytes]:
        """Returns (status, result packet). Only OPEN packets; use read_enroll for ENROLL."""
        now = int(time.time() if now is None else now)
        body = _signed(packet, PacketType.DOOR_UNLOCK, DOOR_OPEN)
        if len(body) != 16 or body[:8] != tag(me.public_key):
            raise AccessError("message is for another door")
        nonce = body[8:]
        t = self.nonces.pop(nonce.hex(), None)
        if t is None or now - t > NONCE_TTL_S:
            status = DOOR_STALE
        elif packet.signer.hex() not in self.allowed:
            status = DOOR_DENIED
        else:
            status = DOOR_OK
        who = self.allowed.get(packet.signer.hex(), packet.signer.hex()[:16])
        self.log.append({"who": who, "status": status, "time": now})
        return status, build(PacketType.DOOR_UNLOCK, bytes([DOOR_RESULT]) + nonce + bytes([status]), me)

    def to_dict(self) -> dict:
        return {"name": self.name, "allowed": self.allowed, "log": self.log[-100:]}

    @classmethod
    def from_dict(cls, d: dict) -> "Door":
        return cls(d["name"], dict(d.get("allowed", {})), {}, list(d.get("log", [])))


def read_door_challenge(packet: Packet) -> tuple[bytes, str, bytes]:
    """Returns (nonce, door name, door public key)."""
    body = _signed(packet, PacketType.DOOR_UNLOCK, DOOR_CHALLENGE)
    name, i = _read_str8(body, 8)
    _end(body, i)
    return body[:8], name, packet.signer


def open_packet(nonce: bytes, door_pub: bytes, me: Identity) -> bytes:
    return build(PacketType.DOOR_UNLOCK, bytes([DOOR_OPEN]) + tag(door_pub) + nonce, me)


def enroll_packet(door_pub: bytes, name: str, me: Identity) -> bytes:
    return build(PacketType.DOOR_UNLOCK, bytes([DOOR_ENROLL]) + tag(door_pub) + _str8(name), me)


def read_enroll(packet: Packet, me: Identity) -> tuple[bytes, str]:
    """Door side: returns (phone public key, name) for the owner to approve."""
    body = _signed(packet, PacketType.DOOR_UNLOCK, DOOR_ENROLL)
    if body[:8] != tag(me.public_key):
        raise AccessError("enroll is for another door")
    name, i = _read_str8(body, 8)
    _end(body, i)
    return packet.signer, name


def read_door_result(packet: Packet, nonce: bytes, door_pub: bytes) -> int:
    body = _signed(packet, PacketType.DOOR_UNLOCK, DOOR_RESULT)
    if len(body) != 9 or body[:8] != nonce or packet.signer != door_pub:
        raise AccessError("result is for someone else")
    return body[8]


# ================================================================ login


@dataclass(frozen=True)
class AuthChallenge:
    session: bytes
    expires: int
    site: str
    user: str
    url: str
    site_pub: bytes = b""

    def body(self) -> bytes:
        return (self.session + struct.pack(">I", self.expires) + _str8(self.site) + _str8(self.user)
                + _str8(self.url, URL_MAX))


def auth_challenge_packet(ch: AuthChallenge, site: Identity) -> bytes:
    if len(ch.session) != 16:
        raise ValueError("session must be 16 bytes")
    return build(PacketType.AUTH_CHALLENGE, ch.body(), site)


def read_auth_challenge(packet: Packet) -> AuthChallenge:
    body = _signed(packet, PacketType.AUTH_CHALLENGE)
    if len(body) < 20:
        raise PacketError("bad login challenge")
    expires = struct.unpack(">I", body[16:20])[0]
    site, i = _read_str8(body, 20)
    user, i = _read_str8(body, i)
    url, i = _read_str8(body, i, URL_MAX)
    _end(body, i)
    return AuthChallenge(body[:16], expires, site, user, url, packet.signer)


def auth_response_packet(ch: AuthChallenge, approve: bool, me: Identity) -> bytes:
    return build(PacketType.AUTH_RESPONSE, ch.session + tag(ch.site_pub) + bytes([1 if approve else 0]), me)


def read_auth_response(packet: Packet, site_pub: bytes) -> tuple[bytes, bool, bytes]:
    """Returns (session, approved, phone public key)."""
    body = _signed(packet, PacketType.AUTH_RESPONSE)
    if len(body) != 25 or body[16:24] != tag(site_pub) or body[24] not in (0, 1):
        raise AccessError("response is not for this site")
    return body[:16], body[24] == 1, packet.signer
