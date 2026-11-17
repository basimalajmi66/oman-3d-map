"""Phase 9: results from signals, dashboard separated by account, insights with minimum samples,
and strategy review suggestions that never change a strategy automatically."""
import io

import pytest

from test_signal import approved_strategy, chart_png  # reuse the Phase 8 end-to-end helpers


def add(services, n, outcome, account="demo", **kw):
    for i in range(n):
        services.records.add_result({
            "account_type": account, "asset": kw.get("asset", "EURUSD"), "timeframe_sec": 30,
            "signal_type": kw.get("side", "BUY"), "signal_time": kw.get("time", f"2026-11-17T{10 + i % 8:02d}:00:00+00:00"),
            "duration_sec": 60, "outcome": outcome, "market_condition": kw.get("condition", "trending"),
            "strategy_id": kw.get("strategy_id"), "confidence": kw.get("confidence"), "data_quality": kw.get("quality"),
            "pnl": kw.get("pnl")})


# ---------------------------------------------------------------- results from signals
def test_record_result_from_signal_copies_context(client):
    approved_strategy(client, {"long": {"all": [{"id": "bullish_candle"}]}, "duration_sec": 60})
    a = client.post("/analysis/inputs", files={"file": ("c.png", io.BytesIO(chart_png()))}).json()["analysis"]
    assert a["signal"] == "BUY"
    r = client.post(f"/signals/{a['signal_id']}/result", json={"account_type": "demo", "outcome": "win", "asset": "EURUSD"})
    assert r.status_code == 201
    res = r.json()
    assert res["signal_id"] == a["signal_id"] and res["signal_type"] == "BUY" and res["duration_sec"] == 60
    assert res["strategy_id"] == a["strategy"]["id"] and res["market_condition"] in ("trending", "ranging", "volatile")
    assert res["confidence"] == a["confidence"] and res["data_quality"] == a["data_quality"]
    dup = client.post(f"/signals/{a['signal_id']}/result", json={"account_type": "demo", "outcome": "loss"})
    assert dup.status_code == 400  # one result per signal
    assert client.post("/signals/999/result", json={"account_type": "demo", "outcome": "win"}).status_code == 404


def test_wait_signal_has_no_result(client, services):
    w = services.records.record_signal(signal="WAIT", timeframe_sec=30, data_basis="image_only", reasons=["x"],
                                       supporting=[], opposing=[], data_quality=0.9)
    r = client.post(f"/signals/{w['id']}/result", json={"account_type": "demo", "outcome": "win"})
    assert r.status_code == 400


# ---------------------------------------------------------------- dashboard
def test_accounts_are_never_mixed(client, services):
    add(services, 8, "win", "demo")
    add(services, 2, "loss", "demo")
    add(services, 1, "win", "real")
    add(services, 4, "loss", "real")
    demo = client.get("/stats/dashboard", params={"account_type": "demo"}).json()
    real = client.get("/stats/dashboard", params={"account_type": "real"}).json()
    assert demo["results"]["wins"] == 8 and demo["results"]["win_rate"] == 0.8
    assert real["results"]["wins"] == 1 and real["results"]["win_rate"] == 0.2
    assert real["results"]["sufficient_sample"] is False  # 5 decided < 10
    assert demo["results"]["win_rate_ci95"][0] < 0.8 < demo["results"]["win_rate_ci95"][1]
    sim = client.get("/stats/dashboard", params={"account_type": "simulation"}).json()
    assert sim["results"]["trades"] == 0 and sim["results"]["win_rate"] is None
    assert client.get("/stats/dashboard", params={"account_type": "paper"}).status_code == 400


def test_groups_include_every_requested_breakdown(client, services):
    add(services, 6, "win", condition="trending", asset="EURUSD", confidence=0.85, quality=0.95)
    add(services, 6, "loss", condition="ranging", asset="GBPUSD", confidence=0.66, quality=0.65, side="SELL")
    d = client.get("/stats/dashboard").json()
    for key in ("by_strategy", "by_asset", "by_timeframe", "by_condition", "by_direction", "by_hour",
                "by_confidence", "by_data_quality", "training_log"):
        assert key in d
    by_cond = {g["key"]: g for g in d["by_condition"]}
    assert by_cond["trending"]["win_rate"] == 1.0 and by_cond["ranging"]["win_rate"] == 0.0
    assert {g["key"] for g in d["by_confidence"]} == {"0.8-0.9", "0.6-0.7"}


# ---------------------------------------------------------------- insights
def test_no_findings_below_minimum_sample(client, services):
    add(services, 3, "win")
    add(services, 2, "loss")
    assert client.get("/stats/insights").json() == [{"code": "insufficient_sample", "sample": 5, "needed": 10}]


def test_condition_worse_streak_and_concentrated_losses(client, services):
    add(services, 30, "win", condition="trending")
    add(services, 12, "loss", condition="ranging")
    add(services, 3, "win", condition="ranging")
    ins = client.get("/stats/insights").json()
    codes = {(i["code"], i.get("key")) for i in ins}
    assert ("condition_worse", "ranging") in codes
    assert ("condition_better", "trending") in codes
    assert any(i["code"] == "losing_streak" and i["length"] >= 5 for i in ins)
    assert any(i["code"] == "losses_concentrated" and i["key"] == "ranging" for i in ins)


def test_confidence_calibration_evidence(client, services):
    add(services, 8, "win", confidence=0.85)
    add(services, 2, "loss", confidence=0.85)
    add(services, 3, "win", confidence=0.65)
    add(services, 7, "loss", confidence=0.65)
    ins = client.get("/stats/insights").json()
    cal = next(i for i in ins if i["code"].startswith("confidence_"))
    assert cal["code"] == "confidence_consistent"
    add(services, 20, "loss", confidence=0.95)  # the highest estimate bucket loses → not consistent
    ins = client.get("/stats/insights").json()
    assert any(i["code"] == "confidence_inconsistent" for i in ins)


def test_underperforming_strategy_gets_review_suggestion_but_stays_approved(client, services):
    s = approved_strategy(client, {"long": {"all": [{"id": "bullish_candle"}]}, "duration_sec": 60})
    add(services, 6, "loss", strategy_id=s["id"])
    add(services, 4, "win", strategy_id=s["id"])
    ins = client.get("/stats/insights").json()
    assert any(i["code"] == "strategy_review_pending_sample" and i["sample"] == 10 for i in ins)
    add(services, 20, "loss", strategy_id=s["id"])  # 4 wins / 30 decided — far below the backtest
    ins = client.get("/stats/insights").json()
    review = next(i for i in ins if i["code"] == "strategy_review_suggested")
    assert review["strategy_id"] == s["id"] and review["sample"] == 30
    assert review["live_ci95"][1] < review["backtest_ci95"][0]
    # never changed automatically: still approved until the user decides
    assert client.get(f"/strategies/{s['id']}").json()["status"] == "approved"
