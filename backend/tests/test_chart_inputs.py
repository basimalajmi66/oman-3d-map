import io

import cv2
import numpy as np
import pytest

from uata.services import chart_input_service as cis


def png(width=320, height=200, color=(30, 30, 30)) -> bytes:
    img = np.full((height, width, 3), color, dtype=np.uint8)
    cv2.rectangle(img, (40, 50), (60, 150), (0, 200, 0), -1)  # a green "candle"
    ok, buf = cv2.imencode(".png", img)
    assert ok
    return buf.tobytes()


def jpg(width=400, height=300) -> bytes:
    ok, buf = cv2.imencode(".jpg", np.zeros((height, width, 3), dtype=np.uint8))
    return buf.tobytes()


def submit(client, data, name="chart.png", mode="upload"):
    return client.post("/analysis/inputs", files={"file": (name, io.BytesIO(data))}, data={"input_mode": mode})


def test_upload_image_returns_honest_wait(client, paths):
    r = submit(client, png(320, 200))
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["analysis"]["signal"] == "WAIT"
    # one green rectangle is not a readable chart: the reader abstains
    assert body["analysis"]["reason_code"] == "image_quality_insufficient"
    assert body["analysis"]["reading"]["usable"] is False
    assert body["analysis"]["data_basis"] == "image_only"
    assert body["analysis"]["confidence"] is None
    assert body["input"]["width"] == 320 and body["input"]["height"] == 200
    assert (paths.files_dir / body["input"]["stored_path"]).exists()
    # no fake entry in the signal log / statistics
    assert client.get("/signals").json() == []


def test_shared_jpeg_is_normalised_to_png(client):
    r = submit(client, jpg(), name="Screenshot_2026.jpg", mode="share")
    assert r.status_code == 201
    img = client.get(f"/analysis/inputs/{r.json()['input']['id']}/image")
    assert img.headers["content-type"] == "image/png"
    decoded = cv2.imdecode(np.frombuffer(img.content, np.uint8), cv2.IMREAD_COLOR)
    assert decoded.shape[:2] == (300, 400)


@pytest.mark.parametrize("data,expected", [
    (b"", "empty"),
    (b"%PDF-1.4 not an image", "not a readable image"),
    (None, "too small"),
])
def test_invalid_images_rejected(client, data, expected):
    if data is None:
        data = png(32, 32)
    r = submit(client, data)
    assert r.status_code == 422
    assert expected in r.json()["detail"]


def test_screen_modes_need_permission_but_share_does_not(client):
    assert submit(client, png(), mode="screenshot").status_code == 403
    assert submit(client, png(), mode="share").status_code == 201
    client.patch("/settings", json={"screen_capture_allowed": True})
    assert submit(client, png(), mode="screenshot").status_code == 201
    assert submit(client, png(), mode="telepathy").status_code == 400


def test_refused_while_emergency_stop_active(client):
    client.post("/analysis/emergency-stop")
    assert submit(client, png()).status_code == 409
    client.post("/analysis/start", json={"input_mode": "upload"})
    r = submit(client, png())
    assert r.status_code == 201
    assert r.json()["input"]["session_id"] is not None  # linked to the running session


def test_list_and_delete_keep_shared_file_until_last_reference(client, paths):
    a = submit(client, png()).json()["input"]
    b = submit(client, png()).json()["input"]  # same bytes -> same stored file
    assert a["stored_path"] == b["stored_path"]
    assert len(client.get("/analysis/inputs").json()) == 2
    client.delete(f"/analysis/inputs/{a['id']}")
    assert (paths.files_dir / b["stored_path"]).exists()
    client.delete(f"/analysis/inputs/{b['id']}")
    assert not (paths.files_dir / b["stored_path"]).exists()
    assert client.delete(f"/analysis/inputs/{b['id']}").status_code == 404
    assert client.get("/analysis/inputs/999/image").status_code == 404


def test_retention_limit(client, monkeypatch):
    monkeypatch.setattr(cis, "MAX_KEEP", 3)
    ids = [submit(client, png(100 + i, 100)).json()["input"]["id"] for i in range(5)]
    remaining = [r["id"] for r in client.get("/analysis/inputs").json()]
    assert remaining == ids[:1:-1]  # newest three, newest first


def test_inputs_are_included_in_backup_and_wipe(client, paths, monkeypatch):
    from uata.services import backup_service as bs
    monkeypatch.setattr(bs, "SCRYPT_N", 2 ** 10)
    inp = submit(client, png()).json()["input"]
    name = client.post("/backups", json={"passphrase": "long passphrase"}).json()["name"]
    raw = client.get(f"/backups/{name}").content
    client.post("/privacy/wipe", json={"confirm": "DELETE ALL MY DATA"})
    assert client.get("/analysis/inputs").json() == []
    client.post("/backups/restore", files={"file": (name, io.BytesIO(raw))}, data={"passphrase": "long passphrase"})
    assert client.get(f"/analysis/inputs/{inp['id']}/image").status_code == 200


# ---------------------------------------------------------------- Phase 3: reading + capture
from uata.vision.synthetic import random_walk_ohlc, render_chart  # noqa: E402


def chart_png(n=50, seed=9, **kw) -> bytes:
    ok, buf = cv2.imencode(".png", render_chart(random_walk_ohlc(n, seed=seed), **kw).image)
    return buf.tobytes()


def test_real_chart_is_read_and_stored(client):
    r = submit(client, chart_png(), name="eurusd.png", mode="share")
    assert r.status_code == 201
    a = r.json()["analysis"]
    assert a["signal"] == "WAIT" and a["reason_code"] == "no_approved_strategy"
    assert a["reading"]["usable"] is True and a["reading"]["candles"] == 50
    assert a["reading"]["closed_candles"] == 49
    iid = r.json()["input"]["id"]
    full = client.get(f"/analysis/inputs/{iid}/reading").json()
    assert len(full["candles"]) == 50 and full["data_basis"] == "image_only"
    ann = client.get(f"/analysis/inputs/{iid}/annotated")
    assert ann.status_code == 200 and ann.headers["content-type"] == "image/png"
    listed = client.get("/analysis/inputs").json()[0]
    assert listed["usable"] == 1 and listed["summary"]["candles"] == 50
    # a real market analysis is recorded — as WAIT, with its reason (no approved strategy yet)
    sigs = client.get("/signals").json()
    assert len(sigs) == 1 and sigs[0]["signal"] == "WAIT" and sigs[0]["reasons"] == ["no_approved_strategy"]


def test_quality_threshold_follows_settings(client):
    blurry = cv2.GaussianBlur(render_chart(random_walk_ohlc(50, seed=9)).image, (7, 7), 0)
    data = cv2.imencode(".png", blurry)[1].tobytes()
    client.patch("/settings", json={"min_data_quality_to_signal": 0.95})
    strict = submit(client, data).json()["analysis"]
    client.patch("/settings", json={"min_data_quality_to_signal": 0.3})
    lenient = submit(client, data).json()["analysis"]
    assert strict["reason_code"] == "image_quality_insufficient"
    assert lenient["reason_code"] == "no_approved_strategy"


def test_capture_requires_permission_and_uses_region(client, capturer):
    assert client.post("/analysis/capture").status_code == 403
    client.patch("/settings", json={"screen_capture_allowed": True,
                                    "capture_region": {"left": 10, "top": 20, "width": 900, "height": 500}})
    r = client.post("/analysis/capture")
    assert r.status_code == 201, r.text
    assert capturer.calls[-1] == {"left": 10, "top": 20, "width": 900, "height": 500}
    assert r.json()["input"]["input_mode"] == "screen_region"
    assert r.json()["analysis"]["reading"]["candles"] == 50


def test_capture_failure_reported(client, capturer):
    client.patch("/settings", json={"screen_capture_allowed": True})
    capturer.fail = "no display"
    r = client.post("/analysis/capture")
    assert r.status_code == 503 and "no display" in r.json()["detail"]


def test_capture_region_validation(client):
    assert client.patch("/settings", json={"capture_region": {"left": 0, "top": 0, "width": 50, "height": 50}}).status_code == 422
    assert client.patch("/settings", json={"capture_region": {"x": 0}}).status_code == 422
    assert client.patch("/settings", json={"capture_interval_sec": 1}).status_code == 422


def _wait_for(pred, timeout=10.0):
    import time
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.05)
    return False


def test_continuous_screen_reading_and_kill_switch(client, capturer):
    client.patch("/settings", json={"screen_capture_allowed": True, "capture_interval_sec": 2})
    st = client.post("/analysis/start", json={"input_mode": "continuous_screen"}).json()
    assert st["screen_watch"]["active"] is True
    assert _wait_for(lambda: client.get("/analysis/status").json()["screen_watch"]["latest"] is not None)
    st = client.get("/analysis/status").json()
    assert st["screen_watch"]["latest"]["summary"]["candles"] == 50
    assert st["recommendation"]["signal"] == "WAIT"
    assert st["recommendation"]["reason_code"] == "no_approved_strategy"
    assert client.get("/analysis/inputs").json() == []  # frames are not stored
    st = client.post("/analysis/emergency-stop").json()
    assert st["screen_watch"]["active"] is False


def test_revoking_permission_stops_continuous_reading(client):
    client.patch("/settings", json={"screen_capture_allowed": True})
    client.post("/analysis/start", json={"input_mode": "continuous_screen"})
    assert client.get("/analysis/status").json()["screen_watch"]["active"] is True
    client.patch("/settings", json={"screen_capture_allowed": False})
    assert client.get("/analysis/status").json()["screen_watch"]["active"] is False


def test_only_the_newest_candles_are_read(client):
    """Settings.chart_max_candles: the newest N candles are kept, the reading says how many were dropped."""
    from uata.vision.synthetic import random_walk_ohlc, render_chart
    png = cv2.imencode(".png", render_chart(random_walk_ohlc(130, seed=4), style="dark_tv", width=1400).image)[1].tobytes()
    client.patch("/settings", json={"chart_max_candles": 60})
    r = client.post("/analysis/inputs", files={"file": ("c.png", png)}).json()
    reading = client.get(f"/analysis/inputs/{r['input']['id']}/reading").json()
    assert len(reading["candles"]) == 60 and reading["candles_limit"] == {"kept": 60, "total": 130}
    assert "candles_limited" in reading["warnings"]
    assert reading["candles"][0]["index"] == 0 and reading["candles"][-1]["status"] == "possibly_forming"
    assert max(c["rel_high"] for c in reading["candles"]) == 1.0 and min(c["rel_low"] for c in reading["candles"]) == 0.0
    assert r["analysis"]["reading"]["candles"] == 60 and r["analysis"]["technical"]["candles_used"] == 59
    client.patch("/settings", json={"chart_max_candles": 0})
    r = client.post("/analysis/inputs", files={"file": ("c2.png", png)}).json()
    assert r["analysis"]["reading"]["candles"] == 130


def test_chart_size_settings_are_validated(client):
    assert client.get("/settings").json()["chart_max_side"] == 1280
    assert client.get("/settings").json()["chart_max_candles"] == 100
    assert client.patch("/settings", json={"chart_max_candles": 30}).status_code == 422  # strategies need 50+
    assert client.patch("/settings", json={"chart_max_side": 300}).status_code == 422
    assert client.patch("/settings", json={"chart_max_side": 0}).json()["chart_max_side"] == 0
