import numpy as np
import pytest

from uata.analysis import indicators as ind
from uata.analysis import patterns as pat
from uata.analysis import structure as st
from uata.analysis.engine import MIN_CANDLES, TechnicalAnalyzer, analyze_reading
from uata.core.settings_model import INDICATORS
from uata.vision.reader import ChartReader
from uata.vision.synthetic import random_walk_ohlc, render_chart

RNG = np.random.default_rng(42)
PRICES = 1.1 + np.cumsum(RNG.normal(0, 0.001, 200))


def candles_from(ohlc):
    return [dict(open=o, high=h, low=l, close=c) for o, h, l, c in ohlc]


def ohlc_arrays(seed=1, n=150):
    data = random_walk_ohlc(n, seed=seed)
    return [np.array(x) for x in zip(*data)]


# ---------------------------------------------------------------- indicator correctness
def test_sma_and_ema_reference():
    x = np.arange(1, 11, dtype=float)
    assert np.isnan(ind.sma(x, 3)[1]) and ind.sma(x, 3)[2] == 2.0 and ind.sma(x, 3)[-1] == 9.0
    e = ind.ema(x, 3)
    assert e[2] == 2.0  # seeded with SMA
    assert e[3] == pytest.approx(4 * 0.5 + 2.0 * 0.5)


def naive_rsi(c, n=14):
    d = np.diff(c)
    g, l_ = np.clip(d, 0, None), np.clip(-d, 0, None)
    ag, al = g[:n].mean(), l_[:n].mean()
    out = [np.nan] * (n + 1)
    out[n] = 100 - 100 / (1 + ag / al) if al else 100.0
    for i in range(n, len(d)):
        ag = (ag * (n - 1) + g[i]) / n
        al = (al * (n - 1) + l_[i]) / n
        out.append(100 - 100 / (1 + ag / al) if al else 100.0)
    return np.array(out)


def test_rsi_matches_independent_implementation_and_extremes():
    np.testing.assert_allclose(ind.rsi(PRICES), naive_rsi(PRICES), equal_nan=True, rtol=1e-12)
    assert ind.rsi(np.arange(30.0))[-1] == 100.0
    assert ind.rsi(np.arange(30.0)[::-1])[-1] == 0.0
    assert ind.rsi(np.ones(30))[-1] == 50.0


def test_macd_bollinger_atr_reference():
    line, sig, hist = ind.macd(PRICES)
    np.testing.assert_allclose(line, ind.ema(PRICES, 12) - ind.ema(PRICES, 26), equal_nan=True)
    np.testing.assert_allclose(hist, line - sig, equal_nan=True)
    lo, mid, hi = ind.bollinger(PRICES, 20, 2)
    assert mid[-1] == pytest.approx(PRICES[-20:].mean())
    assert hi[-1] - mid[-1] == pytest.approx(2 * PRICES[-20:].std())
    o, h, l_, c = ohlc_arrays()
    tr = np.array([h[0] - l_[0]] + [max(h[i] - l_[i], abs(h[i] - c[i - 1]), abs(l_[i] - c[i - 1]))
                                    for i in range(1, len(c))])
    np.testing.assert_allclose(ind.true_range(h, l_, c), tr)
    a = ind.atr(h, l_, c, 14)
    assert a[13] == pytest.approx(tr[:14].mean())


@pytest.mark.parametrize("fn", [
    lambda x: ind.sma(x, 10), lambda x: ind.ema(x, 10), lambda x: ind.rsi(x, 14),
    lambda x: ind.macd(x)[0], lambda x: ind.macd(x)[1], lambda x: ind.bollinger(x)[2],
    lambda x: ind.roc(x, 10), lambda x: ind.linreg_slope(x, 10),
])
def test_indicators_are_causal(fn):
    """Value at index i must be identical whether or not later data exists (no look-ahead)."""
    full = fn(PRICES)
    for cut in (40, 77, 120, 199):
        part = fn(PRICES[:cut])
        np.testing.assert_allclose(part, full[:cut], equal_nan=True, rtol=1e-12)


def test_pivots_are_only_confirmed_ones():
    o, h, l_, c = ohlc_arrays()
    for upto in (30, 60, 149):
        hs, ls = st.pivots(h, l_, 2, upto)
        assert all(j + 2 <= upto for j in hs + ls)


# ---------------------------------------------------------------- patterns
def arrays(rows):
    return [np.array(x, float) for x in zip(*rows)]


def test_hammer_after_decline_and_hanging_man_after_rise():
    hammer = (10.0, 10.45, 8.5, 10.4)  # body ~20% of range, long lower wick
    o, h, l_, c = arrays([hammer])
    assert [p.name for p in pat.detect_at(o, h, l_, c, 0, 1.0, "down")] == ["hammer"]
    assert [p.name for p in pat.detect_at(o, h, l_, c, 0, 1.0, "up")] == ["hanging_man"]
    star = (10.0, 12.0, 9.55, 9.6)
    o, h, l_, c = arrays([star])
    assert [p.name for p in pat.detect_at(o, h, l_, c, 0, 1.0, "up")] == ["shooting_star"]


def test_engulfing_morning_star_doji():
    o, h, l_, c = arrays([(10.5, 10.6, 9.9, 10.0), (9.95, 10.8, 9.9, 10.7)])
    names = {p.name: p for p in pat.detect_at(o, h, l_, c, 1, 0.5, "down")}
    assert "bullish_engulfing" in names and names["bullish_engulfing"].strength == 0.75
    o, h, l_, c = arrays([(11.0, 11.05, 9.9, 10.0), (9.9, 10.0, 9.7, 9.85), (9.9, 10.8, 9.85, 10.7)])
    assert "morning_star" in [p.name for p in pat.detect_at(o, h, l_, c, 2, 0.6, "down")]
    o, h, l_, c = arrays([(10.0, 10.5, 9.5, 10.01)])
    assert [p.name for p in pat.detect_at(o, h, l_, c, 0, 1.0, "sideways")] == ["doji"]


def test_tiny_candles_do_not_make_patterns():
    o, h, l_, c = arrays([(10.0, 10.01, 9.99, 10.0)])
    assert pat.detect_at(o, h, l_, c, 0, 1.0, "down") == []


# ---------------------------------------------------------------- structure
def series(fn, n=120, noise=0.0, seed=0):
    r = np.random.default_rng(seed)
    close = np.array([fn(i) for i in range(n)]) + r.normal(0, noise, n)
    o = np.concatenate([[close[0]], close[:-1]])
    h = np.maximum(o, close) + 0.05
    l_ = np.minimum(o, close) - 0.05
    return o, h, l_, close


@pytest.mark.parametrize("fn,expected", [
    (lambda i: 100 + 0.2 * i, "up"),
    (lambda i: 100 - 0.2 * i, "down"),
    (lambda i: 100 + np.sin(i / 3), "sideways"),
])
def test_trend_direction(fn, expected):
    o, h, l_, c = series(fn, noise=0.05)
    a = ind.atr(h, l_, c)[-1]
    assert st.trend(c, h, l_, a)["direction"] == expected


def test_support_resistance_in_a_range():
    o, h, l_, c = series(lambda i: 100 + 5 * np.sin(i / 4), n=160)
    a = ind.atr(h, l_, c)[-1]
    levels = st.support_resistance(h, l_, c, a)
    prices = [lv.price for lv in levels]
    assert any(abs(p - 105) < 1 for p in prices) and any(abs(p - 95) < 1 for p in prices)
    assert all(lv.touches >= 2 for lv in levels)


def test_supply_demand_zone_after_impulse():
    rows = [(100, 100.3, 99.7, 100.1)] * 20 + [(100.1, 100.2, 100.0, 100.15),  # quiet base
                                              (100.15, 102.5, 100.1, 102.4), (102.4, 103.6, 102.3, 103.5)]
    rows += [(103.5, 103.8, 103.2, 103.6)] * 5
    o, h, l_, c = arrays(rows)
    zones = st.supply_demand(o, h, l_, c, ind.atr(h, l_, c, 14))
    assert zones and zones[0].kind == "demand" and zones[0].fresh
    assert zones[0].low == pytest.approx(100.0) and zones[0].high == pytest.approx(100.2)


def test_liquidity_sweep_and_double_bottom_and_sudden_move():
    base = [(101, 101.5, 100.5, 101)] * 16
    rows = base + [(101, 101.2, 99.0, 100.8), (100.8, 102, 100.6, 101.8), (101.8, 103.5, 101.6, 103.2),
                   (103.2, 103.4, 101.5, 101.7), (101.7, 101.9, 99.02, 101.0), (101.0, 102.8, 100.9, 102.6),
                   (102.6, 103.0, 102.0, 102.4), (102.4, 102.6, 101.8, 102.0)]
    o, h, l_, c = arrays(rows)
    a = ind.atr(h, l_, c)[-1]
    dtb = st.double_top_bottom(h, l_, c, a)
    assert dtb and dtb["name"] == "double_bottom"
    big = rows + [(102.0, 108.0, 101.9, 107.5)]
    o, h, l_, c = arrays(big)
    sm = st.sudden_move(h, l_, c, ind.atr(h, l_, c))
    assert sm and sm["direction"] == "up" and sm["range_atr"] >= 2.5


# ---------------------------------------------------------------- analyzer
def test_analyzer_output_and_toggles():
    cs = candles_from(random_walk_ohlc(120, seed=4))
    r = TechnicalAnalyzer().analyze(cs)
    assert r["available"] and {f["name"] for f in r["factors"]} == set(INDICATORS)
    assert r["market_condition"] in ("trending", "ranging", "volatile")
    assert "volume" in r["confluence"]["unavailable"]  # no volume data → reported, not faked
    assert "no_volume_data" in r["warnings"]
    off = TechnicalAnalyzer().analyze(cs, enabled={"rsi": False, "macd": False})
    rsi = next(f for f in off["factors"] if f["name"] == "rsi")
    assert rsi["enabled"] is False and rsi["direction"] == "neutral"
    assert {"rsi", "macd"} <= set(off["confluence"]["disabled"])
    assert "rsi" not in off["confluence"]["bullish"] + off["confluence"]["bearish"]


def test_volume_used_when_present():
    cs = candles_from(random_walk_ohlc(60, seed=2))
    for i, c in enumerate(cs):
        c["volume"] = 100.0 if i < 59 else 300.0
    r = TechnicalAnalyzer().analyze(cs, has_volume=True)
    vol = next(f for f in r["factors"] if f["name"] == "volume")
    assert vol["available"] and vol["code"] == "volume_high"


def test_insufficient_candles():
    r = TechnicalAnalyzer().analyze(candles_from(random_walk_ohlc(MIN_CANDLES - 1, seed=1)))
    assert r == {"available": False, "reason": "insufficient_candles", "candles_used": MIN_CANDLES - 1,
                 "min_candles": MIN_CANDLES, "analyzer_version": "1.0"}


def test_scale_invariance_relative_units_equal_price_units():
    """Image readings without a price axis give relative units; directions must not change."""
    raw = random_walk_ohlc(120, seed=9)
    a = TechnicalAnalyzer().analyze(candles_from(raw))
    scaled = [tuple(v * 731.0 + 52.0 for v in row) for row in raw]
    b = TechnicalAnalyzer().analyze(candles_from(scaled))
    assert [(f["name"], f["direction"]) for f in a["factors"]] == [(f["name"], f["direction"]) for f in b["factors"]]
    assert a["market_condition"] == b["market_condition"]


@pytest.mark.parametrize("style,seed", [("dark_tv", 3), ("light_classic", 8), ("dark_classic", 15)])
def test_image_reading_analysis_agrees_with_true_prices(style, seed):
    """End-to-end: chart image → reader → analysis vs analysis of the exact OHLC that drew it."""
    ohlc = random_walk_ohlc(90, seed=seed)
    ch = render_chart(ohlc, style=style)
    reading = ChartReader().read(ch.image).to_dict()
    from_image = analyze_reading(reading)
    truth = TechnicalAnalyzer().analyze(candles_from(ohlc[:-1]))  # forming candle excluded on both sides
    assert from_image["available"] and from_image["candles_used"] == 89
    pairs = [(fi["direction"], ft["direction"]) for fi, ft in zip(from_image["factors"], truth["factors"])]
    agree = sum(a == b for a, b in pairs) / len(pairs)
    assert agree >= 0.85, pairs
    assert from_image["trend"]["direction"] == truth["trend"]["direction"]


def test_unusable_reading_is_not_analysed():
    assert analyze_reading({"usable": False}) == {"available": False, "reason": "reading_not_usable"}


# ---------------------------------------------------------------- API integration
import io  # noqa: E402

import cv2  # noqa: E402


def test_uploaded_chart_gets_technical_analysis_respecting_toggles(client):
    client.patch("/settings", json={"indicators": {"rsi": False}})
    png = cv2.imencode(".png", render_chart(random_walk_ohlc(70, seed=5), style="dark_tv").image)[1].tobytes()
    r = client.post("/analysis/inputs", files={"file": ("c.png", io.BytesIO(png))}).json()
    t = r["analysis"]["technical"]
    assert t["available"] and t["candles_used"] == 69  # forming candle excluded
    assert t["units"] == "price" and t["market_condition"] in ("trending", "ranging", "volatile")
    assert "rsi" in t["disabled"] and "volume" in t["unavailable"]
    names = [f["name"] for f in t["supporting_bullish"] + t["supporting_bearish"]]
    assert "rsi" not in names
    assert r["analysis"]["signal"] == "WAIT"  # analysis is not a signal
    full = client.get(f"/analysis/inputs/{r['input']['id']}/reading").json()
    assert len(full["technical"]["factors"]) == 15


def test_short_chart_reports_insufficient_candles(client):
    png = cv2.imencode(".png", render_chart(random_walk_ohlc(20, seed=5)).image)[1].tobytes()
    t = client.post("/analysis/inputs", files={"file": ("c.png", io.BytesIO(png))}).json()["analysis"]["technical"]
    assert t == {"available": False, "reason": "insufficient_candles", "candles_used": 19}


def test_technical_endpoint_for_price_feed(client):
    rows = random_walk_ohlc(60, seed=6)
    body = {"candles": [dict(open=o, high=h, low=l, close=c, volume=100.0) for o, h, l, c in rows]}
    r = client.post("/analysis/technical", json=body).json()
    assert r["available"] and r["candles_used"] == 59 and r["data_basis"] == "price_feed"
    vol = next(f for f in r["factors"] if f["name"] == "volume")
    assert vol["available"] is True
    r2 = client.post("/analysis/technical", json={**body, "last_is_forming": False}).json()
    assert r2["candles_used"] == 60
    bad = {"candles": [dict(open=1.0, high=0.9, low=0.8, close=1.0)]}
    assert client.post("/analysis/technical", json=bad).status_code == 422


def test_continuous_reading_includes_technical(client):
    import time
    client.patch("/settings", json={"screen_capture_allowed": True, "capture_interval_sec": 2})
    client.post("/analysis/start", json={"input_mode": "continuous_screen"})
    end = time.monotonic() + 10
    latest = None
    while time.monotonic() < end and not latest:
        latest = client.get("/analysis/status").json()["screen_watch"]["latest"]
        time.sleep(0.05)
    client.post("/analysis/stop")
    assert latest and latest["technical"]["available"] and latest["technical"]["candles_used"] == 49
