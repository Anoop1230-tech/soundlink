import os

import pytest

from soundlink import Identity, Packet, PacketType, SoundLink
from soundlink import access as A
from soundlink.link import decode_audio

NOW = 1_800_000_000


def P(raw: bytes) -> Packet:
    return Packet.from_bytes(raw)


# ---------------------------------------------------------------- attendance


def test_attendance_flow():
    teacher, student = Identity.generate(), Identity.generate()
    cls = A.ClassSession("DBMS lecture")
    beacon = A.read_beacon(P(cls.beacon(teacher, now=NOW)))
    assert beacon.title == "DBMS lecture" and beacon.teacher == teacher.public_key
    att, ack, new = cls.check_in(P(A.check_in_packet(beacon, "Anoop", student)), teacher, now=NOW + 5)
    assert new and att.name == "Anoop" and len(cls.present) == 1
    assert A.read_ack(P(ack), student, beacon) == 1
    # Same phone again: not counted twice
    _, _, new = cls.check_in(P(A.check_in_packet(beacon, "Anoop", student)), teacher, now=NOW + 6)
    assert not new and len(cls.present) == 1
    assert "Anoop" in cls.csv()


def test_attendance_code_goes_stale():
    teacher, student = Identity.generate(), Identity.generate()
    cls = A.ClassSession("x")
    beacon = A.read_beacon(P(cls.beacon(teacher, now=NOW)))
    ci = P(A.check_in_packet(beacon, "Late", student))
    with pytest.raises(A.AccessError, match="too old"):
        cls.check_in(ci, teacher, now=NOW + 40)


def test_attendance_fake_code_and_other_class():
    teacher, student = Identity.generate(), Identity.generate()
    cls, other = A.ClassSession("a"), A.ClassSession("b")
    real = A.read_beacon(P(cls.beacon(teacher, now=NOW)))
    fake = A.Beacon(real.session, real.window, os.urandom(8), "a", teacher.public_key)
    with pytest.raises(A.AccessError, match="wrong code"):
        cls.check_in(P(A.check_in_packet(fake, "Proxy", student)), teacher, now=NOW)
    with pytest.raises(A.AccessError, match="another class"):
        other.check_in(P(A.check_in_packet(real, "X", student)), teacher, now=NOW)


def test_one_phone_two_names_is_flagged():
    teacher, student = Identity.generate(), Identity.generate()
    cls = A.ClassSession("x")
    b = A.read_beacon(P(cls.beacon(teacher, now=NOW)))
    cls.check_in(P(A.check_in_packet(b, "Me", student)), teacher, now=NOW)
    cls.check_in(P(A.check_in_packet(b, "Friend", student)), teacher, now=NOW)
    assert len(cls.present) == 1 and cls.problems


def test_attendance_over_sound():
    teacher, student = Identity.generate(), Identity.generate()
    cls = A.ClassSession("Lab")
    heard = decode_audio(SoundLink("ultrasonic").encode_bytes(cls.beacon(teacher, now=NOW)), profile="ultrasonic")[0]
    b = A.read_beacon(heard.packet)
    heard = decode_audio(SoundLink("ultrasonic").encode_bytes(A.check_in_packet(b, "S", student)), profile="ultrasonic")[0]
    assert cls.check_in(heard.packet, teacher, now=NOW)[2]


# ---------------------------------------------------------------- tickets


@pytest.fixture
def show():
    org, holder = Identity.generate(), Identity.generate()
    ev = A.Event("Tech Fest", NOW + 3600)
    ticket, issue = ev.issue(P(A.ask_packet("Anoop", holder)), org)
    t, org_pub = A.read_issue(P(issue), holder)
    assert t == ticket and org_pub == org.public_key and t.label == "Anoop"
    return org, holder, ev, t


def gate_once(org, holder, ev, t, now=NOW):
    event, nonce, gate_pub = A.read_gate(P(ev.gate(org, now=now)))
    status, _, res = ev.check(P(A.show_packet(nonce, t, holder)), org, now=now)
    assert A.read_result(P(res), nonce, gate_pub)[0] == status
    return status


def test_ticket_entry_and_reuse(show):
    org, holder, ev, t = show
    assert gate_once(org, holder, ev, t) == A.TICKET_OK
    assert gate_once(org, holder, ev, t) == A.TICKET_USED


def test_copied_ticket_on_another_phone_is_invalid(show):
    org, holder, ev, t = show
    thief = Identity.generate()
    assert gate_once(org, thief, ev, t) == A.TICKET_INVALID
    assert gate_once(org, holder, ev, t) == A.TICKET_OK  # owner still gets in


def test_ticket_expiry_and_other_event(show):
    org, holder, ev, t = show
    assert gate_once(org, holder, ev, t, now=NOW + 7200) == A.TICKET_EXPIRED
    ev2 = A.Event("Other", NOW + 3600)
    _, nonce, _ = A.read_gate(P(ev2.gate(org, now=NOW)))
    assert ev2.check(P(A.show_packet(nonce, t, holder)), org, now=NOW)[0] == A.TICKET_WRONG_EVENT


def test_recorded_show_cannot_be_replayed(show):
    org, holder, ev, t = show
    _, nonce, _ = A.read_gate(P(ev.gate(org, now=NOW)))
    recorded = A.show_packet(nonce, t, holder)
    ev.check(P(recorded), org, now=NOW)
    with pytest.raises(A.AccessError, match="old or unknown"):
        ev.check(P(recorded), org, now=NOW)


def test_event_saves(show):
    org, holder, ev, t = show
    gate_once(org, holder, ev, t)
    ev2 = A.Event.from_dict(ev.to_dict())
    assert gate_once(org, holder, ev2, t) == A.TICKET_USED


# ---------------------------------------------------------------- door


def test_door_open_deny_replay():
    door_id, phone, stranger = Identity.generate(), Identity.generate(), Identity.generate()
    door = A.Door("Lab 3")
    pk, name = A.read_enroll(P(A.enroll_packet(door_id.public_key, "Anoop", phone)), door_id)
    door.allowed[pk.hex()] = name

    nonce, dname, dpub = A.read_door_challenge(P(door.challenge(door_id, now=NOW)))
    assert dname == "Lab 3"
    opener = A.open_packet(nonce, dpub, phone)
    status, res = door.open(P(opener), door_id, now=NOW + 2)
    assert status == A.DOOR_OK and A.read_door_result(P(res), nonce, dpub) == A.DOOR_OK
    # replay of the recorded open sound
    assert door.open(P(opener), door_id, now=NOW + 3)[0] == A.DOOR_STALE

    nonce, _, _ = A.read_door_challenge(P(door.challenge(door_id, now=NOW)))
    assert door.open(P(A.open_packet(nonce, dpub, stranger)), door_id, now=NOW)[0] == A.DOOR_DENIED
    assert [e["status"] for e in door.log] == [0, 2, 1]


def test_door_too_slow():
    door_id, phone = Identity.generate(), Identity.generate()
    door = A.Door("D", {phone.public_key.hex(): "p"})
    nonce, _, dpub = A.read_door_challenge(P(door.challenge(door_id, now=NOW)))
    assert door.open(P(A.open_packet(nonce, dpub, phone)), door_id, now=NOW + 120)[0] == A.DOOR_STALE


def test_door_message_for_other_door():
    d1, d2, phone = Identity.generate(), Identity.generate(), Identity.generate()
    door = A.Door("D", {phone.public_key.hex(): "p"})
    nonce, _, _ = A.read_door_challenge(P(door.challenge(d1, now=NOW)))
    with pytest.raises(A.AccessError):
        door.open(P(A.open_packet(nonce, d2.public_key, phone)), d1, now=NOW)


# ---------------------------------------------------------------- login


def test_login_challenge_response():
    site, phone = Identity.generate(), Identity.generate()
    ch = A.AuthChallenge(os.urandom(16), NOW + 120, "SoundBank", "anoop", "http://192.168.1.10:8000/site/approve")
    got = A.read_auth_challenge(P(A.auth_challenge_packet(ch, site)))
    assert got.site == "SoundBank" and got.user == "anoop" and got.site_pub == site.public_key
    sess, ok, who = A.read_auth_response(P(A.auth_response_packet(got, True, phone)), site.public_key)
    assert sess == ch.session and ok and who == phone.public_key
    with pytest.raises(A.AccessError):
        A.read_auth_response(P(A.auth_response_packet(got, True, phone)), Identity.generate().public_key)


def test_text_limits():
    with pytest.raises(ValueError):
        A.ClassSession("x" * 41).beacon(Identity.generate())
    with pytest.raises(A.AccessError):
        A.read_beacon(P(Packet(PacketType.ATTENDANCE, b"\x01").to_bytes()))  # unsigned
