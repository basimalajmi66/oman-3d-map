"""Historical price datasets: CSV import (user's real data) and labelled synthetic data.

CSV: a header row with a time column (time/date/datetime/timestamp) and
open/high/low/close (volume optional), any order, comma or semicolon separated.
Rows are validated (OHLC consistency, strictly increasing time); the timeframe is
inferred from the median time step. Synthetic data is always flagged
``is_synthetic`` and can never qualify a strategy for approval.
"""

from __future__ import annotations

import csv
import io
from datetime import datetime, timezone

import numpy as np

TIME_COLS = ("time", "date", "datetime", "timestamp", "date_time", "open_time")


class DatasetError(ValueError):
    pass


def _parse_time(s: str) -> float:
    s = s.strip()
    try:
        v = float(s)
        return v / 1000 if v > 1e11 else v  # epoch ms or s
    except ValueError:
        pass
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M", "%Y.%m.%d %H:%M:%S", "%Y.%m.%d %H:%M",
                "%d/%m/%Y %H:%M:%S", "%d/%m/%Y %H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(s.replace("Z", ""), fmt).replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError as e:
        raise DatasetError(f"unrecognised time value: {s!r}") from e


def parse_csv(text: str, max_rows: int = 500_000) -> dict:
    sample = text[:4096]
    delim = ";" if sample.count(";") > sample.count(",") else ","
    reader = csv.reader(io.StringIO(text), delimiter=delim)
    header = [h.strip().lower().lstrip("<").rstrip(">") for h in next(reader, [])]
    idx = {name: header.index(name) for name in ("open", "high", "low", "close", "volume") if name in header}
    tcol = next((header.index(c) for c in TIME_COLS if c in header), None)
    missing = [c for c in ("open", "high", "low", "close") if c not in idx]
    if missing or tcol is None:
        raise DatasetError(f"CSV needs a time column and open/high/low/close (missing: {missing or ['time']})")
    t, o, h, l_, c, v = [], [], [], [], [], []
    for n, row in enumerate(reader, start=2):
        if not row or not any(x.strip() for x in row):
            continue
        if len(t) >= max_rows:
            raise DatasetError(f"too many rows (max {max_rows})")
        try:
            ts = _parse_time(row[tcol])
            oo, hh, ll, cc = (float(row[idx[k]].replace(",", ".") if delim == ";" else row[idx[k]])
                              for k in ("open", "high", "low", "close"))
            vv = float(row[idx["volume"]]) if "volume" in idx and row[idx["volume"]].strip() else None
        except (ValueError, IndexError) as e:
            raise DatasetError(f"row {n}: {e}") from e
        if not (ll <= min(oo, cc) and hh >= max(oo, cc)):
            raise DatasetError(f"row {n}: inconsistent candle (low <= open/close <= high required)")
        t.append(ts), o.append(oo), h.append(hh), l_.append(ll), c.append(cc), v.append(vv)
    if len(t) < 100:
        raise DatasetError("at least 100 candles are needed for a meaningful test")
    ta = np.array(t)
    if np.any(np.diff(ta) <= 0):
        raise DatasetError("time must be strictly increasing (sorted, no duplicates)")
    tf = int(round(float(np.median(np.diff(ta)))))
    has_vol = all(x is not None for x in v)
    return {"time": t, "open": o, "high": h, "low": l_, "close": c, "volume": v if has_vol else None,
            "timeframe_sec": tf, "rows": len(t)}


def synthetic(n: int = 3000, timeframe_sec: int = 30, seed: int = 0, start: float = 1.1) -> dict:
    """Regime-switching random walk (trending / ranging / volatile). Labelled synthetic — never market data."""
    rng = np.random.default_rng(seed)
    t0 = 1_700_000_000
    p, out = start, {"time": [], "open": [], "high": [], "low": [], "close": []}
    regime, left = "ranging", 0
    for i in range(n):
        if left <= 0:
            regime = rng.choice(["trending_up", "trending_down", "ranging", "volatile"])
            left = int(rng.integers(80, 300))
        left -= 1
        drift = {"trending_up": 0.00015, "trending_down": -0.00015}.get(regime, 0.0)
        vol = 0.0012 if regime == "volatile" else 0.0005
        o = p
        c = o + drift + rng.normal(0, vol)
        h = max(o, c) + abs(rng.normal(0, vol * 0.5))
        lo = min(o, c) - abs(rng.normal(0, vol * 0.5))
        for k, val in (("time", t0 + i * timeframe_sec), ("open", o), ("high", h), ("low", lo), ("close", c)):
            out[k].append(round(val, 6) if k != "time" else val)
        p = c
    return {**out, "volume": None, "timeframe_sec": timeframe_sec, "rows": n}


def to_csv(d: dict) -> str:
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["time", "open", "high", "low", "close", "volume"])
    vol = d.get("volume") or [None] * len(d["time"])
    for row in zip(d["time"], d["open"], d["high"], d["low"], d["close"], vol):
        w.writerow(["" if x is None else x for x in row])
    return buf.getvalue()
