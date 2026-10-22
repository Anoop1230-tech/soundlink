import time

import pytest

from soundlink import Identity, Packet, PacketType, SoundLink
from soundlink.link import decode_audio
from soundlink.payment import (
    MAX_PAYMENT,
    PAYMENT_SIZE,
    Cert,
    Merchant,
    PaymentError,
    Wallet,
    request_packet,
    rupees,
)

NOW = 1_800_000_000


@pytest.fixture
def world():
    bank, payer, shop = Identity.generate(), Identity.generate(), Identity.generate()
    wallet = Wallet(bank.public_key)
    wallet.install(Cert.issue(bank, payer.public_key, 1, 100_000, NOW + 86400), payer.public_key)
    return bank, payer, shop, wallet, Merchant(bank.public_key)


def pay(payer, shop, wallet, merchant, amount, note="tea"):
    req = merchant.new_request(amount, note, now=NOW)
    req_pkt = Packet.from_bytes(request_packet(req, shop))
    raw = wallet.pay(req_pkt, payer, now=NOW)
    rec, receipt, new = merchant.accept(Packet.from_bytes(raw), shop, raw, now=NOW)
    return raw, rec, receipt, new


def test_full_payment_flow(world):
    bank, payer, shop, wallet, merchant = world
    raw, rec, receipt, new = pay(payer, shop, wallet, merchant, 2500)
    assert new and rec.amount == 2500 and rec.note == "tea"
    assert wallet.balance == 97_500 and wallet.counter == 1
    assert len(Packet.from_bytes(raw).payload) == PAYMENT_SIZE
    assert len(raw) < 236  # fits in one sound frame

    assert len(wallet.pending) == 1
    r = wallet.accept_receipt(Packet.from_bytes(merchant.receipt_packet(receipt, shop)), payer)
    assert r.amount == 2500 and wallet.pending == []


def test_payment_over_sound(world):
    _, payer, shop, wallet, merchant = world
    req = merchant.new_request(1000, "chai", now=NOW)
    heard = decode_audio(SoundLink("fast").encode_bytes(request_packet(req, shop)), profile="fast")[0]
    raw = wallet.pay(heard.packet, payer, now=NOW)
    heard = decode_audio(SoundLink("fast").encode_bytes(raw), profile="fast")[0]
    rec, _, new = merchant.accept(heard.packet, shop, heard.data, now=NOW)
    assert new and rec.amount == 1000


def test_replayed_payment_gives_same_receipt_but_no_extra_money(world):
    _, payer, shop, wallet, merchant = world
    raw, _, receipt, _ = pay(payer, shop, wallet, merchant, 500)
    _, receipt2, new = merchant.accept(Packet.from_bytes(raw), shop, raw, now=NOW)
    assert not new and receipt2 == receipt and len(merchant.received) == 1


def test_payment_needs_open_request(world):
    _, payer, shop, wallet, merchant = world
    req = merchant.new_request(500, now=NOW)
    raw = wallet.pay(Packet.from_bytes(request_packet(req, shop)), payer, now=NOW)
    other = Merchant(merchant.bank_pub)  # never made this request
    with pytest.raises(PaymentError, match="no open request"):
        other.accept(Packet.from_bytes(raw), shop, raw, now=NOW)


def test_payment_for_another_merchant_rejected(world):
    _, payer, shop, wallet, merchant = world
    req = merchant.new_request(500, now=NOW)
    raw = wallet.pay(Packet.from_bytes(request_packet(req, shop)), payer, now=NOW)
    with pytest.raises(PaymentError, match="another merchant"):
        merchant.accept(Packet.from_bytes(raw), Identity.generate(), raw, now=NOW)


def test_wallet_limits(world):
    _, payer, shop, wallet, merchant = world
    with pytest.raises(ValueError):
        merchant.new_request(MAX_PAYMENT + 1, now=NOW)
    for _ in range(2):
        pay(payer, shop, wallet, merchant, MAX_PAYMENT)
    assert wallet.balance == 0
    req = merchant.new_request(1, now=NOW)
    with pytest.raises(PaymentError, match="not enough"):
        wallet.pay(Packet.from_bytes(request_packet(req, shop)), payer, now=NOW)


def test_fake_bank_certificate_rejected(world):
    _, payer, shop, _, merchant = world
    fake_bank = Identity.generate()
    wallet = Wallet(fake_bank.public_key)
    wallet.install(Cert.issue(fake_bank, payer.public_key, 1, 100_000, NOW + 100), payer.public_key)
    req = merchant.new_request(500, now=NOW)
    raw = wallet.pay(Packet.from_bytes(request_packet(req, shop)), payer, now=NOW)
    with pytest.raises(PaymentError, match="not from the bank"):
        merchant.accept(Packet.from_bytes(raw), shop, raw, now=NOW)


def test_stolen_certificate_rejected(world):
    """Someone copies a real certificate but signs with their own key."""
    bank, payer, shop, wallet, merchant = world
    thief = Identity.generate()
    req = merchant.new_request(500, now=NOW)
    raw = wallet.pay(Packet.from_bytes(request_packet(req, shop)), payer, now=NOW)
    forged = Packet(PacketType.PAYMENT, Packet.from_bytes(raw).payload).to_bytes(sign_with=thief, compress=False)
    with pytest.raises(PaymentError, match="not from the bank"):
        merchant.accept(Packet.from_bytes(forged), shop, forged, now=NOW)


def test_expired_certificate(world):
    bank, payer, shop, _, merchant = world
    wallet = Wallet(bank.public_key)
    wallet.install(Cert.issue(bank, payer.public_key, 1, 100_000, NOW - 1), payer.public_key)
    req = merchant.new_request(500, now=NOW)
    with pytest.raises(PaymentError, match="expired"):
        wallet.pay(Packet.from_bytes(request_packet(req, shop)), payer, now=NOW)


def test_merchant_catches_reset_wallet(world):
    """Payer copies the wallet file before paying and restores it to pay again."""
    _, payer, shop, wallet, merchant = world
    backup = wallet.to_dict()
    pay(payer, shop, wallet, merchant, 1000)
    cheat = Wallet.from_dict(backup)
    req = merchant.new_request(2000, now=NOW)
    raw = cheat.pay(Packet.from_bytes(request_packet(req, shop)), payer, now=NOW)
    with pytest.raises(PaymentError, match="double spending"):
        merchant.accept(Packet.from_bytes(raw), shop, raw, now=NOW)


def test_state_saves_and_loads(world):
    _, payer, shop, wallet, merchant = world
    pay(payer, shop, wallet, merchant, 700)
    assert Wallet.from_dict(wallet.to_dict()) == wallet
    assert Merchant.from_dict(merchant.to_dict()) == merchant


def test_rupees():
    assert rupees(12345) == "Rs 123.45" and rupees(5) == "Rs 0.05"
    assert time.time() < 4_000_000_000  # u32 timestamps are fine for a long time
