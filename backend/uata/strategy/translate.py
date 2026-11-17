"""Translate extracted rules (concepts + actions, Phases 5–6) into testable conditions.

Deterministic mapping, no guessing: a rule is translated only if every concept it
mentions has a testable equivalent. Anything else is kept as *untestable* text so
the user sees exactly what the backtest does not cover (e.g. "news").
"""

from __future__ import annotations

# concept -> condition(s) per trade direction
CONCEPT_MAP: dict[str, dict[str, list[dict]]] = {
    "rsi": {"long": [], "short": []},  # needs overbought/oversold to be meaningful
    "oversold": {"long": [{"id": "rsi_below", "value": 30}], "short": [{"id": "rsi_below", "value": 30}]},
    "overbought": {"long": [{"id": "rsi_above", "value": 70}], "short": [{"id": "rsi_above", "value": 70}]},
    "support": {"long": [{"id": "near_support"}], "short": [{"id": "near_support"}]},
    "resistance": {"long": [{"id": "near_resistance"}], "short": [{"id": "near_resistance"}]},
    "uptrend": {"long": [{"id": "trend_up"}], "short": [{"id": "trend_up"}]},
    "downtrend": {"long": [{"id": "trend_down"}], "short": [{"id": "trend_down"}]},
    "trend": {"long": [{"id": "trend_up"}], "short": [{"id": "trend_down"}]},  # "with the trend"
    "engulfing": {"long": [{"id": "pattern", "name": "bullish_engulfing"}],
                  "short": [{"id": "pattern", "name": "bearish_engulfing"}]},
    "hammer": {"long": [{"id": "pattern", "name": "hammer"}], "short": [{"id": "pattern", "name": "hanging_man"}]},
    "shooting_star": {"long": [{"id": "pattern", "name": "inverted_hammer"}],
                      "short": [{"id": "pattern", "name": "shooting_star"}]},
    "doji": {"long": [{"id": "pattern", "name": "doji"}], "short": [{"id": "pattern", "name": "doji"}]},
    "morning_star": {"long": [{"id": "pattern", "name": "morning_star"}], "short": []},
    "evening_star": {"long": [], "short": [{"id": "pattern", "name": "evening_star"}]},
    "macd": {"long": [{"id": "macd_cross_up"}], "short": [{"id": "macd_cross_down"}]},
    "bollinger": {"long": [{"id": "bb_below_lower"}], "short": [{"id": "bb_above_upper"}]},
    "moving_average": {"long": [{"id": "price_above_ema", "period": 21}], "short": [{"id": "price_below_ema", "period": 21}]},
    "breakout": {"long": [{"id": "breakout_up"}], "short": [{"id": "breakdown"}]},
    "momentum": {"long": [{"id": "momentum_up"}], "short": [{"id": "momentum_down"}]},
    "volatility": {"long": [{"id": "market", "condition": "volatile"}], "short": [{"id": "market", "condition": "volatile"}]},
    "candle_close": {"long": [], "short": []},  # every condition is already evaluated on a closed candle
}
UNTESTABLE = {"news", "liquidity", "supply_demand", "volume", "atr", "pin_bar", "double_top", "double_bottom"}


def _dedup(conds: list[dict]) -> list[dict]:
    seen, out = set(), []
    for c in conds:
        key = tuple(sorted(c.items()))
        if key not in seen:
            seen.add(key)
            out.append(c)
    return out


def translate_rules(rules: list[dict], duration_sec: int = 120) -> dict:
    """``rules``: [{'text', 'actions', 'conditions'}] (approved rule items). Returns a strategy definition."""
    long_c, short_c, veto, untestable, used = [], [], [], [], []
    for r in rules:
        acts = set(r.get("actions", []))
        concepts = sorted(set(r.get("conditions", [])))  # deterministic order
        bad = (set(concepts) & UNTESTABLE) | {c for c in concepts if c not in CONCEPT_MAP and c not in UNTESTABLE}
        if bad or not concepts:
            untestable.append(r["text"])
            continue
        if "act_avoid" in acts:
            # a no-entry rule vetoes trades when its condition holds (direction-agnostic)
            veto += [c for k in concepts for c in CONCEPT_MAP[k]["long"]]
        elif "act_buy" in acts and "act_sell" not in acts:
            long_c += [c for k in concepts for c in CONCEPT_MAP[k]["long"]]
        elif "act_sell" in acts and "act_buy" not in acts:
            short_c += [c for k in concepts for c in CONCEPT_MAP[k]["short"]]
        else:
            untestable.append(r["text"])  # exit-only or ambiguous direction
            continue
        used.append(r["text"])
    return {"long": {"all": _dedup(long_c)}, "short": {"all": _dedup(short_c)}, "veto": _dedup(veto),
            "duration_sec": duration_sec, "untestable": untestable, "translated_rules": used}
