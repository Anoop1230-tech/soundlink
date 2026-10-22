"""Talk to SoundBank from Python (used by the CLI and the tests)."""

from __future__ import annotations

import json
import time

import httpx

from soundlink.crypto import Identity

from .auth import sign_headers


class BankClient:
    def __init__(self, url: str, identity: Identity, http: httpx.Client | None = None):
        self.identity = identity
        self.http = http or httpx.Client(base_url=url.rstrip("/"), timeout=15)

    def _call(self, method: str, path: str, data: dict | None = None) -> dict:
        body = b"" if data is None else json.dumps(data).encode()
        headers = sign_headers(self.identity, method, path, body, int(time.time()))
        if data is not None:
            headers["Content-Type"] = "application/json"
        r = self.http.request(method, path, content=body, headers=headers)
        if r.status_code >= 400:
            raise RuntimeError(f"{r.status_code}: {r.json().get('detail', r.text)}")
        return r.json()

    def info(self) -> dict:
        return self.http.get("/bank").json()

    def register(self, name: str) -> dict:
        return self._call("POST", "/register", {"name": name})

    def account(self) -> dict:
        return self._call("GET", "/account")

    def load(self, amount: int, state: dict) -> dict:
        return self._call("POST", "/wallet/load", {"amount": amount, "state": state})

    def unload(self, state: dict) -> dict:
        return self._call("POST", "/wallet/unload", {"state": state})

    def sync(self, payments: list[bytes]) -> dict:
        return self._call("POST", "/merchant/sync", {"payments": [p.hex() for p in payments]})
