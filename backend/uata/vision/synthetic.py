"""Synthetic candlestick charts with exact ground truth.

Used to *measure* the chart reader instead of trusting it: we render charts
from known OHLC data in several visual styles (dark/light, TradingView-like
teal/red, classic green/red, grid lines, moving-average overlays, price axis
labels, JPEG artefacts, noise) and compare what the reader extracts with the
truth. These images are test fixtures only — never market data.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np

# BGR colours
STYLES = {
    "dark_classic": {"bg": (24, 20, 18), "bull": (80, 175, 76), "bear": (60, 60, 230), "grid": (55, 50, 48),
                     "text": (200, 200, 200)},
    "dark_tv": {"bg": (30, 23, 19), "bull": (136, 166, 38), "bear": (83, 80, 239), "grid": (50, 44, 42),
                "text": (180, 180, 180)},
    "light_classic": {"bg": (255, 255, 255), "bull": (60, 160, 40), "bear": (40, 40, 210), "grid": (225, 225, 225),
                      "text": (60, 60, 60)},
    "light_tv": {"bg": (250, 250, 250), "bull": (153, 166, 8), "bear": (82, 54, 242), "grid": (232, 232, 232),
                 "text": (70, 70, 70)},
}


@dataclass
class SyntheticChart:
    image: np.ndarray
    ohlc: list[tuple[float, float, float, float]]
    truth: list[dict] = field(default_factory=list)  # pixel geometry per candle
    price_to_y: tuple[float, float] = (0.0, 0.0)      # y = a * price + b
    plot: tuple[int, int, int, int] = (0, 0, 0, 0)     # x0, y0, x1, y1


def random_walk_ohlc(n: int, seed: int = 0, start: float = 1.1000, vol: float = 0.0008) -> list[tuple]:
    rng = np.random.default_rng(seed)
    out, price = [], start
    for _ in range(n):
        o = price
        c = o + rng.normal(0, vol)
        h = max(o, c) + abs(rng.normal(0, vol * 0.6))
        lo = min(o, c) - abs(rng.normal(0, vol * 0.6))
        out.append((round(o, 5), round(h, 5), round(lo, 5), round(c, 5)))
        price = c
    return out


def render_chart(ohlc, *, style: str = "dark_classic", width: int = 1000, height: int = 560,
                 grid: bool = True, axis_labels: bool = True, ma_overlay: bool = False,
                 price_tag: bool = True, decimals: int = 5, title: str | None = "EURUSD  30s") -> SyntheticChart:
    st = STYLES[style]
    img = np.full((height, width, 3), st["bg"], dtype=np.uint8)
    x0, y0, x1, y1 = 12, 40, width - 110, height - 30
    lo = min(c[2] for c in ohlc)
    hi = max(c[1] for c in ohlc)
    pad = (hi - lo) * 0.06
    pmin, pmax = lo - pad, hi + pad
    a = -(y1 - y0) / (pmax - pmin)
    b = y0 - a * pmax

    def py(p: float) -> int:
        return int(round(a * p + b))

    # grid + axis labels (right side)
    n_labels = 8
    for i in range(n_labels + 1):
        p = pmin + (pmax - pmin) * i / n_labels
        y = py(p)
        if grid:
            cv2.line(img, (x0, y), (x1, y), st["grid"], 1)
        if axis_labels:
            cv2.putText(img, f"{p:.{decimals}f}", (x1 + 10, y + 5), cv2.FONT_HERSHEY_SIMPLEX, 0.5, st["text"], 1,
                        cv2.LINE_AA)
    if grid:
        for gx in range(x0, x1, 120):
            cv2.line(img, (gx, y0), (gx, y1), st["grid"], 1)
    if title:
        cv2.putText(img, title, (x0 + 4, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.7, st["text"], 2, cv2.LINE_AA)

    n = len(ohlc)
    slot = (x1 - x0) / n
    body_w = max(3, int(slot * 0.62))
    truth = []
    closes_xy = []
    for i, (o, h, low, c) in enumerate(ohlc):
        cx = int(x0 + slot * (i + 0.5))
        bull = c >= o
        col = st["bull"] if bull else st["bear"]
        cv2.line(img, (cx, py(h)), (cx, py(low)), col, 1)
        top, bot = py(max(o, c)), py(min(o, c))
        if bot - top < 1:
            bot = top + 1
        left = cx - body_w // 2
        cv2.rectangle(img, (left, top), (left + body_w - 1, bot), col, -1)
        truth.append({"x": cx, "y_high": py(h), "y_low": py(low), "y_open": py(o), "y_close": py(c),
                      "bullish": bull})
        closes_xy.append((cx, py(c)))

    if ma_overlay and n >= 5:
        closes = np.array([c[3] for c in ohlc])
        ma = np.convolve(closes, np.ones(5) / 5, mode="valid")
        pts = np.array([(closes_xy[i + 4][0], py(v)) for i, v in enumerate(ma)], dtype=np.int32)
        cv2.polylines(img, [pts], False, (255, 160, 40), 2, cv2.LINE_AA)  # blue-ish MA line

    if price_tag:
        last = ohlc[-1]
        col = st["bull"] if last[3] >= last[0] else st["bear"]
        y = py(last[3])
        cv2.rectangle(img, (x1 + 2, y - 10), (width - 2, y + 10), col, -1)
        cv2.putText(img, f"{last[3]:.{decimals}f}", (x1 + 8, y + 5), cv2.FONT_HERSHEY_SIMPLEX, 0.5,
                    (255, 255, 255), 1, cv2.LINE_AA)

    return SyntheticChart(img, list(ohlc), truth, (a, b), (x0, y0, x1, y1))


def degrade(img: np.ndarray, *, jpeg_quality: int | None = None, noise_sigma: float = 0.0,
            blur_ksize: int = 0, scale: float = 1.0, seed: int = 0) -> np.ndarray:
    out = img.copy()
    if scale != 1.0:
        out = cv2.resize(out, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    if blur_ksize:
        out = cv2.GaussianBlur(out, (blur_ksize, blur_ksize), 0)
    if noise_sigma:
        rng = np.random.default_rng(seed)
        out = np.clip(out.astype(np.float32) + rng.normal(0, noise_sigma, out.shape), 0, 255).astype(np.uint8)
    if jpeg_quality:
        ok, buf = cv2.imencode(".jpg", out, [cv2.IMWRITE_JPEG_QUALITY, jpeg_quality])
        out = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    return out


def uptrend_ohlc(n: int = 80, seed: int = 3) -> list[tuple]:
    """A clear uptrend whose last closed candle is bullish (test fixture for the decision engine)."""
    rng = np.random.default_rng(seed)
    rows, p = [], 1.1
    for i in range(n):
        o = p
        c = o + abs(rng.normal(0.0006, 0.0004)) if i % 5 else o - 0.0003
        rows.append((o, max(o, c) + 0.0003, min(o, c) - 0.0003, c))
        p = c
    o = rows[-2][0]
    rows[-2] = (o, max(rows[-2][1], o + 0.0008), rows[-2][2], o + 0.0007)
    return rows
