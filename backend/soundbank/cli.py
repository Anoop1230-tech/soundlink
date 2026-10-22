"""Laptop wallet for the demo bank.

    python -m soundbank.cli serve                       # run the bank on this laptop
    python -m soundbank.cli register "Anoop"            # make an account (Rs 1000 demo money)
    python -m soundbank.cli load 500                    # move Rs 500 into the offline wallet
    python -m soundbank.cli request 25 --note "tea"     # shop: play a request, wait for payment
    python -m soundbank.cli pay                         # payer: listen for a request and pay it
    python -m soundbank.cli sync                        # shop: send payments to the bank
    python -m soundbank.cli account
    python -m soundbank.cli unload
    python -m soundbank.cli demo                        # whole flow in a fake room, no mic needed

Everything is kept in a folder (default .soundlink, change with --home), so
two "people" can be simulated on one laptop with two folders.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from soundlink import Identity, Packet, PacketType, Receiver, SoundLink, audio
from soundlink.payment import Cert, Merchant, PaymentError, Wallet, request_packet, rupees

from .client import BankClient

DEFAULT_URL = "http://127.0.0.1:8000"


class Home:
    def __init__(self, path: str, url: str):
        self.dir = Path(path)
        self.dir.mkdir(parents=True, exist_ok=True)
        key = self.dir / "device.key"
        if not key.exists():
            Identity.generate().save(key)
        self.me = Identity.load(key)
        self.url = url
        self.bank = BankClient(url, self.me)

    def _load(self, name: str) -> dict | None:
        p = self.dir / name
        return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None

    def _save(self, name: str, data: dict) -> None:
        tmp = self.dir / (name + ".tmp")
        tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
        tmp.replace(self.dir / name)  # atomic, so a crash can't leave half a wallet

    def bank_pub(self) -> bytes:
        cached = self._load("bank.json")
        if cached and cached.get("url") == self.url:
            return bytes.fromhex(cached["public_key"])
        info = self.bank.info()
        self._save("bank.json", {"url": self.url, "public_key": info["public_key"]})
        return bytes.fromhex(info["public_key"])

    def wallet(self) -> Wallet:
        d = self._load("wallet.json")
        return Wallet.from_dict(d) if d else Wallet(self.bank_pub())

    def save_wallet(self, w: Wallet) -> None:
        self._save("wallet.json", w.to_dict())

    def merchant(self) -> Merchant:
        d = self._load("merchant.json")
        return Merchant.from_dict(d) if d else Merchant(self.bank_pub())

    def save_merchant(self, m: Merchant) -> None:
        self._save("merchant.json", m.to_dict())


def _paise(rs: str) -> int:
    value = round(float(rs) * 100)
    if value <= 0:
        raise argparse.ArgumentTypeError("amount must be more than 0")
    return value


def _show_account(a: dict) -> None:
    print(f"{a['name']}: online {rupees(a['online'])}" + ("  [FROZEN]" if a["frozen"] else ""))
    if a.get("debt"):
        print(f"  owes the bank {rupees(a['debt'])}")
    if a.get("cert"):
        c = a["cert"]
        print(f"  offline wallet #{c['seq']}: loaded {rupees(c['limit'])}, valid till {time.ctime(c['valid_until'])}")


def _listen_for(profile: str, want: set[int], timeout: float):
    """Listen on the mic until a packet of one of the wanted types arrives."""
    rx = Receiver(profile)
    end = time.time() + timeout
    for block in audio.listen(48000):
        for r in rx.feed(block):
            if r.packet is not None and r.packet.type in want:
                return r
            if r.packet is None:
                print(f"  (ignored: {r.error})")
        if time.time() > end:
            return None
    return None


def cmd_serve(args) -> None:
    import uvicorn

    print("Demo bank on http://0.0.0.0:%d (other devices use this laptop's Wi-Fi IP)" % args.port)
    print("WARNING: demo only. Anyone on this network can create accounts with fake money.")
    uvicorn.run("soundbank.main:app", host=args.host, port=args.port)


def cmd_register(args, h: Home) -> None:
    a = h.bank.register(args.name)
    print("Account created, you got demo money." if a["created"] else "Account already exists (name updated).")
    _show_account(a)


def cmd_account(args, h: Home) -> None:
    _show_account(h.bank.account())
    w = h.wallet()
    print(f"  offline wallet on this device: {rupees(w.balance)} left, {w.counter} payments")
    m = h.merchant()
    if m.unsynced:
        print(f"  {len(m.unsynced)} received payments waiting to sync ({rupees(sum(r.amount for r in m.unsynced))})")


def cmd_load(args, h: Home) -> None:
    w = h.wallet()
    r = h.bank.load(args.amount, w.state())
    w.install(Cert.from_bytes(bytes.fromhex(r["cert_hex"])), h.me.public_key)
    h.save_wallet(w)
    print(f"Offline wallet now holds {rupees(w.balance)}")
    _show_account(r)


def cmd_unload(args, h: Home) -> None:
    w = h.wallet()
    r = h.bank.unload(w.state())
    w.cert, w.counter, w.spent = None, 0, 0
    h.save_wallet(w)
    print(f"Moved {rupees(r['returned'])} back online")
    _show_account(r)


def cmd_sync(args, h: Home) -> None:
    m = h.merchant()
    todo = m.unsynced
    if not todo:
        print("Nothing to sync")
        return
    r = h.bank.sync([p.raw for p in todo])
    for p, res in zip(todo, r["results"]):
        print(f"  {rupees(p.amount)} #{p.counter}: {res['status']}" + (f" ({res['reason']})" if res.get("reason") else ""))
        p.synced = True  # settled, duplicate and rejected ones are all final; don't send again
    h.save_merchant(m)
    _show_account(r)


def cmd_request(args, h: Home) -> None:
    m = h.merchant()
    link = SoundLink(args.profile, volume=args.volume)
    req = m.new_request(args.amount, args.note)
    h.save_merchant(m)
    sound = link.encode_bytes(request_packet(req, h.me), repeat=2)
    print(f"Asking for {rupees(args.amount)}. Playing request...")
    audio.play(sound, link.sample_rate)
    print("Waiting for the payment (Ctrl+C to stop)...")
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        r = _listen_for(args.profile, {PacketType.PAYMENT}, deadline - time.time())
        if r is None:
            break
        try:
            rec, receipt, new = m.accept(r.packet, h.me, r.data)
        except PaymentError as exc:
            print(f"  payment refused: {exc}")
            continue
        h.save_merchant(m)
        print(("Received " if new else "Already had ") + f"{rupees(rec.amount)} (wallet #{rec.seq}, payment {rec.counter})")
        audio.play(link.encode_bytes(m.receipt_packet(receipt, h.me), repeat=2), link.sample_rate)
        print("Receipt played. Run 'sync' when online to get the money.")
        return
    print("No payment received")


def cmd_pay(args, h: Home) -> None:
    w = h.wallet()
    print(f"Wallet: {rupees(w.balance)}. Listening for a payment request...")
    r = _listen_for(args.profile, {PacketType.PAYMENT_REQUEST}, args.timeout)
    if r is None:
        sys.exit("No request heard")
    from soundlink.payment import PaymentRequest

    req = PaymentRequest.from_bytes(r.packet.payload)
    print(f"Request: {rupees(req.amount)} '{req.note}' from {r.packet.signer.hex()[:16]}")
    if not args.yes and input("Pay? [y/N] ").strip().lower() != "y":
        return
    raw = w.pay(r.packet, h.me)
    h.save_wallet(w)  # saved before playing: this money is gone now
    link = SoundLink(args.profile, volume=args.volume)
    for attempt in range(3):
        audio.play(link.encode_bytes(raw), link.sample_rate)
        rc = _listen_for(args.profile, {PacketType.PAYMENT_RECEIPT}, 15)
        if rc is not None:
            try:
                w.accept_receipt(rc.packet, h.me)
                h.save_wallet(w)
                print(f"Paid {rupees(req.amount)}. Receipt OK. Left: {rupees(w.balance)}")
                return
            except PaymentError as exc:
                print(f"  bad receipt: {exc}")
        print("  no receipt yet, playing the payment again")
    print("Paid, but no receipt was heard. The shop can still claim it.")


def cmd_demo(args) -> None:
    """Two people and a bank in one process, sound goes through a fake noisy room."""
    import tempfile

    from fastapi.testclient import TestClient

    from soundlink.link import decode_audio
    from soundlink.sim import channel

    from .main import create_app

    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
        http = TestClient(create_app(Path(tmp) / "bank"))

        def person(name):
            h = Home(str(Path(tmp) / name), "")
            h.bank = BankClient("", h.me, http)
            h.bank.register(name)
            return h

        def air(data: bytes):
            link = SoundLink(args.profile)
            heard = decode_audio(channel(link.encode_bytes(data), 48000, snr_db=10), profile=args.profile)
            assert heard and heard[0].packet is not None, "sound was not decoded"
            return heard[0]

        payer, shop = person("Asha"), person("Chai Shop")
        w = payer.wallet()
        r = payer.bank.load(30_000, w.state())
        w.install(Cert.from_bytes(bytes.fromhex(r["cert_hex"])), payer.me.public_key)
        print(f"1. Asha loads {rupees(w.balance)} into her offline wallet (online)")

        m = shop.merchant()
        req = m.new_request(2_000, "2 chai")
        print("2. Shop plays a request for Rs 20.00 (offline from here)")
        heard = air(request_packet(req, shop.me))
        raw = w.pay(heard.packet, payer.me)
        print(f"3. Asha's phone pays, wallet now {rupees(w.balance)}")
        heard = air(raw)
        rec, receipt, _ = m.accept(heard.packet, shop.me, heard.data)
        print(f"4. Shop checks the payment offline: OK {rupees(rec.amount)}")
        w.accept_receipt(air(m.receipt_packet(receipt, shop.me)).packet, payer.me)
        print("5. Asha hears the receipt")

        cheat = Wallet.from_dict(w.to_dict())
        cheat.counter, cheat.spent = 0, 0  # pretend the first payment never happened
        req2 = m.new_request(30_000, "big order")
        raw2 = cheat.pay(air(request_packet(req2, shop.me)).packet, payer.me)
        try:
            m.accept(air(raw2).packet, shop.me, raw2)
        except PaymentError as exc:
            print(f"6. Asha resets her wallet and tries to spend again: shop refuses ({exc})")

        other = person("Book Shop")
        m2 = other.merchant()
        cheat.counter, cheat.spent = 0, 0  # reset the copy once more
        req3 = m2.new_request(30_000, "books")
        raw3 = cheat.pay(air(request_packet(req3, other.me)).packet, payer.me)
        m2.accept(air(raw3).packet, other.me, raw3)
        print("7. A different shop (offline, never saw her) accepts the copied wallet")

        res = shop.bank.sync([p.raw for p in m.unsynced])
        print(f"8. Chai shop syncs: {[x['status'] for x in res['results']]}, balance {rupees(res['online'])}")
        res = other.bank.sync([p.raw for p in m2.unsynced])
        x = res["results"][0]
        print(f"9. Book shop syncs: {x['status']} ({x.get('reason')}), still gets paid: {rupees(res['online'])}")
        a = payer.bank.account()
        print(f"10. Bank froze Asha (frozen={a['frozen']}) and took the money back: {rupees(a['online'])} online")


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(prog="soundbank", description="SoundLink offline payments (demo money)")
    p.add_argument("--home", default=".soundlink", help="folder for this device's key and wallet")
    p.add_argument("--bank", default=DEFAULT_URL, help="bank URL")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("serve", help="run the demo bank")
    s.add_argument("--host", default="0.0.0.0")
    s.add_argument("--port", type=int, default=8000)

    s = sub.add_parser("register")
    s.add_argument("name")
    sub.add_parser("account")
    s = sub.add_parser("load")
    s.add_argument("rupees", type=_paise, metavar="RUPEES")
    sub.add_parser("unload")
    sub.add_parser("sync")
    for name in ("request", "pay", "demo"):
        s = sub.add_parser(name)
        s.add_argument("--profile", default="normal", choices=["normal", "fast", "ultrasonic"])
        s.add_argument("--volume", type=float, default=0.6)
        s.add_argument("--timeout", type=float, default=120)
        if name == "request":
            s.add_argument("rupees", type=_paise, metavar="RUPEES")
            s.add_argument("--note", default="")
        if name == "pay":
            s.add_argument("--yes", action="store_true", help="pay without asking")

    args = p.parse_args(argv)
    if hasattr(args, "rupees"):
        args.amount = args.rupees
    if args.cmd == "serve":
        return cmd_serve(args)
    if args.cmd == "demo":
        return cmd_demo(args)
    h = Home(args.home, args.bank)
    try:
        globals()[f"cmd_{args.cmd}"](args, h)
    except (RuntimeError, PaymentError) as exc:
        sys.exit(f"error: {exc}")


if __name__ == "__main__":
    main()
