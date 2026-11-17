"""Strategies, datasets and backtests (Phase 7).

Rules enforced here:
* every strategy has a versioned, testable ``definition``; editing it bumps the
  version and puts the strategy back to ``draft`` (an approved strategy is never
  changed silently and old test results never count for a new version);
* backtests are stored per strategy + version + dataset — results are never mixed;
* approval needs (1) a qualifying out-of-sample backtest of the *current* version on
  non-synthetic data and (2) an explicit user action. Nothing is approved automatically.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from uata.db.database import Database, audit, row_to_dict, utcnow
from uata.strategy import conditions as cnd
from uata.strategy import datasets as ds
from uata.strategy.backtest import gate, run_backtest
from uata.strategy.features import FeatureSet
from uata.strategy.translate import translate_rules


class NotFound(Exception):
    pass


class GateRefused(Exception):
    def __init__(self, reasons: list[str]):
        super().__init__(", ".join(reasons))
        self.reasons = reasons


class StrategyService:
    def __init__(self, db: Database, files_dir: Path):
        self.db = db
        self.files_dir = Path(files_dir)
        self._fs_cache: dict[int, tuple[FeatureSet, dict]] = {}

    # ------------------------------------------------------------ datasets
    def _store_dataset(self, name: str, asset: str | None, d: dict, synthetic: bool) -> dict:
        now = utcnow()
        with self.db.session() as conn:
            did = conn.execute(
                "INSERT INTO datasets(name,asset,timeframe_sec,rows,first_time,last_time,has_volume,is_synthetic,"
                "stored_path,created_at) VALUES (?,?,?,?,?,?,?,?,'',?)",
                (name, asset, d["timeframe_sec"], d["rows"], d["time"][0], d["time"][-1],
                 int(d["volume"] is not None), int(synthetic), now)).lastrowid
            rel = f"datasets/{did}.csv"
            path = self.files_dir / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(ds.to_csv(d), encoding="utf-8")
            conn.execute("UPDATE datasets SET stored_path=? WHERE id=?", (rel, did))
            audit(conn, "user", "dataset.add", dataset_id=did, rows=d["rows"], synthetic=synthetic)
        return self.get_dataset(did)

    def import_csv(self, name: str, text: str, asset: str | None = None) -> dict:
        return self._store_dataset(name, asset, ds.parse_csv(text), synthetic=False)

    def create_synthetic(self, n: int = 3000, timeframe_sec: int = 30, seed: int = 0) -> dict:
        if not 200 <= n <= 200_000:
            raise ValueError("n must be between 200 and 200000")
        return self._store_dataset(f"SYNTHETIC (seed {seed})", "SIMULATED", ds.synthetic(n, timeframe_sec, seed), True)

    def list_datasets(self) -> list[dict]:
        with self.db.session() as conn:
            return [row_to_dict(r) for r in conn.execute("SELECT * FROM datasets ORDER BY id DESC").fetchall()]

    def get_dataset(self, did: int) -> dict:
        with self.db.session() as conn:
            r = conn.execute("SELECT * FROM datasets WHERE id=?", (did,)).fetchone()
        if r is None:
            raise NotFound(f"dataset {did}")
        return row_to_dict(r)

    def delete_dataset(self, did: int) -> None:
        d = self.get_dataset(did)
        with self.db.session() as conn:
            conn.execute("DELETE FROM datasets WHERE id=?", (did,))
            audit(conn, "user", "dataset.delete", dataset_id=did)
        (self.files_dir / d["stored_path"]).unlink(missing_ok=True)
        self._fs_cache.pop(did, None)

    def features(self, did: int) -> tuple[FeatureSet, dict]:
        if did not in self._fs_cache:
            meta = self.get_dataset(did)
            d = ds.parse_csv((self.files_dir / meta["stored_path"]).read_text(encoding="utf-8"))
            self._fs_cache[did] = (FeatureSet(d["open"], d["high"], d["low"], d["close"], d["volume"]), meta)
        return self._fs_cache[did]

    # ------------------------------------------------------------ strategies
    def _card(self, conn, row) -> dict:
        s = row_to_dict(row)
        definition = s.pop("definition", None)
        s["definition"] = definition
        if definition:
            s["readable"] = {
                side: [cnd.describe(c, lang) for c in (definition[side]["all"] if side != "veto" else definition["veto"])]
                for side in ("long", "short", "veto") for lang in ("en",)}
            s["readable_ar"] = {
                side: [cnd.describe(c, "ar") for c in (definition[side]["all"] if side != "veto" else definition["veto"])]
                for side in ("long", "short", "veto")}
        runs = conn.execute("SELECT * FROM backtest_runs WHERE strategy_id=? ORDER BY id DESC LIMIT 10",
                            (s["id"],)).fetchall()
        s["backtests"] = [self._run_summary(r) for r in runs]
        latest = next((b for b in s["backtests"] if b["strategy_version"] == s["version"]), None)
        s["latest_backtest"] = latest
        s["examples"] = [row_to_dict(r) for r in conn.execute(
            "SELECT * FROM strategy_examples WHERE strategy_id=? ORDER BY id", (s["id"],)).fetchall()]
        return s

    @staticmethod
    def _run_summary(r) -> dict:
        d = row_to_dict(r)
        m = d.pop("metrics", {}) or {}
        d["in_sample"] = {k: v for k, v in (m.get("in_sample") or {}).items() if k != "equity_curve"}
        d["out_of_sample"] = m.get("out_of_sample")
        d["bars_per_trade"] = m.get("bars_per_trade")
        d["payout"] = m.get("payout")
        return d

    def list(self) -> list[dict]:
        with self.db.session() as conn:
            return [self._card(conn, r) for r in conn.execute("SELECT * FROM strategies ORDER BY id DESC").fetchall()]

    def get(self, sid: int) -> dict:
        with self.db.session() as conn:
            r = conn.execute("SELECT * FROM strategies WHERE id=?", (sid,)).fetchone()
            if r is None:
                raise NotFound(f"strategy {sid}")
            return self._card(conn, r)

    def create(self, name: str, definition: dict, description: str = "", timeframes: list[str] | None = None,
               source_id: int | None = None) -> dict:
        d = cnd.validate_definition(definition)
        now = utcnow()
        with self.db.session() as conn:
            if conn.execute("SELECT 1 FROM strategies WHERE name=?", (name,)).fetchone():
                raise ValueError("a strategy with this name already exists")
            sid = conn.execute(
                "INSERT INTO strategies(name,description,source_id,definition_json,timeframes_json,indicators_json,"
                "status,created_at,updated_at) VALUES (?,?,?,?,?,?,'draft',?,?)",
                (name, description, source_id, json.dumps(d, ensure_ascii=False), json.dumps(timeframes or []),
                 json.dumps(sorted({c["id"] for side in ("long", "short") for c in d[side]["all"]})), now, now)).lastrowid
            audit(conn, "user", "strategy.create", strategy_id=sid)
        return self.get(sid)

    def update(self, sid: int, patch: dict) -> dict:
        allowed = {"name", "description", "definition"}
        if set(patch) - allowed:
            raise ValueError(f"cannot update fields: {sorted(set(patch) - allowed)}")
        cur = self.get(sid)
        sets, args = [], []
        if "name" in patch:
            sets.append("name=?")
            args.append(patch["name"])
        if "description" in patch:
            sets.append("description=?")
            args.append(patch["description"])
        if "definition" in patch:
            d = cnd.validate_definition(patch["definition"])
            # a new definition is a new version: back to draft, previous tests no longer count
            sets += ["definition_json=?", "version=?", "status='draft'", "approved_at=NULL"]
            args += [json.dumps(d, ensure_ascii=False), cur["version"] + 1]
        with self.db.session() as conn:
            conn.execute(f"UPDATE strategies SET {', '.join(sets)}, updated_at=? WHERE id=?", (*args, utcnow(), sid))
            audit(conn, "user", "strategy.update", strategy_id=sid, fields=sorted(patch))
        return self.get(sid)

    def delete(self, sid: int) -> None:
        self.get(sid)
        with self.db.session() as conn:
            conn.execute("DELETE FROM strategies WHERE id=?", (sid,))
            audit(conn, "user", "strategy.delete", strategy_id=sid)

    def from_approved_rules(self, name: str, source_id: int | None = None, item_ids: list[int] | None = None,
                            duration_sec: int = 120) -> dict:
        """Build a testable strategy from APPROVED rule items (a source's, or explicit ids)."""
        sql = "SELECT id, content, rule_json FROM knowledge_items WHERE status='approved' AND rule_json IS NOT NULL"
        args: list[Any] = []
        if item_ids:
            sql += f" AND id IN ({','.join('?' * len(item_ids))})"
            args += item_ids
        elif source_id is not None:
            sql += " AND source_id=?"
            args.append(source_id)
        else:
            raise ValueError("source_id or item_ids is required")
        with self.db.session() as conn:
            rows = conn.execute(sql, args).fetchall()
        if not rows:
            raise ValueError("no approved rules found — approve the extracted rules first")
        rules = [{"text": r["content"], **json.loads(r["rule_json"])} for r in rows]
        d = translate_rules(rules, duration_sec)
        if not d["long"]["all"] and not d["short"]["all"]:
            raise ValueError("none of the approved rules could be translated into testable entry conditions: "
                             + "; ".join(d["untestable"][:3]))
        desc = "Built from approved rules:\n" + "\n".join(f"• {t}" for t in d.pop("translated_rules"))
        return self.create(name, d, desc, source_id=source_id)

    def adopt_video_draft(self, sid: int, duration_sec: int = 120) -> dict:
        """Give a video-extracted draft (text only) a testable definition from its approved rules."""
        s = self.get(sid)
        if s["source_id"] is None:
            raise ValueError("strategy has no source")
        tmp = self.from_approved_rules(f"__tmp_{sid}_{utcnow()}", source_id=s["source_id"], duration_sec=duration_sec)
        try:
            return self.update(sid, {"definition": tmp["definition"]})
        finally:
            self.delete(tmp["id"])

    # ------------------------------------------------------------ backtests
    def backtest(self, sid: int, dataset_id: int, payout: float = 0.85, in_sample: float = 0.7) -> dict:
        s = self.get(sid)
        if not s["definition"]:
            raise ValueError("strategy has no testable definition yet")
        fs, meta = self.features(dataset_id)
        result = run_backtest(fs, s["definition"], meta["timeframe_sec"], payout, in_sample)
        reasons = gate(result, bool(meta["is_synthetic"]))
        now = utcnow()
        t0, t1 = meta["first_time"], meta["last_time"]
        split_t = t0 + (t1 - t0) * in_sample
        with self.db.session() as conn:
            rid = conn.execute(
                "INSERT INTO backtest_runs(strategy_id,strategy_version,dataset,dataset_id,params_json,in_sample_from,"
                "in_sample_to,out_sample_from,out_sample_to,costs_json,metrics_json,qualifies,gate_reasons_json,created_at)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (sid, s["version"], meta["name"], dataset_id,
                 json.dumps({"in_sample": in_sample, "duration_sec": s["definition"]["duration_sec"],
                             "timeframe_sec": meta["timeframe_sec"]}),
                 str(t0), str(split_t), str(split_t), str(t1), json.dumps({"payout": payout, "model": "fixed_time"}),
                 json.dumps(result), int(not reasons), json.dumps(reasons), now)).lastrowid
            if s["status"] == "draft":
                conn.execute("UPDATE strategies SET status='testing', updated_at=? WHERE id=?", (now, sid))
            audit(conn, "system", "strategy.backtest", strategy_id=sid, run_id=rid, qualifies=not reasons)
        return {"run_id": rid, "qualifies": not reasons, "gate_reasons": reasons,
                "synthetic": bool(meta["is_synthetic"]), **result}

    def approve(self, sid: int) -> dict:
        s = self.get(sid)
        latest = s["latest_backtest"]
        if latest is None:
            raise GateRefused(["no_backtest_for_current_version"])
        if not latest["qualifies"]:
            raise GateRefused(latest["gate_reasons"])
        with self.db.session() as conn:
            conn.execute("UPDATE strategies SET status='approved', approved_at=?, updated_at=? WHERE id=?",
                         (utcnow(), utcnow(), sid))
            audit(conn, "user", "strategy.approve", strategy_id=sid, run_id=latest["id"], version=s["version"])
        return self.get(sid)

    def retire(self, sid: int) -> dict:
        self.get(sid)
        with self.db.session() as conn:
            conn.execute("UPDATE strategies SET status='retired', updated_at=? WHERE id=?", (utcnow(), sid))
            audit(conn, "user", "strategy.retire", strategy_id=sid)
        return self.get(sid)

    def compare(self, strategy_ids: list[int], dataset_id: int, payout: float = 0.85) -> list[dict]:
        """Run every strategy on the same dataset; each row is that strategy alone (never mixed)."""
        rows = []
        for sid in strategy_ids:
            r = self.backtest(sid, dataset_id, payout)
            oos = r["out_of_sample"]
            rows.append({"strategy_id": sid, "name": self.get(sid)["name"], "run_id": r["run_id"],
                         "qualifies": r["qualifies"], "gate_reasons": r["gate_reasons"],
                         **{k: oos[k] for k in ("trades", "win_rate", "win_rate_ci95", "expectancy_per_trade",
                                                "profit_factor", "max_drawdown_units", "significant_edge")}})
        return sorted(rows, key=lambda x: (x["expectancy_per_trade"] is None, -(x["expectancy_per_trade"] or 0)))

    def suitable(self, market_condition: str, min_trades: int = 10) -> list[dict]:
        """Approved strategies ranked by their out-of-sample expectancy in this market condition."""
        out = []
        for s in self.list():
            if s["status"] != "approved" or not s["latest_backtest"]:
                continue
            oos = s["latest_backtest"]["out_of_sample"] or {}
            bc = (oos.get("by_condition") or {}).get(market_condition) or {}
            if (bc.get("trades") or 0) < min_trades or bc.get("expectancy_per_trade") is None:
                continue
            out.append({"strategy_id": s["id"], "name": s["name"], "definition": s["definition"],
                        "condition": market_condition, "trades": bc["trades"],
                        "expectancy_per_trade": bc["expectancy_per_trade"], "win_rate": bc["win_rate"],
                        "reason": f"best out-of-sample expectancy in {market_condition} markets "
                                  f"({bc['expectancy_per_trade']:+.3f}/trade over {bc['trades']} trades)"})
        return sorted(out, key=lambda x: -x["expectancy_per_trade"])


def catalog() -> list[dict]:
    return [{"id": cid, "params": spec["params"], "ar": spec["ar"], "en": spec["en"]}
            for cid, spec in cnd.CATALOG.items()]

