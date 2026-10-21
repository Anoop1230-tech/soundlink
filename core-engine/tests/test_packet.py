import pytest

from soundlink import Identity, Packet, PacketError, PacketType, ReplayGuard, key_from_pin, random_key
from soundlink.crc import crc16
from soundlink.packet import MAX_PAYLOAD, Flags


def test_crc16_known_value():
    assert crc16(b"123456789") == 0x29B1  # CRC-16/CCITT-FALSE check value


def test_plain_round_trip():
    p = Packet(PacketType.TEXT, b"hello")
    q = Packet.from_bytes(p.to_bytes())
    assert (q.type, q.payload, q.msg_id, q.timestamp) == (p.type, b"hello", p.msg_id, p.timestamp)
    assert not q.signed


def test_compression_only_when_smaller():
    long = Packet(PacketType.TEXT, b"a" * 500)
    data = long.to_bytes()
    assert len(data) < 100
    assert Packet.from_bytes(data).payload == b"a" * 500

    short = Packet(PacketType.TEXT, b"\x8f\x01")
    short.to_bytes()
    assert not short.flags & Flags.COMPRESSED


def test_signed_round_trip():
    me = Identity.generate()
    q = Packet.from_bytes(Packet(PacketType.PAYMENT, b"pay 50").to_bytes(sign_with=me))
    assert q.signer == me.public_key
    assert q.payload == b"pay 50"


def test_tampered_signed_packet_is_rejected():
    me = Identity.generate()
    data = bytearray(Packet(PacketType.PAYMENT, b"pay 50").to_bytes(sign_with=me, compress=False))
    data[12] ^= 0x01  # change the amount
    body = bytes(data[:-2])
    data[-2:] = crc16(body).to_bytes(2, "big")  # attacker fixes the CRC too
    with pytest.raises(PacketError, match="signature"):
        Packet.from_bytes(bytes(data))


def test_corrupted_packet_fails_crc():
    data = bytearray(Packet(PacketType.TEXT, b"hello").to_bytes())
    data[5] ^= 0xFF
    with pytest.raises(PacketError, match="checksum"):
        Packet.from_bytes(bytes(data))


def test_encrypted_round_trip_and_wrong_key():
    key = random_key()
    data = Packet(PacketType.WIFI, b"secret-password").to_bytes(key=key)
    assert b"secret-password" not in data
    assert Packet.from_bytes(data, key).payload == b"secret-password"
    with pytest.raises(PacketError, match="key needed"):
        Packet.from_bytes(data)
    with pytest.raises(PacketError, match="decryption"):
        Packet.from_bytes(data, random_key())


def test_changing_header_breaks_decryption():
    key = random_key()
    data = bytearray(Packet(PacketType.WIFI, b"pw").to_bytes(key=key))
    data[1] = PacketType.CONTACT  # pretend it's a different type
    data[-2:] = crc16(bytes(data[:-2])).to_bytes(2, "big")
    with pytest.raises(PacketError):
        Packet.from_bytes(bytes(data), key)


def test_signed_and_encrypted():
    me, key = Identity.generate(), key_from_pin("4321")
    q = Packet.from_bytes(Packet(PacketType.TICKET, b"seat 12").to_bytes(sign_with=me, key=key), key)
    assert q.payload == b"seat 12" and q.signer == me.public_key


def test_pin_key_is_stable():
    assert key_from_pin("1234") == key_from_pin("1234") != key_from_pin("1235")


def test_unknown_type_kept_as_int():
    q = Packet.from_bytes(Packet(0x7E, b"x").to_bytes())
    assert q.type == 0x7E


def test_payload_size_limit():
    with pytest.raises(PacketError):
        Packet(PacketType.TEXT, b"x" * (MAX_PAYLOAD + 1)).to_bytes()


def test_identity_save_load(tmp_path):
    me = Identity.generate()
    me.save(tmp_path / "me.key")
    assert Identity.load(tmp_path / "me.key").public_key == me.public_key


def test_replay_guard():
    guard = ReplayGuard(window_s=60)
    p = Packet.from_bytes(Packet(PacketType.DOOR_UNLOCK, b"open", timestamp=1000).to_bytes())
    guard.check(p, now=1010)
    with pytest.raises(PacketError, match="replayed"):
        guard.check(p, now=1011)
    old = Packet.from_bytes(Packet(PacketType.DOOR_UNLOCK, b"open", timestamp=900).to_bytes())
    with pytest.raises(PacketError, match="expired"):
        guard.check(old, now=1010)
