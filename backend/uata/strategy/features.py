"""Per-bar features for strategy evaluation and backtesting — strictly causal.

``FeatureSet(ohlc)`` precomputes causal indicator arrays once (each element i uses
data 0..i only — proven by tests in Phase 4) and evaluates structural features
(trend, support/resistance, patterns, market condition) at bar ``i`` from data up
to ``i`` only. Pivots are used only once confirmed (``j + k <= i``).

``tests/test_strategy.py::test_features_are_causal`` checks that every feature at
bar i is identical whether or not later bars exist.
"""

from __future__ import annotations

import numpy as np

from uata.analysis import indicators as ind
from uata.analysis import patterns as pat

PIVOT_K = 2
WARMUP = 50  # bars needed before features are meaningful (EMA50, ATR, MACD signal)


class FeatureSet:
    def __init__(self, o, h, low, c, volume=None):
        self.o, self.h, self.l, self.c = (np.asarray(x, float) for x in (o, h, low, c))
        self.n = len(self.c)
        self.v = None if volume is None else np.asarray(volume, float)
        c_ = self.c
        self.atr = ind.atr(self.h, self.l, c_, 14)
        self.rsi = ind.rsi(c_, 14)
        self.macd, self.macd_sig, self.macd_hist = ind.macd(c_)
        self.bb_lo, self.bb_mid, self.bb_hi = ind.bollinger(c_, 20, 2.0)
        self.ema = {9: ind.ema(c_, 9), 21: ind.ema(c_, 21), 50: ind.ema(c_, 50)}
        self.slope = ind.linreg_slope(c_, 20)
        self.slope10 = ind.linreg_slope(c_, 10)
        with np.errstate(divide="ignore", invalid="ignore"):
            self.atr_pct = self.atr / np.abs(c_)
        # pivot j is confirmed at bar j + K; its definition only uses bars j-K..j+K
        self.piv_hi: list[int] = []
        self.piv_lo: list[int] = []
        k = PIVOT_K
        for j in range(k, self.n - k):
            wh, wl = self.h[j - k:j + k + 1], self.l[j - k:j + k + 1]
            if self.h[j] == wh.max() and int(np.argmax(wh)) == k:
                self.piv_hi.append(j)
            if self.l[j] == wl.min() and int(np.argmin(wl)) == k:
                self.piv_lo.append(j)

    # ------------------------------------------------------------ helpers
    def _confirmed(self, pivs: list[int], i: int, last: int = 30) -> list[int]:
        out = [j for j in pivs if j + PIVOT_K <= i]
        return out[-last:]

    def trend(self, i: int) -> str:
        a = self.atr[i]
        if np.isnan(self.slope[i]) or np.isnan(a) or a <= 0:
            return "unclear"
        s = self.slope[i] / a
        hs, ls = self._confirmed(self.piv_hi, i, 4), self._confirmed(self.piv_lo, i, 4)
        struct = None
        if len(hs) >= 2 and len(ls) >= 2:
            hh, hl = self.h[hs[-1]] > self.h[hs[-2]], self.l[ls[-1]] > self.l[ls[-2]]
            struct = "up" if hh and hl else "down" if (not hh and not hl) else "mixed"
        if s > 0.08 and struct != "down":
            return "up"
        if s < -0.08 and struct != "up":
            return "down"
        return "sideways"

    def _pattern_trend(self, i: int) -> str:
        j = i - 1
        if j < 9 or np.isnan(self.slope10[j]) or np.isnan(self.atr[j]) or self.atr[j] <= 0:
            return "unclear"
        s = self.slope10[j] / self.atr[j]
        return "up" if s > 0.08 else "down" if s < -0.08 else "sideways"

    def patterns(self, i: int) -> set[str]:
        a = self.atr[i] if not np.isnan(self.atr[i]) else self.h[i] - self.l[i]
        return {p.name for p in pat.detect_at(self.o, self.h, self.l, self.c, i, float(a), self._pattern_trend(i))}

    def levels(self, i: int) -> list[tuple[float, str, int]]:
        """(price, kind, touches) from confirmed pivots up to i, clustered within 0.5 ATR, >= 2 touches."""
        a = self.atr[i]
        if np.isnan(a) or a <= 0:
            return []
        pts = sorted([self.h[j] for j in self._confirmed(self.piv_hi, i)] +
                     [self.l[j] for j in self._confirmed(self.piv_lo, i)])
        clusters: list[list[float]] = []
        for p in pts:
            if clusters and abs(p - np.mean(clusters[-1])) <= 0.5 * a:
                clusters[-1].append(p)
            else:
                clusters.append([p])
        return [(float(np.mean(cl)), "support" if np.mean(cl) < self.c[i] else "resistance", len(cl))
                for cl in clusters if len(cl) >= 2]

    def market_condition(self, i: int) -> str:
        hist = self.atr_pct[max(0, i - 200):i + 1]
        hist = hist[~np.isnan(hist)]
        if len(hist) > 10 and (hist < self.atr_pct[i]).mean() >= 0.85:
            return "volatile"
        a = self.atr[i]
        if not np.isnan(self.slope[i]) and a > 0 and abs(self.slope[i] / a) >= 0.2:
            return "trending"
        return "ranging"

    def ready(self, i: int) -> bool:
        return i >= WARMUP and not np.isnan(self.atr[i]) and not np.isnan(self.macd_sig[i])
