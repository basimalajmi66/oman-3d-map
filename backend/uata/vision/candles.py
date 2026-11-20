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
    candles, diag = _finish(raw, diag, bull_m, bear_m, min_h, open_h)
    if diag["dropped_wide"] >= OVERLAY_TRIGGER:
        # many wide blobs: indicator lines / labels in the candle colours glue candles together (SuperTrend,
        # signal labels). Read again body-first and keep that reading only when it is clearly more consistent.
        widths = [c.right - c.left + 1 for c in raw if c.body_resolved]
        med_w = float(np.median(widths)) if widths else 1.0
        alt_raw = _bodies_first(bull_m, bear_m, bull_l, bear_l, med_w, spacing, h_img)
        if alt_raw:
            alt_diag = dict(diag, raw_components=len(alt_raw), dropped_wide=0, dropped_label_runs=0)
            alt, alt_diag = _finish(alt_raw, alt_diag, bull_m, bear_m, min_h, open_h)
            alt_sp = float(np.median(np.diff([c.x for c in alt]))) if len(alt) >= 3 else 0.0
            if (alt_sp > 0 and len(alt) >= 1.15 * len(candles)
                    and missing_slots([c.x for c in alt], alt_sp) < missing_slots([c.x for c in candles], alt_sp)):
                alt_diag["mode"] = "bodies_first"
                alt_diag["first_pass_candles"] = len(candles)
                return alt, alt_diag
    return candles, diag


OVERLAY_TRIGGER = 3


def _open_rect(mask: np.ndarray, kw: int, kh: int) -> np.ndarray:
    return cv2.morphologyEx(mask, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_RECT, (kw, kh)))


def _bodies_first(bull_m, bear_m, bull_l, bear_l, med_w: float, sp: float, h_img: int) -> list[DetectedCandle]:
    """Candles from their bodies: a k×k opening (k = half a body) erases lines thinner than k in every direction
    (indicator lines, wicks) and keeps bodies; wicks are then followed up and down from the body centre."""
    k = max(3, int(med_w * 0.5))
    opened = []
    for mask, loose, bullish in ((bull_m, bull_l, True), (bear_m, bear_l, False)):
        n, labels, stats, _ = cv2.connectedComponentsWithStats(_open_rect(mask, k, k), connectivity=8)
        opened.append((n, labels, stats, loose, bullish))
    # the candle spacing, measured on the bodies themselves (the first reading's spacing is unreliable here)
    centres = sorted(int(st[0]) + int(st[2]) // 2 for n, _, stats, _, _ in opened for st in stats[1:n]
                     if k <= st[2] <= 2.2 * med_w)
    if len(centres) >= 5:
        sp = float(np.median(np.diff(centres)))
        sp = max(sp, float(k))
    # label boxes (price tags, BUY/SELL labels, buttons) split by their text would look like narrow bodies: erase
    # them first. They are the only shapes with horizontal runs longer than two candle slots.
    opened = []
    for mask, loose, bullish in ((bull_m, bull_l, True), (bear_m, bear_l, False)):
        boxes = _label_boxes(mask, sp)
        if boxes:
            mask, loose = mask.copy(), loose.copy()
            for x, y, w, h in boxes:
                mask[y:y + h, x:x + w] = 0
                loose[y:y + h, x:x + w] = 0
        n, labels, stats, _ = cv2.connectedComponentsWithStats(_open_rect(mask, k, k), connectivity=8)
        opened.append((n, labels, stats, loose, bullish))
    out: list[DetectedCandle] = []
    for n, labels, stats, loose, bullish in opened:
        loose_b = loose > 0
        bodies = []
        for i in range(1, n):
            x, y, w, h, _a = (int(v) for v in stats[i])
            if k <= w <= 1.3 * sp:
                bodies.append(_trim_rows(labels[y:y + h, x:x + w] == i, x, y))
            elif w > 1.3 * sp and h >= w:
                # a body with a thick piece of line still attached (or two bodies joined by one): taller than wide,
                # unlike labels and buttons. Keep the body columns (at least half the tallest column).
                m = labels[y:y + h, x:x + w] == i
                cols = m.sum(axis=0)
                strong = cols >= 0.5 * cols.max()
                j = 0
                while j < w:
                    if not strong[j]:
                        j += 1
                        continue
                    e = j
                    while e + 1 < w and strong[e + 1]:
                        e += 1
                    if k <= e - j + 1 <= 1.3 * sp:
                        bodies.append(_trim_rows(m[:, j:e + 1], x + j, y))
                    j = e + 1
            # else: labels, buttons, price tags — wider than a candle slot
        for x, y, w, h in bodies:
            cx = x + w // 2
            y_high = _extend(loose_b, cx, y, -1)
            y_low = _extend(loose_b, cx, y + h - 1, +1)
            y_open, y_close = (y + h - 1, y) if bullish else (y, y + h - 1)
            out.append(DetectedCandle(cx, x, x + w - 1, y_high, y_low, y_open, y_close, bullish, True))
    out.sort(key=lambda c: c.x)
    # far from its neighbours vertically = not part of the price path (avatars, icons, buttons in candle colours)
    keep = []
    for i, c in enumerate(out):
        nb = [(o.y_high + o.y_low) / 2 for o in out[max(0, i - 4):i] + out[i + 1:i + 5]]
        if nb and abs((c.y_high + c.y_low) / 2 - float(np.median(nb))) > 0.2 * h_img:
            continue
        keep.append(c)
    # two bodies inside one candle slot: a thick piece of an indicator line next to a candle → keep the taller
    grid: list[DetectedCandle] = []
    for c in keep:
        if grid and c.x - grid[-1].x < 0.6 * sp:
            if c.y_low - c.y_high > grid[-1].y_low - grid[-1].y_high:
                grid[-1] = c
            continue
        grid.append(c)
    # stray shapes far beyond either end of the candle row (icons, buttons)
    while len(grid) >= 5 and grid[-1].x - grid[-2].x > 5 * sp:
        grid.pop()
    while len(grid) >= 5 and grid[1].x - grid[0].x > 5 * sp:
        grid.pop(0)
    if len(grid) < 5:
        return grid
    # flat candles (body shorter than k) were erased with the lines: look for a k-wide, >= 2 px tall body in each
    # empty grid slot (flat line pieces span several slots, so they are too wide to be taken)
    flats = []
    for mask, loose, bullish in ((bull_m, bull_l, True), (bear_m, bear_l, False)):
        n, _, stats, _ = cv2.connectedComponentsWithStats(_open_rect(mask, k, 2), connectivity=8)
        for i in range(1, n):
            x, y, w, h, _a = (int(v) for v in stats[i])
            if k <= w <= 1.3 * sp and h < k:
                flats.append((x, y, w, h, bullish, loose > 0))
    filled: list[DetectedCandle] = []
    for a, b in zip(grid, grid[1:]):
        filled.append(a)
        gap = b.x - a.x
        slots = int(gap / sp + 0.5) - 1
        if gap <= 1.5 * sp or slots < 1:
            continue
        lo_y = min(a.y_high, b.y_high) - 3 * sp
        hi_y = max(a.y_low, b.y_low) + 3 * sp
        for j in range(1, slots + 1):
            want = a.x + gap * j / (slots + 1)
            best = None
            for f in flats:
                fx = f[0] + f[2] // 2
                if abs(fx - want) <= 0.35 * sp and lo_y <= f[1] and f[1] + f[3] <= hi_y:
                    if best is None or abs(fx - want) < abs(best[0] + best[2] // 2 - want):
                        best = f
            if best is not None:
                x, y, w, h, bullish, loose_b = best
                cx = x + w // 2
                y_open, y_close = (y + h - 1, y) if bullish else (y, y + h - 1)
                filled.append(DetectedCandle(cx, x, x + w - 1, _extend(loose_b, cx, y, -1),
                                             _extend(loose_b, cx, y + h - 1, +1), y_open, y_close, bullish, True))
    filled.append(grid[-1])
    return filled


def _label_boxes(mask: np.ndarray, sp: float) -> list[tuple[int, int, int, int]]:
    """Boxes made of horizontal runs longer than 2 candle slots, grouped across the text rows that break them."""
    min_run = int(2 * sp) + 1
    on = mask > 0
    runs = np.zeros_like(mask)
    for yy in range(on.shape[0]):
        row = on[yy]
        if row.sum() < min_run:
            continue
        xx = 0
        n = row.shape[0]
        while xx < n:
            if not row[xx]:
                xx += 1
                continue
            e = xx
            while e + 1 < n and row[e + 1]:
                e += 1
            if e - xx + 1 >= min_run:
                runs[yy, xx:e + 1] = 255
            xx = e + 1
    nb, _, stats, _ = cv2.connectedComponentsWithStats(runs, connectivity=8)
    parts = sorted((int(st[1]), int(st[0]), int(st[2]), int(st[3])) for st in stats[1:nb])  # (y, x, w, h)
    groups: list[list[int]] = []  # [x0, y0, x1, y1]
    for y, x, w, h in parts:
        for g in groups:
            overlap = min(g[2], x + w - 1) - max(g[0], x) + 1
            if overlap >= 0.5 * min(g[2] - g[0] + 1, w) and y - g[3] - 1 <= 1.5 * sp:
                g[0], g[1], g[2], g[3] = min(g[0], x), min(g[1], y), max(g[2], x + w - 1), max(g[3], y + h - 1)
                break
        else:
            groups.append([x, y, x + w - 1, y + h - 1])
    return [(g[0], g[1], g[2] - g[0] + 1, g[3] - g[1] + 1) for g in groups if g[3] - g[1] + 1 >= 5]


def _trim_rows(m: np.ndarray, x: int, y: int) -> tuple[int, int, int, int]:
    """Body box of a component: only rows at least 80% as wide as the widest row (a line touching the top or bottom
    of the body adds narrower rows)."""
    widths = m.sum(axis=1)
    full = np.nonzero(widths >= 0.8 * widths.max())[0]
    return x, y + int(full[0]), m.shape[1], int(full[-1]) - int(full[0]) + 1


def missing_slots(xs: list[int], sp: float | None = None) -> int:
    """Empty grid slots between detected candles (the reader's rule), on the given or their own spacing."""
    if len(xs) < 3:
        return 0
    gaps = np.diff(xs)
    sp = float(np.median(gaps)) if sp is None else sp
    return int(sum(max(0, int(g / sp + 0.5) - 1) for g in gaps if g > 1.5 * sp))


def _finish(raw: list[DetectedCandle], diag: dict, bull_m, bear_m, min_h: int, open_h: int):
    """Common clean-up of a raw candle list: wide boxes, tiny candles, duplicates, label boxes and fragments."""
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
