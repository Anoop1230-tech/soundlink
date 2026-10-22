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

    (out / "vectors.json").write_text(json.dumps(vectors, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"wrote {len(vectors['wavs'])} WAVs and vectors.json to {out}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "fixtures")
