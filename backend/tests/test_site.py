import io

import pytest
from fastapi.testclient import TestClient

from soundbank.main import create_app
from soundlink import Identity
from soundlink import access as A
from soundlink.audio import read_wav
from soundlink.link import decode_audio


@pytest.fixture
def http(tmp_path):
    return TestClient(create_app(tmp_path))


def phone_hears(http, user, profile="fast"):
    """Start a login in the 'browser' and decode the WAV like the phone's mic would."""
    start = http.post("/site/start", json={"user": user, "profile": profile}).json()
    wav = http.get(start["sound"]).content
    tmp = io.BytesIO(wav)
    import wave

    with wave.open(tmp) as w:
        assert w.getframerate() == 48000
    import tempfile, os

    fd, path = tempfile.mkstemp(suffix=".wav")
    os.write(fd, wav)
    os.close(fd)
    audio, _ = read_wav(path)
    os.remove(path)
    heard = decode_audio(audio, profile=profile)
    assert heard and heard[0].packet is not None
    return start, A.read_auth_challenge(heard[0].packet)


def test_page_is_served(http):
    r = http.get("/site")
    assert r.status_code == 200 and "Log in with SoundLink" in r.text


def test_login_by_sound(http):
    phone = Identity.generate()
    start, ch = phone_hears(http, "anoop")
    assert ch.user == "anoop" and ch.url.endswith("/site/approve")
    assert ch.site_pub.hex() == http.get("/bank").json()["public_key"]
    assert http.get(f"/site/status/{start['session']}").json()["status"] == "waiting"

    r = http.post("/site/approve", json={"response": A.auth_response_packet(ch, True, phone).hex()})
    assert r.status_code == 200 and r.json()["status"] == "approved"
    st = http.get(f"/site/status/{start['session']}").json()
    assert st["status"] == "approved" and st["device"]
    # the same response can't log in twice
    assert http.post("/site/approve", json={"response": A.auth_response_packet(ch, True, phone).hex()}).status_code == 409


def test_username_is_linked_to_first_phone(http):
    me, other = Identity.generate(), Identity.generate()
    _, ch = phone_hears(http, "asha")
    http.post("/site/approve", json={"response": A.auth_response_packet(ch, True, me).hex()})
    start, ch2 = phone_hears(http, "asha")
    assert start["linked"]
    r = http.post("/site/approve", json={"response": A.auth_response_packet(ch2, True, other).hex()})
    assert r.status_code == 403
    assert http.get(f"/site/status/{start['session']}").json()["status"] == "wrong_phone"


def test_deny_and_garbage(http):
    phone = Identity.generate()
    start, ch = phone_hears(http, "bob")
    assert http.post("/site/approve", json={"response": A.auth_response_packet(ch, False, phone).hex()}).json()["status"] == "denied"
    assert http.post("/site/approve", json={"response": "00ff"}).status_code == 400
    # a response signed for another site
    fake = A.AuthChallenge(ch.session, ch.expires, ch.site, ch.user, ch.url, Identity.generate().public_key)
    assert http.post("/site/approve", json={"response": A.auth_response_packet(fake, True, phone).hex()}).status_code == 400


def test_bad_username(http):
    assert http.post("/site/start", json={"user": "a b<script>"}).status_code == 422
