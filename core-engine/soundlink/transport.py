"""Splits packets that are too big for one sound frame into chunks and joins them back.

Chunk = transfer_id(2) | index(1) | total(1) | data

Sound is one-way (like a radio broadcast), so lost chunks can't be requested
again. The sender can repeat the whole transfer instead; duplicates are ignored.
"""

from __future__ import annotations

import os
import struct
import time
from dataclasses import dataclass, field

from .modem import MAX_FRAME_DATA

CHUNK_HEADER = struct.Struct(">HBB")
CHUNK_DATA = MAX_FRAME_DATA - CHUNK_HEADER.size
MAX_CHUNKS = 255


def split(data: bytes, transfer_id: int | None = None) -> list[bytes]:
    if not data:
        raise ValueError("nothing to send")
    total = -(-len(data) // CHUNK_DATA)
    if total > MAX_CHUNKS:
        raise ValueError(f"data too large ({len(data)} bytes)")
    if transfer_id is None:
        transfer_id = int.from_bytes(os.urandom(2), "big")
    return [
        CHUNK_HEADER.pack(transfer_id, i, total) + data[i * CHUNK_DATA : (i + 1) * CHUNK_DATA]
        for i in range(total)
    ]


@dataclass
class _Transfer:
    total: int
    parts: dict[int, bytes] = field(default_factory=dict)
    started: float = field(default_factory=time.monotonic)


class Reassembler:
    def __init__(self, timeout_s: float = 60.0):
        self.timeout_s = timeout_s
        self._open: dict[int, _Transfer] = {}
        self._done: dict[int, float] = {}

    def add(self, chunk: bytes) -> bytes | None:
        """Returns the full data when the last missing chunk arrives, else None."""
        if len(chunk) <= CHUNK_HEADER.size:
            return None
        tid, index, total = CHUNK_HEADER.unpack_from(chunk)
        if total == 0 or index >= total:
            return None
        now = time.monotonic()
        self._expire(now)
        if tid in self._done:
            return None  # repeated broadcast of something we already have

        transfer = self._open.get(tid)
        if transfer is None or transfer.total != total:
            transfer = self._open[tid] = _Transfer(total)
        transfer.parts[index] = chunk[CHUNK_HEADER.size :]
        if len(transfer.parts) < total:
            return None

        del self._open[tid]
        self._done[tid] = now
        return b"".join(transfer.parts[i] for i in range(total))

    def progress(self) -> dict[int, tuple[int, int]]:
        return {tid: (len(t.parts), t.total) for tid, t in self._open.items()}

    def _expire(self, now: float) -> None:
        self._open = {k: t for k, t in self._open.items() if now - t.started <= self.timeout_s}
        self._done = {k: t for k, t in self._done.items() if now - t <= self.timeout_s}
