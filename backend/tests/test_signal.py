"""Phase 8: the decision engine (14 steps), recording rules and the full pipeline."""
import copy
import io

import cv2
import numpy as np
import pytest

from uata.analysis.engine import analyze_reading
from uata.core.settings_model import Settings
from uata.signal.engine import decide, fingerprint
from uata.vision.reader import ChartReader
from uata.vision.synthetic import render_chart

ALWAYS_UP = {"id": "momentum_up", "atr": -100}      # always true: isolates the engine logic from the market
ALWAYS_DOWN = {"id": "momentum_down", "atr": -100}


def uptrend_rows(n=80, seed=3):
    rng = np.random.default_rng(seed)
    rows, p = [], 1.1
    for i in range(n):
        o = p
        c = o + abs(rng.normal(0.0006, 0.0004)) if i % 5 else o - 0.0003
        rows.append((o, max(o, c) + 0.0003, min(o, c) - 0.0003, c))
        p = c
    o = rows[-2][0]
    rows[-2] = (o, max(rows[-2][1], o + 0.0008), rows[-2][2], o + 0.0007)  # last closed candle bullish
    return rows


@pytest.fixture(scope="module")
def chart():
    img = render_chart(uptrend_rows(), style="dark_tv").image
    reading = ChartReader().read(img).to_dict()
    return img, reading, analyze_reading(reading)


def strategy(conds_long=(ALWAYS_UP,), conds_short=(), tf=30, duration=120, name="S", sid=1, oos_exp=0.11):
    return {"id": sid, "name": name, "version": 1, "status": "approved",
            "definition": {"long": {"all": list(conds_long)}, "short": {"all": list(conds_short)}, "veto": [],
                           "duration_sec": duration, "untestable": []},
            "latest_backtest": {"qualifies": True, "params": {"timeframe_sec": tf},
                                "out_of_sample": {"trades": 40, "win_rate": 0.6, "win_rate_ci95": [0.45, 0.74],
                                                  "expectancy_per_trade": oos_exp, "significant_edge": False,
                                                  "by_condition": {}}}}


def settings(**kw):
    return {**Settings().model_dump(), **kw}


# ---------------------------------------------------------------- success path
def test_buy_with_all_14_steps_and_evidence(chart):
    _, reading, tech = chart
    d = decide(reading, tech, settings(), [strategy()], [{"title": "Trend rule"}])
    assert d.signal == "BUY" and d.reason_codes == ["strategy_signal"]
    assert [s["n"] for s in d.steps] == list(range(1, 15))
    assert all(s["status"] in ("ok", "info") for s in d.steps)
    assert len(d.supporting) >= 3 and d.duration_sec == 120
    assert d.confidence is not None and d.confidence_calibrated is False  # an estimate, never a probability
    assert d.strategy["oos_win_rate_ci95"] == [0.45, 0.74] and d.strategy["oos_trades"] == 40
    assert any("Trend rule" in r for r in d.reasons)
    assert d.steps[4]["name"] == "forming_candle" and "not assumed closed" in d.steps[4]["detail"]


def test_best_strategy_by_out_of_sample_expectancy_is_chosen(chart):
    _, reading, tech = chart
    d = decide(reading, tech, settings(), [strategy(name="weak", sid=1, oos_exp=0.02),
                                           strategy(name="strong", sid=2, oos_exp=0.2)])
    assert d.signal == "BUY" and d.strategy["name"] == "strong"


# ---------------------------------------------------------------- every WAIT path has a reason
def test_wait_reasons(chart):
    _, reading, tech = chart
    s = settings()
    bad = {**reading, "usable": False, "abstain_reasons": ["image_quality_below_threshold"]}
    assert decide(bad, tech, s, [strategy()]).reason_codes == ["image_quality_insufficient"]
    assert decide(reading, tech, settings(min_data_quality_to_signal=0.99), [strategy()]).reason_codes == \
        ["image_quality_insufficient"]
    other_tf = {**reading, "timeframe_sec": 60}
    assert decide(other_tf, tech, s, [strategy()]).reason_codes == ["timeframe_mismatch"]
    assert decide(reading, {"available": False, "reason": "insufficient_candles"}, s, [strategy()]).reason_codes == \
        ["insufficient_candles"]
    assert decide(reading, tech, s, []).reason_codes == ["no_approved_strategy"]
    d = decide(reading, tech, s, [strategy(tf=60)])  # strategy tested on another timeframe
    assert d.reason_codes == ["no_approved_strategy"] and "tested on 60s" in d.steps[-1]["detail"]
    unapproved = {**strategy(), "status": "testing"}
    assert decide(reading, tech, s, [unapproved]).reason_codes == ["no_approved_strategy"]
    not_qualified = copy.deepcopy(strategy())
    not_qualified["latest_backtest"]["qualifies"] = False
    assert decide(reading, tech, s, [not_qualified]).reason_codes == ["no_approved_strategy"]
    never = strategy(conds_long=({"id": "rsi_below", "value": 1},))
    assert decide(reading, tech, s, [never]).reason_codes == ["strategy_conditions_not_met"]
    both = [strategy(sid=1), strategy(conds_long=(), conds_short=(ALWAYS_DOWN,), sid=2)]
    assert decide(reading, tech, s, both).reason_codes == ["strategies_conflict"]
    assert decide(reading, tech, settings(min_confluence_factors=10), [strategy()]).reason_codes == \
        ["insufficient_confluence"]
    sell = strategy(conds_long=(), conds_short=(ALWAYS_DOWN,))  # selling into a clear uptrend
    assert decide(reading, tech, settings(min_confluence_factors=2), [sell]).reason_codes in (
        ["opposing_factors_dominate"], ["insufficient_confluence"])
    assert decide(reading, tech, settings(min_confidence_to_signal=0.95), [strategy()]).reason_codes == ["low_confidence"]
    assert decide(reading, tech, s, [strategy(duration=600)]).reason_codes == ["duration_outside_settings"]


def test_too_few_closed_candles_for_strategy_features():
    rows = uptrend_rows(n=40)
    reading = ChartReader().read(render_chart(rows, style="dark_tv").image).to_dict()
    tech = analyze_reading(reading)
    d = decide(reading, tech, settings(), [strategy()])
    assert d.signal == "WAIT" and d.reason_codes == ["insufficient_history_for_strategies"]


def test_fingerprint_changes_only_with_a_new_closed_candle(chart):
    _, reading, _ = chart
    assert fingerprint(reading) == fingerprint(copy.deepcopy(reading))
    # dropping only the forming candle changes nothing (it is never assumed closed)
    no_forming = {**reading, "candles": reading["candles"][:-1]}
    assert fingerprint(no_forming) == fingerprint(reading)
    # a different set of closed candles is a new analysis
    fewer_closed = {**reading, "candles": reading["candles"][:-2] + reading["candles"][-1:]}
    assert fingerprint(fewer_closed) != fingerprint(reading)
    assert fingerprint({"candles": []}) == ""


# ---------------------------------------------------------------- full pipeline through the API
def csv_uptrend(n=1500):
    lines, p = ["time,open,high,low,close"], 1.0
    rng = np.random.default_rng(1)
    for i in range(n):
        o = p
        c = o + 0.0004 + rng.normal(0, 0.0002)
        lines.append(f"{1_700_000_000 + i * 30},{o},{max(o, c) + 0.0001},{min(o, c) - 0.0001},{c}")
        p = c
    return "\n".join(lines).encode()


def approved_strategy(client, definition):
    ds = client.post("/datasets/csv", files={"file": ("up.csv", io.BytesIO(csv_uptrend()))}).json()
    s = client.post("/strategies", json={"name": "Trend buyer", "definition": definition}).json()
    r = client.post(f"/strategies/{s['id']}/backtest", json={"dataset_id": ds["id"]}).json()
    assert r["qualifies"], r["gate_reasons"]
    assert client.post(f"/strategies/{s['id']}/approve").json()["status"] == "approved"
    return s


def chart_png():
    return cv2.imencode(".png", render_chart(uptrend_rows(), style="dark_tv").image)[1].tobytes()


def test_end_to_end_buy_signal_recorded_and_shown_on_the_panel(client):
    approved_strategy(client, {"long": {"all": [{"id": "bullish_candle"}]}, "duration_sec": 60})
    client.post("/analysis/start", json={"input_mode": "upload"})
    a = client.post("/analysis/inputs", files={"file": ("c.png", io.BytesIO(chart_png()))}).json()["analysis"]
    assert a["signal"] == "BUY", (a["reason_code"], a["steps"])
    assert a["duration_sec"] == 60 and a["strategy"]["name"] == "Trend buyer" and a["confidence_calibrated"] is False
    assert len(a["steps"]) == 14 and a["supporting"] and a["signal_id"]
    st = client.get("/analysis/status").json()
    assert st["recommendation"]["signal"] == "BUY" and st["recommendation"]["strategy"]["name"] == "Trend buyer"
    sig = client.get("/signals").json()[0]
    assert sig["signal"] == "BUY" and sig["strategy_id"] and sig["duration_sec"] == 60 and sig["confidence_calibrated"] == 0
    assert client.get("/stats/summary").json()["signals"]["BUY"] == 1
    # the same chart again: no new analysis → not recorded twice
    again = client.post("/analysis/inputs", files={"file": ("c.png", io.BytesIO(chart_png()))}).json()["analysis"]
    assert again["repeated"] is True and len(client.get("/signals").json()) == 1
    # emergency stop: back to WAIT immediately
    st = client.post("/analysis/emergency-stop").json()
    assert st["recommendation"]["signal"] == "WAIT"


def test_cooldown_blocks_a_second_trade_signal(client, services):
    approved_strategy(client, {"long": {"all": [{"id": "bullish_candle"}]}, "duration_sec": 60})
    client.patch("/settings", json={"signal_cooldown_sec": 300})
    a1 = client.post("/analysis/inputs", files={"file": ("a.png", io.BytesIO(chart_png()))}).json()["analysis"]
    rows = uptrend_rows(n=81, seed=3)  # one more candle → a new analysis
    png2 = cv2.imencode(".png", render_chart(rows, style="dark_tv").image)[1].tobytes()
    a2 = client.post("/analysis/inputs", files={"file": ("b.png", io.BytesIO(png2))}).json()["analysis"]
    assert a1["signal"] == "BUY"
    assert a2["signal"] == "WAIT" and a2["reason_code"] == "cooldown"


def test_unreadable_image_is_not_recorded_as_a_signal(client):
    blank = cv2.imencode(".png", np.full((400, 700, 3), 30, np.uint8))[1].tobytes()
    a = client.post("/analysis/inputs", files={"file": ("x.png", io.BytesIO(blank))}).json()["analysis"]
    assert a["signal"] == "WAIT" and a["reason_code"] == "image_quality_insufficient"
    assert client.get("/signals").json() == []
