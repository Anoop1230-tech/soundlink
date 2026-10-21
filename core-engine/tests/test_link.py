"""End to end: packet -> sound -> (fake room) -> packet."""

import numpy as np

from soundlink import Identity, Packet, PacketType, Receiver, ReplayGuard, SoundLink, key_from_pin
from soundlink.audio import read_wav, write_wav
from soundlink.cli import main
from soundlink.link import decode_audio
from soundlink.sim import channel

rng = np.random.default_rng(7)


def test_signed_encrypted_multi_chunk_through_noisy_room():
    me, key = Identity.generate(), key_from_pin("2468")
    payload = ("BEGIN:VCARD\nFN:Test User\nTEL:+910000000000\nEND:VCARD\n" * 6).encode()
    payload += bytes(rng.integers(0, 256, 300, dtype=np.uint8))  # make sure it needs several chunks
    link = SoundLink("fast", identity=me, key=key)
    x = channel(link.encode(Packet(PacketType.CONTACT, payload)), 48000, snr_db=10, rng=rng)

    results = decode_audio(x, profile="fast", key=key, trusted={me.public_key})
    assert len(results) == 1 and results[0].error is None
    assert results[0].packet.payload == payload
    assert len(results[0].frames) >= 2


def test_untrusted_sender_rejected():
    stranger = Identity.generate()
    x = SoundLink("fast", identity=stranger).encode(Packet(PacketType.DOOR_UNLOCK, b"open"))
    results = decode_audio(x, profile="fast", trusted={Identity.generate().public_key})
    assert results[0].packet is None and "not trusted" in results[0].error


def test_recorded_and_replayed_sound_is_rejected():
    """Someone records the door-unlock sound and plays it again."""
    me = Identity.generate()
    sound = SoundLink("fast", identity=me).encode(Packet(PacketType.DOOR_UNLOCK, b"open"))
    guard = ReplayGuard()
    rx = Receiver("fast", trusted={me.public_key}, replay_guard=guard)
    first = rx.feed(sound) + rx.flush()
    assert first[0].packet is not None
    # Same listener: the chunk layer already ignores the repeat.
    assert rx.feed(sound) + rx.flush() == []
    # New listener session (e.g. app reopened): the replay guard catches it.
    rx2 = Receiver("fast", trusted={me.public_key}, replay_guard=guard)
    replay = rx2.feed(sound) + rx2.flush()
    assert replay[0].packet is None and "replayed" in replay[0].error


def test_repeat_gives_one_packet():
    x = SoundLink("fast").encode(Packet(PacketType.OFFER, b"10% off"), sign=False, repeat=3)
    results = decode_audio(x, profile="fast")
    assert [r.packet.payload for r in results] == [b"10% off"]


def test_wav_round_trip(tmp_path):
    x = SoundLink("normal").encode(Packet(PacketType.TEXT, b"wav test"))
    write_wav(tmp_path / "a.wav", x, 48000)
    y, rate = read_wav(tmp_path / "a.wav")
    assert rate == 48000
    assert decode_audio(y, profile="normal")[0].packet.payload == b"wav test"


def test_cli_encode_decode(tmp_path, capsys):
    key_file, wav = tmp_path / "me.key", tmp_path / "msg.wav"
    main(["keygen", str(key_file)])
    main(["encode", "namaste", str(wav), "--key-file", str(key_file), "--pin", "11", "--profile", "fast"])
    main(["decode", str(wav), "--pin", "11", "--profile", "fast"])
    out = capsys.readouterr().out
    assert "[TEXT]" in out and "namaste" in out
