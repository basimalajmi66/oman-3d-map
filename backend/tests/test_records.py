import pytest


def _result(**kw):
    base = {"account_type": "demo", "asset": "EURUSD", "timeframe_sec": 30, "signal_type": "BUY",
            "signal_time": "2026-11-17T10:00:00Z", "duration_sec": 120, "outcome": "win"}
    return {**base, **kw}


def test_signal_rules_enforced(services):
    rec = services.records
    w = rec.record_signal(signal="WAIT", timeframe_sec=30, data_basis="image_only", reasons=["low quality"],
                          supporting=[], opposing=[], data_quality=0.3)
    assert w["signal"] == "WAIT" and w["confidence_calibrated"] == 0
    with pytest.raises(ValueError):  # no duration
        rec.record_signal(signal="BUY", timeframe_sec=30, data_basis="image_only", reasons=["r"],
                          supporting=["a", "b", "c"], opposing=[], data_quality=0.9)
    with pytest.raises(ValueError):  # single-factor signal
        rec.record_signal(signal="SELL", timeframe_sec=30, data_basis="image_only", reasons=["r"],
                          supporting=["rsi"], opposing=[], data_quality=0.9, duration_sec=60)
    ok = rec.record_signal(signal="BUY", timeframe_sec=30, data_basis="price_feed", reasons=["r"],
                           supporting=["trend", "support", "engulfing"], opposing=["rsi high"],
                           data_quality=0.9, confidence=0.7, duration_sec=120)
    assert ok["supporting"] == ["trend", "support", "engulfing"]


def test_results_separated_by_account(client):
    client.post("/results", json=_result(account_type="demo", outcome="win"))
    client.post("/results", json=_result(account_type="demo", outcome="loss"))
    client.post("/results", json=_result(account_type="real", outcome="loss"))
    client.post("/results", json=_result(account_type="simulation", outcome="draw"))
    s = client.get("/stats/summary").json()["results_by_account"]
    assert s["demo"]["wins"] == 1 and s["demo"]["losses"] == 1 and s["demo"]["win_rate"] == 0.5
    assert s["real"]["wins"] == 0 and s["real"]["win_rate"] == 0.0 and s["real"]["sample_size"] == 1
    assert s["simulation"]["win_rate"] is None  # draws only: no rate invented
    assert len(client.get("/results", params={"account_type": "demo"}).json()) == 2


def test_result_validation(client):
    assert client.post("/results", json=_result(account_type="paper")).status_code == 400
    assert client.post("/results", json=_result(outcome="maybe")).status_code == 400
    assert client.post("/results", json=_result(signal_type="WAIT")).status_code == 400


def test_delete_result(client):
    rid = client.post("/results", json=_result()).json()["id"]
    assert client.delete(f"/results/{rid}").status_code == 200
    assert client.delete(f"/results/{rid}").status_code == 404


def test_signal_list_and_summary(client, services):
    services.records.record_signal(signal="WAIT", timeframe_sec=30, data_basis="image_only", reasons=[],
                                   supporting=[], opposing=[], data_quality=None)
    assert len(client.get("/signals").json()) == 1
    assert client.get("/stats/summary").json()["signals"] == {"total": 1, "BUY": 0, "SELL": 0, "WAIT": 1}
