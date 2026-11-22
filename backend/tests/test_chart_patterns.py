"""Chart patterns: found on the shape they describe, never on the opposite one, and strictly causal."""

import numpy as np
import pytest

from uata.strategy import conditions as cnd
from uata.strategy.chart_patterns import CHART_PATTERNS
from uata.strategy.features import FeatureSet


def path(points: list[tuple[int, float]], seed: int = 0) -> FeatureSet:
    """Candles that walk through (bar, price) waypoints, with a little noise; 80 warm-up bars first."""
    rng = np.random.default_rng(seed)
    xs = [0, 80] + [80 + b for b, _ in points]
    ys = [100.0, 100.0] + [p for _, p in points]
    close = np.interp(np.arange(xs[-1] + 1), xs, ys) + rng.normal(0, 0.05, xs[-1] + 1)
    open_ = np.concatenate([[close[0]], close[:-1]])
    high = np.maximum(open_, close) + 0.08
    low = np.minimum(open_, close) - 0.08
    return FeatureSet(open_, high, low, close)


SHAPES = {
    # rise, two equal highs with a dip between (neckline ≈ 103), then the break below it
    "double_top": [(10, 106), (16, 103), (22, 106), (30, 101)],
    "double_bottom": [(10, 94), (16, 97), (22, 94), (30, 99)],
    # left shoulder 105, head 108, right shoulder 105, neckline ≈ 102, then down through it
    "head_shoulders": [(8, 105), (13, 102), (19, 108), (25, 102), (30, 105), (35, 102), (40, 99)],
    # strong pole up, a small pullback, then a break above the flag top
    "bull_flag": [(8, 108), (13, 106.5), (17, 110)],
    # flat top at 105, rising lows, then the break
    "ascending_triangle": [(6, 105), (11, 101), (17, 105), (22, 103), (27, 105.1), (30, 107)],
}
OPPOSITE = {"double_top": "double_bottom", "double_bottom": "double_top", "head_shoulders": "double_bottom",
            "bull_flag": "double_top", "ascending_triangle": "double_top"}


@pytest.mark.parametrize("name", list(SHAPES))
def test_pattern_found_on_its_shape(name):
    fs = path(SHAPES[name])
    hits = [i for i in range(60, fs.n) if CHART_PATTERNS[name](fs, i)]
    assert hits, name
    assert all(i > 80 for i in hits)  # never in the flat warm-up
    assert not any(CHART_PATTERNS[OPPOSITE[name]](fs, i) for i in hits)


def test_gap_retest_after_a_fast_move():
    # quiet, then one big bullish candle leaves a gap, price runs on and later comes back into the gap
    o = [100.0] * 80
    c = [100.0] * 80
    o += [100.0, 100.1, 102.0, 102.3, 102.6, 102.4, 102.0, 101.5]
    c += [100.1, 102.0, 102.3, 102.6, 102.4, 102.0, 101.5, 101.9]
    o, c = np.array(o), np.array(c)
    h = np.maximum(o, c) + 0.05
    low = np.minimum(o, c) - 0.05
    fs = FeatureSet(o, h, low, c)
    hits = [i for i in range(60, fs.n) if CHART_PATTERNS["gap_retest_bull"](fs, i)]
    assert hits and hits[0] > 82
    assert not any(CHART_PATTERNS["gap_retest_bear"](fs, i) for i in range(60, fs.n))


def test_chart_patterns_are_causal():
    rng = np.random.default_rng(5)
    close = 100 + np.cumsum(rng.normal(0, 0.3, 900))
    open_ = np.concatenate([[close[0]], close[:-1]])
    high = np.maximum(open_, close) + rng.uniform(0, 0.2, 900)
    low = np.minimum(open_, close) - rng.uniform(0, 0.2, 900)
    full = FeatureSet(open_, high, low, close)
    total = 0
    for cut in (200, 517, 899):
        part = FeatureSet(open_[:cut], high[:cut], low[:cut], close[:cut])
        for name, fn in CHART_PATTERNS.items():
            for i in range(60, cut):
                assert fn(part, i) == fn(full, i), (name, cut, i)
                total += fn(full, i)
    assert total > 0


def test_chart_pattern_condition_validates():
    assert cnd.validate({"id": "chart_pattern", "name": "head_shoulders"})["name"] == "head_shoulders"
    with pytest.raises(ValueError):
        cnd.validate({"id": "chart_pattern", "name": "cup_and_handle"})
