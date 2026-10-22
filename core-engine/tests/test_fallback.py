import os
import time

import pytest

from soundlink import Identity, Packet, PacketType, Receiver, SoundLink
from soundlink.fallback import SoundTestScore, from_qr_text, make_test_payload, to_qr_texts
from soundlink.link import decode_audio
from soundlink.modules import Contact


def test_qr_round_trip_single_and_multi():
    me = Identity.generate()
    small = Packet(PacketType.CONTACT, Contact("Asha", phone="123").to_bytes()).to_bytes(sign_with=me)
    texts = to_qr_texts(small)
    assert len(texts) == 1 and texts[0].startswith("SL1:")
    rx = Receiver()
    r = rx.feed_chunk(from_qr_text(texts[0]))
    assert r[0].packet.signer == me.public_key

    big = Packet(PacketType.TEXT, os.urandom(1500)).to_bytes(sign_with=me, compress=False)
    texts = to_qr_texts(big)
    assert len(texts) == 5  # 1500 bytes + header and signature, 400 per QR
    rx = Receiver()
    out = []
    for t in reversed(texts + texts[:1]):  # any order, with a repeat
        out += rx.feed_chunk(from_qr_text(t))
    assert len(out) == 1 and len(out[0].packet.payload) == 1500


def test_qr_rejects_garbage_and_tampering():
    with pytest.raises(ValueError):
        from_qr_text("https://example.com")
    me = Identity.generate()
    t = to_qr_texts(Packet(PacketType.TEXT, b"pay me").to_bytes(sign_with=me))[0]
    chunk = bytearray(from_qr_text(t))
    chunk[-5] ^= 1
    r = Receiver().feed_chunk(bytes(chunk))
    assert r[0].packet is None  # CRC / signature still protect QR packets


@pytest.mark.parametrize("profile", ["fast", "turbo"])
def test_sound_test_packets_scored(profile):
    me = Identity.generate()
    link = SoundLink(profile, identity=me)
    score = SoundTestScore(profile)
    for i in range(3):
        sound = link.encode(Packet(0x70, make_test_payload(profile, i, 3, 64)), encrypt=False)
        for r in decode_audio(sound, profile=profile):
            f = r.frames[0]
            assert score.add(r.packet.payload, f.quality, f.corrected, time.time())
    s = score.summary()
    assert s["received"] == 3 and s["success_pct"] == 100 and s["bad"] == 0
    assert not score.add(make_test_payload("normal", 0, 3, 64), 1, 0, 0)  # other mode ignored
