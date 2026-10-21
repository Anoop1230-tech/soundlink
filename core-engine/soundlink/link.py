"""High-level API that the app modules use: packet -> sound -> packet."""

from __future__ import annotations

import time
from dataclasses import dataclass, field

import numpy as np

from . import transport
from .crypto import Identity
from .modem import Demodulator, Frame, Modem, Profile
from .packet import Packet, PacketError, ReplayGuard


class SoundLink:
    """Sender side."""

    def __init__(
        self,
        profile: Profile | str = "normal",
        identity: Identity | None = None,
        key: bytes | None = None,
        volume: float = 0.5,
    ):
        self.modem = Modem(profile, volume)
        self.identity = identity
        self.key = key

    @property
    def sample_rate(self) -> int:
        return self.modem.profile.sample_rate

    def encode(self, packet: Packet, sign: bool = True, encrypt: bool = True, repeat: int = 1) -> np.ndarray:
        data = packet.to_bytes(
            sign_with=self.identity if sign else None,
            key=self.key if encrypt else None,
        )
        frames = [self.modem.encode_frame(c) for c in transport.split(data)]
        gap = np.zeros(int(0.1 * self.sample_rate), dtype=np.float32)
        parts: list[np.ndarray] = []
        for _ in range(max(1, repeat)):
            for f in frames:
                parts += [f, gap]
        return np.concatenate(parts)


@dataclass
class Received:
    packet: Packet | None
    error: str | None = None
    frames: list[Frame] = field(default_factory=list)
    received_at: float = field(default_factory=time.time)


class Receiver:
    """Receiver side. Feed microphone audio, get packets back."""

    def __init__(
        self,
        profile: Profile | str = "normal",
        key: bytes | None = None,
        trusted: set[bytes] | None = None,
        replay_guard: ReplayGuard | None = None,
        threshold: float | None = None,
    ):
        """
        key: decrypt encrypted packets with this key.
        trusted: if given, signed packets must come from one of these public keys,
                 and unsigned packets are rejected.
        replay_guard: if given, old or repeated packets are rejected.
        """
        self.demod = Demodulator(profile, threshold)
        self.key = key
        self.trusted = trusted
        self.replay_guard = replay_guard
        self._reassembler = transport.Reassembler()
        self._frames: list[Frame] = []

    def _handle(self, data: bytes) -> Received:
        frames, self._frames = self._frames, []
        try:
            packet = Packet.from_bytes(data, self.key)
            if self.trusted is not None and packet.signer not in self.trusted:
                raise PacketError("sender is not trusted")
            if self.replay_guard is not None:
                self.replay_guard.check(packet)
        except PacketError as exc:
            return Received(None, str(exc), frames)
        return Received(packet, None, frames)

    def feed(self, samples: np.ndarray) -> list[Received]:
        return self._process(self.demod.feed(samples))

    def flush(self) -> list[Received]:
        return self._process(self.demod.flush())

    def _process(self, frames: list[Frame]) -> list[Received]:
        out = []
        for frame in frames:
            self._frames.append(frame)
            data = self._reassembler.add(frame.data)
            if data is not None:
                out.append(self._handle(data))
        return out


def decode_audio(audio: np.ndarray, **kwargs) -> list[Received]:
    """Decode a whole recording at once."""
    rx = Receiver(**kwargs)
    return rx.feed(audio) + rx.flush()
