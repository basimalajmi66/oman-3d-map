"""Companion devices over the local network: opt-in TLS listener, one-time pairing, allow-list."""
import hashlib
import socket
import ssl
import time
from urllib.parse import parse_qs, urlparse

import cv2
import httpx
import pytest

from uata.services import companion_service as cs
from uata.vision.synthetic import render_chart, uptrend_ohlc


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def served_fingerprint(port: int) -> str:
    pem = ssl.get_server_certificate(("127.0.0.1", port))
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()


def listening(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


@pytest.fixture
def lan(client):
    port = free_port()
    r = client.patch("/settings", json={"companion_enabled": True, "companion_port": port})
    assert r.status_code == 200
    assert client.get("/companion").json()["running"]
    # verify=False only because the test pins the fingerprint itself, exactly like the phone does
    c = httpx.Client(base_url=f"https://127.0.0.1:{port}", verify=False, timeout=30)  # nosec
    yield port, c
    c.close()


def pair(client, lan_client, name="Phone"):
    p = client.post("/companion/pairing").json()
    r = lan_client.post("/companion/pair", json={"code": p["code"], "name": name})
    assert r.status_code == 200, r.text
    return r.json()["token"]


def test_off_by_default_and_nothing_listens(client):
    st = client.get("/companion").json()
    assert st["enabled"] is False and st["running"] is False
    assert not listening(8766)
    assert client.post("/companion/pairing").status_code == 400


def test_tls_certificate_matches_the_fingerprint_in_the_qr(client, lan):
    port, _ = lan
    p = client.post("/companion/pairing").json()
    q = parse_qs(urlparse(p["uri"]).query)
    assert p["uri"].startswith("uata://pair?")
    assert q["fp"][0] == served_fingerprint(port) == client.get("/companion").json()["fingerprint"]
    assert q["p"][0] == str(port) and q["c"][0] == p["code"]
    # plain HTTP is not served
    with pytest.raises(httpx.HTTPError):
        httpx.get(f"http://127.0.0.1:{port}/health", timeout=3)


def test_pairing_is_one_time_and_device_token_works(client, lan):
    _, c = lan
    p = client.post("/companion/pairing").json()
    ok = c.post("/companion/pair", json={"code": p["code"], "name": "Basim's phone"})
    assert ok.status_code == 200
    token = ok.json()["token"]
    # the same code cannot be used twice
    assert c.post("/companion/pair", json={"code": p["code"], "name": "x"}).status_code == 401
    assert c.get("/analysis/status", headers={"X-UATA-Device": token}).status_code == 200
    devs = client.get("/companion").json()["devices"]
    assert devs[0]["name"] == "Basim's phone" and devs[0]["last_seen_at"]
    # only the hash is stored
    with client.app.state.services.db.session() as conn:
        stored = conn.execute("SELECT token_hash FROM companion_devices").fetchone()[0]
    assert stored != token and stored == hashlib.sha256(token.encode()).hexdigest()


def test_wrong_codes_burn_the_pairing(client, lan):
    _, c = lan
    p = client.post("/companion/pairing").json()
    for _ in range(cs.PAIRING_MAX_ATTEMPTS):
        assert c.post("/companion/pair", json={"code": "guess", "name": "x"}).status_code == 401
    assert c.post("/companion/pair", json={"code": p["code"], "name": "x"}).status_code == 401
    assert c.post("/companion/pair", content=b"not json").status_code == 422


def test_pairing_code_expires(client, lan, monkeypatch):
    _, c = lan
    monkeypatch.setattr(cs, "PAIRING_TTL_SEC", 0)
    p = client.post("/companion/pairing").json()
    time.sleep(0.01)
    assert c.post("/companion/pair", json={"code": p["code"], "name": "x"}).status_code == 401


def test_unpaired_and_local_token_are_refused(client, lan):
    _, c = lan
    assert c.get("/health").status_code == 200  # reachability check only
    assert c.get("/analysis/status").status_code == 401
    assert c.get("/analysis/status", headers={"X-UATA-Device": "made-up"}).status_code == 401
    # the desktop UI's token is never accepted over the network
    from tests.conftest import TOKEN
    assert c.get("/analysis/status", headers={"X-UATA-Token": TOKEN}).status_code == 401


@pytest.mark.parametrize("method,path", [
    ("POST", "/privacy/wipe"), ("GET", "/backups"), ("POST", "/backups"), ("PATCH", "/settings"),
    ("POST", "/settings/reset"), ("POST", "/analysis/capture"), ("GET", "/companion"),
    ("POST", "/companion/pairing"), ("DELETE", "/companion/devices/1"), ("DELETE", "/strategies/1"),
    ("POST", "/strategies/1/approve"), ("POST", "/datasets/csv"), ("DELETE", "/knowledge/sources/1"),
])
def test_dangerous_operations_are_refused_for_devices(client, lan, method, path):
    _, c = lan
    token = pair(client, c)
    r = c.request(method, path, headers={"X-UATA-Device": token}, json={"confirm": "DELETE ALL MY DATA"})
    assert r.status_code == 403, (method, path, r.status_code)
    assert client.get("/settings").status_code == 200  # nothing was wiped


def test_phone_sends_a_chart_and_follows_the_analysis(client, lan):
    _, c = lan
    h = {"X-UATA-Device": pair(client, c)}
    assert c.post("/analysis/start", json={"input_mode": "upload"}, headers=h).status_code == 200
    png = cv2.imencode(".png", render_chart(uptrend_ohlc(), style="dark_tv").image)[1].tobytes()
    r = c.post("/analysis/inputs", files={"file": ("c.png", png)}, headers=h)
    assert r.status_code == 201, r.text
    assert r.json()["analysis"]["signal"] in ("BUY", "SELL", "WAIT")
    assert c.get("/analysis/status", headers=h).json()["session"] is not None
    assert c.get("/settings", headers=h).json()["language"] in ("ar", "en")
    assert c.post("/analysis/emergency-stop", headers=h).status_code == 200


def test_revoke_and_disable(client, lan):
    port, c = lan
    token = pair(client, c)
    dev = client.get("/companion").json()["devices"][0]["id"]
    client.delete(f"/companion/devices/{dev}")
    assert c.get("/analysis/status", headers={"X-UATA-Device": token}).status_code == 401
    client.patch("/settings", json={"companion_enabled": False})
    assert client.get("/companion").json()["running"] is False
    assert not listening(port)


def test_wipe_forgets_devices_and_certificate(client, lan):
    port, c = lan
    pair(client, c)
    old_fp = served_fingerprint(port)
    client.post("/privacy/wipe", json={"confirm": "DELETE ALL MY DATA"})
    st = client.get("/companion").json()
    assert st["devices"] == [] and st["running"] is False and st["enabled"] is False
    client.patch("/settings", json={"companion_enabled": True, "companion_port": port})
    assert served_fingerprint(port) != old_fp  # old phones can never reconnect


def test_port_in_use_is_reported(client):
    with socket.socket() as s:
        s.bind(("0.0.0.0", 0))  # nosec B104 - test occupies a port on purpose
        s.listen()
        port = s.getsockname()[1]
        client.patch("/settings", json={"companion_enabled": True, "companion_port": port})
        st = client.get("/companion").json()
    assert st["running"] is False and "in use" in st["error"]


def test_allow_list_is_narrow():
    assert cs.lan_allowed("POST", "/analysis/inputs")
    assert not cs.lan_allowed("POST", "/analysis/inputs/1")
    assert not cs.lan_allowed("GET", "/backups/x.uatabak")
    assert not cs.lan_allowed("GET", "/settingsX")
    assert not cs.lan_allowed("PATCH", "/settings")
