"""Reference outputs of the Python engine for the Dart (on-device) engine's parity tests.

Reads one JSON request from stdin, writes the JSON result to stdout:
  {"op": "analyze", "series": [[{"open":..,"high":..,"low":..,"close":..}, ...], ...]}
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uata.analysis.engine import TechnicalAnalyzer, analyze_reading  # noqa: E402
from uata.signal.engine import decide  # noqa: E402
from uata.strategy import conditions as cd  # noqa: E402
from uata.strategy.backtest import gate, run_backtest  # noqa: E402
from uata.strategy.features import FeatureSet  # noqa: E402
from uata.strategy.translate import translate_rules  # noqa: E402


def _fs(series):
    return FeatureSet(*[[c[k] for c in series] for k in ("open", "high", "low", "close")])


def main() -> None:
    req = json.load(sys.stdin)
    op = req["op"]
    if op == "analyze":
        out = [TechnicalAnalyzer().analyze(s, req.get("enabled"), has_volume=req.get("has_volume", False))
               for s in req["series"]]
    elif op == "conditions":
        fs = _fs(req["series"])
        out = {}
        for cid, spec in cd.CATALOG.items():
            for params in req["params"].get(cid, [{}]):
                c = cd.validate({"id": cid, **params})
                out[f"{cid}:{json.dumps(params, sort_keys=True)}"] = [cd.holds(fs, i, c) for i in range(fs.n)]
        out["_signal"] = [cd.signal_at(fs, i, cd.validate_definition(req["definition"])) for i in range(fs.n)]
        out["_trend"] = [fs.trend(i) for i in range(fs.n)]
        out["_market"] = [fs.market_condition(i) for i in range(fs.n)]
        out["_levels"] = [[list(lv) for lv in fs.levels(i)] for i in range(fs.n)]
    elif op == "backtest":
        out = []
        for case in req["cases"]:
            r = run_backtest(_fs(case["series"]), cd.validate_definition(case["definition"]), case["timeframe_sec"],
                             payout=case.get("payout", 0.85), in_sample=case.get("in_sample", 0.7))
            r["gate"] = gate(r, synthetic=case.get("synthetic", False))
            out.append(r)
    elif op == "decide":
        out = []
        for case in req["cases"]:
            tech = analyze_reading(case["reading"], case["settings"].get("indicators"))
            dec = decide(case["reading"], tech, case["settings"], case["strategies"], case.get("knowledge"))
            out.append({"technical": tech, "decision": dec.to_dict()})
    elif op == "render_read":
        # render synthetic charts (any degradation already applied in memory), save them as lossless PNG and
        # read them with OCR off; the Dart reader then reads the very same pixels
        import cv2
        from uata.vision.reader import ChartReader
        from uata.vision.synthetic import degrade, random_walk_ohlc, render_chart, uptrend_ohlc
        out = []
        for case in req["cases"]:
            ohlc = uptrend_ohlc() if case.get("uptrend") else random_walk_ohlc(case.get("n", 60), seed=case.get("seed", 0),
                                                                             vol=case.get("vol", 0.0008))
            img = render_chart(ohlc, **case.get("render", {})).image
            if case.get("degrade"):
                img = degrade(img, **case["degrade"])
            cv2.imwrite(case["path"], img)
            out.append(ChartReader(use_ocr=False).read(cv2.imread(case["path"])).to_dict())
    elif op == "translate":
        out = [translate_rules(r, d) for r, d in req["cases"]]
    else:
        raise SystemExit(f"unknown op {op}")
    json.dump(out, sys.stdout)


if __name__ == "__main__":
    main()
