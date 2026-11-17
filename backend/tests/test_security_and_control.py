import os
import stat
import sys

import pytest
from fastapi.testclient import TestClient


def test_health_is_public(app):
    assert TestClient(app).get("/health").json()["ok"] is True


@pytest.mark.parametrize("path", ["/settings", "/analysis/status", "/knowledge/sources", "/signals",
                                  "/stats/summary", "/backups"])
def test_token_required(app, path):
    c = TestClient(app)
    assert c.get(path).status_code == 401
    assert c.get(path, headers={"X-UATA-Token": "wrong"}).status_code == 401


def test_no_trade_execution_endpoint_exists(app):
    paths = {r.path.lower() for r in app.routes}
    for forbidden in ("order", "trade/execute", "execute", "place", "broker", "login", "password"):
        assert not any(forbidden in p for p in paths), forbidden


@pytest.mark.skipif(sys.platform.startswith("win"), reason="POSIX permissions")
def test_token_and_db_files_are_owner_only(paths, app):
    for f in (paths.token_file, paths.db_file):
        assert stat.S_IMODE(os.stat(f).st_mode) == 0o600


def test_status_idle_is_wait(client):
    st = client.get("/analysis/status").json()
    assert st["state"] == "idle"
    assert st["recommendation"]["signal"] == "WAIT"
    assert st["engine_available"] is False


def test_start_without_engine_reports_honestly(client):
    st = client.post("/analysis/start", json={"input_mode": "upload"}).json()
    assert st["state"] == "running_no_engine"
    assert st["recommendation"]["signal"] == "WAIT"
    assert st["recommendation"]["reason_code"] == "analysis_engine_not_installed"
    assert st["recommendation"]["confidence"] is None
    assert st["session"]["timeframe_sec"] == 30


def test_screen_modes_need_permission(client):
    r = client.post("/analysis/start", json={"input_mode": "continuous_screen"})
    assert r.status_code == 403
    client.patch("/settings", json={"screen_capture_allowed": True})
    assert client.post("/analysis/start", json={"input_mode": "continuous_screen"}).status_code == 200


def test_only_one_running_session(client, services):
    client.post("/analysis/start", json={"input_mode": "upload"})
    client.post("/analysis/start", json={"input_mode": "upload"})
    with services.db.session() as conn:
        assert conn.execute("SELECT count(*) FROM analysis_sessions WHERE status='running'").fetchone()[0] == 1


def test_stop(client):
    client.post("/analysis/start", json={"input_mode": "upload"})
    st = client.post("/analysis/stop").json()
    assert st["state"] == "idle" and st["session"] is None


def test_emergency_stop_revokes_permissions(client):
    client.patch("/settings", json={"screen_capture_allowed": True, "continuous_analysis": True})
    client.post("/analysis/start", json={"input_mode": "continuous_screen"})
    st = client.post("/analysis/emergency-stop").json()
    assert st["state"] == "halted" and st["session"] is None
    s = client.get("/settings").json()
    assert s["screen_capture_allowed"] is False and s["continuous_analysis"] is False
    # starting again explicitly clears the halt
    assert client.post("/analysis/start", json={"input_mode": "upload"}).json()["halted"] is False


def test_invalid_input_mode(client):
    assert client.post("/analysis/start", json={"input_mode": "telepathy"}).status_code == 400
