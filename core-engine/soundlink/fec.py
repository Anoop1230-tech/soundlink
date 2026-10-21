"""Reed-Solomon error correction so a few wrong bytes from noise can be fixed.

With `nsym` parity bytes per 255-byte block, RS can fix nsym/2 unknown errors,
or up to nsym errors if we tell it which bytes are probably wrong ("erasures").
The modem knows how confident it was about every byte, so when a normal decode
fails we retry with the least-confident bytes marked as erasures.
"""

from __future__ import annotations

from functools import lru_cache
from math import ceil
from typing import Sequence

from reedsolo import RSCodec

BLOCK = 255


class FECError(ValueError):
    pass


@lru_cache(maxsize=16)
def _codec(nsym: int) -> RSCodec:
    return RSCodec(nsym, nsize=BLOCK)


def encoded_len(n: int, nsym: int) -> int:
    """Length after encoding n bytes (data is split into 255-byte blocks)."""
    return n + nsym * ceil(n / (BLOCK - nsym))


def encode(data: bytes, nsym: int) -> bytes:
    return bytes(_codec(nsym).encode(data))


def _decode_block(block: bytes, nsym: int, confidence: Sequence[float] | None) -> tuple[bytes, int]:
    codec = _codec(nsym)
    try:
        message, _, errata = codec.decode(bytearray(block))
        return bytes(message), len(errata)
    except Exception:  # reedsolo raises several error types on garbage input
        if confidence is None:
            raise FECError("too many errors to correct") from None

    order = sorted(range(len(block)), key=lambda i: confidence[i])
    # Never erase all parity bytes; keep some to check the result is real.
    for k in sorted({max(1, nsym // 4), nsym // 2, (3 * nsym) // 4}):
        try:
            message, _, errata = codec.decode(bytearray(block), erase_pos=order[:k])
            return bytes(message), len(errata)
        except Exception:
            continue
    raise FECError("too many errors to correct")


def decode(data: bytes, nsym: int, confidence: Sequence[float] | None = None) -> tuple[bytes, int]:
    """Returns (original data, number of bytes that were corrected).

    confidence: optional score per byte (higher = more sure), same length as data.
    """
    if confidence is not None and len(confidence) != len(data):
        raise ValueError("confidence must have one value per byte")
    out, fixed = [], 0
    for i in range(0, len(data), BLOCK):
        conf = None if confidence is None else confidence[i : i + BLOCK]
        message, n = _decode_block(data[i : i + BLOCK], nsym, conf)
        out.append(message)
        fixed += n
    return b"".join(out), fixed
