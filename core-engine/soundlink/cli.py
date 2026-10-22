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
        if item is None:
            item = _extra(p)
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


def _extra(p):
    from . import extras

    if p.type == PacketType.EMERGENCY:
        a = extras.Alert.from_bytes(p.payload)
        return f"{extras.SEVERITY[a.severity]} {extras.ALERT_KIND[a.kind]} [{a.area}] {a.title}: {a.message}"
    if p.type == PacketType.SENSOR:
        r = extras.SensorReport.from_bytes(p.payload)
        return f"{r.name} #{r.seq}: " + ", ".join(r.describe())
    if p.type == PacketType.FILE_HANDSHAKE:
        o = extras.FileOffer.from_bytes(p.payload)
        return f"file {o.name} ({o.size} bytes) " + (o.url if o.mode == extras.FILE_LINK else "inline")
    return None


def cmd_alert(args) -> None:
    from .extras import ALERT_KIND, SEVERITY, Alert

    sev = {v.lower(): k for k, v in SEVERITY.items()}[args.severity]
    kind = [k for k, v in ALERT_KIND.items() if v.lower().startswith(args.kind)][0]
    expires = int(time.time() + args.hours * 3600) if args.hours else 0
    a = Alert(args.title, args.message, sev, kind, args.area, expires=expires)
    link = _sender(args)
    wave = link.encode(Packet(PacketType.EMERGENCY, a.to_bytes()), encrypt=False, repeat=args.repeat)
    if args.out:
        audio.write_wav(args.out, wave, link.sample_rate)
        print(f"wrote {args.out} ({len(wave) / link.sample_rate:.1f}s)")
    else:
        print(f"playing alert ({len(wave) / link.sample_rate:.1f}s)")
        audio.play(wave, link.sample_rate)


def cmd_sendfile(args) -> None:
    from pathlib import Path

    from .extras import INLINE_MAX, FileOffer, guess_mime
    from .files import FileShare

    path = Path(args.file)
    link = _sender(args)
    share = None
    if args.inline or path.stat().st_size <= min(args.inline_max, INLINE_MAX):
        offer = FileOffer.inline(path.name, path.read_bytes(), guess_mime(path.name))
        print(f"sending {path.name} inside the sound ({offer.size} bytes)")
    else:
        share = FileShare(path, timeout_s=args.minutes * 60).start()
        offer = share.offer()
        print(f"serving {path.name} at {offer.url} for {args.minutes} min (same Wi-Fi only)")
    wave = link.encode(Packet(PacketType.FILE_HANDSHAKE, offer.to_bytes()), encrypt=False, repeat=args.repeat)
    print(f"playing offer ({len(wave) / link.sample_rate:.1f}s, {args.profile})")
    audio.play(wave, link.sample_rate)
    if share:
        try:
            print("waiting for downloads, Ctrl+C to stop")
            while share._thread.is_alive():
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        finally:
            print(f"{share.downloads} download(s)")
            share.stop()


def cmd_getfile(args) -> None:
    from .extras import FileOffer
    from .files import fetch

    rx = Receiver(args.profile)
    print(f"listening for a file offer ({args.profile})...")
    for block in audio.listen(PROFILES[args.profile].sample_rate):
        for r in rx.feed(block):
            if r.packet is None or r.packet.type != PacketType.FILE_HANDSHAKE:
                continue
            offer = FileOffer.from_bytes(r.packet.payload)
            print(f"got offer: {offer.name} ({offer.size} bytes)")
            print(f"saved {fetch(offer, args.folder)}")
            return


def cmd_qr(args) -> None:
    """Show a message as QR code(s) instead of sound (fallback)."""
    import segno

    from .fallback import to_qr_texts

    link = _sender(args)
    packet = Packet(PacketType.TEXT, args.text.encode()).to_bytes(sign_with=link.identity, key=link.key)
    texts = to_qr_texts(packet)
    for i, t in enumerate(texts, 1):
        qr = segno.make(t, error="m")
        if args.out:
            name = args.out if len(texts) == 1 else args.out.replace(".png", f"-{i}.png")
            qr.save(name, scale=8)
            print(f"saved {name}")
        else:
            print(f"QR {i}/{len(texts)} (scan with SoundLink: Receive -> Scan QR)")
            qr.terminal(compact=True)


def cmd_testsend(args) -> None:
    """Play numbered test packets so a receiver can measure the real success rate."""
    from .fallback import make_test_payload

    link = _sender(args)
    print(f"playing {args.count} test packets of {args.size} bytes ({args.profile})")
    for i in range(args.count):
        wave = link.encode(Packet(0x70, make_test_payload(args.profile, i, args.count, args.size)), encrypt=False)
        print(f"  {i + 1}/{args.count}")
        audio.play(wave, link.sample_rate)
        time.sleep(args.pause)


def cmd_testrecv(args) -> None:
    from .fallback import SoundTestScore

    rx = Receiver(args.profile)
    score = SoundTestScore(args.profile)
    print(f"listening for test packets ({args.profile}) for {args.seconds:.0f}s, Ctrl+C to stop early")
    end = time.time() + args.seconds
    try:
        for block in audio.listen(PROFILES[args.profile].sample_rate):
            for r in rx.feed(block):
                if r.packet is not None and r.packet.type == 0x70 and r.frames:
                    f = r.frames[0]
                    if score.add(r.packet.payload, f.quality, f.corrected, time.time()):
                        print(f"  got {len(score.good)}/{score.total}")
            if time.time() > end or (score.total and len(score.good) == score.total):
                break
    except KeyboardInterrupt:
        pass
    print(score.summary())


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


def _listen_window(rx: Receiver, seconds: float):
    """Listen for a while and return everything decoded."""
    out = []
    end = time.time() + seconds
    for block in audio.listen(48000):
        out += rx.feed(block)
        if time.time() > end:
            break
    return out


def _identity(path: str) -> Identity:
    from pathlib import Path

    p = Path(path)
    if not p.exists():
        Identity.generate().save(p)
        print(f"created a new device key in {p}")
    return Identity.load(p)


def cmd_teach(args) -> None:
    """Laptop as the teacher: plays a rotating attendance code, records students."""
    from . import access as A

    me = _identity(args.key_file)
    cls = A.ClassSession(args.title)
    link = SoundLink(args.profile, volume=args.volume)
    rx = Receiver(args.profile)
    print(f"Class '{args.title}' started. Students: Access -> Attendance -> I'm a student. Ctrl+C to finish.")
    try:
        while True:
            audio.play(link.encode_bytes(cls.beacon(me)), link.sample_rate)
            for r in _listen_window(rx, 6):
                if r.packet is None or r.packet.type != PacketType.ATTENDANCE:
                    continue
                try:
                    a, ack, new = cls.check_in(r.packet, me)
                except (A.AccessError, PacketError) as exc:
                    print(f"  refused: {exc}")
                    continue
                if new:
                    print(f"  present: {a.name}  ({len(cls.present)} total)")
                audio.play(link.encode_bytes(ack), link.sample_rate)
    except KeyboardInterrupt:
        pass
    out = args.out or f"attendance-{time.strftime('%Y%m%d-%H%M')}.csv"
    with open(out, "w", encoding="utf-8", newline="") as f:
        f.write(cls.csv())
    print(f"\n{len(cls.present)} present, saved to {out}")
    for p in cls.problems:
        print(f"  warning: {p}")


def cmd_door(args) -> None:
    """Laptop as a door: asks phones to prove who they are, logs who opened it."""
    import json
    from pathlib import Path

    from . import access as A

    me = _identity(args.key_file)
    state = Path(args.state)
    door = A.Door.from_dict(json.loads(state.read_text())) if state.exists() else A.Door(args.name)
    link = SoundLink(args.profile, volume=args.volume)
    rx = Receiver(args.profile)
    print(f"Door '{door.name}' ({len(door.allowed)} phones allowed). Ctrl+C to stop.")
    try:
        while True:
            audio.play(link.encode_bytes(door.challenge(me)), link.sample_rate)
            for r in _listen_window(rx, 6):
                if r.packet is None or r.packet.type != PacketType.DOOR_UNLOCK:
                    continue
                try:
                    if r.packet.payload[:1] == bytes([A.DOOR_ENROLL]):
                        pub, name = A.read_enroll(r.packet, me)
                        if input(f"  allow '{name}' ({pub.hex()[:16]})? [y/N] ").strip().lower() == "y":
                            door.allowed[pub.hex()] = name
                            print("  added")
                        continue
                    status, res = door.open(r.packet, me)
                except (A.AccessError, PacketError) as exc:
                    print(f"  refused: {exc}")
                    continue
                print(f"  {door.log[-1]['who']}: {A.DOOR_STATUS[status]}")
                audio.play(link.encode_bytes(res), link.sample_rate)
                if status == A.DOOR_OK:
                    print("  *** OPEN ***")
            state.write_text(json.dumps(door.to_dict(), indent=2))
    except KeyboardInterrupt:
        state.write_text(json.dumps(door.to_dict(), indent=2))


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

    p = sub.add_parser("qr", help="show a message as QR code(s) (fallback)")
    p.add_argument("text")
    p.add_argument("--out", help="save PNG instead of printing in the terminal")
    common(p, sender=True)
    p.set_defaults(func=cmd_qr)

    p = sub.add_parser("testsend", help="real-device test: play numbered packets")
    p.add_argument("--count", type=int, default=10)
    p.add_argument("--size", type=int, default=64)
    p.add_argument("--pause", type=float, default=0.5)
    common(p, sender=True)
    p.set_defaults(func=cmd_testsend)

    p = sub.add_parser("testrecv", help="real-device test: count what arrived")
    p.add_argument("--seconds", type=float, default=120)
    common(p)
    p.set_defaults(func=cmd_testrecv)

    p = sub.add_parser("alert", help="broadcast an emergency alert")
    p.add_argument("title")
    p.add_argument("message", nargs="?", default="")
    p.add_argument("--severity", choices=["info", "warning", "danger"], default="warning")
    p.add_argument("--kind", default="general", help="general, flood, fire, earthquake, cyclone, medical, police, evacuate, all")
    p.add_argument("--area", default="")
    p.add_argument("--hours", type=float, default=0, help="alert ends after this many hours")
    p.add_argument("--out", help="save to WAV (e.g. for a loudspeaker or FM radio)")
    common(p, sender=True)
    p.set_defaults(func=cmd_alert)

    p = sub.add_parser("sendfile", help="share a file (small: inside the sound, big: over Wi-Fi)")
    p.add_argument("file")
    p.add_argument("--inline", action="store_true", help="always send the file itself by sound")
    p.add_argument("--inline-max", type=int, default=1500)
    p.add_argument("--minutes", type=float, default=10)
    common(p, sender=True)
    p.set_defaults(func=cmd_sendfile)

    p = sub.add_parser("getfile", help="listen for a file and save it")
    p.add_argument("--folder", default="received")
    common(p)
    p.set_defaults(func=cmd_getfile)

    p = sub.add_parser("teach", help="laptop teacher: rotating attendance code")
    p.add_argument("title")
    p.add_argument("--out", help="CSV file for the attendance list")
    p.add_argument("--key-file", default="teacher.key")
    p.add_argument("--profile", choices=PROFILES, default="ultrasonic")
    p.add_argument("--volume", type=float, default=0.8)
    p.set_defaults(func=cmd_teach)

    p = sub.add_parser("door", help="laptop door: unlock by phone")
    p.add_argument("name")
    p.add_argument("--state", default="door.json", help="allowed phones and log")
    p.add_argument("--key-file", default="door.key")
    p.add_argument("--profile", choices=PROFILES, default="normal")
    p.add_argument("--volume", type=float, default=0.7)
    p.set_defaults(func=cmd_door)

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
