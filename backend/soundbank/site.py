"""Demo website with "Log in with SoundLink" (no password).

1. Browser: enter a username, press the button. The server makes a login
   challenge and the page plays it from the laptop speaker.
2. Phone (Access tab -> Login): hears it, shows "Log in to SoundBank as anoop?",
   and on Approve POSTs a signed AUTH_RESPONSE to the URL inside the challenge.
3. The page polls and shows "logged in". The first phone that approves a
   username is linked to it; after that only that phone can log in as it.

Proves the phone is in the same room as the laptop, because only someone who
heard the sound knows the session. Demo only: no real accounts behind it.
"""

from __future__ import annotations

import io
import os
import threading
from dataclasses import dataclass, field

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse, Response
from pydantic import BaseModel, Field

from soundlink import access as A
from soundlink.audio import write_wav
from soundlink.crypto import Identity, fingerprint_hex
from soundlink.link import SoundLink
from soundlink.packet import Packet, PacketError

LOGIN_TTL_S = 120


@dataclass
class Login:
    user: str
    challenge: A.AuthChallenge
    raw: bytes
    status: str = "waiting"  # waiting, approved, denied, expired, wrong_phone
    wav: bytes = b""
    device: str = ""


@dataclass
class Sites:
    identity: Identity
    clock: object
    db: object
    logins: dict[str, Login] = field(default_factory=dict)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def linked_device(self, user: str) -> str | None:
        rows = self.db.query("SELECT pub FROM site_users WHERE user = ?", (user,))
        return rows[0]["pub"] if rows else None


class StartBody(BaseModel):
    user: str = Field(min_length=1, max_length=40, pattern=r"^[A-Za-z0-9_.\-]+$")
    profile: str = Field(default="normal", pattern="^(normal|fast|ultrasonic)$")


class ApproveBody(BaseModel):
    response: str = Field(max_length=1000)


def router(identity: Identity, db, clock) -> APIRouter:
    with db.tx() as c:
        c.execute("CREATE TABLE IF NOT EXISTS site_users (user TEXT PRIMARY KEY, pub TEXT NOT NULL, created INTEGER NOT NULL)")
    s = Sites(identity, clock, db)
    r = APIRouter(prefix="/site")

    def get(session: str) -> Login:
        with s.lock:
            login = s.logins.get(session)
            if login is None:
                raise HTTPException(404, "unknown login")
            if login.status == "waiting" and s.clock() > login.challenge.expires:
                login.status = "expired"
            return login

    @r.get("", response_class=HTMLResponse)
    def page():
        return PAGE

    @r.post("/start")
    async def start(body: StartBody, request: Request):
        now = s.clock()
        base = str(request.base_url).rstrip("/")
        url = f"{base}/site/approve"
        if len(url.encode()) > A.URL_MAX:
            raise HTTPException(400, "server address is too long for the sound message")
        session = os.urandom(16)
        ch = A.AuthChallenge(session, now + LOGIN_TTL_S, "SoundBank demo", body.user, url)
        raw = A.auth_challenge_packet(ch, s.identity)
        with s.lock:
            # forget old logins so memory can't grow forever
            for k in [k for k, v in s.logins.items() if now - v.challenge.expires > 600]:
                del s.logins[k]
            s.logins[session.hex()] = Login(body.user, A.AuthChallenge(session, ch.expires, ch.site, ch.user, ch.url,
                                                                        s.identity.public_key), raw)
        link = SoundLink(body.profile, volume=0.7)
        buf = io.BytesIO()
        write_wav(buf, link.encode_bytes(raw, repeat=2), link.sample_rate)
        with s.lock:
            s.logins[session.hex()].wav = buf.getvalue()
        return {"session": session.hex(), "expires": ch.expires, "sound": f"/site/sound/{session.hex()}.wav",
                "linked": s.linked_device(body.user) is not None}

    @r.get("/sound/{session}.wav")
    def sound(session: str):
        login = get(session)
        return Response(login.wav, media_type="audio/wav")

    @r.get("/status/{session}")
    def status(session: str):
        login = get(session)
        return {"status": login.status, "user": login.user, "device": login.device}

    @r.post("/approve")
    def approve(body: ApproveBody):
        try:
            packet = Packet.from_bytes(bytes.fromhex(body.response))
            session, ok, phone = A.read_auth_response(packet, s.identity.public_key)
        except (ValueError, PacketError, A.AccessError) as exc:
            raise HTTPException(400, f"bad response: {exc}") from None
        login = get(session.hex())
        with s.lock:
            if login.status != "waiting":
                raise HTTPException(409, f"login is already {login.status}")
            if not ok:
                login.status = "denied"
                return {"status": login.status}
            linked = s.linked_device(login.user)
            if linked is not None and linked != phone.hex():
                login.status = "wrong_phone"
                raise HTTPException(403, "this username is linked to another phone")
            if linked is None:
                with s.db.tx() as c:
                    c.execute("INSERT INTO site_users (user, pub, created) VALUES (?, ?, ?)",
                              (login.user, phone.hex(), s.clock()))
            login.status = "approved"
            login.device = fingerprint_hex(phone)
            return {"status": login.status, "user": login.user}

    return r


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Log in with SoundLink</title>
<style>
 body{font-family:system-ui,sans-serif;max-width:28rem;margin:3rem auto;padding:0 1rem;color:#1b1b1f}
 h1{font-size:1.6rem} label{display:block;margin:.8rem 0 .3rem}
 input,select,button{font-size:1.05rem;padding:.6rem;width:100%;box-sizing:border-box;border-radius:.5rem;border:1px solid #888}
 button{background:#3f51b5;color:#fff;border:0;margin-top:1rem;cursor:pointer} button:disabled{opacity:.5}
 #msg{margin-top:1.2rem;font-size:1.1rem;min-height:3rem} .ok{color:#1b5e20} .bad{color:#b71c1c}
 small{color:#555}
</style></head><body>
<h1>SoundBank demo login</h1>
<p>No password. Your phone hears this laptop and approves the login.</p>
<form id="f">
 <label for="user">Username</label>
 <input id="user" name="user" autocomplete="username" required pattern="[A-Za-z0-9_.\\-]+" maxlength="40">
 <label for="profile">Sound mode (same as in the app)</label>
 <select id="profile"><option value="normal">Normal</option><option value="fast">Fast</option><option value="ultrasonic">Ultrasonic</option></select>
 <button id="go" type="submit">Log in with SoundLink</button>
</form>
<div id="msg" role="status" aria-live="polite"></div>
<audio id="snd"></audio>
<p><small>On the phone: SoundLink → Access → Log in to a website → Listen. Demo only.</small></p>
<script>
const $=id=>document.getElementById(id), msg=$("msg");
function say(t,c){msg.textContent=t;msg.className=c||""}
$("f").onsubmit=async e=>{
 e.preventDefault(); $("go").disabled=true;
 try{
  const r=await fetch("/site/start",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify({user:$("user").value,profile:$("profile").value})});
  const j=await r.json(); if(!r.ok) throw new Error(j.detail||"error");
  say(j.linked?"Playing sound… approve on your phone.":"Playing sound… the first phone that approves will be linked to this username.");
  const a=$("snd"); a.src=j.sound; await a.play();
  const t=setInterval(async()=>{
   const s=await (await fetch("/site/status/"+j.session)).json();
   if(s.status==="waiting") return;
   clearInterval(t); $("go").disabled=false;
   if(s.status==="approved") say("Logged in as "+s.user+" (phone "+s.device+")","ok");
   else if(s.status==="wrong_phone") say("Refused: this username is linked to another phone.","bad");
   else say("Login "+s.status+".","bad");
  },1000);
 }catch(err){say(err.message,"bad");$("go").disabled=false}
};
</script></body></html>"""
