"""Classic chart patterns as testable, causal *break* events at a closed bar ``i``.

Each pattern is built only from swing pivots already confirmed at bar ``i - 1`` (so nothing from
bar ``i`` or later shapes the pattern); the event fires on the candle whose close crosses the
pattern's line (neckline, flag top, triangle top). Sizes are measured in ATR so the same rules
work on any asset and timeframe.

* double top      → close breaks below the neckline (the low between two similar highs) → SELL
* double bottom   → close breaks above the neckline (the high between two similar lows) → BUY
* head & shoulders → close breaks below the neckline through the two lows → SELL
* bull flag       → strong rise (pole), shallow pullback, close breaks above the flag top → BUY
* ascending triangle → flat top + higher lows, close breaks above the top → BUY
* gap retest      → after a fast move leaves a gap between candles, the first return into the gap that
                    closes back on the move's side → enter with the move (bull → BUY, bear → SELL)

The Dart engine (app/lib/engine/strategy/chart_patterns.dart) mirrors this file operation for
operation; the parity test compares both on every bar.
"""

from __future__ import annotations

import math

MAX_AGE = 30  # the last pivot of a pattern must be at most this many bars before the break


def _atr(fs, i: int) -> float | None:
    a = float(fs.atr[i])
    return None if math.isnan(a) or a <= 0 else a


def _between(pivs: list[int], a: int, b: int) -> list[int]:
    return [j for j in pivs if a < j < b]


def double_top(fs, i: int) -> bool:
    a = _atr(fs, i)
    if a is None or i < 1:
        return False
    hs = fs._confirmed(fs.piv_hi, i - 1, 2)
    if len(hs) < 2:
        return False
    h1, h2 = hs[0], hs[1]
    if h2 - h1 < 3 or i - h2 > MAX_AGE or abs(fs.h[h1] - fs.h[h2]) > 0.5 * a:
        return False
    lows = _between(fs.piv_lo, h1, h2)
    if not lows:
        return False
    neck = min(float(fs.l[j]) for j in lows)
    if max(float(fs.h[h1]), float(fs.h[h2])) - neck < a:
        return False
    return fs.c[i - 1] >= neck > fs.c[i]


def double_bottom(fs, i: int) -> bool:
    a = _atr(fs, i)
    if a is None or i < 1:
        return False
    ls = fs._confirmed(fs.piv_lo, i - 1, 2)
    if len(ls) < 2:
        return False
    l1, l2 = ls[0], ls[1]
    if l2 - l1 < 3 or i - l2 > MAX_AGE or abs(fs.l[l1] - fs.l[l2]) > 0.5 * a:
        return False
    highs = _between(fs.piv_hi, l1, l2)
    if not highs:
        return False
    neck = max(float(fs.h[j]) for j in highs)
    if neck - min(float(fs.l[l1]), float(fs.l[l2])) < a:
        return False
    return fs.c[i - 1] <= neck < fs.c[i]


def _neck_at(x1: int, y1: float, x2: int, y2: float, x: int) -> float:
    return y1 + (y2 - y1) * (x - x1) / (x2 - x1)


def head_shoulders(fs, i: int) -> bool:
    a = _atr(fs, i)
    if a is None or i < 1:
        return False
    hs = fs._confirmed(fs.piv_hi, i - 1, 3)
    if len(hs) < 3:
        return False
    ls_, hd, rs = hs[0], hs[1], hs[2]
    if i - rs > MAX_AGE:
        return False
    hl, hh, hr = float(fs.h[ls_]), float(fs.h[hd]), float(fs.h[rs])
    if hh - max(hl, hr) < 0.5 * a or abs(hl - hr) > a:
        return False
    low1, low2 = _between(fs.piv_lo, ls_, hd), _between(fs.piv_lo, hd, rs)
    if not low1 or not low2:
        return False
    j1 = min(low1, key=lambda j: (float(fs.l[j]), j))
    j2 = min(low2, key=lambda j: (float(fs.l[j]), j))
    y1, y2 = float(fs.l[j1]), float(fs.l[j2])
    if hh - max(y1, y2) < 1.5 * a:
        return False
    return fs.c[i - 1] >= _neck_at(j1, y1, j2, y2, i - 1) and fs.c[i] < _neck_at(j1, y1, j2, y2, i)


def bull_flag(fs, i: int) -> bool:
    a = _atr(fs, i)
    if a is None or i < 1:
        return False
    hs = fs._confirmed(fs.piv_hi, i - 1, 1)
    if not hs:
        return False
    p = hs[0]
    if not 3 <= i - p <= 15 or p < 10:
        return False
    top = float(fs.h[p])
    base = min(float(fs.l[j]) for j in range(p - 10, p + 1))
    pole = top - base
    if pole < 3 * a:
        return False
    after = range(p + 1, i)
    if max(float(fs.h[j]) for j in after) > top:
        return False
    dip = top - min(float(fs.l[j]) for j in after)
    if dip <= 0 or dip > 0.5 * pole:
        return False
    return fs.c[i - 1] <= top < fs.c[i]


def ascending_triangle(fs, i: int) -> bool:
    a = _atr(fs, i)
    if a is None or i < 1:
        return False
    hs = fs._confirmed(fs.piv_hi, i - 1, 2)
    ls = fs._confirmed(fs.piv_lo, i - 1, 2)
    if len(hs) < 2 or len(ls) < 2:
        return False
    h1, h2 = hs[0], hs[1]
    l1, l2 = ls[0], ls[1]
    if i - h2 > MAX_AGE or h2 - h1 < 3 or abs(fs.h[h1] - fs.h[h2]) > 0.3 * a:
        return False
    if not (l1 < h2 and l2 > h1) or fs.l[l2] - fs.l[l1] < 0.3 * a:
        return False
    top = max(float(fs.h[h1]), float(fs.h[h2]))
    if top - float(fs.l[l1]) < a:
        return False
    return fs.c[i - 1] <= top < fs.c[i]


def _gap_retest(fs, i: int, up: bool) -> bool:
    """A fast move leaves a gap (imbalance) between candles j-2 and j; price comes back into any such gap of
    the last 20 bars for the first time at bar i and closes back on the move's side → enter with the move."""
    a = _atr(fs, i)
    if a is None or i < 3:
        return False
    for j in range(i - 1, max(2, i - 20) - 1, -1):
        if up:
            lo, hi = float(fs.h[j - 2]), float(fs.l[j])  # bullish gap: candle j's low above candle j-2's high
            if hi - lo < 0.3 * a or not fs.c[j - 1] > fs.o[j - 1]:
                continue
            if any(fs.l[q] <= hi for q in range(j + 1, i)):
                continue  # already retested
            if fs.l[i] <= hi and fs.c[i] > lo:
                return True
            continue
        lo, hi = float(fs.h[j]), float(fs.l[j - 2])  # bearish gap: candle j's high below candle j-2's low
        if hi - lo < 0.3 * a or not fs.c[j - 1] < fs.o[j - 1]:
            continue
        if any(fs.h[q] >= lo for q in range(j + 1, i)):
            continue
        if fs.h[i] >= lo and fs.c[i] < hi:
            return True
    return False


CHART_PATTERNS = {
    "double_top": double_top, "double_bottom": double_bottom, "head_shoulders": head_shoulders,
    "bull_flag": bull_flag, "ascending_triangle": ascending_triangle,
    "gap_retest_bull": lambda fs, i: _gap_retest(fs, i, True),
    "gap_retest_bear": lambda fs, i: _gap_retest(fs, i, False),
}
