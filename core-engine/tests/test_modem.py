import numpy as np
import pytest

from soundlink import fec, transport
from soundlink.modem import MAX_FRAME_DATA, PROFILES, Demodulator, Modem
from soundlink.sim import channel

rng = np.random.default_rng(42)


def random_bytes(n: int) -> bytes:
    return bytes(rng.integers(0, 256, n, dtype=np.uint8))


# ---------- error correction ----------


def test_fec_fixes_errors():
    data = random_bytes(100)
    coded = bytearray(fec.encode(data, 16))
    for i in (0, 10, 20, 30, 40, 50, 60, 70):  # 8 errors = nsym / 2
        coded[i] ^= 0x5A
    out, fixed = fec.decode(bytes(coded), 16)
    assert out == data and fixed == 8


def test_fec_uses_confidence_for_more_errors():
    data = random_bytes(100)
    coded = bytearray(fec.encode(data, 16))
    bad = list(range(0, 110, 10))  # 11 errors: too many without hints
    for i in bad:
        coded[i] ^= 0x33
    with pytest.raises(fec.FECError):
        fec.decode(bytes(coded), 16)
    conf = [0.5 if i in bad else 5.0 for i in range(len(coded))]
    assert fec.decode(bytes(coded), 16, conf)[0] == data


def test_fec_multi_block():
    data = random_bytes(600)
    assert len(fec.encode(data, 16)) == fec.encoded_len(600, 16)
    assert fec.decode(fec.encode(data, 16), 16)[0] == data


# ---------- modem ----------


@pytest.mark.parametrize("name", list(PROFILES))
def test_clean_round_trip(name):
    data = random_bytes(50)
    modem = Modem(name)
    audio = modem.encode_frame(data)
    assert np.max(np.abs(audio)) <= 0.5 + 1e-6
    assert abs(len(audio) / 48000 - modem.frame_duration(50)) < 0.01
    demod = Demodulator(name)
    frames = demod.feed(np.concatenate([np.zeros(3000), audio])) + demod.flush()
    assert [f.data for f in frames] == [data]
    assert frames[0].corrected == 0


@pytest.mark.parametrize("name", list(PROFILES))
def test_noisy_room(name):
    data = random_bytes(MAX_FRAME_DATA)
    audio = Modem(name).encode_frame(data)
    x = channel(audio, 48000, snr_db=5, rng=rng)
    demod = Demodulator(name)
    assert [f.data for f in demod.feed(x) + demod.flush()] == [data]


def test_streaming_in_small_chunks():
    """The mic gives audio in small blocks; frames may be split anywhere."""
    msgs = [random_bytes(20), random_bytes(80)]
    m = Modem("fast")
    audio = np.concatenate([np.zeros(1000), m.encode_frame(msgs[0]), np.zeros(5000), m.encode_frame(msgs[1])])
    audio = channel(audio, 48000, snr_db=15, rng=rng)
    demod = Demodulator("fast")
    got = []
    for i in range(0, len(audio), 1024):
        got += [f.data for f in demod.feed(audio[i : i + 1024])]
    got += [f.data for f in demod.flush()]
    assert got == msgs


def test_silence_and_noise_give_nothing():
    demod = Demodulator("normal")
    assert demod.feed(np.zeros(48000)) == []
    assert demod.feed(np.random.default_rng(0).normal(0, 0.1, 5 * 48000)) == []
    assert demod.flush() == []


def test_speech_like_noise_outside_band_is_ignored():
    """Low hum and a loud tone outside the band should not matter."""
    data = random_bytes(60)
    audio = Modem("ultrasonic").encode_frame(data) * 0.2
    t = np.arange(len(audio)) / 48000
    audio = audio + 0.5 * np.sin(2 * np.pi * 300 * t) + 0.3 * np.sin(2 * np.pi * 1000 * t)
    demod = Demodulator("ultrasonic")
    assert [f.data for f in demod.feed(audio) + demod.flush()] == [data]


def test_frame_size_limits():
    m = Modem("normal")
    with pytest.raises(ValueError):
        m.encode_frame(b"")
    with pytest.raises(ValueError):
        m.encode_frame(b"x" * (MAX_FRAME_DATA + 1))


# ---------- transport ----------


def test_split_and_join_out_of_order_with_duplicates():
    data = random_bytes(1000)
    chunks = transport.split(data)
    assert len(chunks) == 5
    r = transport.Reassembler()
    order = [3, 0, 0, 4, 1, 2]
    results = [r.add(chunks[i]) for i in order]
    assert results[:-1] == [None] * 5 and results[-1] == data
    assert all(r.add(c) is None for c in chunks)  # repeated broadcast is ignored


def test_split_limits():
    with pytest.raises(ValueError):
        transport.split(b"")
    with pytest.raises(ValueError):
        transport.split(b"x" * (transport.CHUNK_DATA * 256))
