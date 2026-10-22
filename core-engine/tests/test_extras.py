import hashlib

import numpy as np
import pytest

from soundlink import Identity, Packet, PacketType, SoundLink
from soundlink.extras import (
    FILE_LINK,
    INLINE_MAX,
    Alert,
    FileOffer,
    SensorReport,
    safe_name,
)
from soundlink.files import FileShare, fetch
from soundlink.link import decode_audio
from soundlink.packet import PacketError
from soundlink.sim import channel


def test_alert_round_trip_and_checks():
    a = Alert("Flood warning", "Move to higher ground near the school.", 2, 1, "Ward 12", 1_800_000_000, 1_800_003_600)
    assert Alert.from_bytes(a.to_bytes()) == a
    assert not a.expired(now=1_800_000_100) and a.expired(now=1_800_010_000)
    hindi = Alert("बाढ़ चेतावनी", "ऊँची जगह पर जाएँ", 2, 1, "वार्ड 12")
    assert Alert.from_bytes(hindi.to_bytes()).title == "बाढ़ चेतावनी"
    with pytest.raises(ValueError):
        Alert("x", "m" * 401).to_bytes()
    with pytest.raises(ValueError):
        Alert("x", severity=9).to_bytes()
    with pytest.raises(PacketError):
        Alert.from_bytes(b"\x09\x00" + bytes(8) + b"\x00\x01x")


def test_alert_over_sound_is_signed():
    gov = Identity.generate()
    a = Alert("Cyclone", "Stay indoors", 2, 4, "Coast")
    x = channel(SoundLink("normal", identity=gov).encode(Packet(PacketType.EMERGENCY, a.to_bytes())), 48000, snr_db=5)
    r = decode_audio(x, profile="normal")[0]
    assert r.packet.signer == gov.public_key and Alert.from_bytes(r.packet.payload).title == "Cyclone"


def test_sensor_report():
    s = SensorReport("BP meter", ((5, 121), (6, 79), (3, 72.5)), seq=7)
    back = SensorReport.from_bytes(s.to_bytes())
    assert back == s and back.describe()[2] == "Heart rate: 72.5 bpm"
    with pytest.raises(ValueError):
        SensorReport("x", ((99, 1),)).to_bytes()
    with pytest.raises(PacketError):
        SensorReport.from_bytes(s.to_bytes()[:-1])


def test_inline_file_through_turbo():
    data = bytes(np.random.default_rng(3).integers(0, 256, 2500, dtype=np.uint8))
    offer = FileOffer.inline("photo.jpg", data, "image/jpeg")
    link = SoundLink("turbo", identity=Identity.generate())
    sound = link.encode(Packet(PacketType.FILE_HANDSHAKE, offer.to_bytes()))
    assert len(sound) / 48000 < 12  # 2.5 kB in a few seconds
    r = decode_audio(channel(sound, 48000, snr_db=20), profile="turbo")[0]
    got = FileOffer.from_bytes(r.packet.payload)
    assert got.data == data and got.name == "photo.jpg"


def test_inline_damage_detected():
    raw = bytearray(FileOffer.inline("a.txt", b"hello").to_bytes())
    raw[-1] ^= 1
    with pytest.raises(PacketError, match="damaged"):
        FileOffer.from_bytes(bytes(raw))
    with pytest.raises(ValueError):
        FileOffer.inline("big", bytes(INLINE_MAX + 1))


def test_safe_names():
    assert safe_name("../../etc/passwd") == "passwd"
    assert safe_name("C:\\Users\\x\\.bashrc") == "bashrc"
    assert safe_name("") == "file"
    assert len(safe_name("a" * 100 + ".pdf").encode()) <= 40 and safe_name("a" * 100 + ".pdf").endswith(".pdf")


def test_link_share_and_fetch(tmp_path):
    src = tmp_path / "notes.pdf"
    src.write_bytes(b"%PDF-1.4 " + bytes(range(256)) * 400)
    share = FileShare(src, host="127.0.0.1", timeout_s=30).start()
    try:
        offer = FileOffer.from_bytes(share.offer().to_bytes())
        assert offer.mode == FILE_LINK and offer.size == src.stat().st_size
        out = fetch(offer, tmp_path / "in")
        assert out.read_bytes() == src.read_bytes() and share.downloads == 1
        assert fetch(offer, tmp_path / "in").name == "notes (1).pdf"  # no overwrite
        # A tampered offer (different checksum) is refused even though the download works
        bad = FileOffer.link(offer.name, offer.size, hashlib.sha256(b"x").digest(), offer.url)
        with pytest.raises(PacketError):
            fetch(bad, tmp_path / "in")
        # Wrong token: 404
        import urllib.error
        wrong = FileOffer.link(offer.name, offer.size, offer.sha256, offer.url.replace(share.token, "0" * 32))
        with pytest.raises(urllib.error.HTTPError):
            fetch(wrong, tmp_path / "in")
    finally:
        share.stop()
