"""Share a big file: the link goes by sound, the file goes over the local Wi-Fi.

The sender starts a tiny HTTP server that serves exactly one file at a random,
unguessable path (/f/<32 hex chars>/<name>) and stops after a time limit.
The receiver downloads it and checks size + sha256 from the signed offer, so
it can't be swapped for another file on the way.
"""

from __future__ import annotations

import hashlib
import http.server
import os
import socket
import threading
import urllib.request
from pathlib import Path
from urllib.parse import quote

from .extras import FileOffer, guess_mime, safe_name

MAX_DOWNLOAD = 200 * 1024 * 1024


def local_ip() -> str:
    """The address other devices on the same Wi-Fi can reach (no packet is actually sent)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


class FileShare:
    """Serves one file until stop() or until `timeout_s` passes."""

    def __init__(self, path: str | Path, host: str | None = None, port: int = 0, timeout_s: float = 600):
        self.path = Path(path)
        self.data = self.path.read_bytes()
        self.name = safe_name(self.path.name)
        self.token = os.urandom(16).hex()
        self.downloads = 0
        share = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                if self.path != f"/f/{share.token}/{quote(share.name)}":
                    self.send_error(404)
                    return
                share.downloads += 1
                self.send_response(200)
                self.send_header("Content-Type", guess_mime(share.name))
                self.send_header("Content-Length", str(len(share.data)))
                self.end_headers()
                self.wfile.write(share.data)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler)
        self.host = host or local_ip()
        self._thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self._timer = threading.Timer(timeout_s, self.stop)

    @property
    def url(self) -> str:
        return f"http://{self.host}:{self.server.server_address[1]}/f/{self.token}/{quote(self.name)}"

    def offer(self) -> FileOffer:
        return FileOffer.link(self.name, len(self.data), hashlib.sha256(self.data).digest(), self.url,
                              guess_mime(self.name))

    def start(self) -> "FileShare":
        self._thread.start()
        self._timer.start()
        return self

    def stop(self) -> None:
        self._timer.cancel()
        self.server.shutdown()
        self.server.server_close()


def fetch(offer: FileOffer, folder: str | Path, timeout: float = 30) -> Path:
    """Download (or unpack an inline file), check it and save it. Returns the saved path."""
    if offer.mode == 2:
        data = offer.check(offer.data)
    else:
        if offer.size > MAX_DOWNLOAD:
            raise ValueError("file is too big")
        with urllib.request.urlopen(offer.url, timeout=timeout) as r:  # noqa: S310 (url is http(s), checked)
            data = r.read(offer.size + 1)
        data = offer.check(data)
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / safe_name(offer.name)
    stem, suffix, n = target.stem, target.suffix, 1
    while target.exists():
        target = folder / f"{stem} ({n}){suffix}"
        n += 1
    target.write_bytes(data)
    return target
