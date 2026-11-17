"""Synthetic educational video with known content and timings (test fixture only)."""

from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np

from uata.vision.synthetic import random_walk_ohlc, render_chart


def slide(text_lines: list[str], size=(1280, 720)) -> np.ndarray:
    img = np.full((size[1], size[0], 3), 255, np.uint8)
    y = 200
    for line in text_lines:
        cv2.putText(img, line, (60, y), cv2.FONT_HERSHEY_SIMPLEX, 1.6, (20, 20, 20), 3, cv2.LINE_AA)
        y += 90
    return img


def uptrend_chart(size=(1280, 720)) -> np.ndarray:
    ohlc = []
    p = 1.1
    rng = np.random.default_rng(3)
    for _ in range(60):
        o = p
        c = o + abs(rng.normal(0.0006, 0.0004))
        ohlc.append((o, max(o, c) + 0.0003, min(o, c) - 0.0003, c))
        p = c
    return render_chart(ohlc, style="dark_tv", width=size[0], height=size[1]).image


SCENES = [  # (start_s, end_s, kind, content)
    (0, 4, "slide", ["RSI Reversal Strategy"]),
    (4, 10, "slide", ["When RSI is oversold at support,", "buy for 2 min."]),
    (10, 16, "chart", None),
    (16, 21, "slide", ["Do not enter when big news", "is expected."]),
]

SRT = """1
00:00:00,500 --> 00:00:03,500
Welcome, today we learn the RSI reversal strategy.

2
00:00:04,000 --> 00:00:09,000
إذا كان مؤشر القوة النسبية في التشبع البيعي عند الدعم فادخل شراء لمدة دقيقتين.

3
00:00:10,500 --> 00:00:15,500
Here the trend is up, so we only look for buys.

4
00:00:16,500 --> 00:00:20,000
Exit the trade when price reaches resistance.
"""


def write_video(path: Path, fps: int = 5) -> Path:
    w = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"), fps, (1280, 720))
    for start, end, kind, content in SCENES:
        frame = slide(content) if kind == "slide" else uptrend_chart()
        for _ in range((end - start) * fps):
            w.write(frame)
    w.release()
    return path
