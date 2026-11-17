"""Statistics dashboard and result analysis (Phase 9).

* Results are always reported **per account type** (simulation / demo / real) — never mixed.
* Every rate comes with its sample size and a 95% Wilson interval; groups below the
  minimum sample are shown as "insufficient sample", never as findings.
* Insights are suggestions only. Nothing here changes a strategy: an underperforming
  approved strategy produces a *review suggestion* only with enough real results that are
  statistically below its out-of-sample backtest; the user decides (e.g. retire it).
"""

from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime
from typing import Any

from uata.db.database import Database, row_to_dict
from uata.strategy.backtest import wilson

ACCOUNTS = ("simulation", "demo", "real")
MIN_GROUP = 10        # minimum decided trades before a group is compared
MIN_REVIEW = 30       # minimum decided trades before a strategy review is suggested


def _rate(rows: list[dict]) -> dict:
    wins = sum(r["outcome"] == "win" for r in rows)
    losses = sum(r["outcome"] == "loss" for r in rows)
    decided = wins + losses
    lo, hi = wilson(wins, decided)
    pnl = [r["pnl"] for r in rows if r.get("pnl") is not None]
    return {"trades": len(rows), "wins": wins, "losses": losses,
            "draws": sum(r["outcome"] == "draw" for r in rows),
            "cancelled": sum(r["outcome"] == "cancelled" for r in rows),
            "decided": decided, "win_rate": round(wins / decided, 4) if decided else None,
            "win_rate_ci95": [round(lo, 4), round(hi, 4)] if decided else None,
            "pnl_total": round(sum(pnl), 2) if pnl else None,
            "sufficient_sample": decided >= MIN_GROUP}


def _bucket(v: float | None, edges=(0.5, 0.6, 0.7, 0.8, 0.9)) -> str:
    if v is None:
        return "unknown"
    lo = 0.0
    for e in edges:
        if v < e:
            return f"{lo:.1f}-{e:.1f}"
        lo = e
    return f"{lo:.1f}-1.0"


def _hour(ts: str) -> str:
    try:
        return f"{datetime.fromisoformat(ts.replace('Z', '+00:00')).hour:02d}"
    except ValueError:
        return "unknown"


class StatsService:
    def __init__(self, db: Database):
        self.db = db

    def _results(self, account: str) -> list[dict]:
        with self.db.session() as conn:
            rows = conn.execute(
                "SELECT r.*, s.name AS strategy_name FROM trade_results r LEFT JOIN strategies s ON s.id=r.strategy_id "
                "WHERE r.account_type=? ORDER BY r.id", (account,)).fetchall()
        return [row_to_dict(r) for r in rows]

    @staticmethod
    def _group(rows: list[dict], key) -> list[dict]:
        groups: dict[str, list[dict]] = defaultdict(list)
        for r in rows:
            groups[str(key(r))].append(r)
        out = [{"key": k, **_rate(v)} for k, v in groups.items()]
        return sorted(out, key=lambda g: (-g["decided"], g["key"]))

    def dashboard(self, account: str) -> dict[str, Any]:
        if account not in ACCOUNTS:
            raise ValueError(f"account_type must be one of {ACCOUNTS}")
        rows = self._results(account)
        with self.db.session() as conn:
            sig = {r[0]: r[1] for r in conn.execute("SELECT signal, count(*) FROM signals GROUP BY signal")}
            runs = conn.execute(
                "SELECT b.id, b.strategy_id, s.name AS strategy_name, b.strategy_version, b.dataset, b.qualifies, "
                "b.created_at, b.metrics_json FROM backtest_runs b LEFT JOIN strategies s ON s.id=b.strategy_id "
                "ORDER BY b.id DESC LIMIT 20").fetchall()
        training = []
        for r in runs:
            m = json.loads(r["metrics_json"] or "{}").get("out_of_sample") or {}
            training.append({"id": r["id"], "strategy_id": r["strategy_id"], "strategy_name": r["strategy_name"],
                             "version": r["strategy_version"], "dataset": r["dataset"], "qualifies": bool(r["qualifies"]),
                             "created_at": r["created_at"], "oos_trades": m.get("trades"),
                             "oos_expectancy": m.get("expectancy_per_trade"), "oos_win_rate": m.get("win_rate")})
        return {
            "account_type": account,
            "signals": {"total": sum(sig.values()), "BUY": sig.get("BUY", 0), "SELL": sig.get("SELL", 0),
                        "WAIT": sig.get("WAIT", 0)},
            "results": _rate(rows),
            "by_strategy": self._group(rows, lambda r: r.get("strategy_name") or "manual / none"),
            "by_asset": self._group(rows, lambda r: r["asset"]),
            "by_timeframe": self._group(rows, lambda r: f"{r['timeframe_sec']}s"),
            "by_condition": self._group(rows, lambda r: r.get("market_condition") or "unknown"),
            "by_direction": self._group(rows, lambda r: r["signal_type"]),
            "by_hour": self._group(rows, lambda r: _hour(r["signal_time"])),
            # calibration evidence: does a higher internal estimate really win more often?
            "by_confidence": self._group(rows, lambda r: _bucket(r.get("confidence"))),
            "by_data_quality": self._group(rows, lambda r: _bucket(r.get("data_quality"))),
            "training_log": training,
            "min_group_sample": MIN_GROUP,
        }

    def insights(self, account: str) -> list[dict[str, Any]]:
        d = self.dashboard(account)
        overall = d["results"]
        out: list[dict] = []
        if overall["decided"] < MIN_GROUP:
            return [{"code": "insufficient_sample", "sample": overall["decided"], "needed": MIN_GROUP}]

        def compare(group_name: str, code_better: str, code_worse: str):
            base = overall["win_rate"]
            for g in d[group_name]:
                if not g["sufficient_sample"] or g["key"] == "unknown":
                    continue
                lo, hi = g["win_rate_ci95"]
                # only report differences that are outside the group's own 95% interval
                if lo > base:
                    out.append({"code": code_better, "group": group_name, "key": g["key"], "win_rate": g["win_rate"],
                                "ci95": g["win_rate_ci95"], "sample": g["decided"], "overall": base})
                elif hi < base:
                    out.append({"code": code_worse, "group": group_name, "key": g["key"], "win_rate": g["win_rate"],
                                "ci95": g["win_rate_ci95"], "sample": g["decided"], "overall": base})

        compare("by_strategy", "strategy_better", "strategy_worse")
        compare("by_condition", "condition_better", "condition_worse")
        compare("by_asset", "asset_better", "asset_worse")
        compare("by_hour", "hour_better", "hour_worse")
        compare("by_data_quality", "quality_better", "quality_worse")

        # calibration: higher estimate buckets should not win less than lower ones
        conf = sorted((g for g in d["by_confidence"] if g["sufficient_sample"] and g["key"] != "unknown"),
                      key=lambda g: g["key"])
        if len(conf) >= 2:
            ordered = all(a["win_rate"] <= b["win_rate"] for a, b in zip(conf, conf[1:]))
            out.append({"code": "confidence_consistent" if ordered else "confidence_inconsistent",
                        "buckets": [{"key": g["key"], "win_rate": g["win_rate"], "sample": g["decided"]} for g in conf]})

        # recurring losses: longest losing streak and the context that dominates losses
        rows = self._results(account)
        streak = longest = 0
        for r in rows:
            if r["outcome"] == "loss":
                streak += 1
                longest = max(longest, streak)
            elif r["outcome"] == "win":
                streak = 0
        if longest >= 5:
            out.append({"code": "losing_streak", "length": longest})
        losses = [r for r in rows if r["outcome"] == "loss"]
        if len(losses) >= MIN_GROUP:
            for field in ("market_condition", "asset", "strategy_name"):
                counts = defaultdict(int)
                for r in losses:
                    counts[r.get(field) or "unknown"] += 1
                key, n = max(counts.items(), key=lambda kv: kv[1])
                total_with_key = sum(1 for r in rows if (r.get(field) or "unknown") == key and r["outcome"] in ("win", "loss"))
                share = n / len(losses)
                if key != "unknown" and share >= 0.6 and total_with_key and n / total_with_key > 1 - (overall["win_rate"] or 0):
                    out.append({"code": "losses_concentrated", "field": field, "key": key, "share": round(share, 2),
                                "losses": n})
        out += self._strategy_reviews(account)
        return out

    def _strategy_reviews(self, account: str) -> list[dict]:
        """Approved strategies whose real results are statistically below their out-of-sample backtest."""
        rows = self._results(account)
        with self.db.session() as conn:
            strategies = conn.execute("SELECT id, name, version FROM strategies WHERE status='approved'").fetchall()
            out = []
            for s in strategies:
                live = [r for r in rows if r["strategy_id"] == s["id"]]
                m = _rate(live)
                run = conn.execute(
                    "SELECT metrics_json FROM backtest_runs WHERE strategy_id=? AND strategy_version=? AND qualifies=1 "
                    "ORDER BY id DESC LIMIT 1", (s["id"], s["version"])).fetchone()
                if run is None:
                    continue
                oos = json.loads(run["metrics_json"])["out_of_sample"]
                if m["decided"] < MIN_REVIEW:
                    out.append({"code": "strategy_review_pending_sample", "strategy_id": s["id"], "name": s["name"],
                                "sample": m["decided"], "needed": MIN_REVIEW})
                    continue
                if oos.get("win_rate_ci95") and m["win_rate_ci95"][1] < oos["win_rate_ci95"][0]:
                    out.append({"code": "strategy_review_suggested", "strategy_id": s["id"], "name": s["name"],
                                "live_win_rate": m["win_rate"], "live_ci95": m["win_rate_ci95"], "sample": m["decided"],
                                "backtest_win_rate": oos["win_rate"], "backtest_ci95": oos["win_rate_ci95"]})
            return out
