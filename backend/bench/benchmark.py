"""Performance benchmark (Phase 10). Run: python -m bench.benchmark  (from backend/)

Measures the operations that matter for live use on realistic sizes and prints a
Markdown table. Numbers depend on the machine; the report records where they came from.
"""

from __future__ import annotations

import gc
import os
import platform
import resource
import statistics
import tempfile
import time
from pathlib import Path

import numpy as np


def timeit(fn, n):
    out = []
    for _ in range(n):
        t = time.perf_counter()
        fn()
        out.append((time.perf_counter() - t) * 1000)
    out.sort()
    return statistics.median(out), out[int(len(out) * 0.95) - 1] if len(out) >= 20 else out[-1]


def rss_mb():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024


def main():
    from uata.analysis.engine import analyze_reading
    from uata.api.app import create_app
    from uata.config import Paths
    from uata.core.settings_model import Settings
    from uata.signal.engine import decide
    from uata.strategy import datasets as ds
    from uata.strategy.backtest import run_backtest
    from uata.strategy.conditions import validate_definition
    from uata.strategy.features import FeatureSet
    from uata.vision.reader import ChartReader
    from uata.vision.synthetic import random_walk_ohlc, render_chart

    rows = []
    img = render_chart(random_walk_ohlc(120, seed=1), style="dark_tv", width=1920, height=1080).image
    reader_ocr, reader_fast = ChartReader(), ChartReader(use_ocr=False)
    rows.append(("Chart reading 1920×1080, 120 candles, with OCR", *timeit(lambda: reader_ocr.read(img), 20)))
    rows.append(("Chart reading 1920×1080, without OCR", *timeit(lambda: reader_fast.read(img), 20)))
    reading = reader_ocr.read(img).to_dict()
    rows.append(("Technical analysis (15 factors, 119 closed candles)", *timeit(lambda: analyze_reading(reading), 50)))
    tech = analyze_reading(reading)
    strat = {"id": 1, "name": "s", "version": 1, "status": "approved",
             "definition": validate_definition({"long": {"all": [{"id": "bullish_candle"}]}, "duration_sec": 120}),
             "latest_backtest": {"qualifies": True, "params": {"timeframe_sec": 30},
                                 "out_of_sample": {"trades": 40, "win_rate": .6, "win_rate_ci95": [.45, .74],
                                                   "expectancy_per_trade": .1, "by_condition": {}}}}
    st = Settings().model_dump()
    rows.append(("Decision engine (14 steps incl. strategy features)", *timeit(lambda: decide(reading, tech, st, [strat]), 50)))
    full = lambda: decide(r := reader_ocr.read(img).to_dict(), analyze_reading(r), st, [strat])  # noqa: E731
    rows.append(("Full frame pipeline (read+OCR → analysis → decision)", *timeit(full, 10)))

    d = ds.synthetic(20000, 30, seed=2)
    t = time.perf_counter()
    fs = FeatureSet(d["open"], d["high"], d["low"], d["close"])
    feat_ms = (time.perf_counter() - t) * 1000
    rows.append(("Feature precomputation, 20 000 candles", feat_ms, feat_ms))
    defs = validate_definition({"long": {"all": [{"id": "rsi_below", "value": 35}, {"id": "bullish_candle"}]},
                                "short": {"all": [{"id": "rsi_above", "value": 65}, {"id": "bearish_candle"}]}})
    rows.append(("Backtest, 20 000 candles (indicator strategy)", *timeit(lambda: run_backtest(fs, defs, 30), 3)))
    sr = validate_definition({"long": {"all": [{"id": "near_support"}, {"id": "bullish_candle"}]}})
    rows.append(("Backtest, 20 000 candles (support/resistance strategy)", *timeit(lambda: run_backtest(fs, sr, 30), 1)))

    with tempfile.TemporaryDirectory() as tmp:
        app = create_app(Paths(Path(tmp)).ensure(), token="t")
        ks = app.state.services.knowledge
        words = ["RSI", "دعم", "مقاومة", "trend", "engulfing", "hammer", "MACD", "بولينجر", "news", "liquidity"]
        rng = np.random.default_rng(0)
        t = time.perf_counter()
        for i in range(5000):
            ks.add_note(f"note {i}", " ".join(rng.choice(words, 12)) + f" item {i}")
        ingest = (time.perf_counter() - t) * 1000 / 5000
        rows.append(("Library ingest per note (with rule extraction + indexing)", ingest, ingest))
        rows.append(("Hybrid retrieval over 5 000 items", *timeit(lambda: ks.retrieve("RSI oversold support", False, 8), 30)))
        db_mb = Path(tmp, "uata.sqlite3").stat().st_size / 1e6

    gc.collect()
    before = rss_mb()
    for _ in range(200):
        reader_ocr.read(img)
    after = rss_mb()

    print(f"Machine: {platform.processor() or platform.machine()}, {os.cpu_count()} CPU, Python {platform.python_version()}\n")
    print("| Operation | median (ms) | p95 (ms) |\n|---|---|---|")
    for name, med, p95 in rows:
        print(f"| {name} | {med:.1f} | {p95:.1f} |")
    print(f"\nPeak RSS growth over 200 consecutive 1080p readings: {after - before:.1f} MB (peak {after:.0f} MB)")
    print(f"Database size with 5 000 notes (+ rules, FTS and vectors): {db_mb:.1f} MB")


if __name__ == "__main__":
    main()
