"""TechnicalAnalyzer: closed candles → independent, explainable factors.

* Input: closed candles only (the forming candle is excluded by the caller /
  :func:`analyze_reading`). Works on real prices or on the relative values the
  chart reader produces, because every threshold is relative to ATR or %.
* Each factor maps 1:1 to a user setting (``Settings.indicators``) and can be
  disabled. A disabled factor is reported as disabled — never silently used.
* A factor returns ``direction`` (bullish / bearish / neutral), ``strength`` 0..1
  and a ``code`` + ``params`` explaining why (localised in the UI).
* No single factor produces a decision. This module does **not** emit BUY/SELL;
  it reports confluence. The decision engine (Phase 8) combines it with the
  approved strategies.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field

import numpy as np

from uata.analysis import indicators as ind
from uata.analysis import patterns as pat
from uata.analysis import structure as st

ANALYZER_VERSION = "1.0"
MIN_CANDLES = 30


@dataclass
class Factor:
    name: str
    enabled: bool = True
    available: bool = True
    direction: str = "neutral"
    strength: float = 0.0
    code: str = ""
    params: dict = field(default_factory=dict)

    def to_dict(self) -> dict:
        d = asdict(self)
        d["strength"] = round(float(d["strength"]), 3)
        return d


def _f(x) -> float | None:
    return None if x is None or (isinstance(x, float) and np.isnan(x)) else round(float(x), 6)


class TechnicalAnalyzer:
    def analyze(self, candles: list[dict], enabled: dict[str, bool] | None = None,
                has_volume: bool = False) -> dict:
        enabled = enabled or {}
        n = len(candles)
        if n < MIN_CANDLES:
            return {"available": False, "reason": "insufficient_candles", "candles_used": n,
                    "min_candles": MIN_CANDLES, "analyzer_version": ANALYZER_VERSION}
        o = np.array([c["open"] for c in candles], float)
        h = np.array([c["high"] for c in candles], float)
        lo = np.array([c["low"] for c in candles], float)
        c = np.array([c_["close"] for c_ in candles], float)
        vol = np.array([c_.get("volume", np.nan) for c_ in candles], float) if has_volume else None

        atr_arr = ind.atr(h, lo, c, 14)
        a = float(atr_arr[-1])
        rsi_arr = ind.rsi(c, 14)
        macd_l, macd_s, macd_h = ind.macd(c)
        bb_lo, bb_mid, bb_hi = ind.bollinger(c, 20, 2.0)
        e9, e21, e50 = ind.ema(c, 9), ind.ema(c, 21), ind.ema(c, 50)
        roc_arr = ind.roc(c, 10)

        tr = st.trend(c, h, lo, a)
        # trend context before each candle for the pattern detectors (causal)
        slope = ind.linreg_slope(c, 10)

        def trend_at(i: int) -> str:
            j = i - 1
            if j < 9 or np.isnan(slope[j]) or np.isnan(atr_arr[j]) or atr_arr[j] <= 0:
                return "unclear"
            s = slope[j] / atr_arr[j]
            return "up" if s > 0.08 else "down" if s < -0.08 else "sideways"

        levels = st.support_resistance(h, lo, c, a)
        zones = st.supply_demand(o, h, lo, c, atr_arr)
        pools = st.liquidity_pools(h, lo, a)
        dtb = st.double_top_bottom(h, lo, c, a)
        sudden = st.sudden_move(h, lo, c, atr_arr)
        recent = pat.recent_patterns(o, h, lo, c, atr_arr, trend_at, lookback=3)

        atr_pct = atr_arr / np.where(c == 0, np.nan, np.abs(c))
        hist = atr_pct[~np.isnan(atr_pct)]
        vol_pctile = float((hist < atr_pct[-1]).mean()) if len(hist) > 5 else 0.5
        width = (bb_hi - bb_lo) / np.where(bb_mid == 0, np.nan, np.abs(bb_mid))
        wv = width[~np.isnan(width)]
        squeeze = bool(len(wv) > 10 and width[-1] <= np.percentile(wv, 20))

        factors = [
            self._price_action(o, h, lo, c, a, sudden),
            self._candles(recent),
            self._sr(levels, c, a),
            Factor("trend", direction={"up": "bullish", "down": "bearish"}.get(tr["direction"], "neutral"),
                   strength=tr["strength"], code=f"trend_{tr['direction']}", params={"structure": tr["structure"]}),
            self._sd(zones, c, a),
            self._liquidity(pools, h, lo, c),
            self._ma(c, e9, e21, e50),
            self._rsi(rsi_arr),
            self._macd(macd_l, macd_s, macd_h),
            self._bb(c, bb_lo, bb_hi, squeeze),
            Factor("atr", code="atr_value", params={"atr": _f(a), "percentile": round(vol_pctile, 2)}),
            self._volume(vol),
            self._momentum(roc_arr, c, a),
            Factor("volatility", code="vol_high" if vol_pctile >= 0.8 else "vol_low" if vol_pctile <= 0.2 else "vol_normal",
                   params={"percentile": round(vol_pctile, 2)}),
            self._chart_pattern(dtb),
        ]
        for f in factors:
            if not enabled.get(f.name, True):
                f.enabled, f.direction, f.strength = False, "neutral", 0.0

        if sudden or vol_pctile >= 0.85:
            condition = "volatile"
        elif tr["direction"] != "sideways" and tr["strength"] >= 0.5:
            condition = "trending"
        else:
            condition = "ranging"

        active = [f for f in factors if f.enabled and f.available]
        bull = [f for f in active if f.direction == "bullish"]
        bear = [f for f in active if f.direction == "bearish"]
        warnings = []
        if sudden:
            warnings.append("sudden_move")
        if not has_volume:
            warnings.append("no_volume_data")
        return {
            "available": True,
            "analyzer_version": ANALYZER_VERSION,
            "candles_used": n,
            "market_condition": condition,
            "trend": tr,
            "levels": [lv.to_dict() for lv in levels],
            "zones": [z.to_dict() for z in zones],
            "liquidity": pools,
            "chart_pattern": dtb,
            "patterns": [asdict(p) for p in recent],
            "sudden_move": sudden,
            "indicators": {
                "rsi": _f(rsi_arr[-1]), "macd": _f(macd_l[-1]), "macd_signal": _f(macd_s[-1]),
                "macd_hist": _f(macd_h[-1]), "bb_lower": _f(bb_lo[-1]), "bb_mid": _f(bb_mid[-1]),
                "bb_upper": _f(bb_hi[-1]), "ema9": _f(e9[-1]), "ema21": _f(e21[-1]), "ema50": _f(e50[-1]),
                "atr": _f(a), "roc10": _f(roc_arr[-1]), "squeeze": squeeze,
            },
            "factors": [f.to_dict() for f in factors],
            "confluence": {
                "bullish": [f.name for f in bull], "bearish": [f.name for f in bear],
                "neutral": [f.name for f in active if f.direction == "neutral"],
                "disabled": [f.name for f in factors if not f.enabled],
                "unavailable": [f.name for f in factors if f.enabled and not f.available],
                "bullish_score": round(sum(f.strength for f in bull), 3),
                "bearish_score": round(sum(f.strength for f in bear), 3),
            },
            "warnings": warnings,
        }

    # ------------------------------------------------------------ factor builders
    @staticmethod
    def _price_action(o, h, lo, c, a, sudden) -> Factor:
        last3 = c[-1] - o[-3]
        pos = (c[-1] - lo[-1]) / max(h[-1] - lo[-1], 1e-12)  # where the close sits in its range
        score = (np.clip(last3 / (2 * a), -1, 1) if a > 0 else 0) * 0.6 + (pos - 0.5) * 0.8
        d = "bullish" if score > 0.15 else "bearish" if score < -0.15 else "neutral"
        params = {"close_position": round(float(pos), 2)}
        if sudden:
            params["sudden_move_atr"] = sudden["range_atr"]
        return Factor("price_action", direction=d, strength=min(1.0, abs(float(score))),
                      code=f"pa_{d}", params=params)

    @staticmethod
    def _candles(recent) -> Factor:
        directional = [p for p in recent if p.direction != "neutral"]
        if not directional:
            names = [p.name for p in recent]
            return Factor("candlesticks", code="pattern_none" if not names else "pattern_neutral",
                          params={"patterns": names})
        best = max(directional, key=lambda p: (p.index, p.strength))
        return Factor("candlesticks", direction=best.direction, strength=best.strength, code=f"pattern_{best.name}",
                      params={"patterns": [p.name for p in recent]})

    @staticmethod
    def _sr(levels, c, a) -> Factor:
        if not levels or a <= 0:
            return Factor("support_resistance", code="sr_none")
        last, prev = c[-1], c[-2]
        for lv in levels:  # fresh breakout through a level is the strongest reading
            if prev < lv.price < last and lv.kind == "support" and last - lv.price < 1.5 * a:
                return Factor("support_resistance", direction="bullish", strength=0.6 * lv.strength + 0.3,
                              code="sr_breakout_up", params={"level": lv.price})
            if prev > lv.price > last and lv.kind == "resistance" and lv.price - last < 1.5 * a:
                return Factor("support_resistance", direction="bearish", strength=0.6 * lv.strength + 0.3,
                              code="sr_breakdown", params={"level": lv.price})
        near = min(levels, key=lambda lv: abs(lv.price - last))
        dist = abs(near.price - last) / a
        if dist <= 0.6:
            d = "bullish" if near.kind == "support" else "bearish"
            return Factor("support_resistance", direction=d, strength=near.strength * (1 - dist / 0.6 * 0.5),
                          code=f"sr_near_{near.kind}", params={"level": near.price, "touches": near.touches})
        return Factor("support_resistance", code="sr_between", params={"nearest": near.price})

    @staticmethod
    def _sd(zones, c, a) -> Factor:
        last = c[-1]
        for z in zones:
            if z.low - 0.3 * a <= last <= z.high + 0.3 * a:
                d = "bullish" if z.kind == "demand" else "bearish"
                return Factor("supply_demand", direction=d, strength=min(1.0, 0.3 + 0.15 * z.impulse_atr) * (1 if z.fresh else 0.6),
                              code=f"sd_in_{z.kind}", params={"low": z.low, "high": z.high, "fresh": z.fresh})
        return Factor("supply_demand", code="sd_none" if not zones else "sd_away", params={"zones": len(zones)})

    @staticmethod
    def _liquidity(pools, h, lo, c) -> Factor:
        for p in pools["equal_lows"]:
            if lo[-1] < p < c[-1]:  # swept the lows and closed back above: liquidity grab
                return Factor("liquidity_zones", direction="bullish", strength=0.55, code="liq_sweep_lows",
                              params={"level": p})
        for p in pools["equal_highs"]:
            if h[-1] > p > c[-1]:
                return Factor("liquidity_zones", direction="bearish", strength=0.55, code="liq_sweep_highs",
                              params={"level": p})
        return Factor("liquidity_zones", code="liq_none",
                      params={"equal_highs": len(pools["equal_highs"]), "equal_lows": len(pools["equal_lows"])})

    @staticmethod
    def _ma(c, e9, e21, e50) -> Factor:
        if np.isnan(e21[-1]):
            return Factor("moving_averages", available=False, code="insufficient_data")
        up = c[-1] > e9[-1] > e21[-1]
        down = c[-1] < e9[-1] < e21[-1]
        with50 = not np.isnan(e50[-1])
        if up:
            s = 0.5 + (0.3 if with50 and e21[-1] > e50[-1] else 0)
            return Factor("moving_averages", direction="bullish", strength=s, code="ma_bull_alignment")
        if down:
            s = 0.5 + (0.3 if with50 and e21[-1] < e50[-1] else 0)
            return Factor("moving_averages", direction="bearish", strength=s, code="ma_bear_alignment")
        return Factor("moving_averages", code="ma_mixed")

    @staticmethod
    def _rsi(r) -> Factor:
        v = r[-1]
        if np.isnan(v):
            return Factor("rsi", available=False, code="insufficient_data")
        p = {"value": round(float(v), 1)}
        if v >= 70:
            return Factor("rsi", direction="bearish", strength=min(1.0, 0.4 + (v - 70) / 30), code="rsi_overbought", params=p)
        if v <= 30:
            return Factor("rsi", direction="bullish", strength=min(1.0, 0.4 + (30 - v) / 30), code="rsi_oversold", params=p)
        if v >= 55:
            return Factor("rsi", direction="bullish", strength=0.2, code="rsi_bull_zone", params=p)
        if v <= 45:
            return Factor("rsi", direction="bearish", strength=0.2, code="rsi_bear_zone", params=p)
        return Factor("rsi", code="rsi_neutral", params=p)

    @staticmethod
    def _macd(line, sig, hist) -> Factor:
        if np.isnan(sig[-1]) or np.isnan(sig[-2]):
            return Factor("macd", available=False, code="insufficient_data")
        crossed_up = hist[-2] <= 0 < hist[-1]
        crossed_dn = hist[-2] >= 0 > hist[-1]
        if crossed_up:
            return Factor("macd", direction="bullish", strength=0.65, code="macd_cross_up")
        if crossed_dn:
            return Factor("macd", direction="bearish", strength=0.65, code="macd_cross_down")
        rising = hist[-1] > hist[-2]
        if hist[-1] > 0:
            return Factor("macd", direction="bullish", strength=0.4 if rising else 0.2, code="macd_positive")
        return Factor("macd", direction="bearish", strength=0.4 if not rising else 0.2, code="macd_negative")

    @staticmethod
    def _bb(c, lo, hi, squeeze) -> Factor:
        if np.isnan(hi[-1]):
            return Factor("bollinger_bands", available=False, code="insufficient_data")
        if c[-1] > hi[-1]:
            return Factor("bollinger_bands", direction="bearish", strength=0.45, code="bb_above_upper")
        if c[-1] < lo[-1]:
            return Factor("bollinger_bands", direction="bullish", strength=0.45, code="bb_below_lower")
        return Factor("bollinger_bands", code="bb_squeeze" if squeeze else "bb_inside")

    @staticmethod
    def _volume(vol) -> Factor:
        if vol is None or np.isnan(vol[-20:]).any():
            return Factor("volume", available=False, code="volume_unavailable")
        avg = vol[-21:-1].mean()
        ratio = vol[-1] / avg if avg > 0 else 1.0
        return Factor("volume", code="volume_high" if ratio >= 1.8 else "volume_normal",
                      params={"ratio": round(float(ratio), 2)})

    @staticmethod
    def _momentum(roc_arr, c, a) -> Factor:
        if np.isnan(roc_arr[-1]) or a <= 0:
            return Factor("momentum", available=False, code="insufficient_data")
        move_atr = (c[-1] - c[-11]) / a
        d = "bullish" if move_atr > 1 else "bearish" if move_atr < -1 else "neutral"
        return Factor("momentum", direction=d, strength=min(1.0, abs(move_atr) / 4) if d != "neutral" else 0.0,
                      code=f"mom_{d}", params={"move_atr": round(float(move_atr), 2)})

    @staticmethod
    def _chart_pattern(dtb) -> Factor:
        if not dtb:
            return Factor("chart_patterns", code="cp_none")
        return Factor("chart_patterns", direction=dtb["direction"], strength=0.7 if dtb["confirmed"] else 0.4,
                      code=f"cp_{dtb['name']}{'_confirmed' if dtb['confirmed'] else ''}",
                      params={"neckline": dtb["neckline"]})


def candles_from_reading(reading: dict) -> tuple[list[dict], str]:
    """Closed candles from a chart reading, in prices when the axis was read, else relative units."""
    closed = [c for c in reading.get("candles", []) if c.get("status") == "closed"]
    if closed and all("close" in c for c in closed):
        return [{"open": c["open"], "high": c["high"], "low": c["low"], "close": c["close"]} for c in closed], "price"
    return [{"open": c["rel_open"], "high": c["rel_high"], "low": c["rel_low"], "close": c["rel_close"]}
            for c in closed], "relative"


def analyze_reading(reading: dict, enabled: dict[str, bool] | None = None) -> dict:
    """Technical analysis of a usable chart reading (image only, no volume)."""
    if not reading.get("usable"):
        return {"available": False, "reason": "reading_not_usable"}
    candles, units = candles_from_reading(reading)
    out = TechnicalAnalyzer().analyze(candles, enabled, has_volume=False)
    out["units"] = units
    return out
