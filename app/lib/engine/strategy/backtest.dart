/// Fixed-time (expiry) backtester without look-ahead (port of strategy/backtest.py).
///
/// Signal on closed bar i → entry at the open of bar i+1 → exit at the close of bar i + bars;
/// win / loss / draw with a fixed payout; one trade at a time; in-sample / out-of-sample split by time.
library;

import 'dart:math' as math;

import '../util.dart';
import 'conditions.dart';
import 'features.dart';

class Trade {
  Trade(this.signalBar, this.entryBar, this.exitBar, this.side, this.entry, this.exit, this.outcome, this.pnl,
      this.condition);
  final int signalBar, entryBar, exitBar;
  final String side;
  final double entry, exit;
  final String outcome; // win | loss | draw
  final double pnl;
  final String condition; // market condition at signal time

  Map<String, dynamic> toJson() => {
        'signal_bar': signalBar, 'entry_bar': entryBar, 'exit_bar': exitBar, 'side': side, 'entry': entry,
        'exit': exit, 'outcome': outcome, 'pnl': pnl, 'condition': condition,
      };
}

(double, double) wilson(int k, int n, [double z = 1.96]) {
  if (n == 0) return (0.0, 1.0);
  final p = k / n;
  final denom = 1 + z * z / n;
  final centre = (p + z * z / (2 * n)) / denom;
  final half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom;
  return (math.max(0.0, centre - half), math.min(1.0, centre + half));
}

Map<String, dynamic> metrics(List<Trade> trades, double payout, int barsTotal) {
  final n = trades.length;
  final wins = trades.where((t) => t.outcome == 'win').length;
  final losses = trades.where((t) => t.outcome == 'loss').length;
  final decided = wins + losses;
  final equity = <double>[];
  var run = 0.0, peak = double.negativeInfinity, maxDd = 0.0;
  for (final t in trades) {
    run += t.pnl;
    equity.add(run);
    peak = math.max(peak, run);
    maxDd = math.max(maxDd, peak - run);
  }
  var streak = 0, longest = 0;
  for (final t in trades) {
    streak = t.outcome == 'loss' ? streak + 1 : 0;
    longest = math.max(longest, streak);
  }
  final (lo, hi) = wilson(wins, decided);
  final breakeven = 1 / (1 + payout);
  final grossWin = wins * payout, grossLoss = losses.toDouble();
  final step = math.max(1, n ~/ 200);
  final total = trades.fold<double>(0, (s, t) => s + t.pnl);
  return {
    'trades': n, 'wins': wins, 'losses': losses, 'draws': n - wins - losses,
    'win_rate': decided > 0 ? roundTo(wins / decided, 4) : null,
    'win_rate_ci95': decided > 0 ? [roundTo(lo, 4), roundTo(hi, 4)] : null,
    'breakeven_win_rate': roundTo(breakeven, 4),
    // statistically better than breakeven only if the whole 95% interval is above it
    'significant_edge': decided > 0 && lo > breakeven,
    'expectancy_per_trade': n > 0 ? roundTo(total / n, 4) : null,
    'total_return_units': roundTo(total, 3),
    'profit_factor': grossLoss > 0 ? roundTo(grossWin / grossLoss, 3) : null,
    'max_drawdown_units': roundTo(maxDd, 3),
    'longest_losing_streak': longest,
    'trades_per_1000_bars': roundTo(n / math.max(1, barsTotal) * 1000, 2),
    'equity_curve': [for (var q = 0; q < equity.length; q += step) roundTo(equity[q], 3)],
  };
}

Map<String, dynamic> byCondition(List<Trade> trades, double payout) => {
      for (final cond in const ['trending', 'ranging', 'volatile'])
        cond: () {
          final m = metrics(trades.where((t) => t.condition == cond).toList(), payout, 1);
          return {for (final k in const ['trades', 'win_rate', 'expectancy_per_trade', 'win_rate_ci95']) k: m[k]};
        }(),
    };

Map<String, dynamic> runBacktest(FeatureSet fs, Map definition, int timeframeSec,
    {double payout = 0.85, double inSample = 0.7, int start = 0, int? end}) {
  if (!(payout > 0 && payout <= 2)) throw StrategyError('payout must be in (0, 2]');
  if (!(inSample >= 0.3 && inSample <= 0.9)) throw StrategyError('in_sample must be between 0.3 and 0.9');
  final bars = math.max(1, ((definition['duration_sec'] as num) / timeframeSec).ceil());
  final e = end == null ? fs.n : math.min(end, fs.n);
  final split = start + ((e - start) * inSample).truncate();
  final trades = <Trade>[];
  var i = start;
  while (i + 1 + bars - 1 < e) {
    final side = signalAt(fs, i, definition);
    if (side == null) {
      i += 1;
      continue;
    }
    final eBar = i + 1, xBar = i + bars;
    final entry = fs.o[eBar], exit = fs.c[xBar];
    final move = side == 'BUY' ? exit - entry : entry - exit;
    final outcome = move > 0 ? 'win' : move < 0 ? 'loss' : 'draw';
    final pnl = outcome == 'win' ? payout : outcome == 'loss' ? -1.0 : 0.0;
    trades.add(Trade(i, eBar, xBar, side, entry, exit, outcome, pnl, fs.marketCondition(i)));
    i = xBar; // one trade at a time
  }
  final isTrades = trades.where((t) => t.signalBar < split).toList();
  final oosTrades = trades.where((t) => t.signalBar >= split).toList();
  return {
    'bars_per_trade': bars,
    'payout': payout,
    'split_bar': split,
    'in_sample': {...metrics(isTrades, payout, split - start), 'by_condition': byCondition(isTrades, payout)},
    'out_of_sample': {...metrics(oosTrades, payout, e - split), 'by_condition': byCondition(oosTrades, payout)},
    'all': metrics(trades, payout, e - start),
    'trades_sample': [for (final t in trades.sublist(math.max(0, trades.length - 50))) t.toJson()],
  };
}

/// Gate for approving a strategy (user approval is still required on top).
const gateMinOosTrades = 30;

List<String> gate(Map result, {required bool synthetic}) {
  final oos = result['out_of_sample'] as Map;
  return [
    if (synthetic) 'tested_on_synthetic_data_only',
    if ((oos['trades'] as int) < gateMinOosTrades) 'too_few_out_of_sample_trades',
    if (oos['expectancy_per_trade'] == null || (oos['expectancy_per_trade'] as num) <= 0)
      'non_positive_out_of_sample_expectancy',
    if (oos['profit_factor'] != null && (oos['profit_factor'] as num) <= 1) 'profit_factor_not_above_1',
  ];
}
