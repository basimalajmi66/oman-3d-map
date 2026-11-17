"""Signal log and trade-result journal.

* Signals are written by the signal engine (Phase 8) through ``record_signal``;
  the method already enforces the rules that a signal must respect so the
  engine cannot bypass them: BUY/SELL need a duration, at least the configured
  number of confluence factors, and confidence is flagged as uncalibrated unless
  calibration evidence exists.
* Trade results are entered by the user and are kept strictly separated by
  account type (simulation / demo / real) in every statistic.
"""

from __future__ import annotations

import json
from typing import Any

from uata.config import ENGINE_VERSION
from uata.db.database import Database, audit, row_to_dict, utcnow

ACCOUNT_TYPES = ("simulation", "demo", "real")
OUTCOMES = ("win", "loss", "draw", "cancelled")


class RecordsService:
    def __init__(self, db: Database):
        self.db = db

    # ------------------------------------------------------------ signals
    def record_signal(self, *, signal: str, timeframe_sec: int, data_basis: str,
                      reasons: list[str], supporting: list[str], opposing: list[str],
                      data_quality: float | None, confidence: float | None = None,
                      confidence_calibrated: bool = False, duration_sec: int | None = None,
                      asset: str | None = None, strategy_id: int | None = None,
                      session_id: int | None = None, min_confluence: int = 3,
                      market_condition: str | None = None) -> dict[str, Any]:
        if signal not in ("BUY", "SELL", "WAIT"):
            raise ValueError("signal must be BUY, SELL or WAIT")
        if signal != "WAIT":
            if duration_sec is None:
                raise ValueError("BUY/SELL require a suggested duration")
            if len(supporting) < min_confluence:
                raise ValueError(f"BUY/SELL require at least {min_confluence} supporting factors")
            if not reasons:
                raise ValueError("BUY/SELL require stated reasons")
        with self.db.session() as conn:
            sid = conn.execute(
                "INSERT INTO signals(session_id,created_at,asset,timeframe_sec,signal,confidence_score,"
                "confidence_calibrated,duration_sec,strategy_id,reasons_json,supporting_json,opposing_json,"
                "data_quality,data_basis,engine_version,market_condition) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (session_id, utcnow(), asset, timeframe_sec, signal, confidence, int(confidence_calibrated),
                 duration_sec, strategy_id, json.dumps(reasons, ensure_ascii=False),
                 json.dumps(supporting, ensure_ascii=False), json.dumps(opposing, ensure_ascii=False),
                 data_quality, data_basis, ENGINE_VERSION, market_condition)).lastrowid
            audit(conn, "system", "signal.record", signal_id=sid, signal=signal)
            return row_to_dict(conn.execute("SELECT * FROM signals WHERE id=?", (sid,)).fetchone())

    def list_signals(self, limit: int = 100, offset: int = 0, signal: str | None = None) -> list[dict[str, Any]]:
        sql, args = "SELECT * FROM signals", []
        if signal:
            sql += " WHERE signal=?"
            args.append(signal)
        sql += " ORDER BY id DESC LIMIT ? OFFSET ?"
        args += [limit, offset]
        with self.db.session() as conn:
            return [row_to_dict(r) for r in conn.execute(sql, args).fetchall()]

    # ------------------------------------------------------------ results
    def add_result(self, data: dict[str, Any]) -> dict[str, Any]:
        required = ("account_type", "asset", "timeframe_sec", "signal_type", "signal_time",
                    "duration_sec", "outcome")
        missing = [k for k in required if data.get(k) in (None, "")]
        if missing:
            raise ValueError(f"missing fields: {missing}")
        if data["account_type"] not in ACCOUNT_TYPES:
            raise ValueError(f"account_type must be one of {ACCOUNT_TYPES}")
        if data["outcome"] not in OUTCOMES:
            raise ValueError(f"outcome must be one of {OUTCOMES}")
        if data["signal_type"] not in ("BUY", "SELL"):
            raise ValueError("signal_type must be BUY or SELL")
        cols = ("signal_id", "account_type", "asset", "timeframe_sec", "strategy_id", "signal_type",
                "signal_time", "duration_sec", "outcome", "pnl", "market_condition", "notes", "confidence",
                "data_quality")
        with self.db.session() as conn:
            rid = conn.execute(
                f"INSERT INTO trade_results({','.join(cols)},created_at) VALUES ({','.join('?' * len(cols))},?)",  # nosec B608 - constant column tuple
                (*[data.get(c) for c in cols], utcnow())).lastrowid
            audit(conn, "user", "result.add", result_id=rid, account_type=data["account_type"])
            return row_to_dict(conn.execute("SELECT * FROM trade_results WHERE id=?", (rid,)).fetchone())

    def result_from_signal(self, signal_id: int, account_type: str, outcome: str, asset: str | None = None,
                           pnl: float | None = None, notes: str | None = None) -> dict[str, Any]:
        """Record the outcome of a BUY/SELL signal; context is copied from the signal, not re-typed."""
        with self.db.session() as conn:
            sig = conn.execute("SELECT * FROM signals WHERE id=?", (signal_id,)).fetchone()
            dup = conn.execute("SELECT id FROM trade_results WHERE signal_id=?", (signal_id,)).fetchone()
        if sig is None:
            raise KeyError(signal_id)
        if sig["signal"] == "WAIT":
            raise ValueError("a WAIT signal has no trade to record")
        if dup:
            raise ValueError("a result is already recorded for this signal")
        return self.add_result({
            "signal_id": signal_id, "account_type": account_type, "asset": asset or sig["asset"] or "UNKNOWN",
            "timeframe_sec": sig["timeframe_sec"], "strategy_id": sig["strategy_id"], "signal_type": sig["signal"],
            "signal_time": sig["created_at"], "duration_sec": sig["duration_sec"], "outcome": outcome, "pnl": pnl,
            "market_condition": sig["market_condition"], "notes": notes, "confidence": sig["confidence_score"],
            "data_quality": sig["data_quality"]})

    def list_results(self, account_type: str | None = None, limit: int = 200) -> list[dict[str, Any]]:
        sql, args = "SELECT * FROM trade_results", []
        if account_type:
            sql += " WHERE account_type=?"
            args.append(account_type)
        sql += " ORDER BY id DESC LIMIT ?"
        args.append(limit)
        with self.db.session() as conn:
            return [row_to_dict(r) for r in conn.execute(sql, args).fetchall()]

    def delete_result(self, result_id: int) -> bool:
        with self.db.session() as conn:
            n = conn.execute("DELETE FROM trade_results WHERE id=?", (result_id,)).rowcount
            if n:
                audit(conn, "user", "result.delete", result_id=result_id)
        return bool(n)

    # ------------------------------------------------------------ summary
    def summary(self) -> dict[str, Any]:
        """Basic counts (full dashboard in Phase 9). Results never mix account types."""
        with self.db.session() as conn:
            sig = {r[0]: r[1] for r in conn.execute("SELECT signal, count(*) FROM signals GROUP BY signal")}
            by_account: dict[str, Any] = {}
            for acct in ACCOUNT_TYPES:
                rows = {r[0]: r[1] for r in conn.execute(
                    "SELECT outcome, count(*) FROM trade_results WHERE account_type=? GROUP BY outcome", (acct,))}
                decided = rows.get("win", 0) + rows.get("loss", 0)
                by_account[acct] = {
                    "total": sum(rows.values()),
                    "wins": rows.get("win", 0),
                    "losses": rows.get("loss", 0),
                    "draws": rows.get("draw", 0),
                    "cancelled": rows.get("cancelled", 0),
                    # win rate is reported with its sample size; never alone
                    "win_rate": (rows.get("win", 0) / decided) if decided else None,
                    "sample_size": decided,
                }
        return {
            "signals": {"total": sum(sig.values()), "BUY": sig.get("BUY", 0),
                        "SELL": sig.get("SELL", 0), "WAIT": sig.get("WAIT", 0)},
            "results_by_account": by_account,
        }
