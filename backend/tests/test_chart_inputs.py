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
    assert body["analysis"]["reason_code"] == "analysis_engine_not_installed"
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
