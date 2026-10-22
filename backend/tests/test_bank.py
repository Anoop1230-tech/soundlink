import time

import pytest
from fastapi.testclient import TestClient

from soundbank.auth import sign_headers
from soundbank.client import BankClient
from soundbank.main import create_app
from soundlink import Identity, Packet
from soundlink.payment import Cert, Merchant, Wallet, request_packet


@pytest.fixture
def http(tmp_path):
    return TestClient(create_app(tmp_path))


class Person:
    def __init__(self, http, name):
        self.id = Identity.generate()
        self.bank = BankClient("", self.id, http)
        self.acc = self.bank.register(name)
        bank_pub = bytes.fromhex(self.bank.info()["public_key"])
        self.wallet = Wallet(bank_pub)
        self.shop = Merchant(bank_pub)

    def load(self, amount):
        r = self.bank.load(amount, self.wallet.state())
        self.wallet.install(Cert.from_bytes(bytes.fromhex(r["cert_hex"])), self.id.public_key)
        return r

    def pay(self, merchant: "Person", amount, wallet=None):
        req = merchant.shop.new_request(amount, "test")
        raw = (wallet or self.wallet).pay(Packet.from_bytes(request_packet(req, merchant.id)), self.id)
        merchant.shop.accept(Packet.from_bytes(raw), merchant.id, raw)
        return raw

    def sync(self):
        r = self.bank.sync([p.raw for p in self.shop.unsynced])
        for p in self.shop.unsynced:
            p.synced = True
        return r


def test_register_gives_demo_money(http):
    a = Person(http, "Asha")
    assert a.acc["created"] and a.acc["online"] == 100_000 and a.acc["name"] == "Asha"
    again = a.bank.register("Asha V")
    assert not again["created"] and again["online"] == 100_000 and again["name"] == "Asha V"


def test_load_pay_sync_unload(http):
    payer, shop = Person(http, "Payer"), Person(http, "Shop")
    r = payer.load(50_000)
    assert r["online"] == 50_000 and payer.wallet.balance == 50_000

    payer.pay(shop, 12_000)
    payer.pay(shop, 3_000)
    res = shop.sync()
    assert [x["status"] for x in res["results"]] == ["settled", "settled"]
    assert res["online"] == 100_000 + 15_000
    assert shop.sync()["results"] == []  # nothing new

    # Same payments sent again: counted once.
    again = shop.bank.sync([p.raw for p in shop.shop.received])
    assert [x["status"] for x in again["results"]] == ["duplicate", "duplicate"]
    assert again["online"] == 115_000

    # Top up: unspent Rs 350 moves to the new certificate.
    r = payer.load(10_000)
    assert payer.wallet.balance == 45_000 and r["online"] == 40_000
    r = payer.bank.unload(payer.wallet.state())
    assert r["returned"] == 45_000 and r["online"] == 85_000 and r["cert"] is None


def test_wallet_limit_and_balance_checks(http):
    p = Person(http, "P")
    with pytest.raises(RuntimeError, match="not enough online"):
        p.load(100_001)
    p.load(100_000)
    with pytest.raises(RuntimeError, match="at most"):
        # Rs 1000 already offline + Rs 1500 more would be over the Rs 2000 limit
        p.bank.load(150_000, p.wallet.state())
    with pytest.raises(RuntimeError, match="not enough online"):
        p.bank.load(1, p.wallet.state())  # all Rs 1000 is already offline


def test_double_spend_is_caught_and_merchants_still_paid(http):
    cheat, shop1, shop2 = Person(http, "Cheat"), Person(http, "Shop1"), Person(http, "Shop2")
    cheat.load(30_000)
    backup = Wallet.from_dict(cheat.wallet.to_dict())  # copy the wallet before paying
    cheat.pay(shop1, 30_000)
    cheat.pay(shop2, 30_000, wallet=backup)  # same money again with the old copy

    assert shop1.sync()["results"][0]["status"] == "settled"
    r = shop2.sync()
    assert r["results"][0]["status"] == "settled_fraud"
    assert "same payment number" in r["results"][0]["reason"]
    assert r["online"] == 130_000  # merchant is protected

    acc = cheat.bank.account()
    assert acc["frozen"]
    assert acc["online"] == 70_000 - 30_000  # bank took back the double-spent money
    with pytest.raises(RuntimeError, match="frozen"):
        cheat.bank.load(1_000, cheat.wallet.state())


def test_lying_about_spending_is_caught(http):
    cheat, shop = Person(http, "Liar"), Person(http, "Shop")
    cheat.load(20_000)
    cheat.pay(shop, 15_000)
    shop.sync()
    with pytest.raises(RuntimeError, match="frozen"):
        cheat.bank.unload({"seq": 1, "counter": 0, "spent": 0})  # "I spent nothing"
    assert cheat.bank.account()["frozen"]


def test_payment_after_unload_is_fraud(http):
    """Pays offline, then unloads claiming the money is still there."""
    cheat, shop = Person(http, "Late"), Person(http, "Shop")
    cheat.load(20_000)
    old = Wallet.from_dict(cheat.wallet.to_dict())
    r = cheat.bank.unload(cheat.wallet.state())  # gets Rs 200 back online
    assert r["returned"] == 20_000
    cheat.pay(shop, 20_000, wallet=old)  # still spends the old certificate offline
    res = shop.sync()["results"][0]
    assert res["status"] == "settled_fraud" and "closed" in res["reason"]
    acc = cheat.bank.account()
    assert acc["frozen"] and acc["online"] == 80_000


def test_payment_for_someone_else_is_rejected(http):
    payer, shop, thief = Person(http, "P"), Person(http, "S"), Person(http, "T")
    payer.load(5_000)
    raw = payer.pay(shop, 5_000)
    res = thief.bank.sync([raw])["results"][0]
    assert res["status"] == "rejected" and "another merchant" in res["reason"]
    assert thief.bank.account()["online"] == 100_000


def test_garbage_and_fake_certificates_rejected(http):
    shop = Person(http, "S")
    fake_bank, payer = Identity.generate(), Identity.generate()
    w = Wallet(fake_bank.public_key)
    w.install(Cert.issue(fake_bank, payer.public_key, 1, 50_000, int(time.time()) + 100), payer.public_key)
    req = shop.shop.new_request(1000)
    raw = w.pay(Packet.from_bytes(request_packet(req, shop.id)), payer)
    res = shop.bank.sync([raw, b"\x00\x01"])["results"]
    assert res[0]["status"] == "rejected" and "not from the bank" in res[0]["reason"]
    assert res[1]["status"] == "rejected"


def test_requests_must_be_signed_and_fresh(http):
    me = Identity.generate()
    assert http.post("/register", json={"name": "x"}).status_code == 401
    body = b'{"name": "x"}'
    h = sign_headers(me, "POST", "/register", body, int(time.time()))
    assert http.post("/register", content=body, headers=h).status_code == 200
    assert http.post("/register", content=body, headers=h).status_code == 401  # replayed
    old = sign_headers(me, "POST", "/register", body, int(time.time()) - 3600)
    assert http.post("/register", content=body, headers=old).status_code == 401
    h = sign_headers(me, "POST", "/register", body, int(time.time()))
    assert http.post("/register", content=b'{"name": "evil"}', headers=h).status_code == 401  # body changed
    assert http.get("/account").status_code == 401
    # Two identical requests in the same second still both work (random nonce).
    t = int(time.time())
    for _ in range(2):
        assert http.get("/account", headers=sign_headers(me, "GET", "/account", b"", t)).status_code == 200
