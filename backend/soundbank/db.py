"""SQLite storage for the demo bank. Amounts are in paise."""

from __future__ import annotations

import sqlite3
import threading
import time
from contextlib import contextmanager
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS accounts (
    pub      TEXT PRIMARY KEY,           -- hex Ed25519 public key of the device
    name     TEXT NOT NULL,
    online   INTEGER NOT NULL,           -- online balance (demo money)
    frozen   INTEGER NOT NULL DEFAULT 0, -- set when double spending is found
    debt     INTEGER NOT NULL DEFAULT 0, -- money still owed after fraud
    created  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS certs (
    pub         TEXT NOT NULL,
    seq         INTEGER NOT NULL,
    lim         INTEGER NOT NULL,        -- offline money in this certificate
    valid_until INTEGER NOT NULL,
    issued      INTEGER NOT NULL,
    cap_spent   INTEGER,                 -- set when retired: what the wallet said it spent
    cap_counter INTEGER,
    PRIMARY KEY (pub, seq)
);
CREATE TABLE IF NOT EXISTS payments (
    wallet      TEXT NOT NULL,
    seq         INTEGER NOT NULL,
    counter     INTEGER NOT NULL,
    amount      INTEGER NOT NULL,
    spent_after INTEGER NOT NULL,
    merchant    TEXT NOT NULL,
    digest      TEXT NOT NULL UNIQUE,    -- sha256 of the raw packet
    raw         BLOB NOT NULL,
    fraud       INTEGER NOT NULL DEFAULT 0,
    received    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS payments_cert ON payments (wallet, seq, counter);
CREATE TABLE IF NOT EXISTS ledger (
    id    INTEGER PRIMARY KEY AUTOINCREMENT,
    pub   TEXT NOT NULL,
    delta INTEGER NOT NULL,
    kind  TEXT NOT NULL,                 -- signup, load, unload, received, fraud_recovery
    note  TEXT NOT NULL DEFAULT '',
    time  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS seen_sigs (
    sig  TEXT PRIMARY KEY,
    time INTEGER NOT NULL
);
"""


class DB:
    def __init__(self, path: str | Path):
        self.path = str(path)
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(self.path, check_same_thread=False, isolation_level=None)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA foreign_keys = ON")
        self._conn.executescript(SCHEMA)
        self._lock = threading.Lock()

    @contextmanager
    def tx(self):
        """One write transaction at a time, so balances can't race."""
        with self._lock:
            self._conn.execute("BEGIN IMMEDIATE")
            try:
                yield self._conn
                self._conn.execute("COMMIT")
            except BaseException:
                self._conn.execute("ROLLBACK")
                raise

    def query(self, sql: str, args: tuple = ()) -> list[sqlite3.Row]:
        with self._lock:
            return self._conn.execute(sql, args).fetchall()


def now() -> int:
    return int(time.time())
