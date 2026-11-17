from uata.core.settings_model import INDICATORS


def test_defaults_match_spec(client):
    s = client.get("/settings").json()
    assert s["candle_timeframe_sec"] == 30
    assert s["trade_duration_min_sec"] == 60
    assert s["trade_duration_max_sec"] == 180
    assert s["trading_mode"] == "manual"
    assert s["continuous_analysis"] is False
    assert s["screen_capture_allowed"] is False
    assert s["min_confluence_factors"] >= 2
    assert set(s["indicators"]) == set(INDICATORS)


def test_partial_update_persists(client, app, paths):
    r = client.patch("/settings", json={"language": "en", "indicators": {"rsi": False}})
    assert r.status_code == 200
    assert r.json()["language"] == "en"
    assert r.json()["indicators"]["rsi"] is False
    assert r.json()["indicators"]["macd"] is True  # untouched
    # survives a "restart": new app over the same data dir
    from uata.api.app import create_app
    from fastapi.testclient import TestClient
    c2 = TestClient(create_app(paths, token="t2"))
    s = c2.get("/settings", headers={"X-UATA-Token": "t2"}).json()
    assert s["language"] == "en" and s["indicators"]["rsi"] is False


def test_auto_trading_mode_is_impossible(client):
    r = client.patch("/settings", json={"trading_mode": "auto"})
    assert r.status_code == 422
    assert client.get("/settings").json()["trading_mode"] == "manual"


def test_invalid_values_rejected(client):
    assert client.patch("/settings", json={"candle_timeframe_sec": 7}).status_code == 422
    assert client.patch("/settings", json={"trade_duration_min_sec": 300,
                                           "trade_duration_max_sec": 120}).status_code == 422
    assert client.patch("/settings", json={"unknown_key": 1}).status_code == 422
    assert client.patch("/settings", json={"indicators": {"made_up": True}}).status_code == 422


def test_cannot_disable_all_but_one_factor(client):
    off = {name: False for name in INDICATORS}
    off["rsi"] = True
    assert client.patch("/settings", json={"indicators": off}).status_code == 422


def test_reset(client):
    client.patch("/settings", json={"language": "en"})
    assert client.post("/settings/reset").json()["language"] == "ar"
