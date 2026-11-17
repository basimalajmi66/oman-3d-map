"""Market structure: confirmed pivots, trend, support/resistance, supply/demand,
liquidity pools, double tops/bottoms, sudden moves.

Pivots need ``k`` candles on each side, so a pivot at index ``j`` is only
*known* at index ``j + k``. Functions take the analysis index ``i`` and use only
pivots with ``j + k <= i`` (no look-ahead).
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

import numpy as np


@dataclass
class Level:
    price: float
    kind: str          # support | resistance
    touches: int
    last_index: int
    strength: float    # 0..1

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class Zone:
    low: float
    high: float
    kind: str          # demand | supply
    origin_index: int
    impulse_atr: float  # size of the move that left the zone, in ATRs
    fresh: bool         # price has not come back into it since

    def to_dict(self) -> dict:
        return asdict(self)


def pivots(high, low, k: int, upto: int) -> tuple[list[int], list[int]]:
    """Indices of confirmed swing highs / lows known at bar ``upto``."""
    hs, ls = [], []
    for j in range(k, upto - k + 1):
        win_h = high[j - k:j + k + 1]
        win_l = low[j - k:j + k + 1]
        if high[j] == win_h.max() and np.argmax(win_h) == k:
            hs.append(j)
        if low[j] == win_l.min() and np.argmin(win_l) == k:
            ls.append(j)
    return hs, ls


def trend(close, high, low, atr_i: float, k: int = 2, window: int = 30) -> dict:
    """Trend from (a) regression slope normalised by ATR and (b) swing structure."""
    n = len(close)
    w = min(window, n)
    seg = close[n - w:]
    t = np.arange(w) - (w - 1) / 2
    slope = float((t * (seg - seg.mean())).sum() / max((t ** 2).sum(), 1e-12))
    slope_atr = slope / atr_i if atr_i > 0 else 0.0
    hs, ls = pivots(high, low, k, n - 1)
    hs, ls = [j for j in hs if j >= n - w], [j for j in ls if j >= n - w]
    struct = "unclear"
    if len(hs) >= 2 and len(ls) >= 2:
        hh = high[hs[-1]] > high[hs[-2]]
        hl = low[ls[-1]] > low[ls[-2]]
        if hh and hl:
            struct = "up"
        elif not hh and not hl:
            struct = "down"
        else:
            struct = "mixed"
    if slope_atr > 0.08 and struct in ("up", "unclear", "mixed"):
        direction = "up"
    elif slope_atr < -0.08 and struct in ("down", "unclear", "mixed"):
        direction = "down"
    else:
        direction = "sideways"
    if struct in ("up", "down") and struct != direction and direction != "sideways":
        direction = "sideways"
    strength = float(min(1.0, abs(slope_atr) / 0.4)) * (1.0 if struct == direction else 0.6)
    return {"direction": direction, "strength": round(strength, 3), "slope_atr_per_bar": round(slope_atr, 4),
            "structure": struct}


def support_resistance(high, low, close, atr_i: float, k: int = 2, max_levels: int = 4) -> list[Level]:
    """Cluster confirmed pivots within 0.5 ATR; more touches + recency = stronger."""
    n = len(close)
    hs, ls = pivots(high, low, k, n - 1)
    pts = [(high[j], j) for j in hs] + [(low[j], j) for j in ls]
    if not pts or atr_i <= 0:
        return []
    pts.sort()
    tol = 0.5 * atr_i
    # compare with the cluster centre (not its last member) so clusters cannot chain
    clusters: list[list[tuple[float, int]]] = [[pts[0]]]
    for p in pts[1:]:
        centre = float(np.mean([q[0] for q in clusters[-1]]))
        if abs(p[0] - centre) <= tol:
            clusters[-1].append(p)
        else:
            clusters.append([p])
    clusters = [cl for cl in clusters if len(cl) >= 2]  # a level needs at least two touches
    last = close[-1]
    levels = []
    for cl in clusters:
        price = float(np.mean([p[0] for p in cl]))
        touches = len(cl)
        last_idx = max(p[1] for p in cl)
        recency = 1 - (n - 1 - last_idx) / max(n, 1)
        strength = min(1.0, 0.25 * touches + 0.3 * recency)
        levels.append(Level(price, "support" if price < last else "resistance", touches, last_idx, round(strength, 3)))
    # keep the strongest levels closest to price
    levels.sort(key=lambda lv: (-lv.strength, abs(lv.price - last)))
    return sorted(levels[:max_levels], key=lambda lv: lv.price)


def supply_demand(o, high, low, close, atr_arr, impulse: float = 2.0, max_zones: int = 3) -> list[Zone]:
    """A base (1–3 small candles) followed by an impulsive move of >= ``impulse`` ATR."""
    n = len(close)
    zones: list[Zone] = []
    for j in range(1, n - 1):
        a = atr_arr[j]
        if np.isnan(a) or a <= 0:
            continue
        base_lo, base_hi = low[j], high[j]
        if (base_hi - base_lo) > 1.0 * a:  # base must be a quiet candle
            continue
        end = min(n, j + 4)
        move_up = high[j + 1:end].max() - base_hi
        move_dn = base_lo - low[j + 1:end].min()
        if move_up >= impulse * a and close[j + 1] > o[j + 1]:
            fresh = low[end:].min() > base_hi if end < n else True
            zones.append(Zone(float(base_lo), float(base_hi), "demand", j, round(float(move_up / a), 2), bool(fresh)))
        elif move_dn >= impulse * a and close[j + 1] < o[j + 1]:
            fresh = high[end:].max() < base_lo if end < n else True
            zones.append(Zone(float(base_lo), float(base_hi), "supply", j, round(float(move_dn / a), 2), bool(fresh)))
    zones.sort(key=lambda z: (not z.fresh, -z.origin_index))
    return zones[:max_zones]


def liquidity_pools(high, low, atr_i: float, k: int = 2) -> dict:
    """Equal highs / equal lows (within 0.15 ATR): where stop orders tend to rest."""
    n = len(high)
    hs, ls = pivots(high, low, k, n - 1)
    tol = 0.15 * atr_i

    def equal(idx, arr):
        pools = []
        for a_i in range(len(idx)):
            for b_i in range(a_i + 1, len(idx)):
                if abs(arr[idx[a_i]] - arr[idx[b_i]]) <= tol:
                    pools.append(float((arr[idx[a_i]] + arr[idx[b_i]]) / 2))
        return sorted(set(round(p, 10) for p in pools))

    return {"equal_highs": equal(hs, high), "equal_lows": equal(ls, low)}


def double_top_bottom(high, low, close, atr_i: float, k: int = 2) -> dict | None:
    """Two comparable swing extremes with a meaningful pullback between them."""
    n = len(close)
    hs, ls = pivots(high, low, k, n - 1)
    if len(hs) >= 2:
        a, b = hs[-2], hs[-1]
        trough = low[a:b + 1].min()
        if abs(high[a] - high[b]) <= 0.3 * atr_i and (min(high[a], high[b]) - trough) >= 1.5 * atr_i \
                and b - a >= 4 and close[-1] < high[b]:
            return {"name": "double_top", "direction": "bearish", "neckline": float(trough),
                    "confirmed": bool(close[-1] < trough)}
    if len(ls) >= 2:
        a, b = ls[-2], ls[-1]
        peak = high[a:b + 1].max()
        if abs(low[a] - low[b]) <= 0.3 * atr_i and (peak - max(low[a], low[b])) >= 1.5 * atr_i \
                and b - a >= 4 and close[-1] > low[b]:
            return {"name": "double_bottom", "direction": "bullish", "neckline": float(peak),
                    "confirmed": bool(close[-1] > peak)}
    return None


def sudden_move(high, low, close, atr_arr, factor: float = 2.5) -> dict | None:
    """The last closed candle's range is unusually large relative to ATR (before it)."""
    n = len(close)
    if n < 3 or np.isnan(atr_arr[-2]) or atr_arr[-2] <= 0:
        return None
    rng = high[-1] - low[-1]
    ratio = rng / atr_arr[-2]
    if ratio >= factor:
        return {"range_atr": round(float(ratio), 2), "direction": "up" if close[-1] > close[-2] else "down"}
    return None
