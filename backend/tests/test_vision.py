"""Accuracy of the chart reader, measured against synthetic charts with exact ground truth.

Thresholds encode what was measured during Phase 3 development (see
docs/reports/PHASE_3_REPORT.md); a regression below them fails the build.
"""
import numpy as np
import pytest

from uata.vision import axis
from uata.vision.candles import detect_candles
from uata.vision.quality import assess_image
from uata.vision.reader import ChartReader, annotate
from uata.vision.synthetic import STYLES, degrade, random_walk_ohlc, render_chart


def match(det, truth, scale=1.0):
    """Match detections to truth by x; return (recall, precision, dir_acc, abs pixel errors)."""
    tx = np.array([g["x"] * scale for g in truth])
    sp = np.median(np.diff(tx))
    used, errs, dirs = set(), [], []
    for d in det:
        i = int(np.argmin(np.abs(tx - d.x)))
        if abs(tx[i] - d.x) <= 0.4 * sp and i not in used:
            used.add(i)
            g = truth[i]
            errs.append([abs(getattr(d, k) - g[k] * scale) for k in ("y_high", "y_low", "y_open", "y_close")])
            dirs.append(d.bullish == g["bullish"])
    return len(used) / len(truth), len(used) / max(1, len(det)), float(np.mean(dirs)), np.array(errs)


def corpus(**degrade_kw):
    for style in STYLES:
        for k, n in enumerate((30, 60, 90)):
            ch = render_chart(random_walk_ohlc(n, seed=100 + k * 13 + n), style=style, ma_overlay=k % 2 == 0)
            yield ch, degrade(ch.image, **degrade_kw), degrade_kw.get("scale", 1.0)


@pytest.mark.parametrize("name,kw,min_recall,min_precision,max_mean_px", [
    ("clean", {}, 0.99, 0.995, 0.5),
    ("jpeg70", {"jpeg_quality": 70}, 0.97, 0.98, 2.0),
    ("noise", {"noise_sigma": 6}, 0.99, 0.99, 0.6),
    ("scaled0.7", {"scale": 0.7}, 0.96, 0.98, 1.0),
    ("blur3", {"blur_ksize": 3}, 0.98, 0.98, 1.0),
])
def test_detection_accuracy(name, kw, min_recall, min_precision, max_mean_px):
    recalls, precisions, dirs, errs = [], [], [], []
    for ch, img, sc in corpus(**kw):
        det, _ = detect_candles(img)
        r, p, d, e = match(det, ch.truth, sc)
        recalls.append(r), precisions.append(p), dirs.append(d), errs.append(e)
    e = np.vstack(errs)
    assert np.mean(recalls) >= min_recall, (name, np.mean(recalls))
    assert np.mean(precisions) >= min_precision, (name, np.mean(precisions))
    assert np.mean(dirs) >= 0.99, (name, np.mean(dirs))
    assert e.mean() <= max_mean_px, (name, e.mean())


def test_quality_flags_blur_and_low_resolution():
    ch = render_chart(random_walk_ohlc(40, seed=1))
    assert assess_image(ch.image).score > 0.85
    blurred = assess_image(degrade(ch.image, blur_ksize=9))
    assert "blurry" in blurred.issues and blurred.score < 0.6
    tiny = assess_image(degrade(ch.image, scale=0.25))
    assert "low_resolution" in tiny.issues


@pytest.mark.skipif(not axis.ocr_available(), reason="tesseract not installed")
@pytest.mark.parametrize("style", list(STYLES))
def test_reader_reads_prices_and_timeframe(style):
    ch = render_chart(random_walk_ohlc(50, seed=21), style=style)
    rd = ChartReader().read(ch.image)
    assert rd.usable, rd.abstain_reasons
    assert rd.price_scale is not None
    assert rd.timeframe_sec == 30
    a, b = ch.price_to_y
    px = abs(1 / a)
    closes = np.array([c["close"] for c in rd.candles])
    truth = np.array([o[3] for o in ch.ohlc])
    assert np.median(np.abs(closes - truth)) <= 1.5 * px  # within ~1 px of the true price
    assert rd.candles[-1]["status"] == "possibly_forming"
    assert all(c["status"] == "closed" for c in rd.candles[:-1])
    s = rd.summary()
    assert s["closed_candles"] == 49 and s["prices_read"] is True


def test_no_prices_without_axis_labels():
    ch = render_chart(random_walk_ohlc(50, seed=2), axis_labels=False, price_tag=False)
    rd = ChartReader().read(ch.image)
    assert rd.usable
    assert rd.price_scale is None
    assert "close" not in rd.candles[0]  # no invented prices
    assert any(w.endswith("relative_units_only") for w in rd.warnings)
    assert 0 <= rd.candles[0]["rel_close"] <= 1


def test_without_ocr_reports_relative_units():
    ch = render_chart(random_walk_ohlc(40, seed=3))
    rd = ChartReader(use_ocr=False).read(ch.image)
    assert rd.price_scale is None and rd.timeframe_sec is None


@pytest.mark.parametrize("img_factory,reason", [
    (lambda: np.full((500, 900, 3), 30, np.uint8), "no_candles_found_or_unsupported_colours"),
    (lambda: degrade(render_chart(random_walk_ohlc(40, seed=4)).image, blur_ksize=15), "image_quality_below_threshold"),
    (lambda: render_chart(random_walk_ohlc(6, seed=5)).image, "too_few_candles"),
])
def test_reader_abstains(img_factory, reason):
    rd = ChartReader().read(img_factory())
    assert not rd.usable
    assert reason in rd.abstain_reasons


def test_monochrome_candles_are_not_guessed():
    ch = render_chart(random_walk_ohlc(40, seed=6), style="light_classic")
    grey = np.repeat(ch.image.mean(axis=2, keepdims=True).astype(np.uint8), 3, axis=2)
    rd = ChartReader().read(grey)
    assert not rd.usable and rd.candles == []


def test_annotate_draws_on_copy():
    ch = render_chart(random_walk_ohlc(30, seed=7))
    rd = ChartReader(use_ocr=False).read(ch.image).to_dict()
    out = annotate(ch.image, rd)
    assert out.shape == ch.image.shape and not np.array_equal(out, ch.image)


@pytest.mark.parametrize("style", ["dark_tv", "light_tv", "dark_classic"])
@pytest.mark.parametrize("seed", [0, 4, 7, 10])
def test_indicator_lines_and_labels_in_candle_colours(style, seed):
    """A SuperTrend-like line and BUY/SELL labels in the candle colours touch the candles (Pocket Option style):
    the reader switches to the body-first reading and still finds the candles, their direction and their body."""
    ch = render_chart(random_walk_ohlc(80, seed=seed), style=style, supertrend=True, signal_labels=True,
                      width=1400, height=720)
    r = ChartReader(use_ocr=False).read(ch.image)
    assert r.usable, r.abstain_reasons
    assert r.detection.get("mode") == "bodies_first"
    xs = [c["x"] for c in r.candles]
    hits = [t for t in ch.truth if min(abs(t["x"] - x) for x in xs) <= 2]
    false = [x for x in xs if min(abs(t["x"] - x) for t in ch.truth) > 2]
    assert len(hits) >= 0.93 * len(ch.truth)
    assert len(false) <= 0.04 * len(ch.truth)
    matched = [(c, t) for c in r.candles for t in ch.truth if abs(t["x"] - c["x"]) <= 2]
    assert sum(c["bullish"] == t["bullish"] for c, t in matched) >= 0.98 * len(matched)


def test_plain_charts_keep_the_first_reading():
    for seed in range(4):
        ch = render_chart(random_walk_ohlc(80, seed=seed), style="dark_tv", width=1400, height=720)
        r = ChartReader(use_ocr=False).read(ch.image)
        assert "mode" not in r.detection and len(r.candles) == 80
