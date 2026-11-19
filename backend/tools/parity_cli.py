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
            reading = ChartReader(use_ocr=False).read(cv2.imread(case["path"])).to_dict()
            if case.get("limit"):
                from uata.vision.reader import limit_candles
                reading = limit_candles(reading, case["limit"])
            out.append(reading)
    elif op == "backup_make":
        # a computer-side backup with known content, for the phone to restore
        from uata.api.app import build_services
        from uata.config import Paths
        paths = Paths(Path(req["dir"])).ensure()
        svc = build_services(paths)
        svc.strategies.create("From the computer", {"long": {"all": [{"id": "bullish_candle"}]}, "duration_sec": 60})
        svc.settings.update({"language": "en"})
        (paths.files_dir / "datasets").mkdir(parents=True, exist_ok=True)
        (paths.files_dir / "datasets" / "note.txt").write_text("hello from the computer")
        out = {"path": str(svc.backup.create(req["passphrase"]))}
    elif op == "backup_read":
        # open a phone-made backup with the computer's code and report what is inside
        import io, sqlite3, tempfile, zipfile
        from uata.services.backup_service import decrypt_stream
        buf = io.BytesIO()
        with open(req["path"], "rb") as src:
            decrypt_stream(src, buf, req["passphrase"])
        z = zipfile.ZipFile(io.BytesIO(buf.getvalue()))
        with tempfile.TemporaryDirectory() as tmp:
            z.extract("uata.sqlite3", tmp)
            con = sqlite3.connect(Path(tmp) / "uata.sqlite3")
            out = {"manifest": json.loads(z.read("manifest.json")), "names": sorted(z.namelist()),
                   "strategies": [r[0] for r in con.execute("SELECT name FROM strategies ORDER BY id")],
                   "signals": con.execute("SELECT count(*) FROM signals").fetchone()[0],
                   "integrity": con.execute("PRAGMA integrity_check").fetchone()[0]}
            con.close()
    elif op == "kn_text":
        from uata.knowledge.rules import extract_rules
        from uata.knowledge.textnorm import concepts, normalize
        from uata.knowledge.retrieval import HashingEmbedder, expand_query
        emb = HashingEmbedder()
        out = [{"normalized": normalize(t), "concepts": sorted(concepts(t)), "expanded_concepts": sorted(concepts(expand_query(t))),
                "rules": [r.to_dict() for r in extract_rules(t, "x")],
                "features": {k: round(v, 6) for k, v in emb.features(t).items()},
                "vector": [round(float(x), 6) for x in emb.embed(t)]} for t in req["texts"]]
    elif op == "kn_files":
        # build real DOCX/XLSX files with the same libraries users' files come from, extract with the engine
        import docx, openpyxl
        from uata.knowledge import extract as kx
        d = docx.Document()
        for para in req["docx_paragraphs"]:
            d.add_paragraph(para)
        t = d.add_table(rows=len(req["docx_table"]), cols=len(req["docx_table"][0]))
        for i, row in enumerate(req["docx_table"]):
            for j, v in enumerate(row):
                t.cell(i, j).text = v
        d.save(req["docx_path"])
        wb = openpyxl.Workbook()
        ws = wb.active
        ws.title = "Rules"
        for row in req["xlsx_rows"]:
            ws.append(row)
        ws2 = wb.create_sheet("Long")
        for i in range(95):
            ws2.append([f"row {i}", i, i * 1.5])
        wb.save(req["xlsx_path"])
        out = {k: [{"text": c.text, "location": c.location} for c in kx.extract(k, Path(req[f"{k}_path"]))]
               for k in ("docx", "xlsx")}
        out["txt"] = [{"text": c.text, "location": c.location} for c in kx.extract_txt(req["txt"].encode())]
    elif op == "kn_search":
        from uata.db.database import Database
        from uata.services.knowledge_service import KnowledgeService
        db = Database(Path(req["dir"]) / "k.sqlite3")
        db.migrate()
        ks = KnowledgeService(db, Path(req["dir"]) / "files")
        for n in req["notes"]:
            src = ks.add_note(n["title"], n["content"])
            if n.get("approve"):
                ks.decide_report(src["report"]["id"], "approve")
        out = {q: [h["title"] for h in ks.retrieve(q, approved_only, 8)]
               for q in req["queries"] for approved_only in [req.get("approved_only", True)]}
    elif op == "translate":
        out = [translate_rules(r, d) for r, d in req["cases"]]
    else:
        raise SystemExit(f"unknown op {op}")
    json.dump(out, sys.stdout)


if __name__ == "__main__":
    main()
