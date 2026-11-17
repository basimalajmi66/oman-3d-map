"""Continuous screen reading (input mode ``continuous_screen``).

Runs only while an analysis session in that mode is active AND the user has
granted screen capture. Every ``capture_interval_sec`` it grabs the screen (or the
configured region), reads the chart and keeps the latest reading in memory.
Frames are not written to disk. Emergency stop or revoking the permission stops
it immediately.
"""

from __future__ import annotations

import threading
from datetime import datetime, timezone
from typing import Any, Callable

from uata.vision.capture import CaptureUnavailable, Capturer


class ScreenWatcher:
    def __init__(self, capturer: Capturer, read: Callable[..., dict]):
        self.capturer = capturer
        self._read = read
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self.latest: dict | None = None
        self.error: str | None = None
        self.frames = 0

    @property
    def active(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def start(self, interval_sec: float, region: dict | None, min_quality: float,
              allowed: Callable[[], bool], enabled: Callable[[], dict] | None = None) -> None:
        self.stop()
        self._stop.clear()
        self.latest, self.error, self.frames = None, None, 0

        def run() -> None:
            while not self._stop.is_set():
                if not allowed():  # permission revoked → stop on our own
                    self.error = "screen_capture_permission_revoked"
                    return
                try:
                    img = self.capturer.grab(region)
                    reading = self._read(img, min_quality, enabled() if enabled else None)
                    with self._lock:
                        from uata.services.chart_input_service import technical_summary
                        self.latest = {
                            "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                            "summary": reading["summary"],
                            "data_quality": reading["data_quality"],
                            "usable": reading["usable"],
                            "technical": technical_summary(reading.get("technical")),
                            "knowledge": reading.get("knowledge", [])[:3],
                            "decision": reading.get("decision"),
                        }
                        self.frames += 1
                        self.error = None
                except CaptureUnavailable as e:
                    self.error = str(e)
                except Exception as e:  # keep running; report instead of crashing the engine
                    self.error = f"reading failed: {e}"
                self._stop.wait(interval_sec)

        self._thread = threading.Thread(target=run, name="uata-screen-watch", daemon=True)
        self._thread.start()

    def stop(self, timeout: float = 5.0) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout)
        self._thread = None

    def snapshot(self) -> dict:
        with self._lock:
            return {"active": self.active, "latest": self.latest, "error": self.error, "frames": self.frames}
