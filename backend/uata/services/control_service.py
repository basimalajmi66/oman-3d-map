"""Analysis session control and the emergency stop (kill switch).

Sessions are created, tracked and stopped here. Chart reading exists since
Phase 3; the signal engine arrives in Phase 8. Until then ``status()`` honestly
reports ``engine_available = False`` and the recommendation is always WAIT with
an explicit reason — no fabricated signal is ever produced.
"""

from __future__ import annotations

import threading
from typing import Any

from uata.db.database import Database, audit, row_to_dict, utcnow

ENGINE_COMPONENTS = {
    # name: available-in-this-build
    "chart_vision": True,        # Phase 3 ✔
    "technical_analysis": False, # Phase 4
    "knowledge_rag": False,      # Phase 5 (Phase 1 provides keyword search only)
    "video_learning": False,     # Phase 6
    "strategy_engine": False,    # Phase 7
    "signal_engine": False,      # Phase 8
}

INPUT_MODES = ("upload", "screenshot", "screen_region", "continuous_screen", "price_feed")
SCREEN_MODES = {"screenshot", "screen_region", "continuous_screen"}


class PermissionRequired(Exception):
    pass


class ControlService:
    def __init__(self, db: Database, watcher=None):
        self.db = db
        self.watcher = watcher  # ScreenWatcher for continuous_screen sessions (optional)
        self._lock = threading.Lock()
        self._halted = False

    @property
    def halted(self) -> bool:
        return self._halted

    def start(self, input_mode: str, timeframe_sec: int, asset: str | None,
              screen_capture_allowed: bool) -> dict[str, Any]:
        if input_mode not in INPUT_MODES:
            raise ValueError(f"input_mode must be one of {INPUT_MODES}")
        if input_mode in SCREEN_MODES and not screen_capture_allowed:
            raise PermissionRequired("screen capture permission has not been granted by the user")
        with self._lock, self.db.session() as conn:
            self._halted = False
            # only one running session at a time
            conn.execute(
                "UPDATE analysis_sessions SET status='stopped', stopped_at=?, stop_reason='superseded' "
                "WHERE status='running'", (utcnow(),))
            cur = conn.execute(
                "INSERT INTO analysis_sessions(input_mode, asset, timeframe_sec, status, started_at) "
                "VALUES (?,?,?,'running',?)", (input_mode, asset, timeframe_sec, utcnow()))
            audit(conn, "user", "analysis.start", session_id=cur.lastrowid, input_mode=input_mode)
            row = conn.execute("SELECT * FROM analysis_sessions WHERE id=?", (cur.lastrowid,)).fetchone()
        return row_to_dict(row)

    def stop(self, reason: str = "user_stop", emergency: bool = False) -> int:
        """Stop every running session. Returns how many were stopped."""
        if self.watcher is not None:
            self.watcher.stop()
        with self._lock, self.db.session() as conn:
            if emergency:
                self._halted = True
            n = conn.execute(
                "UPDATE analysis_sessions SET status='stopped', stopped_at=?, stop_reason=? WHERE status='running'",
                (utcnow(), reason)).rowcount
            audit(conn, "user", "analysis.emergency_stop" if emergency else "analysis.stop", stopped=n)
        return n

    def current_session(self) -> dict[str, Any] | None:
        with self.db.session() as conn:
            row = conn.execute(
                "SELECT * FROM analysis_sessions WHERE status='running' ORDER BY id DESC LIMIT 1").fetchone()
        return row_to_dict(row)

    def status(self) -> dict[str, Any]:
        session = self.current_session()
        engine_ready = all(ENGINE_COMPONENTS.values())
        if self._halted:
            state, reason = "halted", "emergency_stop_active"
        elif session is None:
            state, reason = "idle", "analysis_not_running"
        elif not engine_ready:
            state, reason = "running_no_engine", "analysis_engine_not_installed"
        else:
            state, reason = "analyzing", None
        watch = self.watcher.snapshot() if self.watcher is not None else None
        if session is not None and watch and watch["latest"] and not self._halted:
            # the screen is being read: say why there is still no signal
            reason = "signal_engine_not_installed" if watch["latest"]["usable"] else "image_quality_insufficient"
        return {
            "state": state,
            "halted": self._halted,
            "session": session,
            "engine_available": engine_ready,
            "components": ENGINE_COMPONENTS,
            "screen_watch": watch,
            # The panel shows this. Without an engine it is always WAIT, never a guess.
            "recommendation": {
                "signal": "WAIT",
                "reason_code": reason,
                "confidence": None,
                "confidence_calibrated": False,
                "duration_sec": None,
            },
        }
