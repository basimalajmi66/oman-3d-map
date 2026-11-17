"""Fixed-time (expiry) backtester without look-ahead.

Mechanics (matches manual 1–3 minute fixed-duration trades):
* the signal is computed on **closed** bar ``i`` (causal features);
* entry price = **open of bar i+1** (you cannot trade the close you just saw);
* expiry after ``bars = ceil(duration / timeframe)`` bars → exit price = close of bar ``i + bars``;
* win if price moved in the trade's direction, loss if against, draw if unchanged;
* P&L per unit stake: win = +payout, loss = −1, draw = 0 (refund) — payout is the cost
  model of fixed-time products (e.g. 0.85 means the broker keeps 15%);
* one trade at a time: the next signal is only considered after the previous expiry.

Out-of-sample: the series is split by time; the first ``in_sample`` fraction is
reported separately from the rest. Features for the out-of-sample part still only
use past data, and no parameter is fitted here, so nothing leaks across the split.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from uata.strategy.conditions import signal_at
from uata.strategy.features import FeatureSet


@dataclass
class Trade:
    signal_bar: int
    entry_bar: int
    exit_bar: int
    side: str
    entry: float
    exit: float
    outcome: str      # win | loss | draw
    pnl: float
    condition: str    # market condition at signal time


def wilson(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    if n == 0:
        return 0.0, 1.0
    p = k / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return max(0.0, centre - half), min(1.0, centre + half)


def metrics(trades: list[Trade], payout: float, bars_total: int) -> dict:
    n = len(trades)
    wins = sum(t.outcome == "win" for t in trades)
    losses = sum(t.outcome == "loss" for t in trades)
    draws = n - wins - losses
    decided = wins + losses
    pnl = np.array([t.pnl for t in trades]) if trades else np.zeros(0)
    equity = np.cumsum(pnl) if n else np.zeros(0)
    peak = np.maximum.accumulate(equity) if n else np.zeros(0)
    max_dd = float((peak - equity).max()) if n else 0.0
    streak = longest = 0
    for t in trades:
        streak = streak + 1 if t.outcome == "loss" else 0
        longest = max(longest, streak)
    lo, hi = wilson(wins, decided)
    breakeven = 1 / (1 + payout)
    gross_win, gross_loss = wins * payout, float(losses)
    step = max(1, n // 200)
    return {
        "trades": n, "wins": wins, "losses": losses, "draws": draws,
        "win_rate": round(wins / decided, 4) if decided else None,
        "win_rate_ci95": [round(lo, 4), round(hi, 4)] if decided else None,
        "breakeven_win_rate": round(breakeven, 4),
        # statistically better than breakeven only if the whole 95% interval is above it
        "significant_edge": bool(decided and lo > breakeven),
        "expectancy_per_trade": round(float(pnl.mean()), 4) if n else None,
        "total_return_units": round(float(pnl.sum()), 3),
        "profit_factor": round(gross_win / gross_loss, 3) if gross_loss else None,
        "max_drawdown_units": round(max_dd, 3),
        "longest_losing_streak": longest,
        "trades_per_1000_bars": round(n / max(1, bars_total) * 1000, 2),
        "equity_curve": [round(float(x), 3) for x in equity[::step]],
    }


def by_condition(trades: list[Trade], payout: float) -> dict:
    out = {}
    for cond in ("trending", "ranging", "volatile"):
        ts = [t for t in trades if t.condition == cond]
        m = metrics(ts, payout, 1)
        out[cond] = {k: m[k] for k in ("trades", "win_rate", "expectancy_per_trade", "win_rate_ci95")}
    return out


def run_backtest(fs: FeatureSet, definition: dict, timeframe_sec: int, payout: float = 0.85,
                 in_sample: float = 0.7, start: int = 0, end: int | None = None) -> dict:
    if not 0 < payout <= 2:
        raise ValueError("payout must be in (0, 2]")
    if not 0.3 <= in_sample <= 0.9:
        raise ValueError("in_sample must be between 0.3 and 0.9")
    bars = max(1, math.ceil(definition["duration_sec"] / timeframe_sec))
    end = fs.n if end is None else min(end, fs.n)
    split = start + int((end - start) * in_sample)
    trades: list[Trade] = []
    i = start
    while i + 1 + bars - 1 < end:  # need the entry bar and the expiry bar
        side = signal_at(fs, i, definition)
        if side is None:
            i += 1
            continue
        e_bar, x_bar = i + 1, i + bars
        entry, exit_ = fs.o[e_bar], fs.c[x_bar]
        move = exit_ - entry if side == "BUY" else entry - exit_
        outcome = "win" if move > 0 else "loss" if move < 0 else "draw"
        pnl = payout if outcome == "win" else -1.0 if outcome == "loss" else 0.0
        trades.append(Trade(i, e_bar, x_bar, side, float(entry), float(exit_), outcome, pnl, fs.market_condition(i)))
        i = x_bar  # one trade at a time; next decision on the expiry bar's close
    is_trades = [t for t in trades if t.signal_bar < split]
    # out-of-sample trades must start after the split AND must not overlap it
    oos_trades = [t for t in trades if t.signal_bar >= split]
    return {
        "bars_per_trade": bars,
        "payout": payout,
        "split_bar": split,
        "in_sample": {**metrics(is_trades, payout, split - start), "by_condition": by_condition(is_trades, payout)},
        "out_of_sample": {**metrics(oos_trades, payout, end - split), "by_condition": by_condition(oos_trades, payout)},
        "all": metrics(trades, payout, end - start),
        "trades_sample": [t.__dict__ for t in trades[-50:]],
    }


# gate for approving a strategy (user approval is still required on top)
GATE_MIN_OOS_TRADES = 30


def gate(result: dict, synthetic: bool) -> list[str]:
    """Reasons why a backtest does NOT qualify a strategy for approval (empty list = qualifies)."""
    oos = result["out_of_sample"]
    reasons = []
    if synthetic:
        reasons.append("tested_on_synthetic_data_only")
    if oos["trades"] < GATE_MIN_OOS_TRADES:
        reasons.append("too_few_out_of_sample_trades")
    if oos["expectancy_per_trade"] is None or oos["expectancy_per_trade"] <= 0:
        reasons.append("non_positive_out_of_sample_expectancy")
    if oos["profit_factor"] is not None and oos["profit_factor"] <= 1:
        reasons.append("profit_factor_not_above_1")
    return reasons
