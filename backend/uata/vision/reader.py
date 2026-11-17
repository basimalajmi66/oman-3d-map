"""ChartReader: image → structured, honest chart reading.

Output contract (``ChartReading.to_dict()``):

* ``usable``          — False means *do not analyse*: the reader abstains and says why.
* ``data_quality``    — 0..1, combines image quality and detection consistency.
* ``candles``         — left→right; geometry in pixels, relative values 0..1, and real
                        prices **only** when the price axis was read reliably.
* ``price_scale``     — the OCR'd linear axis, or ``None`` ("relative units only").
* ``last_candle``     — the right-most candle is treated as *possibly still forming*:
                        an image alone cannot prove it has closed, so it is excluded
                        from ``closed_candles``.
* ``data_basis``      — always ``image_only`` for this reader.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np

from uata.vision.axis import PriceScale, ocr_available, read_price_scale, read_timeframe
from uata.vision.candles import DetectedCandle, detect_candles
from uata.vision.quality import assess_image

READER_VERSION = "1.0"
MIN_CANDLES = 10


@dataclass
class ChartReading:
    usable: bool
    abstain_reasons: list[str]
    data_quality: float
    image: dict
    detection: dict
    candles: list[dict] = field(default_factory=list)
    price_scale: dict | None = None
    timeframe_sec: int | None = None
    timeframe_label: str | None = None
    missing_slots: int = 0
    warnings: list[str] = field(default_factory=list)
    reader_version: str = READER_VERSION
    data_basis: str = "image_only"

    @property
    def closed_candles(self) -> list[dict]:
        return self.candles[:-1]

    def summary(self) -> dict:
        closed = self.closed_candles
        last_closed = closed[-1] if closed else None
        return {
            "usable": self.usable,
            "abstain_reasons": self.abstain_reasons,
            "data_quality": self.data_quality,
            "candles": len(self.candles),
            "closed_candles": len(closed),
            "bullish": sum(1 for c in closed if c["bullish"]),
            "bearish": sum(1 for c in closed if not c["bullish"]),
            "last_closed_direction": None if last_closed is None else ("up" if last_closed["bullish"] else "down"),
            "last_closed_close": None if last_closed is None else last_closed.get("close"),
            "forming_direction": None if not self.candles else ("up" if self.candles[-1]["bullish"] else "down"),
            "prices_read": self.price_scale is not None,
            "timeframe_sec": self.timeframe_sec,
            "timeframe_label": self.timeframe_label,
            "missing_slots": self.missing_slots,
            "theme": self.detection.get("theme"),
            "warnings": self.warnings,
        }

    def to_dict(self) -> dict:
        return {
            "usable": self.usable, "abstain_reasons": self.abstain_reasons, "data_quality": self.data_quality,
            "image": self.image, "detection": self.detection, "candles": self.candles,
            "price_scale": self.price_scale, "timeframe_sec": self.timeframe_sec,
            "timeframe_label": self.timeframe_label, "missing_slots": self.missing_slots,
            "warnings": self.warnings, "reader_version": self.reader_version, "data_basis": self.data_basis,
            "summary": self.summary(),
        }


def _candle_dict(c: DetectedCandle, i: int, n: int, y_top: int, y_bot: int, scale: PriceScale | None) -> dict:
    span = max(1, y_bot - y_top)

    def rel(y: int) -> float:  # 1.0 = highest point on the chart, 0.0 = lowest
        return round(1 - (y - y_top) / span, 4)

    d = {
        "index": i, "x": int(c.x), "left": int(c.left), "right": int(c.right),
        "y_high": int(c.y_high), "y_low": int(c.y_low), "y_open": int(c.y_open), "y_close": int(c.y_close),
        "rel_high": rel(c.y_high), "rel_low": rel(c.y_low), "rel_open": rel(c.y_open), "rel_close": rel(c.y_close),
        "bullish": bool(c.bullish), "body_resolved": bool(c.body_resolved),
        "status": "possibly_forming" if i == n - 1 else "closed",
    }
    if scale is not None:
        d.update(high=scale.price(c.y_high), low=scale.price(c.y_low),
                 open=scale.price(c.y_open), close=scale.price(c.y_close))
    return d


class ChartReader:
    def __init__(self, min_quality: float = 0.6, use_ocr: bool = True):
        self.min_quality = min_quality
        self.use_ocr = use_ocr

    def read(self, img: np.ndarray) -> ChartReading:
        iq = assess_image(img)
        candles, diag = detect_candles(img)
        reasons: list[str] = []
        warnings: list[str] = list(iq.issues)

        # --- detection consistency
        missing = 0
        q_det = 0.0
        if len(candles) >= 3:
            xs = np.array([c.x for c in candles])
            gaps = np.diff(xs)
            sp = float(np.median(gaps))
            missing = int(sum(max(0, round(g / sp) - 1) for g in gaps if g > 1.5 * sp))
            resolved = np.mean([c.body_resolved for c in candles])
            q_spacing = max(0.0, 1 - diag.get("spacing_cv", 1.0) * 2)
            q_missing = max(0.0, 1 - missing / max(1, len(candles)) * 5)
            q_det = float(min(q_spacing, 1.0) * 0.4 + resolved * 0.3 + q_missing * 0.3)
            if missing:
                warnings.append("missing_candle_slots")
            if resolved < 0.9:
                warnings.append("bodies_not_resolved")

        if diag["bull_pixels"] + diag["bear_pixels"] < 200:
            reasons.append("no_candles_found_or_unsupported_colours")
        elif len(candles) < MIN_CANDLES:
            reasons.append("too_few_candles")
        # the weaker of image quality and detection consistency dominates: a blurry image
        # with a regular candle grid is still a blurry image
        weak, mean = min(iq.score, q_det), (iq.score + q_det) / 2
        quality = round(float(weak * 0.6 + mean * 0.4), 3) if candles else 0.0
        if quality < self.min_quality:
            reasons.append("image_quality_below_threshold")

        scale = None
        tf_sec = tf_label = None
        if candles and self.use_ocr:
            plot_left = min(c.left for c in candles)
            plot_right = max(c.right for c in candles)
            ps, axis_diag = read_price_scale(img, plot_left, plot_right)
            diag["axis"] = axis_diag
            scale = ps
            tf_sec, tf_label = read_timeframe(img)
        if candles and scale is None:
            warnings.append("price_axis_not_read_relative_units_only" if ocr_available() or not self.use_ocr
                            else "ocr_not_installed_relative_units_only")

        y_top = min((c.y_high for c in candles), default=0)
        y_bot = max((c.y_low for c in candles), default=1)
        cds = [_candle_dict(c, i, len(candles), y_top, y_bot, scale) for i, c in enumerate(candles)]
        return ChartReading(
            usable=not reasons, abstain_reasons=reasons, data_quality=quality, image=iq.to_dict(),
            detection={k: (list(v) if isinstance(v, tuple) else v) for k, v in diag.items()},
            candles=cds, price_scale=scale.to_dict() if scale else None,
            timeframe_sec=tf_sec, timeframe_label=tf_label, missing_slots=missing, warnings=warnings,
        )


def annotate(img: np.ndarray, reading: dict) -> np.ndarray:
    """Draw what was detected so the user can verify the reading visually."""
    out = img.copy()
    for c in reading.get("candles", []):
        col = (0, 255, 0) if c["bullish"] else (0, 0, 255)
        if c["status"] == "possibly_forming":
            col = (0, 200, 255)
        cv2.rectangle(out, (c["left"] - 1, min(c["y_open"], c["y_close"]) - 1),
                      (c["right"] + 1, max(c["y_open"], c["y_close"]) + 1), col, 1)
        cv2.line(out, (c["x"], c["y_high"]), (c["x"], c["y_low"]), (255, 255, 0), 1)
    label = f"candles={len(reading.get('candles', []))} q={reading.get('data_quality', 0):.2f}"
    label += " prices=yes" if reading.get("price_scale") else " prices=no"
    cv2.putText(out, label, (8, out.shape[0] - 8), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 255), 1, cv2.LINE_AA)
    return out
