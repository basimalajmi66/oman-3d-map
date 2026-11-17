"""The embedded (mobile) entry point serves the same API from a background thread."""
import socket

import httpx

from uata import android_entry


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_start_serve_stop(tmp_path):
    port = free_port()
    data = tmp_path / "files" / "uata"
    try:
        info = android_entry.start(str(data), port)
        assert info["already_running"] is False
        assert android_entry.is_running()
        assert android_entry.start(str(data), port)["already_running"] is True  # idempotent
        assert httpx.get(f"http://127.0.0.1:{port}/health").json()["ok"] is True
        token = (data / "api_token").read_text()
        s = httpx.get(f"http://127.0.0.1:{port}/settings", headers={"X-UATA-Token": token}).json()
        assert s["trading_mode"] == "manual"
    finally:
        android_entry.stop()
    assert not android_entry.is_running()
