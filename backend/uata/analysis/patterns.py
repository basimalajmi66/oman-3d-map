"""Japanese candlestick patterns on *closed* candles.

Each detector looks only at the candles ending at index ``i`` (causal). Size
thresholds are relative to the candle's own range and to ATR, so they work on
real prices and on the relative units produced from images alike.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass
class Pattern:
    name: str
    index: int          # index of the last candle of the pattern
    direction: str      # bullish | bearish | neutral
    strength: float     # 0..1


def _parts(o, h, low, c):
    rng = max(h - low, 1e-12)
    body = abs(c - o)
    upper = h - max(o, c)
    lower = min(o, c) - low
    return rng, body, upper, lower


def detect_at(o, h, low, c, i: int, atr_i: float, trend: str) -> list[Pattern]:
    """Patterns completed at candle ``i``. ``trend`` is the context before the pattern."""
    out: list[Pattern] = []
    rng, body, up, lo = _parts(o[i], h[i], low[i], c[i])
    big = atr_i > 0 and rng >= 0.5 * atr_i  # ignore patterns on insignificant candles

    if body <= 0.1 * rng and big:
        out.append(Pattern("doji", i, "neutral", 0.3))
    if big and lo >= 2 * body and up <= 0.25 * rng and body > 0.02 * rng:
        # hammer after a decline is bullish; the same shape after a rise is a hanging man
        if trend == "down":
            out.append(Pattern("hammer", i, "bullish", 0.6))
        elif trend == "up":
            out.append(Pattern("hanging_man", i, "bearish", 0.45))
    if big and up >= 2 * body and lo <= 0.25 * rng and body > 0.02 * rng:
        if trend == "up":
            out.append(Pattern("shooting_star", i, "bearish", 0.6))
        elif trend == "down":
            out.append(Pattern("inverted_hammer", i, "bullish", 0.45))
    if big and body >= 0.9 * rng:
        out.append(Pattern("marubozu", i, "bullish" if c[i] > o[i] else "bearish", 0.5))

    if i >= 1:
        po, pc = o[i - 1], c[i - 1]
        p_body = abs(pc - po)
        if pc < po and c[i] > o[i] and o[i] <= pc and c[i] >= po and body > p_body and big:
            out.append(Pattern("bullish_engulfing", i, "bullish", 0.75 if trend == "down" else 0.55))
        if pc > po and c[i] < o[i] and o[i] >= pc and c[i] <= po and body > p_body and big:
            out.append(Pattern("bearish_engulfing", i, "bearish", 0.75 if trend == "up" else 0.55))
        if h[i] <= h[i - 1] and low[i] >= low[i - 1]:
            out.append(Pattern("inside_bar", i, "neutral", 0.25))

    if i >= 2:
        o1, c1, o2, c2 = o[i - 2], c[i - 2], o[i - 1], c[i - 1]
        r1 = max(h[i - 2] - low[i - 2], 1e-12)
        small_mid = abs(c2 - o2) <= 0.3 * max(h[i - 1] - low[i - 1], 1e-12)
        if (c1 < o1 and abs(c1 - o1) >= 0.6 * r1 and small_mid and c[i] > o[i]
                and c[i] >= (o1 + c1) / 2 and trend == "down"):
            out.append(Pattern("morning_star", i, "bullish", 0.8))
        if (c1 > o1 and abs(c1 - o1) >= 0.6 * r1 and small_mid and c[i] < o[i]
                and c[i] <= (o1 + c1) / 2 and trend == "up"):
            out.append(Pattern("evening_star", i, "bearish", 0.8))
    return out


def recent_patterns(o, h, low, c, atr_arr, trend_at, lookback: int = 3) -> list[Pattern]:
    """Patterns completed on the last ``lookback`` closed candles."""
    n = len(c)
    out: list[Pattern] = []
    for i in range(max(0, n - lookback), n):
        a = atr_arr[i] if not np.isnan(atr_arr[i]) else (h[i] - low[i])
        out.extend(detect_at(o, h, low, c, i, float(a), trend_at(i)))
    return out
