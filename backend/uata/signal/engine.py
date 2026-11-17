"""Decision engine: the 14 steps before BUY / SELL / WAIT (specification section 7).

Principles enforced in code
---------------------------
* A BUY/SELL can only come from an **approved** strategy whose current version passed an
  out-of-sample backtest on real data, tested on the **same candle timeframe** as the chart.
* The strategy's conditions must hold on the last **closed** candle (causal FeatureSet).
* Confluence: at least ``min_confluence_factors`` technical factors agree with the direction,
  and the opposing score must be lower than the supporting score.
* Data quality must reach the user's threshold; the forming candle is never assumed closed —
  a strong forming candle against the direction is an opposing factor.
* The confidence value is an internal estimate (``confidence_calibrated = False``), shown with
  the strategy's real out-of-sample win rate and its 95% interval as evidence.
* Anything missing → WAIT with explicit reason codes. No forced signals.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from uata.strategy.conditions import describe, signal_at
from uata.strategy.features import FeatureSet

ENGINE_VERSION = "1.0"


@dataclass
class Decision:
    signal: str = "WAIT"
    reason_codes: list[str] = field(default_factory=list)
    reasons: list[str] = field(default_factory=list)
    supporting: list[str] = field(default_factory=list)
    opposing: list[str] = field(default_factory=list)
    confidence: float | None = None
    confidence_calibrated: bool = False
    duration_sec: int | None = None
    data_quality: float | None = None
    data_basis: str = "image_only"
    strategy: dict | None = None
    steps: list[dict] = field(default_factory=list)

    def step(self, n: int, name: str, status: str, detail: str = "") -> None:
        self.steps.append({"n": n, "name": name, "status": status, "detail": detail})

    def to_dict(self) -> dict:
        d = dict(self.__dict__)
        d["reason_code"] = self.reason_codes[0] if self.reason_codes else None
        d["engine_version"] = ENGINE_VERSION
        return d


def _closed_series(reading: dict) -> tuple[np.ndarray, ...] | None:
    closed = [c for c in reading.get("candles", []) if c.get("status") == "closed"]
    if not closed:
        return None
    key = "close" if all("close" in c for c in closed) else None
    if key:
        return tuple(np.array([c[k] for c in closed], float) for k in ("open", "high", "low", "close"))
    return tuple(np.array([c[f"rel_{k}"] for c in closed], float) for k in ("open", "high", "low", "close"))


def decide(reading: dict, technical: dict, settings: dict, strategies: list[dict],
           knowledge: list[dict] | None = None) -> Decision:
    """``strategies``: approved strategies (from StrategyService.list()) with their latest backtest."""
    d = Decision(data_quality=reading.get("data_quality"), data_basis=reading.get("data_basis", "image_only"))
    tf = settings["candle_timeframe_sec"]

    # 1 — data validity
    q_min = settings["min_data_quality_to_signal"]
    if not reading.get("usable"):
        d.step(1, "data_validity", "fail", ", ".join(reading.get("abstain_reasons", [])))
        d.reason_codes.append("image_quality_insufficient")
        return d
    if (d.data_quality or 0) < q_min:
        d.step(1, "data_validity", "fail", f"quality {d.data_quality:.2f} < {q_min:.2f}")
        d.reason_codes.append("image_quality_insufficient")
        return d
    shown_tf = reading.get("timeframe_sec")
    if shown_tf and shown_tf != tf:
        d.step(1, "data_validity", "fail", f"chart timeframe {shown_tf}s ≠ settings {tf}s")
        d.reason_codes.append("timeframe_mismatch")
        return d
    d.step(1, "data_validity", "ok", f"quality {d.data_quality:.2f}" + ("" if shown_tf else ", timeframe not shown in image"))
    if not technical or not technical.get("available"):
        d.step(2, "trend", "fail", (technical or {}).get("reason", "no technical analysis"))
        d.reason_codes.append("insufficient_candles")
        return d

    # 2 — trend, 3 — strength
    tr = technical["trend"]
    d.step(2, "trend", "info", f"{tr['direction']} ({tr['structure']})")
    d.step(3, "trend_strength", "info", f"{tr['strength']:.2f}, market {technical['market_condition']}")

    factors = {f["name"]: f for f in technical["factors"]}

    # 4 — previous candles, 5 — current (forming) candle without assuming its close
    pa = factors.get("price_action", {})
    d.step(4, "previous_candles", "info", f"{pa.get('direction', 'n/a')} ({pa.get('code', '')})")
    forming = next((c for c in reversed(reading.get("candles", [])) if c.get("status") == "possibly_forming"), None)
    forming_dir = None
    if forming:
        rng = forming["rel_high"] - forming["rel_low"]
        body = forming["rel_close"] - forming["rel_open"]
        closed_ranges = [c["rel_high"] - c["rel_low"] for c in reading["candles"] if c.get("status") == "closed"][-14:]
        avg = float(np.mean(closed_ranges)) if closed_ranges else 0.0
        if avg > 0 and rng >= avg and abs(body) >= 0.5 * rng:
            forming_dir = "bullish" if body > 0 else "bearish"
        d.step(5, "forming_candle", "info", f"not assumed closed; strong move: {forming_dir or 'none'}")
    else:
        d.step(5, "forming_candle", "info", "none")

    # 6 — indicators, 7 — support/resistance, 8 — supply/demand
    ind_names = ("moving_averages", "rsi", "macd", "bollinger_bands", "momentum")
    d.step(6, "indicators", "info", ", ".join(f"{n}={factors[n]['direction']}" for n in ind_names
                                               if n in factors and factors[n]["enabled"]))
    d.step(7, "support_resistance", "info", factors.get("support_resistance", {}).get("code", ""))
    d.step(8, "supply_demand", "info", factors.get("supply_demand", {}).get("code", ""))

    # 9 — matching strategies from the library
    usable = []
    skipped = []
    for s in strategies:
        bt = s.get("latest_backtest")
        if s.get("status") != "approved" or not bt or not bt.get("qualifies") or not s.get("definition"):
            continue
        s_tf = (bt.get("params") or {}).get("timeframe_sec")
        if s_tf != tf:
            skipped.append(f"{s['name']} (tested on {s_tf}s)")
            continue
        usable.append(s)
    if not usable:
        d.step(9, "strategy_lookup", "fail", "no approved strategy for this timeframe"
               + (f"; skipped: {', '.join(skipped)}" if skipped else ""))
        d.reason_codes.append("no_approved_strategy")
        return d
    d.step(9, "strategy_lookup", "ok", ", ".join(s["name"] for s in usable))

    # 10 — strategy conditions on the last closed candle (causal)
    series = _closed_series(reading)
    fs = FeatureSet(*series) if series is not None else None
    last = (fs.n - 1) if fs else -1
    fired: list[tuple[dict, str]] = []
    if fs is None or not fs.ready(last):
        d.step(10, "strategy_conditions", "fail", "not enough closed candles to evaluate strategy conditions (need 50+)")
        d.reason_codes.append("insufficient_history_for_strategies")
        return d
    cond = technical["market_condition"]
    for s in usable:
        side = signal_at(fs, last, s["definition"])
        if side:
            fired.append((s, side))
    if not fired:
        d.step(10, "strategy_conditions", "fail", "no strategy's conditions are met on the last closed candle")
        d.reason_codes.append("strategy_conditions_not_met")
        return d
    sides = {side for _, side in fired}
    if len(sides) > 1:
        d.step(10, "strategy_conditions", "fail", "approved strategies disagree (BUY and SELL)")
        d.reason_codes.append("strategies_conflict")
        return d
    side = sides.pop()

    # choose the strategy with the best out-of-sample expectancy in the current market condition
    def score(s):
        oos = s["latest_backtest"]["out_of_sample"] or {}
        bc = (oos.get("by_condition") or {}).get(cond) or {}
        return (bc.get("expectancy_per_trade") if (bc.get("trades") or 0) >= 10 else None) or oos.get("expectancy_per_trade") or 0

    chosen = max((s for s, _ in fired), key=score)
    oos = chosen["latest_backtest"]["out_of_sample"]
    d.step(10, "strategy_conditions", "ok", f"{chosen['name']} → {side}")

    # 11 — opposing factors / confluence
    want = "bullish" if side == "BUY" else "bearish"
    against = "bearish" if want == "bullish" else "bullish"
    active = [f for f in technical["factors"] if f["enabled"] and f["available"]]
    sup = [f for f in active if f["direction"] == want]
    opp = [f for f in active if f["direction"] == against]
    if forming_dir == against:
        opp.append({"name": "forming_candle", "code": "forming_against", "strength": 0.5, "direction": against})
    d.supporting = [f"{f['name']}: {f['code']}" for f in sup]
    d.opposing = [f"{f['name']}: {f['code']}" for f in opp]
    sup_score, opp_score = sum(f["strength"] for f in sup), sum(f["strength"] for f in opp)
    need = settings["min_confluence_factors"]
    if len(sup) < need:
        d.step(11, "opposing_factors", "fail", f"{len(sup)} supporting < {need} required")
        d.reason_codes.append("insufficient_confluence")
        return d
    if opp_score >= sup_score:
        d.step(11, "opposing_factors", "fail", f"opposing {opp_score:.2f} ≥ supporting {sup_score:.2f}")
        d.reason_codes.append("opposing_factors_dominate")
        return d
    d.step(11, "opposing_factors", "ok", f"supporting {sup_score:.2f} vs opposing {opp_score:.2f}")

    # 12 — opportunity quality (internal estimate, NOT a probability of profit)
    agreement = sup_score / (sup_score + opp_score) if (sup_score + opp_score) else 0.0
    confidence = round(0.5 * agreement + 0.3 * float(d.data_quality or 0) + 0.2 * min(1.0, len(sup) / 6), 3)
    d.confidence = confidence
    if confidence < settings["min_confidence_to_signal"]:
        d.step(12, "opportunity_quality", "fail", f"estimate {confidence:.2f} < {settings['min_confidence_to_signal']:.2f}")
        d.reason_codes.append("low_confidence")
        return d
    d.step(12, "opportunity_quality", "ok", f"estimate {confidence:.2f} (uncalibrated)")

    # 13 — duration: the tested duration, within the user's range
    dur = int(chosen["definition"]["duration_sec"])
    lo, hi = settings["trade_duration_min_sec"], settings["trade_duration_max_sec"]
    if not lo <= dur <= hi:
        d.step(13, "duration", "fail", f"strategy duration {dur}s outside your range {lo}–{hi}s")
        d.reason_codes.append("duration_outside_settings")
        return d
    d.step(13, "duration", "ok", f"{dur}s (as tested)")

    # 14 — reasons
    d.signal, d.duration_sec = side, dur
    d.strategy = {"id": chosen["id"], "name": chosen["name"], "version": chosen["version"],
                  "oos_trades": oos["trades"], "oos_win_rate": oos["win_rate"], "oos_win_rate_ci95": oos["win_rate_ci95"],
                  "oos_expectancy": oos["expectancy_per_trade"], "significant_edge": oos.get("significant_edge", False),
                  "conditions": [describe(c) for c in chosen["definition"]["long" if side == "BUY" else "short"]["all"]]}
    d.reasons = [f"approved strategy '{chosen['name']}' conditions met on the last closed candle",
                 f"{len(sup)} supporting factor(s) vs {len(opp)} opposing",
                 f"market {cond}, trend {tr['direction']}"]
    if knowledge:
        d.reasons.append("related approved knowledge: " + "; ".join(k["title"] for k in knowledge[:2]))
    d.reason_codes = ["strategy_signal"]
    d.step(14, "reasons", "ok", "; ".join(d.reasons))
    return d


def fingerprint(reading: dict) -> str:
    """Identity of the last closed candle: a repeat signal needs a new closed candle."""
    closed = [c for c in reading.get("candles", []) if c.get("status") == "closed"]
    if not closed:
        return ""
    c = closed[-1]
    return f"{len(closed)}:{c['y_open']}:{c['y_close']}:{c['y_high']}:{c['y_low']}"
