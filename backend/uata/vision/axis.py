"""Price-axis and timeframe reading with OCR (Tesseract, fully local).

Prices are only reported when the axis can be read *and* the labels are
consistent with a linear scale. Otherwise the reading stays in relative
(pixel) units and says so — prices are never guessed.
"""

from __future__ import annotations

import re
import shutil
from dataclasses import asdict, dataclass

import cv2
import numpy as np

try:  # optional dependency: without it the reader works in relative units
    import pytesseract
except ImportError:  # pragma: no cover
    pytesseract = None

NUM_RE = re.compile(r"^-?\d{1,7}(?:[.,]\d{1,8})?$")
TF_RE = re.compile(r"(?<![\w.])(\d{1,3})\s*(s|sec|secs|m|min|mins|h|hr|d|D|w|W)(?![\w])|(?<![\w])([MHDW])(\d{1,3})(?![\w])")
TF_UNIT_SEC = {"s": 1, "sec": 1, "secs": 1, "m": 60, "min": 60, "mins": 60, "h": 3600, "hr": 3600,
               "d": 86400, "D": 86400, "w": 604800, "W": 604800}


def _locate_tesseract() -> str | None:
    """PATH, then UATA_TESSERACT, then the default Windows installer location."""
    import os
    for cand in (os.environ.get("UATA_TESSERACT"), shutil.which("tesseract"),
                 r"C:\Program Files\Tesseract-OCR\tesseract.exe",
                 r"C:\Program Files (x86)\Tesseract-OCR\tesseract.exe"):
        if cand and os.path.isfile(cand):
            return cand
    return None


_TESSERACT = _locate_tesseract()
if pytesseract is not None and _TESSERACT:
    pytesseract.pytesseract.tesseract_cmd = _TESSERACT


def ocr_available() -> bool:
    return pytesseract is not None and _TESSERACT is not None


@dataclass
class PriceScale:
    slope: float          # price = slope * y + intercept
    intercept: float
    labels_used: int
    r2: float
    decimals: int
    side: str             # 'right' | 'left'

    def price(self, y: float) -> float:
        return round(self.slope * y + self.intercept, self.decimals + 1)

    def to_dict(self) -> dict:
        return asdict(self)


def _prep(crop: np.ndarray, scale: int = 3) -> np.ndarray:
    g = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
    g = cv2.resize(g, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
    if g.mean() < 128:  # dark theme: make text dark on light
        g = 255 - g
    _, th = cv2.threshold(g, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    return th


def _labels(crop: np.ndarray, scale: int = 3) -> list[tuple[float, float, int]]:
    """OCR numeric labels in a crop → [(y_centre_in_crop, value, decimals)]."""
    data = pytesseract.image_to_data(_prep(crop, scale), config="--psm 11 -c tessedit_char_whitelist=0123456789.,-",
                                     output_type=pytesseract.Output.DICT)
    out = []
    for text, top, height, conf in zip(data["text"], data["top"], data["height"], data["conf"]):
        t = text.strip().replace(",", ".")
        if not t or not NUM_RE.match(t) or float(conf) < 30:
            continue
        dec = len(t.split(".")[1]) if "." in t else 0
        out.append(((top + height / 2) / scale, float(t), dec))
    return out


def _fit(points: list[tuple[float, float, int]]) -> tuple[float, float, float] | None:
    if len(points) < 3:
        return None
    ys = np.array([p[0] for p in points])
    vs = np.array([p[1] for p in points])
    if np.ptp(ys) < 20:
        return None
    slope, intercept = np.polyfit(ys, vs, 1)
    pred = slope * ys + intercept
    ss_res = float(((vs - pred) ** 2).sum())
    ss_tot = float(((vs - vs.mean()) ** 2).sum()) or 1e-12
    return float(slope), float(intercept), 1 - ss_res / ss_tot


def read_price_scale(img: np.ndarray, plot_left: int, plot_right: int) -> tuple[PriceScale | None, dict]:
    """Try the strip right of the candles, then left of them. Robust to OCR outliers."""
    diag: dict = {"ocr": ocr_available()}
    if not ocr_available():
        return None, diag
    h, w = img.shape[:2]
    candidates = []
    if w - plot_right > 25:
        candidates.append(("right", img[:, plot_right + 3:]))
    if plot_left > 25:
        candidates.append(("left", img[:, :max(1, plot_left - 3)]))
    for side, crop in candidates:
        pts = _labels(crop)
        diag[f"{side}_labels"] = len(pts)
        # iteratively drop the worst outlier until the fit is near-perfect
        while len(pts) >= 3:
            fit = _fit(pts)
            if fit is None:
                break
            slope, intercept, r2 = fit
            if slope < 0 and r2 >= 0.9995:  # prices rise upwards
                decimals = max(p[2] for p in pts)
                return PriceScale(slope, intercept, len(pts), round(r2, 6), decimals, side), diag
            resid = [abs(p[1] - (slope * p[0] + intercept)) for p in pts]
            pts.pop(int(np.argmax(resid)))
    return None, diag


def read_timeframe(img: np.ndarray) -> tuple[int | None, str | None]:
    """Look for a timeframe label (e.g. '30s', '1m', 'M5', 'H1') in the top strip of the chart."""
    if not ocr_available():
        return None, None
    h = img.shape[0]
    strip = img[: max(30, h // 8)]
    text = pytesseract.image_to_string(_prep(strip, 2), config="--psm 6")
    for m in TF_RE.finditer(text):
        if m.group(1):
            n, unit = int(m.group(1)), m.group(2)
        else:
            unit, n = m.group(3), int(m.group(4))
            unit = {"M": "m", "H": "h", "D": "d", "W": "w"}[unit]
        if n == 0:
            continue
        return n * TF_UNIT_SEC[unit], m.group(0).strip()
    return None, None
