"""Testable strategy conditions (a small, explicit DSL).

A condition is a JSON object ``{"id": "...", ...params}``. Every condition is
evaluated at a *closed* bar ``i`` using ``FeatureSet`` (causal). The catalogue is
closed on purpose: anything that cannot be expressed here is reported as
*untestable* instead of being guessed.

Strategy definition::

    {"long":  {"all": [cond, ...]},          # BUY when every condition holds
     "short": {"all": [cond, ...]},          # SELL when every condition holds
     "veto":  [cond, ...],                   # never enter when any holds
     "duration_sec": 120,
     "untestable": ["text of rules that could not be translated"]}
"""

from __future__ import annotations

from typing import Any, Callable

import numpy as np

from uata.analysis.patterns import detect_at  # noqa: F401  (documented dependency)
from uata.strategy.features import FeatureSet

PATTERNS = ("hammer", "hanging_man", "shooting_star", "inverted_hammer", "doji", "marubozu",
            "bullish_engulfing", "bearish_engulfing", "morning_star", "evening_star", "inside_bar")


def _nan(x) -> bool:
    return x is None or (isinstance(x, float) and np.isnan(x))


def _near(fs: FeatureSet, i: int, kind: str, atr_mult: float) -> bool:
    a = fs.atr[i]
    return any(k == kind and abs(p - fs.c[i]) <= atr_mult * a for p, k, _ in fs.levels(i))


def _breakout(fs: FeatureSet, i: int, up: bool) -> bool:
    if i < 1:
        return False
    for p, _, _ in fs.levels(i - 1):  # levels known before this candle
        if up and fs.c[i - 1] < p < fs.c[i]:
            return True
        if not up and fs.c[i - 1] > p > fs.c[i]:
            return True
    return False


CATALOG: dict[str, dict[str, Any]] = {
    "rsi_below": {"params": {"value": 30}, "ar": "RSI أقل من {value}", "en": "RSI below {value}",
                  "fn": lambda fs, i, p: not _nan(fs.rsi[i]) and fs.rsi[i] < p["value"]},
    "rsi_above": {"params": {"value": 70}, "ar": "RSI أعلى من {value}", "en": "RSI above {value}",
                  "fn": lambda fs, i, p: not _nan(fs.rsi[i]) and fs.rsi[i] > p["value"]},
    "macd_cross_up": {"params": {}, "ar": "تقاطع MACD صاعد", "en": "MACD bullish cross",
                      "fn": lambda fs, i, p: i > 0 and fs.macd_hist[i - 1] <= 0 < fs.macd_hist[i]},
    "macd_cross_down": {"params": {}, "ar": "تقاطع MACD هابط", "en": "MACD bearish cross",
                        "fn": lambda fs, i, p: i > 0 and fs.macd_hist[i - 1] >= 0 > fs.macd_hist[i]},
    "macd_positive": {"params": {}, "ar": "هيستوجرام MACD موجب", "en": "MACD histogram positive",
                      "fn": lambda fs, i, p: fs.macd_hist[i] > 0},
    "macd_negative": {"params": {}, "ar": "هيستوجرام MACD سالب", "en": "MACD histogram negative",
                      "fn": lambda fs, i, p: fs.macd_hist[i] < 0},
    "price_above_ema": {"params": {"period": 21}, "ar": "السعر فوق EMA {period}", "en": "price above EMA {period}",
                        "fn": lambda fs, i, p: fs.c[i] > fs.ema[p["period"]][i]},
    "price_below_ema": {"params": {"period": 21}, "ar": "السعر تحت EMA {period}", "en": "price below EMA {period}",
                        "fn": lambda fs, i, p: fs.c[i] < fs.ema[p["period"]][i]},
    "ema_bull_alignment": {"params": {}, "ar": "EMA 9 > 21 > 50", "en": "EMA 9 > 21 > 50",
                           "fn": lambda fs, i, p: fs.ema[9][i] > fs.ema[21][i] > fs.ema[50][i]},
    "ema_bear_alignment": {"params": {}, "ar": "EMA 9 < 21 < 50", "en": "EMA 9 < 21 < 50",
                           "fn": lambda fs, i, p: fs.ema[9][i] < fs.ema[21][i] < fs.ema[50][i]},
    "bb_below_lower": {"params": {}, "ar": "الإغلاق تحت بولينجر السفلي", "en": "close below lower Bollinger",
                       "fn": lambda fs, i, p: fs.c[i] < fs.bb_lo[i]},
    "bb_above_upper": {"params": {}, "ar": "الإغلاق فوق بولينجر العلوي", "en": "close above upper Bollinger",
                       "fn": lambda fs, i, p: fs.c[i] > fs.bb_hi[i]},
    "trend_up": {"params": {}, "ar": "اتجاه صاعد", "en": "uptrend", "fn": lambda fs, i, p: fs.trend(i) == "up"},
    "trend_down": {"params": {}, "ar": "اتجاه هابط", "en": "downtrend", "fn": lambda fs, i, p: fs.trend(i) == "down"},
    "trend_sideways": {"params": {}, "ar": "سوق عرضي", "en": "sideways",
                       "fn": lambda fs, i, p: fs.trend(i) == "sideways"},
    "near_support": {"params": {"atr": 0.6}, "ar": "قرب دعم ({atr} ATR)", "en": "near support ({atr} ATR)",
                     "fn": lambda fs, i, p: _near(fs, i, "support", p["atr"])},
    "near_resistance": {"params": {"atr": 0.6}, "ar": "قرب مقاومة ({atr} ATR)", "en": "near resistance ({atr} ATR)",
                        "fn": lambda fs, i, p: _near(fs, i, "resistance", p["atr"])},
    "breakout_up": {"params": {}, "ar": "اختراق مقاومة", "en": "breakout above a level",
                    "fn": lambda fs, i, p: _breakout(fs, i, True)},
    "breakdown": {"params": {}, "ar": "كسر دعم", "en": "breakdown below a level",
                  "fn": lambda fs, i, p: _breakout(fs, i, False)},
    "pattern": {"params": {"name": "bullish_engulfing"}, "ar": "نمط {name}", "en": "pattern {name}",
                "fn": lambda fs, i, p: p["name"] in fs.patterns(i)},
    "market": {"params": {"condition": "trending"}, "ar": "سوق {condition}", "en": "market {condition}",
               "fn": lambda fs, i, p: fs.market_condition(i) == p["condition"]},
    "bullish_candle": {"params": {}, "ar": "شمعة صاعدة", "en": "bullish candle", "fn": lambda fs, i, p: fs.c[i] > fs.o[i]},
    "bearish_candle": {"params": {}, "ar": "شمعة هابطة", "en": "bearish candle", "fn": lambda fs, i, p: fs.c[i] < fs.o[i]},
    "momentum_up": {"params": {"atr": 1.0}, "ar": "زخم صاعد", "en": "upward momentum",
                    "fn": lambda fs, i, p: i >= 10 and (fs.c[i] - fs.c[i - 10]) > p["atr"] * fs.atr[i]},
    "momentum_down": {"params": {"atr": 1.0}, "ar": "زخم هابط", "en": "downward momentum",
                      "fn": lambda fs, i, p: i >= 10 and (fs.c[i - 10] - fs.c[i]) > p["atr"] * fs.atr[i]},
}


def validate(cond: dict) -> dict:
    cid = cond.get("id")
    if cid not in CATALOG:
        raise ValueError(f"unknown condition '{cid}'")
    params = {**CATALOG[cid]["params"], **{k: v for k, v in cond.items() if k != "id"}}
    unknown = set(params) - set(CATALOG[cid]["params"])
    if unknown:
        raise ValueError(f"unknown parameters for {cid}: {sorted(unknown)}")
    if cid == "pattern" and params["name"] not in PATTERNS:
        raise ValueError(f"unknown pattern '{params['name']}'")
    if cid == "market" and params["condition"] not in ("trending", "ranging", "volatile"):
        raise ValueError("market condition must be trending, ranging or volatile")
    if cid in ("price_above_ema", "price_below_ema") and params["period"] not in (9, 21, 50):
        raise ValueError("EMA period must be 9, 21 or 50")
    return {"id": cid, **params}


def validate_definition(d: dict) -> dict:
    out = {"long": {"all": []}, "short": {"all": []}, "veto": [], "duration_sec": int(d.get("duration_sec", 120)),
           "untestable": list(d.get("untestable", []))}
    for side in ("long", "short"):
        out[side]["all"] = [validate(c) for c in (d.get(side) or {}).get("all", [])]
    out["veto"] = [validate(c) for c in d.get("veto", [])]
    if not out["long"]["all"] and not out["short"]["all"]:
        raise ValueError("a strategy needs at least one long or short entry condition")
    if not 5 <= out["duration_sec"] <= 86400:
        raise ValueError("duration_sec must be between 5 and 86400")
    return out


def holds(fs: FeatureSet, i: int, cond: dict) -> bool:
    fn: Callable = CATALOG[cond["id"]]["fn"]
    return bool(fn(fs, i, cond))


def describe(cond: dict, lang: str = "en") -> str:
    tpl = CATALOG[cond["id"]][lang]
    return tpl.format(**{k: v for k, v in cond.items() if k != "id"})


EXPENSIVE = {"near_support": 3, "near_resistance": 3, "breakout_up": 3, "breakdown": 3, "pattern": 2,
             "trend_up": 2, "trend_down": 2, "trend_sideways": 2, "market": 2}


def _by_cost(conds: list[dict]) -> list[dict]:
    """Cheap conditions first: all() short-circuits, the result is identical (AND is order-independent)."""
    return sorted(conds, key=lambda c: EXPENSIVE.get(c["id"], 0))


def signal_at(fs: FeatureSet, i: int, definition: dict) -> str | None:
    """'BUY' / 'SELL' / None at closed bar i. Vetoes block both sides; a bar matching both sides is skipped."""
    if not fs.ready(i):
        return None
    if any(holds(fs, i, c) for c in definition["veto"]):
        return None
    long_ok = bool(definition["long"]["all"]) and all(holds(fs, i, c) for c in _by_cost(definition["long"]["all"]))
    short_ok = bool(definition["short"]["all"]) and all(holds(fs, i, c) for c in _by_cost(definition["short"]["all"]))
    if long_ok and not short_ok:
        return "BUY"
    if short_ok and not long_ok:
        return "SELL"
    return None
