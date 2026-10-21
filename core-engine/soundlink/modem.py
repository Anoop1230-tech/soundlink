"""Sound modem: turns bytes into audio and back.

Modulation is multi-tone FSK (MFSK). The band is split into `groups`; each
group has 16 tones and plays exactly one of them per symbol, so one symbol
carries 4 bits per group. With 4 groups that's 2 bytes per symbol.

One frame on air:

    [chirp preamble] [gap] [length block] [data block] [tail]

- The chirp is found with a matched filter, which gives sample-exact timing.
- Length block: 2-byte data length + 6 Reed-Solomon parity bytes.
- Data block: data + Reed-Solomon parity (profile.nsym per 255-byte block).
- The receiver skips the first 20% and last 10% of every symbol so echoes and
  small clock drift between devices don't hurt.
"""

from __future__ import annotations

from dataclasses import dataclass
from math import ceil

import numpy as np

from . import fec

TONES = 16
LEN_FIELD = 2
LEN_NSYM = 6
MAX_FRAME_DATA = 240
SKIP_FRONT = 0.20
SKIP_BACK = 0.10
FADE = 0.05
TAIL_S = 0.05
FILTER_TAPS = 255


@dataclass(frozen=True)
class Profile:
    name: str
    base_freq: float
    spacing: float
    groups: int
    symbol_s: float
    nsym: int
    preamble_s: float = 0.16
    gap_s: float = 0.03
    sample_rate: int = 48000
    threshold: float = 0.3

    @property
    def symbol_len(self) -> int:
        return int(round(self.symbol_s * self.sample_rate))

    @property
    def num_tones(self) -> int:
        return self.groups * TONES

    @property
    def low_freq(self) -> float:
        return self.base_freq

    @property
    def high_freq(self) -> float:
        return self.base_freq + self.spacing * (self.num_tones - 1)

    @property
    def raw_bytes_per_s(self) -> float:
        return self.groups * 4 / 8 / self.symbol_s


PROFILES: dict[str, Profile] = {
    # Audible, most reliable. Good default for phones and laptops.
    "normal": Profile("normal", base_freq=1500, spacing=62.5, groups=4, symbol_s=0.048, nsym=32),
    # Audible, twice as fast, needs a quieter room.
    "fast": Profile("fast", base_freq=1500, spacing=125, groups=4, symbol_s=0.024, nsym=32),
    # Near-ultrasonic (18-20 kHz), almost silent for adults, slower.
    "ultrasonic": Profile("ultrasonic", base_freq=18000, spacing=62.5, groups=2, symbol_s=0.048, nsym=16),
}


@dataclass
class Frame:
    data: bytes
    start: int  # sample index where the preamble starts
    score: float  # preamble match, 0..1
    quality: float  # average ratio of best tone to second-best tone
    corrected: int  # bytes fixed by Reed-Solomon


def _bytes_to_values(data: bytes, groups: int) -> np.ndarray:
    arr = np.frombuffer(data, dtype=np.uint8)
    nibbles = np.empty(len(arr) * 2, dtype=np.int64)
    nibbles[0::2] = arr >> 4
    nibbles[1::2] = arr & 0x0F
    pad = (-len(nibbles)) % groups
    if pad:
        nibbles = np.concatenate([nibbles, np.zeros(pad, dtype=np.int64)])
    return nibbles.reshape(-1, groups)


def _values_to_bytes(values: np.ndarray, nbytes: int) -> bytes:
    flat = values.reshape(-1)[: nbytes * 2].astype(np.uint8)
    return bytes((flat[0::2] << 4) | flat[1::2])


def _byte_confidence(confidence: np.ndarray, nbytes: int) -> list[float]:
    """A byte is only as sure as its weakest nibble."""
    flat = confidence.reshape(-1)[: nbytes * 2]
    return np.minimum(flat[0::2], flat[1::2]).tolist()


def _symbols_for(nbytes: int, groups: int) -> int:
    return ceil(nbytes * 2 / groups)


def _rotate(values: np.ndarray, direction: int) -> np.ndarray:
    """Shift the value->tone mapping every symbol and group.

    Rooms make some frequencies very quiet. Without this, the same value would
    always land on the same quiet tone (think of a payload full of zero bytes),
    and errors would pile up in one place. With it they are spread out, which
    Reed-Solomon handles much better.
    """
    s = np.arange(values.shape[0])[:, None]
    g = np.arange(values.shape[1])[None, :]
    return (values + direction * (7 * s + 5 * g)) % TONES


def _bandpass_taps(low: float, high: float, sr: int, n: int = FILTER_TAPS) -> np.ndarray:
    m = np.arange(n) - (n - 1) / 2

    def lowpass(fc: float) -> np.ndarray:
        return 2 * fc / sr * np.sinc(2 * fc / sr * m)

    return (lowpass(high) - lowpass(low)) * np.blackman(n)


class BandFilter:
    """Streaming FIR band-pass filter that removes speech, hum and hiss outside our band."""

    def __init__(self, profile: Profile):
        sr = profile.sample_rate
        low = max(50.0, profile.low_freq - 4 * profile.spacing)
        high = min(sr / 2 - 100, profile.high_freq + 4 * profile.spacing)
        self.taps = _bandpass_taps(low, high, sr)
        self._state = np.zeros(len(self.taps) - 1)

    def process(self, x: np.ndarray) -> np.ndarray:
        joined = np.concatenate([self._state, x])
        self._state = joined[-(len(self.taps) - 1) :]
        return np.convolve(joined, self.taps, mode="valid")


class Modem:
    def __init__(self, profile: Profile | str = "normal", volume: float = 0.5):
        if isinstance(profile, str):
            profile = PROFILES[profile]
        if not 0 < volume <= 1:
            raise ValueError("volume must be in (0, 1]")
        self.profile = p = profile
        self.volume = volume
        sr = p.sample_rate
        self.L = L = p.symbol_len
        if p.high_freq + 2 * p.spacing >= sr / 2:
            raise ValueError("profile frequencies are above Nyquist")

        self.freqs = p.base_freq + p.spacing * np.arange(p.num_tones)
        t = np.arange(L) / sr
        fade = max(1, int(FADE * L))
        env = np.ones(L)
        env[:fade] = np.linspace(0, 1, fade)
        env[-fade:] = np.linspace(1, 0, fade)
        self._tones = np.sin(2 * np.pi * self.freqs[:, None] * t[None, :]) * env

        n = int(p.preamble_s * sr)
        tt = np.arange(n) / sr
        f0, f1 = p.low_freq - p.spacing, p.high_freq + p.spacing
        chirp = np.sin(2 * np.pi * (f0 * tt + (f1 - f0) / (2 * p.preamble_s) * tt**2))
        taper = max(1, n // 20)
        chirp[:taper] *= np.linspace(0, 1, taper)
        chirp[-taper:] *= np.linspace(1, 0, taper)
        self.chirp = chirp
        self.gap_len = int(p.gap_s * sr)
        self.tail_len = int(TAIL_S * sr)

        self._a0, self._a1 = int(SKIP_FRONT * L), L - int(SKIP_BACK * L)
        idx = np.arange(self._a0, self._a1)
        window = np.hanning(len(idx))
        self._analysis = np.exp(-2j * np.pi * self.freqs[:, None] * idx[None, :] / sr) * window
        self.len_symbols = _symbols_for(LEN_FIELD + LEN_NSYM, p.groups)

    # ---------- sending ----------

    def frame_symbols(self, nbytes: int) -> int:
        return self.len_symbols + _symbols_for(fec.encoded_len(nbytes, self.profile.nsym), self.profile.groups)

    def frame_duration(self, nbytes: int) -> float:
        n = len(self.chirp) + self.gap_len + self.frame_symbols(nbytes) * self.L + self.tail_len
        return n / self.profile.sample_rate

    def _symbols_audio(self, values: np.ndarray) -> np.ndarray:
        g = self.profile.groups
        tones = _rotate(values, +1)
        audio = np.zeros((len(values), self.L))
        for group in range(g):
            audio += self._tones[group * TONES + tones[:, group]]
        return (audio / g).reshape(-1)

    def encode_frame(self, data: bytes) -> np.ndarray:
        if not 0 < len(data) <= MAX_FRAME_DATA:
            raise ValueError(f"frame data must be 1..{MAX_FRAME_DATA} bytes")
        g = self.profile.groups
        length_block = fec.encode(len(data).to_bytes(LEN_FIELD, "big"), LEN_NSYM)
        body = fec.encode(data, self.profile.nsym)
        audio = np.concatenate(
            [
                self.chirp,
                np.zeros(self.gap_len),
                # Each block is modulated on its own so its tone rotation starts at 0,
                # the same way the receiver demodulates it.
                self._symbols_audio(_bytes_to_values(length_block, g)),
                self._symbols_audio(_bytes_to_values(body, g)),
                np.zeros(self.tail_len),
            ]
        )
        return (audio * self.volume).astype(np.float32)

    # ---------- receiving ----------

    def demodulate(self, x: np.ndarray, start: int, count: int) -> tuple[np.ndarray, np.ndarray]:
        """Returns (values, confidence), both shaped (count, groups).

        confidence = best tone / second-best tone. Near 1 means a coin flip.
        """
        idx = start + np.arange(count)[:, None] * self.L + np.arange(self._a0, self._a1)[None, :]
        mags = np.abs(x[idx] @ self._analysis.T).reshape(count, self.profile.groups, TONES)
        values = _rotate(mags.argmax(axis=2), -1)
        top2 = np.sort(mags, axis=2)[:, :, -2:]
        confidence = top2[:, :, 1] / (top2[:, :, 0] + 1e-12)
        return values, confidence


def _xcorr(x: np.ndarray, template: np.ndarray) -> np.ndarray:
    """Cross-correlation r[k] = sum(x[k+j] * template[j]) for every full overlap."""
    n = len(x) + len(template) - 1
    nfft = 1 << (n - 1).bit_length()
    r = np.fft.irfft(np.fft.rfft(x, nfft) * np.conj(np.fft.rfft(template, nfft)), nfft)
    return r[: len(x) - len(template) + 1]


class Demodulator:
    """Streaming receiver. Feed it audio in any chunk size; it returns decoded frames."""

    def __init__(self, profile: Profile | str = "normal", threshold: float | None = None):
        self.modem = Modem(profile)
        self.profile = self.modem.profile
        self.threshold = self.profile.threshold if threshold is None else threshold
        self.filter = BandFilter(self.profile)
        self.buf = np.zeros(0)
        self.offset = 0  # absolute sample index of buf[0]
        self.errors = 0  # preambles found but frame could not be decoded
        self._pending: tuple[int, float] | None = None
        self._lookahead = int(0.005 * self.profile.sample_rate)
        self._chirp_norm = float(np.linalg.norm(self.modem.chirp))

    def _drop(self, n: int) -> None:
        n = max(0, min(n, len(self.buf)))
        self.buf = self.buf[n:]
        self.offset += n

    def _find_preamble(self) -> tuple[int, float] | None:
        m = len(self.modem.chirp)
        if len(self.buf) < m + self._lookahead:
            return None
        corr = _xcorr(self.buf, self.modem.chirp)
        csum = np.concatenate([[0.0], np.cumsum(self.buf**2)])
        energy = csum[m:] - csum[:-m]
        norm = corr / (np.sqrt(np.maximum(energy, 0)) * self._chirp_norm + 1e-9)
        hits = np.flatnonzero(norm > self.threshold)
        if len(hits) == 0:
            self._drop(len(norm) - self._lookahead)
            return None
        i = int(hits[0])
        if i + self._lookahead >= len(norm):
            self._drop(i)  # peak may still be rising; wait for more audio
            return None
        p = i + int(np.argmax(norm[i : i + self._lookahead]))
        return p, float(norm[p])

    def _try_decode(self, p: int, score: float) -> tuple[Frame | None, int] | None:
        """None = need more audio. Otherwise (frame or None on failure, samples consumed)."""
        mod, prof = self.modem, self.profile
        skip_on_fail = p + len(mod.chirp)
        ds = p + len(mod.chirp) + mod.gap_len
        if len(self.buf) < ds + mod.len_symbols * mod.L:
            return None
        values, conf = mod.demodulate(self.buf, ds, mod.len_symbols)
        n = LEN_FIELD + LEN_NSYM
        try:
            length_bytes, _ = fec.decode(_values_to_bytes(values, n), LEN_NSYM, _byte_confidence(conf, n))
        except fec.FECError:
            return None, skip_on_fail
        length = int.from_bytes(length_bytes, "big")
        if not 0 < length <= MAX_FRAME_DATA:
            return None, skip_on_fail

        body_len = fec.encoded_len(length, prof.nsym)
        nb = _symbols_for(body_len, prof.groups)
        end = ds + (mod.len_symbols + nb) * mod.L
        if len(self.buf) < end:
            return None
        values, conf = mod.demodulate(self.buf, ds + mod.len_symbols * mod.L, nb)
        try:
            data, corrected = fec.decode(
                _values_to_bytes(values, body_len), prof.nsym, _byte_confidence(conf, body_len)
            )
        except fec.FECError:
            return None, skip_on_fail
        quality = float(np.median(conf))
        return Frame(data, self.offset + p, score, quality, corrected), end

    def feed(self, samples: np.ndarray) -> list[Frame]:
        x = np.asarray(samples, dtype=np.float64).reshape(-1)
        self.buf = np.concatenate([self.buf, self.filter.process(x)])
        frames: list[Frame] = []
        while True:
            if self._pending is None:
                self._pending = self._find_preamble()
                if self._pending is None:
                    break
            result = self._try_decode(*self._pending)
            if result is None:
                break
            frame, consumed = result
            self._pending = None
            if frame is None:
                self.errors += 1
            else:
                frames.append(frame)
            self._drop(consumed)
        return frames

    def flush(self) -> list[Frame]:
        """Push silence through so the last frame in the buffer gets decoded."""
        return self.feed(np.zeros(len(self.modem.chirp) + len(self.filter.taps)))
