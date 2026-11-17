import io
import os

import pytest

from uata.services import backup_service as bs
from uata.services.backup_service import BackupError, decrypt_stream, encrypt_stream

PASS = "correct horse battery"


@pytest.fixture(autouse=True)
def fast_kdf(monkeypatch):
    monkeypatch.setattr(bs, "SCRYPT_N", 2 ** 10)  # keep tests fast; production uses 2**15


@pytest.mark.parametrize("size", [0, 10, bs.CHUNK, bs.CHUNK * 2 + 7])
def test_stream_roundtrip(monkeypatch, size):
    monkeypatch.setattr(bs, "CHUNK", 1024)
    data = os.urandom(size if size < 5000 else 3000)
    enc = io.BytesIO()
    encrypt_stream(io.BytesIO(data), enc, PASS)
    out = io.BytesIO()
    decrypt_stream(io.BytesIO(enc.getvalue()), out, PASS)
    assert out.getvalue() == data
    if len(data) >= 16:
        assert data[:16] not in enc.getvalue()


def test_wrong_passphrase_and_tamper(monkeypatch):
    monkeypatch.setattr(bs, "CHUNK", 64)
    enc = io.BytesIO()
    encrypt_stream(io.BytesIO(b"x" * 300), enc, PASS)
    blob = enc.getvalue()
    with pytest.raises(BackupError):
        decrypt_stream(io.BytesIO(blob), io.BytesIO(), "wrong passphrase!")
    tampered = bytearray(blob)
    tampered[-5] ^= 1
    with pytest.raises(BackupError):
        decrypt_stream(io.BytesIO(bytes(tampered)), io.BytesIO(), PASS)
    # truncation at a chunk boundary (drop the final chunk) must be detected:
    # final chunk = 300 % 64 = 44 bytes plaintext + 16 tag + 4 length prefix
    with pytest.raises(BackupError):
        decrypt_stream(io.BytesIO(blob[: -(44 + 16 + 4)]), io.BytesIO(), PASS)
    with pytest.raises(BackupError):
        decrypt_stream(io.BytesIO(b"NOTABACKUP"), io.BytesIO(), PASS)


def test_full_backup_restore_cycle(client, paths):
    client.patch("/settings", json={"language": "en"})
    src = client.post("/knowledge/files", files={"file": ("s.txt", io.BytesIO(b"keep this strategy"),
                                                          "text/plain")}).json()
    client.post("/knowledge/notes", json={"title": "note", "content": "body"})
    r = client.post("/backups", json={"passphrase": PASS})
    assert r.status_code == 201
    name = r.json()["name"]
    raw = client.get(f"/backups/{name}").content
    assert b"keep this strategy" not in raw  # encrypted at rest

    # wipe everything, then restore
    assert client.post("/privacy/wipe", json={"confirm": "DELETE ALL MY DATA"}).json()["wiped"]
    assert client.get("/knowledge/sources").json() == []
    assert client.get("/settings").json()["language"] == "ar"
    assert not (paths.files_dir / src["stored_path"]).exists()

    bad = client.post("/backups/restore", files={"file": (name, io.BytesIO(raw))}, data={"passphrase": "nope-nope-nope"})
    assert bad.status_code == 400
    ok = client.post("/backups/restore", files={"file": (name, io.BytesIO(raw))}, data={"passphrase": PASS})
    assert ok.status_code == 200, ok.text
    assert client.get("/settings").json()["language"] == "en"
    assert len(client.get("/knowledge/sources").json()) == 2
    assert (paths.files_dir / src["stored_path"]).read_bytes() == b"keep this strategy"
    assert len(client.get("/knowledge/search", params={"q": "strategy"}).json()) == 1


def test_short_passphrase_rejected(client):
    assert client.post("/backups", json={"passphrase": "short"}).status_code == 400


def test_wipe_requires_exact_confirmation(client):
    client.post("/knowledge/notes", json={"title": "n", "content": "c"})
    assert client.post("/privacy/wipe", json={"confirm": "yes"}).status_code == 400
    assert len(client.get("/knowledge/sources").json()) == 1


def test_wipe_can_include_backups(client, paths):
    client.post("/backups", json={"passphrase": PASS})
    client.post("/privacy/wipe", json={"confirm": "DELETE ALL MY DATA"})
    assert client.get("/backups").json() != []
    client.post("/privacy/wipe", json={"confirm": "DELETE ALL MY DATA", "include_backups": True})
    assert client.get("/backups").json() == []


def test_download_backup_rejects_traversal(client):
    assert client.get("/backups/..%2F..%2Fapi_token").status_code == 404
