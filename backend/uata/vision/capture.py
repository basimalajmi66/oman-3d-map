"""Screen capture through the operating system's public screenshot API (mss).

Only used after the user grants ``screen_capture_allowed``. It reads pixels the
user can already see; it does not inject into, hook or automate any application.
"""

from __future__ import annotations

from typing import Protocol

import numpy as np


class Capturer(Protocol):
    def grab(self, region: dict | None) -> np.ndarray: ...


class CaptureUnavailable(RuntimeError):
    pass


class MssCapturer:
    """Primary monitor, or a region {left, top, width, height} in screen pixels."""

    def grab(self, region: dict | None) -> np.ndarray:
        try:
            import mss
        except ImportError as e:  # pragma: no cover
            raise CaptureUnavailable("screen capture library (mss) is not installed") from e
        try:
            factory = getattr(mss, "MSS", None) or mss.mss
            with factory() as sct:
                mon = dict(region) if region else sct.monitors[1]
                shot = np.asarray(sct.grab(mon))  # BGRA
        except Exception as e:  # no display, permission denied by the OS, ...
            raise CaptureUnavailable(f"screen capture failed: {e}") from e
        return np.ascontiguousarray(shot[:, :, :3])
