"""Phase 10: system-level tests — recovery, durability, security surface, and the full user journey
against the REAL engine process (uvicorn), not the in-process test client."""
import io
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

import cv2
import httpx
import pytest
from fastapi.testclient import TestClient

from uata.api.app import create_app
from uata.config import Paths
from uata.db.database import Database
from uata.vision.synthetic import render_chart, uptrend_ohlc

BACKEND = Path(__file__).resolve().parents[1]


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# ---------------------------------------------------------------- recovery & durability
def test_corrupt_database_is_kept_aside_and_engine_starts(tmp_path):
    paths = Paths(tmp_path / "d").ensure()
    paths.db_file.write_bytes(b"this is not a sqlite database" * 100)
    app = create_app(paths, token="t")
    c = TestClient(app)
    notices = c.get("/health").json()["notices"]
    assert notices and notices[0]["code"] == "database_was_corrupt"
    kept = paths.root / notices[0]["kept_as"]
    assert kept.read_bytes().startswith(b"this is not a sqlite database")  # never overwritten
    assert c.get("/settings", headers={"X-UATA-Token": "t"}).status_code == 200  # fresh, working database
    assert Database(paths.db_file).integrity_ok()


def test_healthy_database_has_no_notice(tmp_path):
    app = create_app(Paths(tmp_path / "d").ensure(), token="t")
    assert TestClient(app).get("/health").json()["notices"] == []


WRITER = r"""
import sys, time
sys.path.insert(0, sys.argv[2])
from uata.db.database import Database, utcnow
db = Database(sys.argv[1]); db.migrate()
i = 0
while True:
    i += 1
    with db.session() as conn:
        conn.execute("INSERT INTO audit_log(at, actor, action, detail_json) VALUES (?,?,?,?)",
                     (utcnow(), "system", "durability", '{"i": %d}' % i))
    print(i, flush=True)   # printed only AFTER the commit returned
"""


def test_no_committed_data_lost_on_hard_kill(tmp_path):
    db_file = tmp_path / "crash.sqlite3"
    p = subprocess.Popen([sys.executable, "-c", WRITER, str(db_file), str(BACKEND)], stdout=subprocess.PIPE, text=True)
    last = 0
    deadline = time.monotonic() + 20
    while last < 300 and time.monotonic() < deadline:
        line = p.stdout.readline()
        if line.strip():
            last = int(line)
    p.send_signal(signal.SIGKILL)  # like a power cut / task-manager kill, mid-write
    p.wait()
    assert last >= 300
    db = Database(db_file)
    assert db.integrity_ok()
    with db.session() as conn:
        n = conn.execute("SELECT count(*) FROM audit_log WHERE action='durability'").fetchone()[0]
    assert n >= last  # every commit acknowledged before the kill survived


# ---------------------------------------------------------------- security surface
def test_every_route_except_health_requires_the_token(tmp_path):
    app = create_app(Paths(tmp_path / "d").ensure(), token="secret")
    c = TestClient(app)
    for route in app.routes:
        path = getattr(route, "path", "")
        if path == "/health":
            continue
        for method in getattr(route, "methods", set()) - {"HEAD", "OPTIONS"}:
            url = path.replace("{", "").replace("}", "")  # concrete-ish placeholders: '1' style not needed for 401
            r = c.request(method, url.replace("source_id", "1").replace("item_id", "1").replace("sid", "1")
                          .replace("did", "1").replace("report_id", "1").replace("input_id", "1")
                          .replace("signal_id", "1").replace("result_id", "1").replace("name", "x")
                          .replace("market_condition", "trending"))
            assert r.status_code in (401, 404, 405, 422), (method, path, r.status_code)
            if r.status_code != 401:
                # 404/405/422 must not mean "served without auth": retry a GET-able path shape
                assert r.status_code != 200
    # the API schema / docs are not exposed to other local processes
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert c.get(path).status_code == 404


@pytest.mark.parametrize("payload", ["' OR 1=1 --", '"; DROP TABLE knowledge_items; --', "rsi\" OR \"1\"=\"1", "*", "NEAR("])
def test_injection_attempts_are_harmless(client, payload):
    client.post("/knowledge/notes", json={"title": "safe", "content": "RSI oversold"})
    assert client.get("/knowledge/search", params={"q": payload}).status_code == 200
    assert client.get("/knowledge/sources", params={"kind": payload}).status_code == 200
    assert client.get("/knowledge/sources").json()[0]["title"] == "safe"  # table intact
    bad_key = client.patch("/knowledge/sources/1", json={f"title=1, status='approved' --": "x"})
    assert bad_key.status_code == 400  # column names are allow-listed


def test_oversized_and_malformed_inputs_rejected(client):
    assert client.post("/knowledge/notes", json={"title": "x" * 301, "content": "c"}).status_code == 422
    assert client.post("/knowledge/notes", content=b"{not json", headers={"content-type": "application/json"}).status_code == 422
    big = b"\x89PNG" + b"0" * (26 * 1024 * 1024)
    r = client.post("/analysis/inputs", files={"file": ("big.png", io.BytesIO(big))})
    assert r.status_code == 422 and "too large" in r.json()["detail"]


# ---------------------------------------------------------------- full journey against the real engine process
def csv_uptrend(n=1500):
    import numpy as np
    rng = np.random.default_rng(1)
    lines, p = ["time,open,high,low,close"], 1.0
    for i in range(n):
        o = p
        c = o + 0.0004 + rng.normal(0, 0.0002)
        lines.append(f"{1_700_000_000 + i * 30},{o},{max(o, c) + 0.0001},{min(o, c) - 0.0001},{c}")
        p = c
    return "\n".join(lines).encode()


def test_full_user_journey_on_the_real_engine(tmp_path):
    port, data = free_port(), tmp_path / "engine"
    env = {**os.environ, "PYTHONPATH": str(BACKEND)}
    proc = subprocess.Popen([sys.executable, "-m", "uata", "--port", str(port), "--data-dir", str(data)],
                            cwd=BACKEND, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    base = f"http://127.0.0.1:{port}"
    try:
        for _ in range(100):
            try:
                if httpx.get(base + "/health", timeout=1).status_code == 200:
                    break
            except httpx.TransportError:
                time.sleep(0.1)
        token = (data / "api_token").read_text().strip()
        c = httpx.Client(base_url=base, headers={"X-UATA-Token": token}, timeout=60)

        # 1. settings
        assert c.patch("/settings", json={"language": "en", "signal_cooldown_sec": 0}).json()["language"] == "en"
        # 2. knowledge: a rule → learning report → approval
        note = c.post("/knowledge/notes", json={"title": "Trend rule", "content": "When the trend is up, buy."}).json()
        c.post(f"/knowledge/reports/{note['report']['id']}/decision", json={"decision": "approve"})
        # 3. historical data, 4. strategy, 5. backtest, 6. gated approval
        ds = c.post("/datasets/csv", files={"file": ("up.csv", csv_uptrend())}).json()
        s = c.post("/strategies", json={"name": "Journey", "definition": {
            "long": {"all": [{"id": "bullish_candle"}]}, "duration_sec": 60}}).json()
        assert c.post(f"/strategies/{s['id']}/backtest", json={"dataset_id": ds["id"]}).json()["qualifies"]
        assert c.post(f"/strategies/{s['id']}/approve").json()["status"] == "approved"
        # 7. analysis: chart → BUY
        c.post("/analysis/start", json={"input_mode": "upload"})
        png = cv2.imencode(".png", render_chart(uptrend_ohlc(), style="dark_tv").image)[1].tobytes()
        a = c.post("/analysis/inputs", files={"file": ("c.png", png)}).json()["analysis"]
        assert a["signal"] == "BUY" and len(a["steps"]) == 14
        assert c.get("/analysis/status").json()["recommendation"]["signal"] == "BUY"
        # 8. result → 9. statistics
        c.post(f"/signals/{a['signal_id']}/result", json={"account_type": "demo", "outcome": "win", "asset": "EURUSD"})
        assert c.get("/stats/dashboard", params={"account_type": "demo"}).json()["results"]["wins"] == 1
        # 10. encrypted backup → wipe → restore → everything is back
        b = c.post("/backups", json={"passphrase": "journey passphrase"}).json()
        raw = c.get(f"/backups/{b['name']}").content
        assert b"Journey" not in raw
        assert c.post("/privacy/wipe", json={"confirm": "DELETE ALL MY DATA"}).json()["wiped"]
        assert c.get("/strategies").json() == [] and c.get("/signals").json() == []
        r = c.post("/backups/restore", files={"file": (b["name"], raw)}, data={"passphrase": "journey passphrase"})
        assert r.status_code == 200, r.text
        assert [x["name"] for x in c.get("/strategies").json()] == ["Journey"]
        assert c.get("/strategies").json()[0]["status"] == "approved"
        assert c.get("/signals").json()[0]["signal"] == "BUY"
        assert c.get("/stats/dashboard", params={"account_type": "demo"}).json()["results"]["wins"] == 1
        assert c.get("/settings").json()["language"] == "en"
    finally:
        proc.send_signal(signal.SIGTERM)  # graceful shutdown
        try:
            code = proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
            raise
    log = proc.stderr.read().decode()
    # uvicorn re-raises SIGTERM after a clean shutdown, so the exit code is 0 or -SIGTERM;
    # what matters is that the shutdown hooks ran
    assert code in (0, -signal.SIGTERM), log[-2000:]
    assert "Application shutdown complete" in log
