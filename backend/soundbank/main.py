"""SoundBank: a demo bank for SoundLink offline payments (dummy money only).

Run:  uvicorn soundbank.main:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from soundlink.crypto import Identity
from soundlink.payment import CERT_DAYS, MAX_PAYMENT, MAX_WALLET

from . import bank as rules
from .auth import verify_request
from .db import DB, now


class WalletState(BaseModel):
    seq: int = Field(ge=0)
    counter: int = Field(ge=0)
    spent: int = Field(ge=0)


class RegisterBody(BaseModel):
    name: str = Field(min_length=1, max_length=40)


class LoadBody(BaseModel):
    amount: int = Field(ge=0, le=MAX_WALLET)
    state: WalletState


class UnloadBody(BaseModel):
    state: WalletState


class SyncBody(BaseModel):
    payments: list[str] = Field(max_length=200)


def _bank_identity(data_dir: Path) -> Identity:
    """The bank's signing key. Created once and kept on the server only."""
    path = data_dir / "bank.key"
    if path.exists():
        return Identity.load(path)
    data_dir.mkdir(parents=True, exist_ok=True)
    ident = Identity.generate()
    ident.save(path)
    return ident


def create_app(data_dir: str | Path | None = None, clock=now) -> FastAPI:
    data_dir = Path(data_dir or os.environ.get("SOUNDBANK_DATA", Path(__file__).resolve().parents[1] / "data"))
    bank = _bank_identity(data_dir)
    db = DB(data_dir / "bank.db")
    app = FastAPI(title="SoundBank (demo money)", version="0.3.0")

    @app.exception_handler(rules.BankError)
    async def bank_error(_, exc: rules.BankError):
        return JSONResponse({"detail": exc.message}, status_code=exc.status)

    async def caller(request: Request) -> str:
        return await verify_request(request, db, clock())

    async def body(request: Request, model):
        try:
            return model.model_validate(json.loads(await request.body() or b"{}"))
        except (ValueError, TypeError) as exc:
            raise HTTPException(422, f"bad request body: {exc}") from None

    def run(fn):
        """Run bank rules in one transaction. Some errors still keep their changes."""
        with db.tx() as c:
            try:
                return fn(c)
            except rules.BankError as exc:
                if not exc.commit:
                    raise
                error = exc
        raise error

    @app.get("/bank")
    def bank_info():
        return {
            "name": "SoundBank (demo money)",
            "public_key": bank.public_key.hex(),
            "max_payment": MAX_PAYMENT,
            "max_wallet": MAX_WALLET,
            "cert_days": CERT_DAYS,
            "signup_bonus": rules.SIGNUP_BONUS,
            "time": clock(),
        }

    @app.post("/register")
    async def register(request: Request):
        pub = await caller(request)
        b = await body(request, RegisterBody)

        def go(c):
            created = rules.register(c, pub, b.name.strip(), clock())
            return {"created": created, **rules.account_view(c, pub)}

        return run(go)

    @app.get("/account")
    async def account(request: Request):
        pub = await caller(request)
        return run(lambda c: rules.account_view(c, pub))

    @app.post("/wallet/load")
    async def load(request: Request):
        pub = await caller(request)
        b = await body(request, LoadBody)

        def go(c):
            cert = rules.load(c, bank, pub, b.amount, b.state.model_dump(), clock())
            return {**rules.account_view(c, pub), "cert_hex": cert.to_bytes().hex()}

        return run(go)

    @app.post("/wallet/unload")
    async def unload(request: Request):
        pub = await caller(request)
        b = await body(request, UnloadBody)

        def go(c):
            returned = rules.unload(c, pub, b.state.model_dump(), clock())
            return {"returned": returned, **rules.account_view(c, pub)}

        return run(go)

    @app.post("/merchant/sync")
    async def sync(request: Request):
        pub = await caller(request)
        b = await body(request, SyncBody)

        def go(c):
            rules._account(c, pub)
            results = [rules.settle(c, bank, pub, raw, clock()) for raw in b.payments]
            return {"results": results, **rules.account_view(c, pub)}

        return run(go)

    return app


def __getattr__(name: str):
    # Created on first use so importing this module doesn't make a data folder.
    if name == "app":
        globals()["app"] = create_app()
        return globals()["app"]
    raise AttributeError(name)
