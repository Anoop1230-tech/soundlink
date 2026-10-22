import pytest

from soundlink import Identity, Packet, PacketError, PacketType, SoundLink, key_from_pin, modules
from soundlink.link import decode_audio
from soundlink.modules import Contact, Offer, Wifi, WifiSecurity


def test_contact_round_trip_and_vcard():
    c = Contact("Asha Verma", phone="+91 90000 00000", email="asha@example.com", org="Sitare")
    data = c.to_bytes()
    assert len(data) < 60  # much smaller than JSON or a vCard
    assert Contact.from_bytes(data) == c
    vcard = c.to_vcard()
    assert "FN:Asha Verma" in vcard and "TEL:+91 90000 00000" in vcard


def test_contact_needs_name():
    with pytest.raises(ValueError):
        Contact("", phone="123").to_bytes()
    with pytest.raises(PacketError):
        Contact.from_bytes(bytes([2, 3]) + b"123")


def test_unicode_contact():
    c = Contact("अनूप कुमार", note="नमस्ते")
    assert Contact.from_bytes(c.to_bytes()) == c


def test_unknown_fields_are_skipped():
    data = Contact("A").to_bytes() + bytes([99, 2]) + b"xx"
    assert Contact.from_bytes(data).name == "A"


def test_broken_fields_rejected():
    with pytest.raises(PacketError):
        Contact.from_bytes(bytes([1, 10]) + b"abc")


def test_wifi_round_trip():
    w = Wifi("Home WiFi", "p@ss;word", WifiSecurity.WPA3, hidden=True)
    assert Wifi.from_bytes(w.to_bytes()) == w
    assert Wifi.from_bytes(Wifi("Cafe", security=WifiSecurity.OPEN).to_bytes()).password == ""
    assert w.to_qr_string() == r"WIFI:T:WPA;S:Home WiFi;P:p@ss\;word;H:true;;"


def test_wifi_validation():
    with pytest.raises(ValueError):
        Wifi("Home", "").to_bytes()  # WPA needs a password
    with pytest.raises(PacketError):
        Wifi.from_bytes(bytes([0x05]) + Contact("x").to_bytes())  # unknown security


def test_offer_round_trip_and_expiry():
    o = Offer("20% off on medicines", shop="City Pharmacy", code="SAVE20", expires=2_000_000_000)
    assert Offer.from_bytes(o.to_bytes()) == o
    assert not o.expired(now=1_900_000_000) and o.expired(now=2_100_000_000)
    assert not Offer("Free tea").expired()


def test_parse_dispatch():
    assert modules.parse(PacketType.TEXT, "hi".encode()) == "hi"
    assert modules.parse(PacketType.WIFI, Wifi("N", "pw").to_bytes()).ssid == "N"
    assert modules.parse(PacketType.PAYMENT, b"\x00") is None


def test_encrypted_wifi_through_sound():
    key = key_from_pin("2580")
    me = Identity.generate()
    w = Wifi("Office", "correct horse battery")
    sound = SoundLink("fast", identity=me, key=key).encode(Packet(PacketType.WIFI, w.to_bytes()))

    locked = decode_audio(sound, profile="fast")[0]
    assert locked.packet is None and "key needed" in locked.error
    # The raw packet is kept, so the app can ask for the PIN and open it afterwards.
    opened = Packet.from_bytes(locked.data, key)
    assert Wifi.from_bytes(opened.payload) == w and opened.signer == me.public_key
