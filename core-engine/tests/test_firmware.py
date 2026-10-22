"""Builds the ESP32 firmware code for this PC (zig cc) and checks it against the
Python engine: same packet bytes, and its sound decodes in all MFSK modes.
Skipped if the ziglang package isn't installed (pip install ziglang)."""

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

from soundlink import Identity, Packet, PacketType
from soundlink.audio import read_wav
from soundlink.extras import SensorReport
from soundlink.link import decode_audio

FW = Path(__file__).resolve().parents[2] / "firmware" / "esp32"

pytestmark = pytest.mark.skipif(importlib.util.find_spec("ziglang") is None, reason="needs: pip install ziglang")


@pytest.fixture(scope="module")
def sltx(tmp_path_factory):
    exe = tmp_path_factory.mktemp("fw") / ("sltx.exe" if sys.platform == "win32" else "sltx")
    src = [FW / "test" / "host_tx.c", FW / "src" / "soundlink.c", FW / "src" / "monocypher" / "monocypher.c",
           FW / "src" / "monocypher" / "monocypher-ed25519.c"]
    cmd = [sys.executable, "-m", "ziglang", "cc", "-std=c99", "-O2", "-Wall", "-Wextra", "-Werror", "-o", str(exe),
           *map(str, src)]
    if sys.platform != "win32":
        cmd.append("-lm")
    r = subprocess.run(cmd, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return exe


def expected_packet() -> bytes:
    dev = Identity.from_seed(bytes(range(200, 232)))
    report = SensorReport("ESP32 room", ((1, 31.25), (2, 64.5), (8, 87.0)), seq=1)
    return Packet(PacketType.SENSOR, report.to_bytes(), msg_id=0x0A0B0C0D, timestamp=1_800_000_000).to_bytes(
        sign_with=dev, compress=False)


@pytest.mark.parametrize("profile", ["normal", "fast", "ultrasonic"])
def test_firmware_sound_decodes(sltx, tmp_path, profile):
    wav = tmp_path / "esp.wav"
    out = subprocess.run([str(sltx), str(wav), profile], capture_output=True, text=True, check=True).stdout.strip()
    assert bytes.fromhex(out) == expected_packet()  # identical bytes, signature included

    audio, rate = read_wav(wav)
    assert rate == 48000
    res = decode_audio(audio, profile=profile)
    assert len(res) == 1 and res[0].error is None
    p = res[0].packet
    assert p.signer == Identity.from_seed(bytes(range(200, 232))).public_key
    assert SensorReport.from_bytes(p.payload).describe() == ["Temperature: 31.25 °C", "Humidity: 64.5 %", "Battery: 87 %"]


def test_firmware_sound_survives_noisy_room(sltx, tmp_path):
    import numpy as np

    from soundlink.sim import channel

    wav = tmp_path / "esp.wav"
    subprocess.run([str(sltx), str(wav), "normal"], capture_output=True, check=True)
    audio, _ = read_wav(wav)
    res = decode_audio(channel(audio, 48000, snr_db=5, rng=np.random.default_rng(9)), profile="normal")
    assert res and res[0].packet is not None and res[0].packet.payload == Packet.from_bytes(expected_packet()).payload
