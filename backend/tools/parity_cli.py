"""Reference outputs of the Python engine for the Dart (on-device) engine's parity tests.

Reads one JSON request from stdin, writes the JSON result to stdout:
  {"op": "analyze", "series": [[{"open":..,"high":..,"low":..,"close":..}, ...], ...]}
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uata.analysis.engine import TechnicalAnalyzer  # noqa: E402


def main() -> None:
    req = json.load(sys.stdin)
    op = req["op"]
    if op == "analyze":
        out = [TechnicalAnalyzer().analyze(s, req.get("enabled"), has_volume=req.get("has_volume", False))
               for s in req["series"]]
    else:
        raise SystemExit(f"unknown op {op}")
    json.dump(out, sys.stdout)


if __name__ == "__main__":
    main()
