"""Entry point used when the engine runs embedded inside the mobile app.

On Android the Kotlin side (``MainActivity.kt``) starts Python through Chaquopy
and calls :func:`start` with the app's private files directory. The engine then
serves the exact same API as on Windows, on the loopback interface only, and
the Flutter UI connects to it with the token written to ``<data_dir>/api_token``.
"""

from __future__ import annotations

import threading
import time
from pathlib import Path

_server = None
_thread: threading.Thread | None = None
_lock = threading.Lock()


def start(data_dir: str, port: int = 8765, timeout: float = 20.0) -> dict:
    """Start the engine in a daemon thread (idempotent). Returns ``{port, data_dir}``."""
    global _server, _thread
    with _lock:
        if _server is not None and _thread is not None and _thread.is_alive():
            return {"port": port, "data_dir": data_dir, "already_running": True}

        import uvicorn

        from uata.api.app import create_app
        from uata.config import DEFAULT_HOST, Paths

        app = create_app(Paths(Path(data_dir)))
        config = uvicorn.Config(app, host=DEFAULT_HOST, port=int(port), log_level="warning",
                                lifespan="off", loop="asyncio", http="h11")
        _server = uvicorn.Server(config)
        _server.install_signal_handlers = lambda: None  # not the main thread
        _thread = threading.Thread(target=_server.run, name="uata-engine", daemon=True)
        _thread.start()

    deadline = time.monotonic() + timeout
    while not _server.started:
        if not _thread.is_alive() or time.monotonic() > deadline:
            raise RuntimeError("engine failed to start")
        time.sleep(0.05)
    return {"port": int(port), "data_dir": data_dir, "already_running": False}


def stop(timeout: float = 10.0) -> None:
    global _server, _thread
    with _lock:
        if _server is None:
            return
        _server.should_exit = True
        if _thread is not None:
            _thread.join(timeout)
        _server, _thread = None, None


def is_running() -> bool:
    return _server is not None and _thread is not None and _thread.is_alive()
