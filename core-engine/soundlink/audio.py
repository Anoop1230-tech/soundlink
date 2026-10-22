"""Speaker / microphone / WAV helpers."""

from __future__ import annotations

import queue
import wave
from pathlib import Path
from typing import Iterator

import numpy as np


def write_wav(path: str | Path, audio: np.ndarray, sample_rate: int) -> None:
    pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2")
    with wave.open(path if hasattr(path, "write") else str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(pcm.tobytes())


def read_wav(path: str | Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as w:
        if w.getsampwidth() != 2:
            raise ValueError("only 16-bit WAV files are supported")
        rate, channels = w.getframerate(), w.getnchannels()
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
    audio = pcm.reshape(-1, channels).mean(axis=1) / 32768.0
    return audio, rate


def play(audio: np.ndarray, sample_rate: int) -> None:
    import sounddevice as sd

    sd.play(audio.astype(np.float32), sample_rate, blocking=True)


def listen(sample_rate: int, block_s: float = 0.1) -> Iterator[np.ndarray]:
    """Yields microphone blocks forever (stop with Ctrl+C)."""
    import sounddevice as sd

    q: queue.Queue[np.ndarray] = queue.Queue()

    def callback(indata, frames, time_info, status):  # runs on the audio thread
        q.put(indata[:, 0].copy())

    with sd.InputStream(
        samplerate=sample_rate,
        channels=1,
        dtype="float32",
        blocksize=int(block_s * sample_rate),
        callback=callback,
    ):
        while True:
            yield q.get()


def play_and_record(audio: np.ndarray, sample_rate: int, extra_s: float = 0.5) -> np.ndarray:
    """Plays through the speaker and records the mic at the same time."""
    import sounddevice as sd

    padded = np.concatenate([np.zeros(int(0.3 * sample_rate)), audio, np.zeros(int(extra_s * sample_rate))])
    rec = sd.playrec(padded.astype(np.float32).reshape(-1, 1), sample_rate, channels=1, blocking=True)
    return rec[:, 0]
