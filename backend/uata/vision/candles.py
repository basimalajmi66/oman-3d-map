"""Candlestick detection from a chart image (platform independent).

Approach (classical computer vision, no learned model — every step is explainable):

1. Estimate the background colour (most frequent quantised colour) → dark/light theme.
2. Build two colour masks in HSV: *bullish* hues (green → teal) and *bearish*
   hues (red → magenta), keeping only saturated pixels. Grey grid lines and text
   are excluded by the saturation threshold; other overlay colours (blue/yellow
   moving averages, etc.) fall outside both hue bands.
3. Morphological opening with a vertical kernel removes thin, near-horizontal
   structures (overlay lines) while keeping wicks and bodies, which are tall.
4. Connected components per mask; components of the same colour that overlap in
   x are merged (a wick cut by an overlay line).
5. Per component: high = top row, low = bottom row; the body is the band of rows
   whose width is close to the widest row. Bullish: open = body bottom,
   close = body top; bearish the opposite.
6. Outliers are dropped: components much wider than the typical candle (price
   tags on the axis, legends) and tiny specks.

Limits (reported, not hidden): a candle whose body is completely covered by an
overlay line of another colour cannot be seen; monochrome / hollow candle styles, heikin-ashi
colour schemes that are not green/red, and candles narrower than 3 px cannot be
read reliably; those cases lower the quality score or make the reader abstain.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

import cv2
import numpy as np

SAT_MIN = 70
VAL_MIN = 60
# OpenCV hue range is 0..179
BULL_HUES = (35, 93)           # green .. teal (blue overlays start ~100)
BEAR_HUES_LOW = (0, 12)        # red
BEAR_HUES_HIGH = (160, 179)    # red/magenta wrap-around


@dataclass
class DetectedCandle:
    x: int            # centre column (px)
    left: int
    right: int
    y_high: int
    y_low: int
    y_open: int
    y_close: int
    bullish: bool
    body_resolved: bool   # False when body and wick have the same width (cannot separate)

    def to_dict(self) -> dict:
        return asdict(self)


def background_color(img: np.ndarray) -> tuple[int, int, int]:
    small = cv2.resize(img, (min(200, img.shape[1]), min(120, img.shape[0])), interpolation=cv2.INTER_NEAREST)
    q = (small // 16).reshape(-1, 3)
    vals, counts = np.unique(q, axis=0, return_counts=True)
    b, g, r = (vals[counts.argmax()] * 16 + 8).tolist()
    return int(b), int(g), int(r)


def colour_masks(img: np.ndarray, sat_min: int = SAT_MIN, val_min: int = VAL_MIN) -> tuple[np.ndarray, np.ndarray]:
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    chroma = (s >= sat_min) & (v >= val_min)
    bull = chroma & (h >= BULL_HUES[0]) & (h <= BULL_HUES[1])
    bear = chroma & (((h >= BEAR_HUES_LOW[0]) & (h <= BEAR_HUES_LOW[1])) |
                     ((h >= BEAR_HUES_HIGH[0]) & (h <= BEAR_HUES_HIGH[1])))
    return bull.astype(np.uint8) * 255, bear.astype(np.uint8) * 255


def _clean(mask: np.ndarray, open_h: int) -> np.ndarray:
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (1, open_h))
    return cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)


def _components(mask: np.ndarray, min_h: int) -> list[tuple[int, int, int, int, np.ndarray]]:
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    out = []
    for i in range(1, n):
        x, y, w, h, area = stats[i]
        if h < min_h or area < 3:
            continue
        out.append((x, y, w, h, (labels[y:y + h, x:x + w] == i)))
    return out


def _merge_same_column(comps):
    """Merge components whose x-ranges overlap strongly (wick split by an overlay line)."""
    comps = sorted(comps, key=lambda c: c[0])
    merged: list[list] = []
    for x, y, w, h, m in comps:
        if merged:
            px, py, pw, ph, pm = merged[-1]
            overlap = min(px + pw, x + w) - max(px, x)
            v_overlap = min(py + ph, y + h) - max(py, y)
            # strong x-overlap (wick cut by a line) or a body sliced by a line drawn across it
            if overlap >= 0.5 * min(pw, w) or (overlap >= -2 and v_overlap >= 0.5 * min(ph, h) and min(pw, w) <= 2):
                nx, ny = min(px, x), min(py, y)
                nw, nh = max(px + pw, x + w) - nx, max(py + ph, y + h) - ny
                nm = np.zeros((nh, nw), dtype=bool)
                nm[py - ny:py - ny + ph, px - nx:px - nx + pw] |= pm
                nm[y - ny:y - ny + h, x - nx:x - nx + w] |= m
                merged[-1] = [nx, ny, nw, nh, nm]
                continue
        merged.append([x, y, w, h, m])
    return merged


MAX_WICK_GAP = 4


def _extend(orig: np.ndarray, col: int, y: int, step: int) -> int:
    """Follow the wick column beyond ``y`` across gaps of at most MAX_WICK_GAP px."""
    h, w = orig.shape
    cols = [c for c in (col - 1, col, col + 1) if 0 <= c < w]
    best, gap, yy = y, 0, y + step
    while 0 <= yy < h and gap <= MAX_WICK_GAP:
        if orig[yy, cols].any():
            best, gap = yy, 0
        else:
            gap += 1
        yy += step
    return best


def _measure(orig: np.ndarray, loose: np.ndarray, x: int, y: int, w: int, h: int, m: np.ndarray,
             lo_col: int, hi_col: int, bullish: bool) -> DetectedCandle:
    """Measure geometry on the *original* mask around the wick found in the cleaned mask.

    Rows are measured as the contiguous run of colour pixels that contains the wick
    column, limited to [lo_col, hi_col] (half-way to the neighbours), so a short
    body that the vertical opening removed is recovered and nearby objects
    (price tags, neighbours) are not counted.
    """
    rows = np.nonzero(m.any(axis=1))[0]
    y_high, y_low = y + int(rows[0]), y + int(rows[-1])
    col_counts = m.sum(axis=0)
    wick = x + int(col_counts.argmax())
    # bridge short gaps where an overlay (moving average, cross-hair) is drawn over the wick
    # thin wicks lose saturation in JPEG/scaled images: follow them on the looser mask
    y_high = _extend(loose, wick, y_high, -1)
    y_low = _extend(loose, wick, y_low, +1)
    run_l = np.full(y_low - y_high + 1, wick)
    run_r = np.full(y_low - y_high + 1, wick)
    for k, yy in enumerate(range(y_high, y_low + 1)):
        row = orig[yy]
        if not row[wick]:
            continue
        l = wick
        while l - 1 >= lo_col and row[l - 1]:
            l -= 1
        r = wick
        while r + 1 <= hi_col and row[r + 1]:
            r += 1
        run_l[k], run_r[k] = l, r
    widths = run_r - run_l + 1
    max_w = int(widths.max())
    resolved = max_w >= 3
    if resolved:
        body = np.nonzero(widths >= max(2, 0.6 * max_w))[0]
        b_top, b_bot = y_high + int(body[0]), y_high + int(body[-1])
        left, right = int(run_l[body].min()), int(run_r[body].max())
    else:
        b_top, b_bot, left, right = y_high, y_low, wick, wick
    y_open, y_close = (b_bot, b_top) if bullish else (b_top, b_bot)
    return DetectedCandle((left + right) // 2, left, right, y_high, y_low, y_open, y_close, bullish, resolved)


def detect_candles(img: np.ndarray) -> tuple[list[DetectedCandle], dict]:
    """Return candles sorted left→right plus diagnostics."""
    h_img = img.shape[0]
    bg = background_color(img)
    theme = "dark" if sum(bg) / 3 < 128 else "light"
    bull_m, bear_m = colour_masks(img)
    bull_l, bear_l = colour_masks(img, sat_min=35, val_min=45)
    open_h = max(5, h_img // 120)
    min_h = open_h  # after the opening every remaining structure is at least this tall
    found = []
    for mask, loose, bullish in ((bull_m, bull_l, True), (bear_m, bear_l, False)):
        orig_b, loose_b = mask > 0, loose > 0  # once per mask (was once per candle: 2 full-frame copies each)
        for x, y, w, h, m in _merge_same_column(_components(_clean(mask, open_h), min_h)):
            found.append((x + int(m.sum(axis=0).argmax()), x, y, w, h, m, bullish, orig_b, loose_b))
    found.sort(key=lambda f: f[0])
    # wide boxes in the cleaned mask (price tags, legends) are not candles: a candle
    # body is never wider than the distance between neighbouring candles
    n_found = len(found)
    if len(found) >= 3:
        sp = float(np.median(np.diff([f[0] for f in found])))
        found = [f for f in found if f[3] <= max(3.0, 1.3 * sp)]
    dropped_box = n_found - len(found)
    centres = [f[0] for f in found]
    spacing = float(np.median(np.diff(centres))) if len(centres) >= 3 else 20.0
    reach = max(2, int(spacing * 0.45))
    raw = []
    for i, (cx, x, y, w, h, m, bullish, orig, loose) in enumerate(found):
        lo_col = max(0, cx - reach, (centres[i - 1] + cx) // 2 + 1 if i else 0)
        hi_col = min(img.shape[1] - 1, cx + reach, (centres[i + 1] + cx) // 2 - 1 if i + 1 < len(found) else 10 ** 9)
        raw.append(_measure(orig, loose, x, y, w, h, m, lo_col, hi_col, bullish))
    raw.sort(key=lambda c: c.x)

    diag = {"background_bgr": bg, "theme": theme, "bull_pixels": int(bull_m.sum() // 255),
            "bear_pixels": int(bear_m.sum() // 255), "raw_components": len(raw), "dropped_wide": dropped_box,
            "dropped_label_runs": 0}
    if not raw:
        return [], diag

    widths = np.array([c.right - c.left + 1 for c in raw if c.body_resolved] or [1])
    med_w = float(np.median(widths))
    candles = []
    for c in raw:
        w = c.right - c.left + 1
        if c.body_resolved and w > 2.2 * med_w:
            diag["dropped_wide"] += 1  # price tag / legend box, not a candle
            continue
        candles.append(c)

    # second pass: tiny candles (total range of a few px, quiet markets) are erased by
    # the vertical opening. Recover solid body-shaped blobs from the raw masks that sit
    # in an empty slot of the regular candle grid.
    if len(candles) >= 5:
        sp = float(np.median(np.diff([c.x for c in candles])))
        taken = np.array([c.x for c in candles])
        y_min = min(c.y_high for c in candles) - 2 * sp
        y_max = max(c.y_low for c in candles) + 2 * sp
        x_max = max(c.right for c in candles)
        for mask, bullish in ((bull_m, True), (bear_m, False)):
            n, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
            for i in range(1, n):
                x, y, w, h, area = stats[i]
                cx = x + w // 2
                if not (2 <= h < min_h + open_h and w >= max(2, 0.5 * med_w) and w <= 1.3 * sp):
                    continue
                if y < y_min or y + h > y_max or cx > x_max + sp:
                    continue
                if (labels[y:y + h, x:x + w] == i).sum(axis=1).max() < max(2, 0.5 * med_w):
                    continue  # needs at least one body-wide row (rejects specks and line fragments)
                if np.min(np.abs(taken - cx)) < 0.6 * sp:
                    continue
                m = labels[y:y + h, x:x + w] == i
                col = m.sum(axis=0)
                rows = np.nonzero(m.any(axis=1))[0]
                yh, yl = y + int(rows[0]), y + int(rows[-1])
                wick_rows = np.nonzero(m[:, int(col.argmax())])[0]
                body_rows = np.nonzero(m.sum(axis=1) >= max(2, 0.6 * w))[0]
                bt, bb = (y + int(body_rows[0]), y + int(body_rows[-1])) if len(body_rows) else (yh, yl)
                del wick_rows
                yo, yc = (bb, bt) if bullish else (bt, bb)
                candles.append(DetectedCandle(cx, x, x + w - 1, yh, yl, yo, yc, bullish, True))
                taken = np.append(taken, cx)
                diag["recovered_small"] = diag.get("recovered_small", 0) + 1
        candles.sort(key=lambda c: c.x)

    # same column detected in both colours (rare: anti-aliasing at a doji) → keep the taller one
    dedup: list[DetectedCandle] = []
    for c in candles:
        if dedup and abs(c.x - dedup[-1].x) < max(2, med_w * 0.5):
            if (c.y_low - c.y_high) > (dedup[-1].y_low - dedup[-1].y_high):
                dedup[-1] = c
            continue
        dedup.append(c)

    # runs of >=3 neighbours with identical extent and no wick are a label box split
    # by its text (e.g. the current-price tag), not consecutive candles
    keep = [True] * len(dedup)

    def boxy(c: DetectedCandle) -> bool:
        return min(c.y_open, c.y_close) - c.y_high <= 1 and c.y_low - max(c.y_open, c.y_close) <= 1

    i = 0
    while i < len(dedup):
        j = i
        while (j + 1 < len(dedup) and abs(dedup[j + 1].y_high - dedup[i].y_high) <= 1
               and abs(dedup[j + 1].y_low - dedup[i].y_low) <= 1 and boxy(dedup[j + 1]) and boxy(dedup[i])):
            j += 1
        if j - i + 1 >= 3:
            for k in range(i, j + 1):
                keep[k] = False
            diag["dropped_label_runs"] += j - i + 1
        i = j + 1
    dedup = [c for c, k in zip(dedup, keep) if k]

    # label fragments right after the last candle (the current-price tag cut by its text into 1-2 pieces,
    # typical after downscaling) must not become the "forming" candle. They have no wicks and either sit closer
    # than the candle spacing or are clearly narrower than the candles; a real candle — even a forming one
    # without wicks yet — sits on its own grid slot and has the full body width.
    if len(dedup) >= 5:
        sp = float(np.median(np.diff([c.x for c in dedup])))
        def fragment(c: DetectedCandle, prev: DetectedCandle) -> bool:
            return boxy(c) and ((c.x - prev.x) < 0.9 * sp or (c.right - c.left + 1) < 0.8 * med_w)

        while len(dedup) >= 5 and fragment(dedup[-1], dedup[-2]):
            dedup = dedup[:-1]
            diag["dropped_label_runs"] += 1

    diag["median_body_width"] = med_w
    xs = np.array([c.x for c in dedup])
    if len(xs) >= 3:
        gaps = np.diff(xs)
        diag["median_spacing"] = float(np.median(gaps))
        diag["spacing_cv"] = float(np.std(gaps) / max(1.0, np.mean(gaps)))
    return dedup, diag
