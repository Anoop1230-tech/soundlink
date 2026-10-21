"""Fake room for tests and benchmarks: echo, clock drift, noise, random delay."""

from __future__ import annotations

import numpy as np


def channel(
    audio: np.ndarray,
    sample_rate: int,
    snr_db: float = 20.0,
    echo: bool = True,
    drift_ppm: float = 50.0,
    gain: float = 0.3,
    rng: np.random.Generator | None = None,
) -> np.ndarray:
    rng = rng or np.random.default_rng()
    x = np.asarray(audio, dtype=np.float64)

    if echo:  # a few reflections, 3-25 ms later and quieter
        out = x.copy()
        for delay_ms, level in ((3, 0.5), (11, 0.3), (25, 0.15)):
            d = int(delay_ms * sample_rate / 1000)
            out[d:] += level * x[:-d]
        x = out

    if drift_ppm:  # sender and receiver sound cards never run at exactly the same speed
        ratio = 1 + drift_ppm * 1e-6
        t = np.arange(int(len(x) / ratio)) * ratio
        x = np.interp(t, np.arange(len(x)), x)

    x = x * gain
    lead = np.zeros(int(rng.uniform(0.1, 0.5) * sample_rate))
    x = np.concatenate([lead, x, np.zeros(int(0.2 * sample_rate))])

    # SNR is measured against the signal while it is playing, over the full band.
    power = np.mean((x[len(lead) : len(lead) + len(audio)]) ** 2)
    noise = rng.normal(0, np.sqrt(power / 10 ** (snr_db / 10)), len(x))
    return x + noise
