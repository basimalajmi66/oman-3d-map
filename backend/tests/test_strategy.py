"""Phase 7: strategy DSL, causal features, leak-free backtests, approval gate, comparison, selection."""
import io

import numpy as np
import pytest

from uata.strategy import conditions as cnd
from uata.strategy import datasets as ds
from uata.strategy.backtest import gate, run_backtest, wilson
from uata.strategy.features import FeatureSet
from uata.strategy.translate import translate_rules
from uata.vision.synthetic import random_walk_ohlc

RSI_DEF = {"long": {"all": [{"id": "rsi_below", "value": 35}, {"id": "bullish_candle"}]},
           "short": {"all": [{"id": "rsi_above", "value": 65}, {"id": "bearish_candle"}]}, "duration_sec": 120}


def fs_from(rows):
    o, h, l_, c = map(np.array, zip(*rows))
    return FeatureSet(o, h, l_, c)


def trending_rows(n=1500, drift=0.0004, noise=0.0002, seed=1):
    """Strongly up-drifting market: a 'bullish candle → buy' strategy genuinely has an edge here."""
    rng = np.random.default_rng(seed)
    rows, p = [], 1.0
    for _ in range(n):
        o = p
        c = o + drift + rng.normal(0, noise)
        rows.append((o, max(o, c) + 0.0001, min(o, c) - 0.0001, c))
        p = c
    return rows


# ---------------------------------------------------------------- causality / leakage
def test_features_are_causal():
    rows = random_walk_ohlc(600, seed=3)
    full = fs_from(rows)
    definition = cnd.validate_definition({"long": {"all": [{"id": "near_support"}, {"id": "bullish_candle"}]},
                                          "short": {"all": [{"id": "breakdown"}]}, "duration_sec": 60})
    for cut in (120, 333, 599):
        part = fs_from(rows[:cut])
        for i in range(60, cut):
            assert part.trend(i) == full.trend(i)
            assert part.patterns(i) == full.patterns(i)
            assert part.levels(i) == full.levels(i)
            assert part.market_condition(i) == full.market_condition(i)
            assert cnd.signal_at(part, i, definition) == cnd.signal_at(full, i, definition)


def test_backtest_has_no_lookahead():
    rows = random_walk_ohlc(1500, seed=5)
    d = cnd.validate_definition(RSI_DEF)
    full = run_backtest(fs_from(rows), d, 30)
    cut = 1000
    part = run_backtest(fs_from(rows[:cut]), d, 30)
    full_trades = [t for t in full["trades_sample"] if t["exit_bar"] < cut]
    part_trades = [t for t in part["trades_sample"] if t["exit_bar"] < cut]
    # every trade that completed before the cut is identical whether or not the future exists
    assert {(t["signal_bar"], t["outcome"]) for t in full_trades} <= {(t["signal_bar"], t["outcome"]) for t in part_trades} \
        or {(t["signal_bar"], t["outcome"]) for t in part_trades} >= {(t["signal_bar"], t["outcome"]) for t in full_trades}
    common = sorted(set(t["signal_bar"] for t in full_trades) & set(t["signal_bar"] for t in part_trades))
    assert common, "expected overlapping trades"
    fmap = {t["signal_bar"]: t for t in full_trades}
    pmap = {t["signal_bar"]: t for t in part_trades}
    for b in common:
        assert fmap[b] == pmap[b]


def test_entry_is_next_open_and_exit_is_expiry_close():
    rows = random_walk_ohlc(800, seed=8)
    fs = fs_from(rows)
    r = run_backtest(fs, cnd.validate_definition({"long": {"all": [{"id": "bullish_candle"}]}, "duration_sec": 90}), 30)
    assert r["bars_per_trade"] == 3
    for t in r["trades_sample"]:
        assert t["entry_bar"] == t["signal_bar"] + 1 and t["entry"] == pytest.approx(fs.o[t["entry_bar"]])
        assert t["exit_bar"] == t["signal_bar"] + 3 and t["exit"] == pytest.approx(fs.c[t["exit_bar"]])
    bars = [t["signal_bar"] for t in r["trades_sample"]]
    assert all(b2 >= b1 + 3 for b1, b2 in zip(bars, bars[1:]))  # one trade at a time


def test_unpredictable_planted_future_cannot_be_exploited():
    """Price jumps up after every 7th bar — invisible in past data. A causal strategy must not profit."""
    rng = np.random.default_rng(0)
    rows, p = [], 1.0
    for i in range(3000):
        o = p
        c = o + (0.003 if i % 7 == 0 else 0.0) + rng.normal(0, 0.0005)
        rows.append((o, max(o, c) + 0.0002, min(o, c) - 0.0002, c))
        p = c
    r = run_backtest(fs_from(rows), cnd.validate_definition(
        {"long": {"all": [{"id": "bearish_candle"}]}, "duration_sec": 30}), 30)
    oos = r["out_of_sample"]
    assert not oos["significant_edge"]


@pytest.mark.parametrize("seed", [1, 2, 3, 4])
def test_random_walk_shows_no_significant_edge(seed):
    r = run_backtest(fs_from(random_walk_ohlc(3000, seed=seed)), cnd.validate_definition(RSI_DEF), 30, payout=0.85)
    for part in ("in_sample", "out_of_sample"):
        m = r[part]
        assert not m["significant_edge"]
        assert m["win_rate_ci95"][0] <= 0.5 <= m["win_rate_ci95"][1] or m["trades"] < 30


def test_real_edge_is_detected():
    r = run_backtest(fs_from(trending_rows()), cnd.validate_definition(
        {"long": {"all": [{"id": "bullish_candle"}]}, "duration_sec": 60}), 30)
    oos = r["out_of_sample"]
    assert oos["significant_edge"] and oos["expectancy_per_trade"] > 0.3 and oos["trades"] >= 30
    assert gate(r, synthetic=False) == []
    assert gate(r, synthetic=True) == ["tested_on_synthetic_data_only"]


def test_wilson_interval():
    lo, hi = wilson(50, 100)
    assert lo == pytest.approx(0.4038, abs=1e-3) and hi == pytest.approx(0.5962, abs=1e-3)
    assert wilson(0, 0) == (0.0, 1.0)


def test_metrics_go_beyond_win_rate():
    r = run_backtest(fs_from(random_walk_ohlc(2000, seed=9)), cnd.validate_definition(RSI_DEF), 30)
    m = r["all"]
    for key in ("expectancy_per_trade", "profit_factor", "max_drawdown_units", "longest_losing_streak",
                "win_rate_ci95", "breakeven_win_rate", "equity_curve", "trades_per_1000_bars"):
        assert key in m
    assert set(r["out_of_sample"]["by_condition"]) == {"trending", "ranging", "volatile"}


# ---------------------------------------------------------------- DSL
def test_definition_validation():
    with pytest.raises(ValueError):
        cnd.validate_definition({"long": {"all": []}, "short": {"all": []}})
    with pytest.raises(ValueError):
        cnd.validate_definition({"long": {"all": [{"id": "telepathy"}]}})
    with pytest.raises(ValueError):
        cnd.validate_definition({"long": {"all": [{"id": "pattern", "name": "unicorn"}]}})
    with pytest.raises(ValueError):
        cnd.validate_definition({"long": {"all": [{"id": "rsi_below", "colour": "red"}]}})
    d = cnd.validate_definition({"long": {"all": [{"id": "rsi_below"}]}})
    assert d["long"]["all"] == [{"id": "rsi_below", "value": 30}] and d["duration_sec"] == 120
    assert cnd.describe(d["long"]["all"][0], "ar") == "RSI أقل من 30"


def test_veto_and_conflicting_sides():
    fs = fs_from(random_walk_ohlc(400, seed=2))
    always = {"long": {"all": [{"id": "momentum_up", "atr": -100}]}, "short": {"all": []}, "veto": [], "duration_sec": 60}
    always = cnd.validate_definition(always)
    i = 200
    assert cnd.signal_at(fs, i, always) == "BUY"
    vetoed = {**always, "veto": [cnd.validate({"id": "momentum_up", "atr": -100})]}
    assert cnd.signal_at(fs, i, vetoed) is None
    both = {**always, "short": {"all": [cnd.validate({"id": "momentum_up", "atr": -100})]}}
    assert cnd.signal_at(fs, i, both) is None
    assert cnd.signal_at(fs, 10, always) is None  # warm-up: not enough history


def test_translate_rules_and_untestable():
    d = translate_rules([
        {"text": "If RSI oversold at support, buy", "actions": ["act_buy"], "conditions": ["oversold", "rsi", "support"]},
        {"text": "Sell a bearish engulfing in a downtrend", "actions": ["act_sell"], "conditions": ["downtrend", "engulfing"]},
        {"text": "Do not trade overbought", "actions": ["act_avoid"], "conditions": ["overbought"]},
        {"text": "Avoid news", "actions": ["act_avoid"], "conditions": ["news"]},
        {"text": "Exit at resistance", "actions": ["act_exit"], "conditions": ["resistance"]},
    ])
    assert d["long"]["all"] == [{"id": "rsi_below", "value": 30}, {"id": "near_support"}]
    assert {"id": "pattern", "name": "bearish_engulfing"} in d["short"]["all"] and {"id": "trend_down"} in d["short"]["all"]
    assert d["veto"] == [{"id": "rsi_above", "value": 70}]
    assert d["untestable"] == ["Avoid news", "Exit at resistance"]
    cnd.validate_definition(d)


# ---------------------------------------------------------------- datasets
def csv_text(rows, start=1_700_000_000, step=30, sep=","):
    lines = [sep.join(["time", "open", "high", "low", "close"])]
    for i, (o, h, l_, c) in enumerate(rows):
        lines.append(sep.join(str(x) for x in (start + i * step, o, h, l_, c)))
    return "\n".join(lines)


def test_csv_parsing_and_validation():
    d = ds.parse_csv(csv_text(random_walk_ohlc(150, seed=1)))
    assert d["rows"] == 150 and d["timeframe_sec"] == 30 and d["volume"] is None
    dated = "Date,Open,High,Low,Close,Volume\n" + "\n".join(
        f"2026-11-17 10:{i // 60:02d}:{i % 60:02d},1,1.1,0.9,1.05,{i}" for i in range(120))
    assert ds.parse_csv(dated)["timeframe_sec"] == 1
    ms = csv_text(random_walk_ohlc(120, seed=2), start=1_700_000_000_000, step=60_000)
    assert ds.parse_csv(ms)["timeframe_sec"] == 60
    with pytest.raises(ds.DatasetError, match="missing"):
        ds.parse_csv("time,open,close\n1,1,1")
    with pytest.raises(ds.DatasetError, match="at least 100"):
        ds.parse_csv(csv_text(random_walk_ohlc(50, seed=1)))
    bad = csv_text([(1.0, 0.9, 0.8, 1.0)] + random_walk_ohlc(120, seed=1))
    with pytest.raises(ds.DatasetError, match="inconsistent"):
        ds.parse_csv(bad)
    unsorted = csv_text(random_walk_ohlc(120, seed=1)).split("\n")
    unsorted[5], unsorted[6] = unsorted[6], unsorted[5]
    with pytest.raises(ds.DatasetError, match="increasing"):
        ds.parse_csv("\n".join(unsorted))


# ---------------------------------------------------------------- API: full training workflow
def upload_csv(client, rows, name="EURUSD 30s"):
    return client.post("/datasets/csv", files={"file": ("data.csv", io.BytesIO(csv_text(rows).encode()))},
                       data={"name": name, "asset": "EURUSD"}).json()


def test_synthetic_results_can_never_approve(client):
    syn = client.post("/datasets/synthetic", json={"rows": 2000, "seed": 3}).json()
    assert syn["is_synthetic"] == 1 and syn["asset"] == "SIMULATED"
    s = client.post("/strategies", json={"name": "Bull candle", "definition": {
        "long": {"all": [{"id": "bullish_candle"}]}, "duration_sec": 60}}).json()
    assert s["status"] == "draft" and s["readable_ar"]["long"] == ["شمعة صاعدة"]
    r = client.post(f"/strategies/{s['id']}/backtest", json={"dataset_id": syn["id"]}).json()
    assert r["synthetic"] and "tested_on_synthetic_data_only" in r["gate_reasons"]
    assert client.get(f"/strategies/{s['id']}").json()["status"] == "testing"
    refused = client.post(f"/strategies/{s['id']}/approve")
    assert refused.status_code == 409 and "tested_on_synthetic_data_only" in refused.json()["reasons"]


def test_qualifying_real_data_then_user_approval_then_edit_resets(client):
    data = upload_csv(client, trending_rows())
    assert data["is_synthetic"] == 0 and data["timeframe_sec"] == 30
    s = client.post("/strategies", json={"name": "Trend follower", "definition": {
        "long": {"all": [{"id": "bullish_candle"}]}, "duration_sec": 60}}).json()
    assert client.post(f"/strategies/{s['id']}/approve").json()["reasons"] == ["no_backtest_for_current_version"]
    r = client.post(f"/strategies/{s['id']}/backtest", json={"dataset_id": data["id"]}).json()
    assert r["qualifies"] and r["out_of_sample"]["significant_edge"]
    ok = client.post(f"/strategies/{s['id']}/approve").json()
    assert ok["status"] == "approved" and ok["approved_at"]
    # editing the definition creates a new version: back to draft, old test does not count
    edited = client.patch(f"/strategies/{s['id']}", json={"definition": {
        "long": {"all": [{"id": "bullish_candle"}, {"id": "trend_up"}]}, "duration_sec": 60}}).json()
    assert edited["version"] == 2 and edited["status"] == "draft" and edited["latest_backtest"] is None
    assert client.post(f"/strategies/{s['id']}/approve").status_code == 409
    assert len(edited["backtests"]) == 1 and edited["backtests"][0]["strategy_version"] == 1


def test_compare_keeps_results_separate_and_suitable_selection(client):
    data = upload_csv(client, trending_rows(n=2500, seed=4))
    a = client.post("/strategies", json={"name": "A long", "definition": {
        "long": {"all": [{"id": "bullish_candle"}]}, "duration_sec": 60}}).json()
    b = client.post("/strategies", json={"name": "B short", "definition": {
        "short": {"all": [{"id": "bearish_candle"}]}, "duration_sec": 60}}).json()
    rows = client.post("/strategies/compare", json={"strategy_ids": [a["id"], b["id"]], "dataset_id": data["id"]}).json()
    assert [r["name"] for r in rows] == ["A long", "B short"]  # sorted by out-of-sample expectancy
    assert rows[0]["expectancy_per_trade"] > 0 > rows[1]["expectancy_per_trade"]
    assert rows[0]["run_id"] != rows[1]["run_id"]
    client.post(f"/strategies/{a['id']}/approve")
    suit = client.get("/strategies/suitable/trending").json()
    assert suit and suit[0]["name"] == "A long" and "trending" in suit[0]["reason"]
    assert all(s["name"] != "B short" for s in suit)  # not approved → never suggested


def test_strategy_from_approved_rules_and_untestable(client):
    n = client.post("/knowledge/notes", json={"title": "Rules", "content":
                    "When RSI is oversold at support, buy.\nAvoid trading when big news is expected."}).json()
    assert client.post("/strategies/from-rules", json={"name": "x", "source_id": n["id"]}).status_code == 400  # not approved
    client.post(f"/knowledge/reports/{n['report']['id']}/decision", json={"decision": "approve"})
    s = client.post("/strategies/from-rules", json={"name": "From notes", "source_id": n["id"]}).json()
    assert s["definition"]["long"]["all"] == [{"id": "rsi_below", "value": 30}, {"id": "near_support", "atr": 0.6}]
    assert s["definition"]["untestable"] == ["Avoid trading when big news is expected."]
    assert s["status"] == "draft" and "Built from approved rules" in s["description"]


def test_catalog_validation_errors_and_404(client):
    cat = client.get("/strategies/catalog").json()
    assert {c["id"] for c in cat} >= {"rsi_below", "pattern", "near_support"}
    assert client.post("/strategies", json={"name": "bad", "definition": {"long": {"all": [{"id": "nope"}]}}}).status_code == 400
    assert client.get("/strategies/999").status_code == 404
    assert client.post("/strategies/999/backtest", json={"dataset_id": 1}).status_code == 404
    bad_csv = client.post("/datasets/csv", files={"file": ("x.csv", io.BytesIO(b"a,b\n1,2"))})
    assert bad_csv.status_code == 400
