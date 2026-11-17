"""Runs the decision engine and records signals (Phase 8).

* Every *new* market analysis is recorded (BUY, SELL or WAIT) so statistics are complete.
  An image the reader could not read is not a market analysis and is not recorded.
* "New" means a new last closed candle: the same chart analysed again (continuous
  screen reading every few seconds, a re-uploaded screenshot) is not recorded twice.
* After a BUY/SELL, another BUY/SELL is suppressed for ``signal_cooldown_sec``.
"""

from __future__ import annotations

import threading
import time

from uata.services.records_service import RecordsService
from uata.signal.engine import Decision, decide, fingerprint


class SignalService:
    def __init__(self, records: RecordsService, strategies, settings):
        self.records = records
        self.strategies = strategies   # StrategyService
        self.settings = settings       # SettingsService
        self._lock = threading.Lock()
        self._last_fp: dict[str, str] = {}
        # None = no trade signal yet (monotonic time starts near 0 after a reboot: never compare against 0)
        self._last_trade_signal_at: float | None = None
        self.latest: dict | None = None

    def evaluate(self, reading: dict, technical: dict, knowledge: list[dict] | None, stream: str,
                 session_id: int | None = None, asset: str | None = None) -> dict:
        s = self.settings.get()
        st = s.model_dump()
        approved = [x for x in self.strategies.list() if x["status"] == "approved"]
        d: Decision = decide(reading, technical, st, approved, knowledge)
        fp = fingerprint(reading)
        out = d.to_dict()
        with self._lock:
            repeated = bool(fp) and self._last_fp.get(stream) == fp
            in_cooldown = (self._last_trade_signal_at is not None
                           and time.monotonic() - self._last_trade_signal_at < s.signal_cooldown_sec)
            if d.signal != "WAIT" and in_cooldown:
                out.update(signal="WAIT", reason_code="cooldown", reason_codes=["cooldown"] + out["reason_codes"],
                           duration_sec=None)
            out["repeated"] = repeated
            out["recorded"] = False
            if not repeated and reading.get("usable"):
                self._last_fp[stream] = fp
                rec = self.records.record_signal(
                    signal=out["signal"], timeframe_sec=s.candle_timeframe_sec, data_basis=out["data_basis"],
                    reasons=out["reasons"] or [out["reason_code"] or "wait"], supporting=out["supporting"],
                    opposing=out["opposing"], data_quality=out["data_quality"], confidence=out["confidence"],
                    confidence_calibrated=False, duration_sec=out["duration_sec"], asset=asset,
                    strategy_id=(out["strategy"] or {}).get("id"), session_id=session_id,
                    min_confluence=s.min_confluence_factors,
                    market_condition=(technical or {}).get("market_condition"))
                out["signal_id"] = rec["id"]
                out["recorded"] = True
                if out["signal"] != "WAIT":
                    self._last_trade_signal_at = time.monotonic()
            self.latest = out
        return out
