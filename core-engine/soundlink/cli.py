"""Command line tool for trying the engine on a laptop.

    python -m soundlink keygen me.key
    python -m soundlink send "hello" --key-file me.key
    python -m soundlink listen
    python -m soundlink encode "hello" out.wav
    python -m soundlink decode out.wav
    python -m soundlink bench
    python -m soundlink loopback
"""

from __future__ import annotations

import argparse
import sys
import time

import numpy as np

from . import audio, modules
from .crypto import Identity, key_from_pin
from .link import Receiver, SoundLink, decode_audio
from .modem import PROFILES
from .packet import Packet, PacketError, PacketType


def _sender(args) -> SoundLink:
    identity = Identity.load(args.key_file) if args.key_file else None
    key = key_from_pin(args.pin) if args.pin else None
    return SoundLink(args.profile, identity=identity, key=key, volume=args.volume)


def _show(result, t0: float | None = None) -> None:
    if result.packet is None:
        print(f"  [rejected] {result.error}")
        return
    p = result.packet
    name = p.type.name if isinstance(p.type, PacketType) else hex(p.type)
    who = p.signer.hex()[:16] + "..." if p.signer else "unsigned"
    try:
        item = modules.parse(p.type, p.payload)
        text = p.payload.hex() if item is None else str(item)
    except PacketError as exc:
        text = f"(bad payload: {exc}) {p.payload.hex()}"
    f = result.frames
    stats = ""
    if f:
        stats = (
            f" | frames={len(f)} score={min(x.score for x in f):.2f}"
            f" quality={min(x.quality for x in f):.1f} fixed={sum(x.corrected for x in f)}"
        )
    print(f"  [{name}] from {who}: {text}{stats}")


def cmd_keygen(args) -> None:
    identity = Identity.generate()
    identity.save(args.path)
    print(f"saved {args.path}\npublic key: {identity.public_key.hex()}")


def cmd_send(args) -> None:
    link = _sender(args)
    wave = link.encode(Packet(PacketType.TEXT, args.text.encode()), repeat=args.repeat)
    print(f"playing {len(wave) / link.sample_rate:.1f}s of sound ({args.profile})...")
    audio.play(wave, link.sample_rate)


def cmd_encode(args) -> None:
    link = _sender(args)
    wave = link.encode(Packet(PacketType.TEXT, args.text.encode()), repeat=args.repeat)
    audio.write_wav(args.out, wave, link.sample_rate)
    print(f"wrote {args.out} ({len(wave) / link.sample_rate:.1f}s)")


def cmd_share(args) -> None:
    """Send a contact, Wi-Fi network or offer (to the speaker, or to a WAV with --out)."""
    if args.kind == "contact":
        item = modules.Contact(args.name or "", args.phone or "", args.email or "", args.org or "")
    elif args.kind == "wifi":
        sec = modules.WifiSecurity[args.security.upper()]
        item = modules.Wifi(args.ssid or "", args.password or "", sec, args.hidden)
    else:
        expires = int(time.time() + args.days * 86400) if args.days else 0
        item = modules.Offer(args.title or "", args.shop or "", args.details or "", args.code or "", expires=expires)
    try:
        payload = item.to_bytes()
    except ValueError as exc:
        sys.exit(f"error: {exc}")
    link = _sender(args)
    wave = link.encode(Packet(modules.TYPE_OF[type(item)], payload), repeat=args.repeat)
    seconds = len(wave) / link.sample_rate
    if args.out:
        audio.write_wav(args.out, wave, link.sample_rate)
        print(f"wrote {args.out} ({seconds:.1f}s): {item}")
    else:
        print(f"playing {seconds:.1f}s: {item}")
        audio.play(wave, link.sample_rate)


def cmd_decode(args) -> None:
    samples, rate = audio.read_wav(args.wav)
    if rate != PROFILES[args.profile].sample_rate:
        sys.exit(f"WAV is {rate} Hz, expected {PROFILES[args.profile].sample_rate} Hz")
    key = key_from_pin(args.pin) if args.pin else None
    results = decode_audio(samples, profile=args.profile, key=key)
    if not results:
        print("nothing found")
    for r in results:
        _show(r)


def cmd_listen(args) -> None:
    key = key_from_pin(args.pin) if args.pin else None
    rx = Receiver(args.profile, key=key)
    print(f"listening ({args.profile}), Ctrl+C to stop...")
    try:
        for block in audio.listen(PROFILES[args.profile].sample_rate):
            for r in rx.feed(block):
                _show(r)
    except KeyboardInterrupt:
        pass


def cmd_loopback(args) -> None:
    """Play through this laptop's speaker and decode from its own mic."""
    link = _sender(args)
    text = args.text
    wave = link.encode(Packet(PacketType.TEXT, text.encode()))
    print(f"playing and recording {len(wave) / link.sample_rate:.1f}s ({args.profile})...")
    rec = audio.play_and_record(wave, link.sample_rate)
    print(f"mic level: peak={np.max(np.abs(rec)):.3f}")
    if args.save:
        audio.write_wav(args.save, rec, link.sample_rate)
    key = key_from_pin(args.pin) if args.pin else None
    results = decode_audio(rec, profile=args.profile, key=key)
    if not results:
        print("FAILED: nothing decoded (turn the volume up or try --profile normal)")
        sys.exit(1)
    for r in results:
        _show(r)
    ok = any(r.packet and r.packet.payload == text.encode() for r in results)
    print("OK" if ok else "FAILED: data did not match")
    sys.exit(0 if ok else 1)


def cmd_bench(args) -> None:
    """Simulated channel: noise, echo and clock drift. No speaker needed."""
    from .sim import channel

    rng = np.random.default_rng(args.seed)
    identity = Identity.generate()
    print(f"{'profile':<11} {'bytes':>5} {'airtime':>8} {'speed':>9}  " + "  ".join(f"{s:>5}dB" for s in args.snr))
    for name in args.profiles:
        link = SoundLink(name, identity=identity)
        for size in args.sizes:
            payload = bytes(rng.integers(0, 256, size, dtype=np.uint8))
            wave = link.encode(Packet(PacketType.TEXT, payload))
            seconds = len(wave) / link.sample_rate
            cells = []
            for snr in args.snr:
                ok = 0
                for _ in range(args.trials):
                    rx = channel(wave, link.sample_rate, snr_db=snr, rng=rng)
                    res = decode_audio(rx, profile=name)
                    ok += any(r.packet and r.packet.payload == payload for r in res)
                cells.append(f"{100 * ok / args.trials:>6.0f}%")
            print(f"{name:<11} {size:>5} {seconds:>7.2f}s {size / seconds:>6.1f}B/s  " + "  ".join(cells))


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="soundlink", description="Send data through sound.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    def common(p, sender=False):
        p.add_argument("--profile", choices=PROFILES, default="normal")
        p.add_argument("--pin", help="encrypt/decrypt with a shared PIN")
        if sender:
            p.add_argument("--key-file", help="sign with this identity (from keygen)")
            p.add_argument("--volume", type=float, default=0.5)
            p.add_argument("--repeat", type=int, default=1)

    p = sub.add_parser("keygen", help="create a signing identity")
    p.add_argument("path")
    p.set_defaults(func=cmd_keygen)

    p = sub.add_parser("send", help="play a text message")
    p.add_argument("text")
    common(p, sender=True)
    p.set_defaults(func=cmd_send)

    p = sub.add_parser("encode", help="save a text message as WAV")
    p.add_argument("text")
    p.add_argument("out")
    common(p, sender=True)
    p.set_defaults(func=cmd_encode)

    p = sub.add_parser("decode", help="decode a WAV recording")
    p.add_argument("wav")
    common(p)
    p.set_defaults(func=cmd_decode)

    p = sub.add_parser("share", help="send a contact, Wi-Fi network or offer")
    p.add_argument("kind", choices=["contact", "wifi", "offer"])
    p.add_argument("--out", help="save to a WAV file instead of playing")
    g = p.add_argument_group("contact")
    g.add_argument("--name")
    g.add_argument("--phone")
    g.add_argument("--email")
    g.add_argument("--org")
    g = p.add_argument_group("wifi")
    g.add_argument("--ssid")
    g.add_argument("--password")
    g.add_argument("--security", choices=[s.name.lower() for s in modules.WifiSecurity], default="wpa")
    g.add_argument("--hidden", action="store_true")
    g = p.add_argument_group("offer")
    g.add_argument("--title")
    g.add_argument("--shop")
    g.add_argument("--details")
    g.add_argument("--code")
    g.add_argument("--days", type=float, help="offer ends after this many days")
    common(p, sender=True)
    p.set_defaults(func=cmd_share)

    p = sub.add_parser("listen", help="listen on the microphone")
    common(p)
    p.set_defaults(func=cmd_listen)

    p = sub.add_parser("loopback", help="speaker -> own mic test")
    p.add_argument("text", nargs="?", default="hello from soundlink")
    p.add_argument("--save", help="save the recording to a WAV file")
    common(p, sender=True)
    p.set_defaults(func=cmd_loopback)

    p = sub.add_parser("bench", help="simulated noise benchmark")
    p.add_argument("--profiles", nargs="+", choices=PROFILES, default=list(PROFILES))
    p.add_argument("--sizes", nargs="+", type=int, default=[16, 64, 200])
    p.add_argument("--snr", nargs="+", type=float, default=[20, 10, 5, 0])
    p.add_argument("--trials", type=int, default=5)
    p.add_argument("--seed", type=int, default=1)
    p.set_defaults(func=cmd_bench)

    args = parser.parse_args(argv)
    t0 = time.time()
    args.func(args)
    if args.cmd == "bench":
        print(f"done in {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
