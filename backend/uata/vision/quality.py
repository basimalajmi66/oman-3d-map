"""Image quality assessment: decides whether a chart image is clear enough to read."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field

import cv2
import numpy as np


@dataclass
class ImageQuality:
    width: int
    height: int
    sharpness: float        # variance of the Laplacian (higher = sharper)
    contrast: float         # std-dev of grey levels
    score: float            # 0..1 combined image score (before candle detection)
    issues: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


def _ramp(value: float, bad: float, good: float) -> float:
    """0 at/below ``bad``, 1 at/above ``good``, linear in between."""
    if value <= bad:
        return 0.0
    if value >= good:
        return 1.0
    return (value - bad) / (good - bad)


def assess_image(img: np.ndarray) -> ImageQuality:
    h, w = img.shape[:2]
    grey = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    sharp = float(cv2.Laplacian(grey, cv2.CV_64F).var())
    contrast = float(grey.std())
    issues = []
    q_res = _ramp(min(w, h), 200, 450)
    # calibrated on synthetic charts: 3-5 px blur still reads accurately, >=9 px does not
    q_sharp = _ramp(sharp, 8, 120)
    q_con = _ramp(contrast, 8, 30)
    if q_res < 1:
        issues.append("low_resolution")
    if q_sharp < 0.5:
        issues.append("blurry")
    if q_con < 0.5:
        issues.append("low_contrast")
    score = float(round(min(q_res, 1.0) * 0.3 + q_sharp * 0.45 + q_con * 0.25, 3))
    return ImageQuality(w, h, round(sharp, 1), round(contrast, 1), score, issues)
