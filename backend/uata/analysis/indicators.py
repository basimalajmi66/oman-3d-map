"""Technical indicators — all strictly *causal*.

Every function returns an array aligned with the input where element ``i`` is
computed from elements ``0..i`` only (NaN until enough data exists). This is
what prevents look-ahead bias in live analysis and in backtests; it is enforced
by ``tests/test_analysis.py::test_indicators_are_causal``.
"""

from __future__ import annotations

import numpy as np

NAN = np.nan


def _arr(x) -> np.ndarray:
    return np.asarray(x, dtype=float)


def sma(x, n: int) -> np.ndarray:
    x = _arr(x)
    out = np.full(len(x), NAN)
    if len(x) >= n:
        c = np.cumsum(np.insert(x, 0, 0.0))
        out[n - 1:] = (c[n:] - c[:-n]) / n
    return out


def ema(x, n: int) -> np.ndarray:
    """EMA seeded with the SMA of the first ``n`` values (standard convention)."""
    x = _arr(x)
    out = np.full(len(x), NAN)
    if len(x) < n:
        return out
    k = 2.0 / (n + 1)
    out[n - 1] = x[:n].mean()
    for i in range(n, len(x)):
        out[i] = x[i] * k + out[i - 1] * (1 - k)
    return out


def _wilder(x: np.ndarray, n: int) -> np.ndarray:
    out = np.full(len(x), NAN)
    if len(x) < n:
        return out
    out[n - 1] = x[:n].mean()
    for i in range(n, len(x)):
        out[i] = (out[i - 1] * (n - 1) + x[i]) / n
    return out


def rsi(close, n: int = 14) -> np.ndarray:
    """Wilder's RSI. Element i needs n price changes, i.e. i >= n."""
    c = _arr(close)
    out = np.full(len(c), NAN)
    if len(c) <= n:
        return out
    d = np.diff(c)
    gain = _wilder(np.clip(d, 0, None), n)
    loss = _wilder(np.clip(-d, 0, None), n)
    with np.errstate(divide="ignore", invalid="ignore"):
        rs = gain / loss
        r = 100 - 100 / (1 + rs)
    r = np.where(loss == 0, np.where(gain == 0, 50.0, 100.0), r)
    out[1:] = r
    return out


def macd(close, fast: int = 12, slow: int = 26, signal: int = 9) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    c = _arr(close)
    line = ema(c, fast) - ema(c, slow)
    sig = np.full(len(c), NAN)
    valid = ~np.isnan(line)
    if valid.sum() >= signal:
        start = int(np.argmax(valid))
        sig[start:] = ema(line[start:], signal)
    return line, sig, line - sig


def bollinger(close, n: int = 20, k: float = 2.0) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    c = _arr(close)
    mid = sma(c, n)
    sd = np.full(len(c), NAN)
    for i in range(n - 1, len(c)):
        sd[i] = c[i - n + 1:i + 1].std()
    return mid - k * sd, mid, mid + k * sd


def true_range(high, low, close) -> np.ndarray:
    h, lo, c = _arr(high), _arr(low), _arr(close)
    prev = np.concatenate([[NAN], c[:-1]])
    tr = np.nanmax(np.vstack([h - lo, np.abs(h - prev), np.abs(lo - prev)]), axis=0)
    tr[0] = h[0] - lo[0]
    return tr


def atr(high, low, close, n: int = 14) -> np.ndarray:
    return _wilder(true_range(high, low, close), n)


def roc(close, n: int = 10) -> np.ndarray:
    """Rate of change in % over n bars (momentum)."""
    c = _arr(close)
    out = np.full(len(c), NAN)
    if len(c) > n:
        with np.errstate(divide="ignore", invalid="ignore"):
            out[n:] = (c[n:] / c[:-n] - 1) * 100
    return out


def linreg_slope(x, n: int) -> np.ndarray:
    """Slope of a least-squares line over the last n values (per bar)."""
    x = _arr(x)
    out = np.full(len(x), NAN)
    t = np.arange(n) - (n - 1) / 2
    denom = (t ** 2).sum()
    for i in range(n - 1, len(x)):
        w = x[i - n + 1:i + 1]
        out[i] = (t * (w - w.mean())).sum() / denom
    return out


# ---------------------------------------------------------------- oscillators / trend strength used by strategies
# Written as plain loops on purpose: the phone engine (Dart) runs the very same operations in the same order, so
# both engines produce bit-identical values (parity tests).

def _sma_strict(x: np.ndarray, n: int) -> np.ndarray:
    """Simple average of the last n values; NaN if any of them is NaN (sequential sum)."""
    out = np.full(len(x), NAN)
    for i in range(n - 1, len(x)):
        s = 0.0
        ok = True
        for j in range(i - n + 1, i + 1):
            v = float(x[j])
            if v != v:
                ok = False
                break
            s += v
        if ok:
            out[i] = s / n
    return out


def stochastic(high, low, close, k: int = 14, d: int = 3, smooth: int = 3) -> tuple[np.ndarray, np.ndarray]:
    """Slow stochastic: %K = SMA(smooth) of the raw %K over k bars, %D = SMA(d) of %K (0..100)."""
    h, lo, c = _arr(high), _arr(low), _arr(close)
    raw = np.full(len(c), NAN)
    for i in range(k - 1, len(c)):
        hh = max(float(v) for v in h[i - k + 1:i + 1])
        ll = min(float(v) for v in lo[i - k + 1:i + 1])
        rng = hh - ll
        raw[i] = 50.0 if rng == 0 else 100.0 * (float(c[i]) - ll) / rng
    kk = _sma_strict(raw, smooth)
    return kk, _sma_strict(kk, d)


def adx(high, low, close, n: int = 14) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Wilder's ADX with +DI / -DI."""
    h, lo, c = _arr(high), _arr(low), _arr(close)
    m = len(c)
    pdm, mdm = np.zeros(m), np.zeros(m)
    for i in range(1, m):
        up, down = float(h[i]) - float(h[i - 1]), float(lo[i - 1]) - float(lo[i])
        pdm[i] = up if (up > down and up > 0) else 0.0
        mdm[i] = down if (down > up and down > 0) else 0.0
    s_tr, s_p, s_m = _wilder(true_range(h, lo, c), n), _wilder(pdm, n), _wilder(mdm, n)
    pdi, mdi, dx = np.full(m, NAN), np.full(m, NAN), np.full(m, NAN)
    for i in range(m):
        t = float(s_tr[i])
        if t != t:
            continue
        p = 0.0 if t == 0 else 100.0 * float(s_p[i]) / t
        q = 0.0 if t == 0 else 100.0 * float(s_m[i]) / t
        pdi[i], mdi[i] = p, q
        dx[i] = 0.0 if p + q == 0 else 100.0 * abs(p - q) / (p + q)
    out = np.full(m, NAN)
    if m >= n:
        out[n - 1:] = _wilder(dx[n - 1:], n)
    return out, pdi, mdi


def psar(high, low, step: float = 0.02, max_af: float = 0.2) -> tuple[np.ndarray, np.ndarray]:
    """Parabolic SAR and its direction (+1 up: SAR below price, -1 down: SAR above price)."""
    h, lo = _arr(high), _arr(low)
    m = len(h)
    sar_out, dir_out = np.full(m, NAN), np.full(m, NAN)
    if m < 2:
        return sar_out, dir_out
    up = float(h[1]) + float(lo[1]) >= float(h[0]) + float(lo[0])
    sar = float(lo[0]) if up else float(h[0])
    ep = float(h[1]) if up else float(lo[1])
    af = step
    sar_out[1], dir_out[1] = sar, 1.0 if up else -1.0
    for i in range(2, m):
        sar = sar + af * (ep - sar)
        if up:
            sar = min(sar, float(lo[i - 1]), float(lo[i - 2]))
            if float(lo[i]) < sar:
                up, sar, ep, af = False, ep, float(lo[i]), step
            elif float(h[i]) > ep:
                ep, af = float(h[i]), min(af + step, max_af)
        else:
            sar = max(sar, float(h[i - 1]), float(h[i - 2]))
            if float(h[i]) > sar:
                up, sar, ep, af = True, ep, float(h[i]), step
            elif float(lo[i]) < ep:
                ep, af = float(lo[i]), min(af + step, max_af)
        sar_out[i], dir_out[i] = sar, 1.0 if up else -1.0
    return sar_out, dir_out
