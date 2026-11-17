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
