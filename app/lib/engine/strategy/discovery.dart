/// Strategy discovery: try many combinations of known conditions on real prices — honestly.
///
/// 1. Candidates: a trigger (RSI levels, Bollinger, MACD cross, candle patterns, breakout, momentum) × a filter
///    (none, support/resistance, with / against the trend, sideways, ranging / trending market, EMA) × durations,
///    always mirrored (buy setup and its sell twin).
/// 2. Search on the first 60% of the history only; keep the 10 best by the *lower* end of their win-rate interval
///    (needs >= 40 trades and a positive result there).
/// 3. Judge those 10 once on the last 40% — data the search never saw — with a correction for having tried many
///    (Bonferroni over the 10 finalists, after picking them from all candidates on separate data).
/// Nothing is approved here: a finalist can be saved as a strategy, which then goes through the normal backtest and
/// approval gate.
library;

import 'dart:math' as math;

import '../util.dart';
import 'backtest.dart' show metrics, Trade, wilson;
import 'conditions.dart' show signalAt;
import 'features.dart';

typedef Cond = Map<String, dynamic>;

/// (name in Arabic, name in English, long conditions, short conditions)
typedef Setup = (String, String, List<Cond>, List<Cond>);

const _triggers = <Setup>[
  ('RSI < 20 / > 80', 'RSI < 20 / > 80', [{'id': 'rsi_below', 'value': 20}], [{'id': 'rsi_above', 'value': 80}]),
  ('RSI < 25 / > 75', 'RSI < 25 / > 75', [{'id': 'rsi_below', 'value': 25}], [{'id': 'rsi_above', 'value': 75}]),
  ('RSI < 30 / > 70', 'RSI < 30 / > 70', [{'id': 'rsi_below', 'value': 30}], [{'id': 'rsi_above', 'value': 70}]),
  ('RSI < 35 / > 65', 'RSI < 35 / > 65', [{'id': 'rsi_below', 'value': 35}], [{'id': 'rsi_above', 'value': 65}]),
  ('خارج بولينجر', 'outside Bollinger', [{'id': 'bb_below_lower'}], [{'id': 'bb_above_upper'}]),
  ('تقاطع MACD', 'MACD cross', [{'id': 'macd_cross_up'}], [{'id': 'macd_cross_down'}]),
  ('المطرقة / الشهاب', 'hammer / shooting star', [{'id': 'pattern', 'name': 'hammer'}], [{'id': 'pattern', 'name': 'shooting_star'}]),
  ('الابتلاع', 'engulfing', [{'id': 'pattern', 'name': 'bullish_engulfing'}], [{'id': 'pattern', 'name': 'bearish_engulfing'}]),
  ('نجمة الصباح / المساء', 'morning / evening star', [{'id': 'pattern', 'name': 'morning_star'}], [{'id': 'pattern', 'name': 'evening_star'}]),
  ('المطرقة المقلوبة / الرجل المشنوق', 'inverted hammer / hanging man', [{'id': 'pattern', 'name': 'inverted_hammer'}], [{'id': 'pattern', 'name': 'hanging_man'}]),
  ('اختراق مستوى', 'level breakout', [{'id': 'breakout_up'}], [{'id': 'breakdown'}]),
  ('زخم', 'momentum', [{'id': 'momentum_up', 'atr': 1.0}], [{'id': 'momentum_down', 'atr': 1.0}]),
  ('زخم قوي', 'strong momentum', [{'id': 'momentum_up', 'atr': 1.5}], [{'id': 'momentum_down', 'atr': 1.5}]),
  ('شمعة باتجاه', 'candle colour', [{'id': 'bullish_candle'}], [{'id': 'bearish_candle'}]),
];

const _filters = <Setup>[
  ('', '', [], []),
  ('عند الدعم / المقاومة', 'at support / resistance', [{'id': 'near_support', 'atr': 0.6}], [{'id': 'near_resistance', 'atr': 0.6}]),
  ('مع الاتجاه', 'with the trend', [{'id': 'trend_up'}], [{'id': 'trend_down'}]),
  ('عكس الاتجاه', 'against the trend', [{'id': 'trend_down'}], [{'id': 'trend_up'}]),
  ('سوق عرضي', 'sideways market', [{'id': 'trend_sideways'}], [{'id': 'trend_sideways'}]),
  ('سوق متذبذب', 'ranging market', [{'id': 'market', 'condition': 'ranging'}], [{'id': 'market', 'condition': 'ranging'}]),
  ('سوق متجه', 'trending market', [{'id': 'market', 'condition': 'trending'}], [{'id': 'market', 'condition': 'trending'}]),
  ('ترتيب المتوسطات', 'EMA alignment', [{'id': 'ema_bull_alignment'}], [{'id': 'ema_bear_alignment'}]),
  ('مع EMA 21', 'with EMA 21', [{'id': 'price_above_ema', 'period': 21}], [{'id': 'price_below_ema', 'period': 21}]),
];

class Candidate {
  Candidate(this.nameAr, this.nameEn, this.definition);
  final String nameAr, nameEn;
  final Map<String, dynamic> definition;
}

/// All candidates for a timeframe: trades of 2, 4 and 6 candles.
List<Candidate> candidates(int timeframeSec) => [
      for (final t in _triggers)
        for (final f in _filters)
          if (!(t.$1.startsWith('شمعة') && f.$1.isEmpty)) // a bare candle colour is noise
            for (final bars in const [2, 4, 6])
              Candidate(
                '${t.$1}${f.$1.isEmpty ? '' : ' — ${f.$1}'} · ${bars * timeframeSec}ث',
                '${t.$2}${f.$2.isEmpty ? '' : ' — ${f.$2}'} · ${bars * timeframeSec}s',
                {
                  'long': {'all': [...t.$3, ...f.$3]},
                  'short': {'all': [...t.$4, ...f.$4]},
                  'veto': <Cond>[],
                  'duration_sec': bars * timeframeSec,
                },
              ),
    ];

/// Trades of a definition between bars [start, end) — the backtest's mechanics (enter next open, one at a time).
List<Trade> tradesBetween(FeatureSet fs, Map def, int timeframeSec, int start, int end, double payout) {
  final bars = math.max(1, ((def['duration_sec'] as num) / timeframeSec).ceil());
  final out = <Trade>[];
  var i = math.max(start, warmup);
  while (i + bars < end) {
    final side = signalAt(fs, i, def);
    if (side == null) {
      i++;
      continue;
    }
    final eBar = i + 1, xBar = i + bars;
    final entry = fs.o[eBar], exit = fs.c[xBar];
    final move = side == 'BUY' ? exit - entry : entry - exit;
    final outcome = move > 0 ? 'win' : move < 0 ? 'loss' : 'draw';
    out.add(Trade(i, eBar, xBar, side, entry, exit, outcome, outcome == 'win' ? payout : outcome == 'loss' ? -1.0 : 0.0,
        fs.marketCondition(i)));
    i = xBar;
  }
  return out;
}

/// One-sided p-value of `wins` out of `n` decided trades if the true win rate were `p0` (normal approximation with
/// continuity correction; used only with n >= 30).
double pValueAbove(int wins, int n, double p0) {
  if (n == 0) return 1;
  final mean = n * p0, sd = math.sqrt(n * p0 * (1 - p0));
  final z = (wins - 0.5 - mean) / sd;
  return 0.5 * _erfc(z / math.sqrt2);
}

double _erfc(double x) {
  // Numerical Recipes erfc (fractional error < 1.2e-7)
  final z = x.abs(), t = 1 / (1 + 0.5 * z);
  final r = t *
      math.exp(-z * z - 1.26551223 + t * (1.00002368 + t * (0.37409196 + t * (0.09678418 + t * (-0.18628806 +
          t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277)))))))));
  return x >= 0 ? r : 2 - r;
}

/// Run the search. `progress` gets 0..1. Returns a JSON-able report.
Map<String, dynamic> discover(FeatureSet fs, int timeframeSec,
    {double payout = 0.88, int finalists = 10, void Function(double)? progress}) {
  final all = candidates(timeframeSec);
  final split = (fs.n * 0.6).truncate();
  final breakeven = 1 / (1 + payout);
  final scored = <(Candidate, Map<String, dynamic>, double)>[];
  for (var k = 0; k < all.length; k++) {
    final c = all[k];
    final m = metrics(tradesBetween(fs, c.definition, timeframeSec, 0, split, payout), payout, split);
    final decided = (m['wins'] as int) + (m['losses'] as int);
    final exp = m['expectancy_per_trade'] as num?;
    if (decided >= 40 && exp != null && exp > 0) {
      final (lo, _) = wilson(m['wins'] as int, decided);
      scored.add((c, m, lo));
    }
    progress?.call((k + 1) / all.length * 0.9);
  }
  scored.sort((a, b) => b.$3.compareTo(a.$3));
  final picked = scored.take(finalists).toList();
  final alpha = 0.05 / math.max(1, picked.length);
  final results = <Map<String, dynamic>>[];
  for (final (c, mSearch, _) in picked) {
    final m = metrics(tradesBetween(fs, c.definition, timeframeSec, split, fs.n, payout), payout, fs.n - split);
    final wins = m['wins'] as int, decided = wins + (m['losses'] as int);
    final exp = m['expectancy_per_trade'] as num?;
    final p = decided >= 30 ? pValueAbove(wins, decided, breakeven) : 1.0;
    final verdict = decided < 30
        ? 'too_few'
        : (exp == null || exp <= 0)
            ? 'failed'
            : (p < alpha ? 'significant' : 'positive_maybe_luck');
    results.add({
      'name_ar': c.nameAr, 'name_en': c.nameEn, 'definition': c.definition,
      'search': {'trades': mSearch['trades'], 'win_rate': mSearch['win_rate'], 'expectancy_per_trade': mSearch['expectancy_per_trade']},
      'holdout': {
        'trades': m['trades'], 'win_rate': m['win_rate'], 'win_rate_ci95': m['win_rate_ci95'],
        'expectancy_per_trade': exp, 'p_value': roundTo(p, 6),
      },
      'verdict': verdict,
    });
  }
  const order = {'significant': 0, 'positive_maybe_luck': 1, 'failed': 2, 'too_few': 3};
  results.sort((a, b) {
    final o = order[a['verdict']]!.compareTo(order[b['verdict']]!);
    if (o != 0) return o;
    return ((b['holdout'] as Map)['expectancy_per_trade'] as num? ?? -9)
        .compareTo((a['holdout'] as Map)['expectancy_per_trade'] as num? ?? -9);
  });
  progress?.call(1);
  return {
    'candidates_tested': all.length,
    'passed_search': scored.length,
    'finalists': results.length,
    'alpha_per_finalist': roundTo(alpha, 6),
    'breakeven_win_rate': roundTo(breakeven, 4),
    'search_bars': split,
    'holdout_bars': fs.n - split,
    'payout': payout,
    'results': results,
  };
}
