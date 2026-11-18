"""Companion devices (phone / tablet) over the local network.

The engine on the computer stays the only place where data is stored and
analysed. When — and only when — the user turns this on, a second listener is
opened on the local network:

* **TLS** with a self-signed certificate generated on this computer. The phone
  pins its SHA-256 fingerprint, which it receives through the pairing QR code,
  so nobody on the network can read or impersonate the traffic.
* **Pairing**: a one-time code, valid for 5 minutes and 5 attempts, shown as a
  QR code on the computer. A successful pairing gives the device its own token;
  only a hash of it is stored and the user can revoke it at any time.
* **Allow-list**: a device can follow the analysis, send charts and documents,
  record results and read statistics. It can never wipe data, touch backups,
  change settings, capture this computer's screen or manage devices.
* The local token of the desktop UI is never accepted over the network.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import re
import secrets
import socket
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

from uata.config import _restrict_permissions
from uata.db.database import Database, audit, row_to_dict, utcnow

PAIRING_TTL_SEC = 300
PAIRING_MAX_ATTEMPTS = 5

# (method, path regex) a paired device may call. Everything else is refused with 403.
_ALLOWED: list[tuple[str, re.Pattern]] = [(m, re.compile(p)) for m, p in [
    ("GET", r"/settings"),                       # read-only: language, theme, timeframe
    ("GET", r"/analysis/status"),
    ("POST", r"/analysis/(start|stop|emergency-stop)"),
    ("POST", r"/analysis/inputs"),               # a chart from the phone (share / screenshot)
    ("GET", r"/analysis/inputs(/\d+(/(image|annotated|reading))?)?"),
    ("GET", r"/signals"),
    ("POST", r"/signals/\d+/result"),
    ("GET", r"/results(/\d+)?"),
    ("GET", r"/stats/(dashboard|insights|summary)"),
    ("GET", r"/strategies(/\d+|/catalog|/suitable/\w+)?"),
    ("GET", r"/knowledge/(sources|items|reports|search|retrieve)(/\d+)?"),
    ("POST", r"/knowledge/(files|notes|urls)"),   # new material always waits for approval
    ("POST", r"/knowledge/(reports|items)/\d+/decision"),
    ("GET", r"/videos(/\d+)?"),
    ("POST", r"/videos"),
]]


def lan_allowed(method: str, path: str) -> bool:
    return any(method == m and rx.fullmatch(path) for m, rx in _ALLOWED)


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def lan_addresses() -> list[str]:
    """IPv4 addresses of this computer on the local network (primary first)."""
    out: list[str] = []
    try:  # no packet is sent: connecting a UDP socket only picks the outgoing interface
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            out.append(s.getsockname()[0])
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in out and not ip.startswith(("127.", "169.254.")):  # loopback / link-local
                out.append(ip)
    except OSError:
        pass
    return out


def ensure_certificate(folder: Path) -> tuple[Path, Path, str]:
    """Self-signed certificate for the companion listener → (cert, key, sha256 fingerprint of the DER)."""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID

    folder.mkdir(parents=True, exist_ok=True)
    _restrict_permissions(folder, 0o700)
    cert_file, key_file = folder / "cert.pem", folder / "key.pem"
    if not (cert_file.exists() and key_file.exists()):
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "UATA companion")])
        now = dt.datetime.now(dt.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - dt.timedelta(days=1)).not_valid_after(now + dt.timedelta(days=3650))
                .sign(key, hashes.SHA256()))
        key_file.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                               serialization.NoEncryption()))
        _restrict_permissions(key_file, 0o600)
        cert_file.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    cert = x509.load_pem_x509_certificate(cert_file.read_bytes())
    fp = hashlib.sha256(cert.public_bytes(serialization.Encoding.DER)).hexdigest()
    return cert_file, key_file, fp


@dataclass
class _Pairing:
    code: str
    expires: float
    attempts: int = 0


class CompanionService:
    def __init__(self, db: Database, folder: Path):
        self.db = db
        self.folder = folder
        self._pairing: _Pairing | None = None
        self._lock = threading.Lock()
        self._server = None
        self._thread: threading.Thread | None = None
        self.port: int | None = None
        self.error: str | None = None
        self.fingerprint: str | None = None

    # ------------------------------------------------------------ listener
    @property
    def running(self) -> bool:
        return self._server is not None and bool(getattr(self._server, "started", False))

    def start(self, inner_app, local_token: str, port: int) -> None:
        if self.running and self.port == port:
            return
        self.stop()
        import uvicorn

        cert, key, self.fingerprint = ensure_certificate(self.folder)
        gateway = LanGateway(inner_app, self, local_token)
        config = uvicorn.Config(gateway, host="0.0.0.0", port=port,  # nosec B104 - opt-in LAN listener, TLS + device tokens + allow-list
                                ssl_certfile=str(cert), ssl_keyfile=str(key),
                                lifespan="off", log_level="warning", access_log=False)
        server = uvicorn.Server(config)
        self._server, self.port, self.error = server, port, None

        def run() -> None:
            try:
                server.run()
            except BaseException as e:  # noqa: BLE001 - bind errors end as SystemExit inside uvicorn
                self.error = f"companion listener stopped: {e!r}"

        self._thread = threading.Thread(target=run, name="uata-companion", daemon=True)
        self._thread.start()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not server.started and self._thread.is_alive():
            time.sleep(0.05)
        if not server.started:
            self.stop()
            self.error = f"could not listen on port {port} (is it in use?)"
            return
        with self.db.session() as conn:
            audit(conn, "user", "companion.started", port=port)

    def stop(self) -> None:
        server, thread = self._server, self._thread
        self._server = self._thread = None
        self._pairing = None
        if server is not None:
            server.should_exit = True
            if thread is not None:
                thread.join(timeout=10)
            with self.db.session() as conn:
                audit(conn, "user", "companion.stopped")

    def forget_certificate(self) -> None:
        """Used by "delete all my data": a new certificate means old pairings can never reconnect."""
        self.stop()
        for f in ("cert.pem", "key.pem"):
            (self.folder / f).unlink(missing_ok=True)
        self.fingerprint = None

    # ------------------------------------------------------------ pairing
    def new_pairing(self) -> dict[str, Any]:
        if not self.running:
            raise ValueError("turn on companion devices first")
        code = secrets.token_urlsafe(9)
        with self._lock:
            self._pairing = _Pairing(code, time.monotonic() + PAIRING_TTL_SEC)
        # every address of this computer (Wi-Fi, Ethernet, ...): the phone tries them in turn, and the pinned
        # certificate guarantees it is always this computer whichever address answers
        addrs = lan_addresses()[:6]
        host = addrs[0] if addrs else "127.0.0.1"
        uri = "uata://pair?" + urlencode({"h": ",".join(addrs or [host]), "p": self.port,
                                         "fp": self.fingerprint, "c": code})
        return {"uri": uri, "code": code, "host": host, "addresses": addrs, "port": self.port,
                "fingerprint": self.fingerprint, "expires_in_sec": PAIRING_TTL_SEC}

    def cancel_pairing(self) -> None:
        with self._lock:
            self._pairing = None

    def pair(self, code: str, name: str) -> dict[str, Any]:
        """Exchange a valid one-time code for a device token. Raises PermissionError otherwise."""
        name = (name or "").strip()[:60] or "device"
        with self._lock:
            p = self._pairing
            if p is None or time.monotonic() > p.expires:
                self._pairing = None
                raise PermissionError("no active pairing code — create one on the computer")
            if not secrets.compare_digest(code or "", p.code):
                p.attempts += 1
                if p.attempts >= PAIRING_MAX_ATTEMPTS:
                    self._pairing = None  # too many wrong codes: the code is burnt
                raise PermissionError("wrong pairing code")
            self._pairing = None  # one-time
        token = secrets.token_urlsafe(32)
        with self.db.session() as conn:
            cur = conn.execute("INSERT INTO companion_devices(name, token_hash, created_at) VALUES (?,?,?)",
                               (name, _hash(token), utcnow()))
            audit(conn, "user", "companion.paired", device_id=cur.lastrowid, name=name)
        return {"device_id": cur.lastrowid, "token": token, "name": name}

    def authenticate(self, token: str | None) -> dict | None:
        if not token:
            return None
        with self.db.session() as conn:
            row = conn.execute("SELECT * FROM companion_devices WHERE token_hash=? AND revoked_at IS NULL",
                               (_hash(token),)).fetchone()
            if row is None:
                return None
            conn.execute("UPDATE companion_devices SET last_seen_at=? WHERE id=?", (utcnow(), row["id"]))
        return row_to_dict(row)

    # ------------------------------------------------------------ devices
    def devices(self) -> list[dict]:
        with self.db.session() as conn:
            rows = conn.execute("SELECT id, name, created_at, last_seen_at, revoked_at FROM companion_devices "
                                "ORDER BY id DESC").fetchall()
        return [row_to_dict(r) for r in rows]

    def revoke(self, device_id: int) -> None:
        with self.db.session() as conn:
            n = conn.execute("UPDATE companion_devices SET revoked_at=? WHERE id=? AND revoked_at IS NULL",
                             (utcnow(), device_id)).rowcount
            if not n:
                raise ValueError("unknown or already revoked device")
            audit(conn, "user", "companion.revoked", device_id=device_id)

    def status(self, enabled: bool) -> dict[str, Any]:
        p = self._pairing
        return {"enabled": enabled, "running": self.running, "port": self.port, "error": self.error,
                "fingerprint": self.fingerprint, "addresses": lan_addresses() if self.running else [],
                "pairing_active": bool(p and time.monotonic() < p.expires),
                "devices": self.devices()}


class LanGateway:
    """ASGI front for the LAN listener: device auth + allow-list, then the normal engine app."""

    def __init__(self, inner, companion: CompanionService, local_token: str):
        self.inner, self.companion, self.local_token = inner, companion, local_token.encode()

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return
        method, path = scope["method"], scope["path"]
        if path == "/health" and method == "GET":
            return await self.inner(self._with_token(scope), receive, send)
        if path == "/companion/pair" and method == "POST":
            return await self._pair(receive, send)
        headers = dict(scope["headers"])
        device = self.companion.authenticate(headers.get(b"x-uata-device", b"").decode("latin-1"))
        if device is None:
            return await _json(send, 401, {"detail": "this device is not paired (or was revoked)"})
        if not lan_allowed(method, path):
            return await _json(send, 403, {"detail": "not available from a companion device — use the computer"})
        return await self.inner(self._with_token(scope), receive, send)

    def _with_token(self, scope):
        # whatever the device sent as X-UATA-Token is dropped; the engine's own token is added here
        headers = [(k, v) for k, v in scope["headers"] if k not in (b"x-uata-token", b"x-uata-device")]
        headers.append((b"x-uata-token", self.local_token))
        return {**scope, "headers": headers}

    async def _pair(self, receive, send):
        body, more = b"", True
        while more:
            msg = await receive()
            body += msg.get("body", b"")
            more = msg.get("more_body", False)
            if len(body) > 4096:
                return await _json(send, 413, {"detail": "too large"})
        try:
            data = json.loads(body or b"{}")
            result = self.companion.pair(str(data.get("code", "")), str(data.get("name", "")))
        except PermissionError as e:
            return await _json(send, 401, {"detail": str(e)})
        except (ValueError, AttributeError):
            return await _json(send, 422, {"detail": "expected {\"code\": ..., \"name\": ...}"})
        return await _json(send, 200, result)


async def _json(send, status: int, payload: dict) -> None:
    body = json.dumps(payload).encode()
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())]})
    await send({"type": "http.response.body", "body": body})
