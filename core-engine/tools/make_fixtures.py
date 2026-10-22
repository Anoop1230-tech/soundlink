"""Makes test data for the Flutter app so the Dart engine is checked against this one.

    python tools/make_fixtures.py ../mobile-app/test/fixtures

Writes vectors.json (CRC, Reed-Solomon, PIN key, packets, module payloads) and
a few WAV files with expected results (some go through the fake noisy room).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from soundlink import Identity, Packet, PacketType, SoundLink, fec, key_from_pin  # noqa: E402
from soundlink.audio import write_wav  # noqa: E402
from soundlink.crc import crc16  # noqa: E402
from soundlink.modules import Contact, Offer, Wifi, WifiSecurity  # noqa: E402
from soundlink.sim import channel  # noqa: E402

SEED = bytes(range(32))  # fixed test identity, never use for anything real
PIN = "1234"


def main(out_dir: str) -> None:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(2026)
    me = Identity.from_seed(SEED)
    key = key_from_pin(PIN)

    rs = []
    for nsym, n in ((6, 2), (16, 50), (32, 200), (32, 300)):
        data = bytes(rng.integers(0, 256, n, dtype=np.uint8))
        rs.append({"nsym": nsym, "data": data.hex(), "encoded": fec.encode(data, nsym).hex()})

    contact = Contact("Asha Verma", phone="+91 90000 00000", email="asha@example.com", org="Sitare")
    wifi = Wifi("Home WiFi", "p@ss;word", WifiSecurity.WPA3, hidden=True)
    offer = Offer("20% off on medicines", shop="City Pharmacy", code="SAVE20", expires=2_000_000_000)

    def pkt(ptype, payload, **kw):
        return Packet(ptype, payload, msg_id=0x01020304, timestamp=1_800_000_000).to_bytes(**kw).hex()

    vectors = {
        "crc16": {"data": b"123456789".hex(), "crc": crc16(b"123456789")},
        "reed_solomon": rs,
        "pin": {"pin": PIN, "key": key.hex()},
        "identity": {"seed": SEED.hex(), "public_key": me.public_key.hex()},
        "packets": {
            "plain": pkt(PacketType.TEXT, b"hello"),
            "compressed": pkt(PacketType.TEXT, b"abc" * 100),
            "signed": pkt(PacketType.PAYMENT, b"pay 50", sign_with=me),
            "encrypted_signed": pkt(PacketType.WIFI, wifi.to_bytes(), sign_with=me, key=key),
        },
        "modules": {
            "contact": {"hex": contact.to_bytes().hex(), "value": contact.__dict__},
            "wifi": {
                "hex": wifi.to_bytes().hex(),
                "value": {"ssid": wifi.ssid, "password": wifi.password, "security": int(wifi.security),
                          "hidden": wifi.hidden},
                "qr": wifi.to_qr_string(),
            },
            "offer": {"hex": offer.to_bytes().hex(), "value": offer.__dict__},
        },
        "wavs": [],
    }

    def wav(name, profile, ptype, payload, snr=None, sign=True, use_key=False):
        link = SoundLink(profile, identity=me, key=key if use_key else None)
        sound = link.encode(Packet(ptype, payload), sign=sign, encrypt=use_key)
        if snr is not None:
            sound = channel(sound, link.sample_rate, snr_db=snr, rng=rng)
        write_wav(out / name, sound, link.sample_rate)
        vectors["wavs"].append({
            "file": name, "profile": profile, "type": int(ptype), "payload": payload.hex(),
            "signed": sign, "pin": PIN if use_key else None, "noisy": snr is not None,
        })

    wav("normal_text.wav", "normal", PacketType.TEXT, "hello from python".encode(), sign=False)
    wav("fast_contact_noisy.wav", "fast", PacketType.CONTACT, contact.to_bytes(), snr=8)
    wav("normal_wifi_pin.wav", "normal", PacketType.WIFI, wifi.to_bytes(), snr=12, use_key=True)
    wav("ultrasonic_offer.wav", "ultrasonic", PacketType.OFFER, offer.to_bytes())
    big = bytes(rng.integers(0, 256, 520, dtype=np.uint8))  # random so it can't compress: 3 frames
    wav("fast_multichunk_noisy.wav", "fast", PacketType.TEXT, big, snr=10, sign=False)
    pv = _payment_vectors(me)
    wav("fast_payment_noisy.wav", "fast", PacketType.PAYMENT,
        Packet.from_bytes(bytes.fromhex(pv["payment"])).payload, snr=10)
    vectors["payment"] = pv
    vectors["access"] = _access_vectors(me)
    vectors["extras"] = _extra_vectors()
    from soundlink.fallback import make_test_payload, to_qr_texts
    vectors["fallback"] = {
        "qr_packet": bytes.fromhex(vectors["packets"]["signed"]).hex(),
        "qr_texts": to_qr_texts(bytes.fromhex(vectors["packets"]["signed"])),
        "qr_big_texts": to_qr_texts(Packet(PacketType.TEXT, bytes(range(256)) * 4, msg_id=1, timestamp=2).to_bytes(compress=False)),
        "test_payload": make_test_payload("turbo", 5, 10, 32).hex(),
    }
    # turbo: one clean, one through the noisy room, and one multi-chunk inline file
    from soundlink.extras import FileOffer
    wav("turbo_text.wav", "turbo", PacketType.TEXT, "turbo from python ".encode() * 20, sign=False)
    wav("turbo_contact_noisy.wav", "turbo", PacketType.CONTACT, contact.to_bytes(), snr=20)
    blob = bytes(rng.integers(0, 256, 2400, dtype=np.uint8))
    wav("turbo_file_noisy.wav", "turbo", PacketType.FILE_HANDSHAKE, FileOffer.inline("blob.bin", blob).to_bytes(), snr=20)
    from soundlink.modem import pn_bytes, Modem as _M
    vectors["ofdm"] = {"pn_ref": pn_bytes(0x51D0F00D, 16).hex(), "pn_white": pn_bytes(0x0BADC0DE, 16).hex(),
                       "frame_head": _M("turbo", volume=0.5).encode_frame(b"hi")[7680:7700].tolist()}

    (out / "vectors.json").write_text(json.dumps(vectors, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"wrote {len(vectors['wavs'])} WAVs and vectors.json to {out}")


def _extra_vectors() -> dict:
    from soundlink.extras import Alert, FileOffer, SensorReport

    a = Alert("Flood warning", "Move to higher ground. \u092c\u093e\u0922\u093c", 2, 1, "Ward 12", 1_800_000_000, 1_800_003_600)
    s = SensorReport("BP meter", ((5, 121), (6, 79), (3, 72.5), (1, -4.25)), seq=7)
    f = FileOffer.link("notes.pdf", 1234, bytes(range(32)), "http://192.168.1.5:8123/f/abc/notes.pdf", "application/pdf")
    i = FileOffer.inline("hi.txt", b"hello file", "text/plain")
    return {"alert": a.to_bytes().hex(), "sensor": s.to_bytes().hex(), "file_link": f.to_bytes().hex(),
            "file_inline": i.to_bytes().hex()}


def _access_vectors(phone: Identity) -> dict:
    """Packets from the 'other side' (teacher, organizer, gate, door, site) plus
    the payloads the phone should answer with. Ed25519 is deterministic, so the
    Dart side must build exactly the same payloads."""
    from soundlink import access as A

    other = Identity.from_seed(bytes(range(96, 128)))
    now = 1_800_000_000
    cls = A.ClassSession("DBMS lecture", session=0x0A0B0C0D, secret=bytes(16), started=now)
    beacon_raw = cls.beacon(other, now=now)
    b = A.read_beacon(Packet.from_bytes(beacon_raw))
    checkin = Packet.from_bytes(A.check_in_packet(b, "Anoop", phone))
    _, ack, _ = cls.check_in(checkin, other, now=now)

    ev = A.Event("Tech Fest", now + 3600, event=0x11223344)
    ask = Packet.from_bytes(A.ask_packet("Anoop", phone))
    ticket, issue = ev.issue(ask, other)
    gate = ev.gate(other, now=now)
    _, gnonce, _ = A.read_gate(Packet.from_bytes(gate))
    show = Packet.from_bytes(A.show_packet(gnonce, ticket, phone))
    _, _, result = ev.check(show, other, now=now)

    door = A.Door("Lab 3", {phone.public_key.hex(): "Anoop"})
    dch = door.challenge(other, now=now)
    dnonce, _, _ = A.read_door_challenge(Packet.from_bytes(dch))
    dopen = Packet.from_bytes(A.open_packet(dnonce, other.public_key, phone))
    _, dres = door.open(dopen, other, now=now)
    enroll = Packet.from_bytes(A.enroll_packet(other.public_key, "Anoop", phone))

    ch = A.AuthChallenge(bytes(range(16)), now + 120, "SoundBank demo", "anoop", "http://192.168.1.10:8000/site/approve")
    ach = A.auth_challenge_packet(ch, other)
    resp = Packet.from_bytes(A.auth_response_packet(A.read_auth_challenge(Packet.from_bytes(ach)), True, phone))

    return {
        "now": now,
        "other_seed": other.seed.hex(),
        "other_pub": other.public_key.hex(),
        "attendance": {"secret": cls.secret.hex(), "session": cls.session, "window": b.window,
                       "code": b.code.hex(), "beacon": beacon_raw.hex(), "checkin_payload": checkin.payload.hex(),
                       "ack": ack.hex()},
        "ticket": {"event": ev.event, "valid_until": ev.valid_until, "ask_payload": ask.payload.hex(),
                   "issue": issue.hex(), "ticket": ticket.to_bytes().hex(), "gate": gate.hex(),
                   "show_payload": show.payload.hex(), "result": result.hex()},
        "door": {"challenge": dch.hex(), "open_payload": dopen.payload.hex(), "result": dres.hex(),
                 "enroll_payload": enroll.payload.hex()},
        "auth": {"challenge": ach.hex(), "response_payload": resp.payload.hex()},
    }


def _payment_vectors(payer: Identity) -> dict:
    """Fixed bank / shop keys and a full request -> payment -> receipt exchange."""
    from soundlink.payment import Cert, Merchant, Wallet, request_packet, tag

    bank = Identity.from_seed(bytes(range(32, 64)))
    shop = Identity.from_seed(bytes(range(64, 96)))
    now = 1_800_000_000
    cert = Cert.issue(bank, payer.public_key, 7, 150_000, now + 30 * 86400)
    wallet = Wallet(bank.public_key)
    wallet.install(cert, payer.public_key)
    merchant = Merchant(bank.public_key)
    req = merchant.new_request(2_550, "2 chai", now=now)
    req_raw = request_packet(req, shop)
    pay_raw = wallet.pay(Packet.from_bytes(req_raw), payer, now=now)
    _, receipt, _ = merchant.accept(Packet.from_bytes(pay_raw), shop, pay_raw, now=now)
    return {
        "now": now,
        "bank_seed": bank.seed.hex(),
        "bank_pub": bank.public_key.hex(),
        "shop_seed": shop.seed.hex(),
        "shop_pub": shop.public_key.hex(),
        "tag_payer": tag(payer.public_key).hex(),
        "cert": cert.to_bytes().hex(),
        "request_nonce": req.nonce.hex(),
        "request": req_raw.hex(),
        "payment": pay_raw.hex(),
        "receipt_payload": receipt.to_bytes().hex(),
        "receipt": merchant.receipt_packet(receipt, shop).hex(),
    }


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "fixtures")
