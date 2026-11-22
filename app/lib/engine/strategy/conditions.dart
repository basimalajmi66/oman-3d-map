/// Testable strategy conditions — the same closed catalogue as strategy/conditions.py.
///
/// Anything that cannot be expressed here is reported as *untestable* instead of being guessed.
library;

import 'chart_patterns.dart';
import 'features.dart';

typedef Cond = Map<String, dynamic>;

const patternNames = [
  'hammer', 'hanging_man', 'shooting_star', 'inverted_hammer', 'doji', 'marubozu', //
  'bullish_engulfing', 'bearish_engulfing', 'morning_star', 'evening_star', 'inside_bar',
];

double _n(Object? v) => (v as num).toDouble();

bool _near(FeatureSet fs, int i, String kind, double atrMult) {
  final a = fs.atr[i];
  return fs.levels(i).any((lv) => lv.$2 == kind && (lv.$1 - fs.c[i]).abs() <= atrMult * a);
}

bool _breakout(FeatureSet fs, int i, bool up) {
  if (i < 1) return false;
  for (final lv in fs.levels(i - 1)) {
    final p = lv.$1; // levels known before this candle
    if (up && fs.c[i - 1] < p && p < fs.c[i]) return true;
    if (!up && fs.c[i - 1] > p && p > fs.c[i]) return true;
  }
  return false;
}

bool _cross(List<double> a, List<double> b, int i, bool up) {
  if (i < 1 || a[i - 1].isNaN || b[i - 1].isNaN || a[i].isNaN || b[i].isNaN) return false;
  return up ? a[i - 1] <= b[i - 1] && a[i] > b[i] : a[i - 1] >= b[i - 1] && a[i] < b[i];
}

bool _streak(FeatureSet fs, int i, int n, bool up) {
  if (i < n - 1) return false;
  for (var j = i - n + 1; j <= i; j++) {
    if (up ? !(fs.c[j] > fs.o[j]) : !(fs.c[j] < fs.o[j])) return false;
  }
  return true;
}

const emaPeriods = [5, 9, 13, 21, 50, 200];

class CondSpec {
  const CondSpec(this.params, this.ar, this.en, this.fn);
  final Map<String, dynamic> params;
  final String ar, en;
  final bool Function(FeatureSet fs, int i, Cond p) fn;
}

final Map<String, CondSpec> catalog = {
  'rsi_below': CondSpec({'value': 30}, 'RSI أقل من {value}', 'RSI below {value}',
      (fs, i, p) => !fs.rsi[i].isNaN && fs.rsi[i] < _n(p['value'])),
  'rsi_above': CondSpec({'value': 70}, 'RSI أعلى من {value}', 'RSI above {value}',
      (fs, i, p) => !fs.rsi[i].isNaN && fs.rsi[i] > _n(p['value'])),
  'macd_cross_up': CondSpec({}, 'تقاطع MACD صاعد', 'MACD bullish cross',
      (fs, i, p) => i > 0 && fs.macdHist[i - 1] <= 0 && 0 < fs.macdHist[i]),
  'macd_cross_down': CondSpec({}, 'تقاطع MACD هابط', 'MACD bearish cross',
      (fs, i, p) => i > 0 && fs.macdHist[i - 1] >= 0 && 0 > fs.macdHist[i]),
  'macd_positive': CondSpec({}, 'هيستوجرام MACD موجب', 'MACD histogram positive', (fs, i, p) => fs.macdHist[i] > 0),
  'macd_negative': CondSpec({}, 'هيستوجرام MACD سالب', 'MACD histogram negative', (fs, i, p) => fs.macdHist[i] < 0),
  'price_above_ema': CondSpec({'period': 21}, 'السعر فوق EMA {period}', 'price above EMA {period}',
      (fs, i, p) => fs.c[i] > fs.ema[(p['period'] as num).toInt()]![i]),
  'price_below_ema': CondSpec({'period': 21}, 'السعر تحت EMA {period}', 'price below EMA {period}',
      (fs, i, p) => fs.c[i] < fs.ema[(p['period'] as num).toInt()]![i]),
  'ema_bull_alignment': CondSpec({}, 'EMA 9 > 21 > 50', 'EMA 9 > 21 > 50',
      (fs, i, p) => fs.ema[9]![i] > fs.ema[21]![i] && fs.ema[21]![i] > fs.ema[50]![i]),
  'ema_bear_alignment': CondSpec({}, 'EMA 9 < 21 < 50', 'EMA 9 < 21 < 50',
      (fs, i, p) => fs.ema[9]![i] < fs.ema[21]![i] && fs.ema[21]![i] < fs.ema[50]![i]),
  'bb_below_lower': CondSpec({}, 'الإغلاق تحت بولينجر السفلي', 'close below lower Bollinger', (fs, i, p) => fs.c[i] < fs.bbLo[i]),
  'bb_above_upper': CondSpec({}, 'الإغلاق فوق بولينجر العلوي', 'close above upper Bollinger', (fs, i, p) => fs.c[i] > fs.bbHi[i]),
  'trend_up': CondSpec({}, 'اتجاه صاعد', 'uptrend', (fs, i, p) => fs.trend(i) == 'up'),
  'trend_down': CondSpec({}, 'اتجاه هابط', 'downtrend', (fs, i, p) => fs.trend(i) == 'down'),
  'trend_sideways': CondSpec({}, 'سوق عرضي', 'sideways', (fs, i, p) => fs.trend(i) == 'sideways'),
  'near_support': CondSpec({'atr': 0.6}, 'قرب دعم ({atr} ATR)', 'near support ({atr} ATR)',
      (fs, i, p) => _near(fs, i, 'support', _n(p['atr']))),
  'near_resistance': CondSpec({'atr': 0.6}, 'قرب مقاومة ({atr} ATR)', 'near resistance ({atr} ATR)',
      (fs, i, p) => _near(fs, i, 'resistance', _n(p['atr']))),
  'breakout_up': CondSpec({}, 'اختراق مقاومة', 'breakout above a level', (fs, i, p) => _breakout(fs, i, true)),
  'breakdown': CondSpec({}, 'كسر دعم', 'breakdown below a level', (fs, i, p) => _breakout(fs, i, false)),
  'pattern': CondSpec({'name': 'bullish_engulfing'}, 'نمط {name}', 'pattern {name}',
      (fs, i, p) => fs.patterns(i).contains(p['name'])),
  'chart_pattern': CondSpec({'name': 'double_bottom'}, 'كسر نموذج {name}', '{name} break',
      (fs, i, p) => chartPatterns[p['name']]!(fs, i)),
  'market': CondSpec({'condition': 'trending'}, 'سوق {condition}', 'market {condition}',
      (fs, i, p) => fs.marketCondition(i) == p['condition']),
  'bullish_candle': CondSpec({}, 'شمعة صاعدة', 'bullish candle', (fs, i, p) => fs.c[i] > fs.o[i]),
  'bearish_candle': CondSpec({}, 'شمعة هابطة', 'bearish candle', (fs, i, p) => fs.c[i] < fs.o[i]),
  'stoch_below': CondSpec({'value': 20}, 'ستوكاستيك أقل من {value}', 'Stochastic below {value}',
      (fs, i, p) => !fs.stochK[i].isNaN && fs.stochK[i] < _n(p['value'])),
  'stoch_above': CondSpec({'value': 80}, 'ستوكاستيك أعلى من {value}', 'Stochastic above {value}',
      (fs, i, p) => !fs.stochK[i].isNaN && fs.stochK[i] > _n(p['value'])),
  'stoch_cross_up': CondSpec({}, 'تقاطع ستوكاستيك صاعد', 'Stochastic bullish cross',
      (fs, i, p) => _cross(fs.stochK, fs.stochD, i, true)),
  'stoch_cross_down': CondSpec({}, 'تقاطع ستوكاستيك هابط', 'Stochastic bearish cross',
      (fs, i, p) => _cross(fs.stochK, fs.stochD, i, false)),
  'adx_above': CondSpec({'value': 25}, 'ADX أعلى من {value} (اتجاه قوي)', 'ADX above {value} (strong trend)',
      (fs, i, p) => !fs.adx[i].isNaN && fs.adx[i] > _n(p['value'])),
  'adx_below': CondSpec({'value': 20}, 'ADX أقل من {value} (لا اتجاه)', 'ADX below {value} (no trend)',
      (fs, i, p) => !fs.adx[i].isNaN && fs.adx[i] < _n(p['value'])),
  'di_bull': CondSpec({}, '+DI فوق -DI', '+DI above -DI', (fs, i, p) => !fs.pdi[i].isNaN && fs.pdi[i] > fs.mdi[i]),
  'di_bear': CondSpec({}, '-DI فوق +DI', '-DI above +DI', (fs, i, p) => !fs.pdi[i].isNaN && fs.mdi[i] > fs.pdi[i]),
  'sar_bull': CondSpec({}, 'Parabolic SAR تحت السعر', 'Parabolic SAR below price', (fs, i, p) => fs.sarDir[i] == 1.0),
  'sar_bear': CondSpec({}, 'Parabolic SAR فوق السعر', 'Parabolic SAR above price', (fs, i, p) => fs.sarDir[i] == -1.0),
  'sar_flip_up': CondSpec({}, 'انقلاب SAR للأعلى', 'SAR flips up',
      (fs, i, p) => i > 0 && fs.sarDir[i] == 1.0 && fs.sarDir[i - 1] == -1.0),
  'sar_flip_down': CondSpec({}, 'انقلاب SAR للأسفل', 'SAR flips down',
      (fs, i, p) => i > 0 && fs.sarDir[i] == -1.0 && fs.sarDir[i - 1] == 1.0),
  'ema_cross_up': CondSpec({'fast': 5, 'slow': 13}, 'تقاطع EMA {fast} فوق EMA {slow}', 'EMA {fast} crosses above EMA {slow}',
      (fs, i, p) => _cross(fs.ema[(p['fast'] as num).toInt()]!, fs.ema[(p['slow'] as num).toInt()]!, i, true)),
  'ema_cross_down': CondSpec({'fast': 5, 'slow': 13}, 'تقاطع EMA {fast} تحت EMA {slow}', 'EMA {fast} crosses below EMA {slow}',
      (fs, i, p) => _cross(fs.ema[(p['fast'] as num).toInt()]!, fs.ema[(p['slow'] as num).toInt()]!, i, false)),
  'candle_streak_up': CondSpec({'n': 3}, '{n} شموع صاعدة متتالية', '{n} bullish candles in a row',
      (fs, i, p) => _streak(fs, i, (p['n'] as num).toInt(), true)),
  'candle_streak_down': CondSpec({'n': 3}, '{n} شموع هابطة متتالية', '{n} bearish candles in a row',
      (fs, i, p) => _streak(fs, i, (p['n'] as num).toInt(), false)),
  'momentum_up': CondSpec({'atr': 1.0}, 'زخم صاعد', 'upward momentum',
      (fs, i, p) => i >= 10 && (fs.c[i] - fs.c[i - 10]) > _n(p['atr']) * fs.atr[i]),
  'momentum_down': CondSpec({'atr': 1.0}, 'زخم هابط', 'downward momentum',
      (fs, i, p) => i >= 10 && (fs.c[i - 10] - fs.c[i]) > _n(p['atr']) * fs.atr[i]),
};

/// Raised for an invalid strategy definition (the API maps it to 400, like Python's ValueError).
class StrategyError implements Exception {
  StrategyError(this.message);
  final String message;
  @override
  String toString() => message;
}

Cond validate(Map cond) {
  final cid = cond['id'];
  final spec = catalog[cid];
  if (spec == null) throw StrategyError("unknown condition '$cid'");
  final params = {...spec.params, for (final e in cond.entries) if (e.key != 'id') e.key as String: e.value};
  final unknown = params.keys.toSet().difference(spec.params.keys.toSet()).toList()..sort();
  if (unknown.isNotEmpty) throw StrategyError('unknown parameters for $cid: $unknown');
  if (cid == 'pattern' && !patternNames.contains(params['name'])) throw StrategyError("unknown pattern '${params['name']}'");
  if (cid == 'chart_pattern' && !chartPatternNames.contains(params['name'])) {
    throw StrategyError("unknown chart pattern '${params['name']}'");
  }
  if (cid == 'market' && !const ['trending', 'ranging', 'volatile'].contains(params['condition'])) {
    throw StrategyError('market condition must be trending, ranging or volatile');
  }
  if ((cid == 'price_above_ema' || cid == 'price_below_ema') && !emaPeriods.contains(params['period'])) {
    throw StrategyError('EMA period must be one of 5, 9, 13, 21, 50, 200');
  }
  if ((cid == 'ema_cross_up' || cid == 'ema_cross_down') &&
      !(emaPeriods.contains(params['fast']) && emaPeriods.contains(params['slow']) &&
          (params['fast'] as num) < (params['slow'] as num))) {
    throw StrategyError('EMA cross needs fast < slow, both in 5, 9, 13, 21, 50, 200');
  }
  if ((cid == 'candle_streak_up' || cid == 'candle_streak_down') && !const [2, 3, 4, 5, 6].contains(params['n'])) {
    throw StrategyError('candle streak length must be 2..6');
  }
  return {'id': cid, ...params};
}

Map<String, dynamic> validateDefinition(Map d) {
  List<Cond> side(String s) => [for (final c in ((d[s] as Map?)?['all'] as List? ?? const [])) validate(c as Map)];
  final out = <String, dynamic>{
    'long': {'all': side('long')},
    'short': {'all': side('short')},
    'veto': [for (final c in (d['veto'] as List? ?? const [])) validate(c as Map)],
    'duration_sec': (d['duration_sec'] as num? ?? 120).toInt(),
    'untestable': [...(d['untestable'] as List? ?? const [])],
  };
  if ((out['long']['all'] as List).isEmpty && (out['short']['all'] as List).isEmpty) {
    throw StrategyError('a strategy needs at least one long or short entry condition');
  }
  final dur = out['duration_sec'] as int;
  if (dur < 5 || dur > 86400) throw StrategyError('duration_sec must be between 5 and 86400');
  return out;
}

bool holds(FeatureSet fs, int i, Cond cond) => catalog[cond['id']]!.fn(fs, i, cond);

const _chartPatternAr = {
  'double_top': 'القمة المزدوجة (بيع)', 'double_bottom': 'القاع المزدوج (شراء)', 'head_shoulders': 'الرأس والكتفين (بيع)', //
  'bull_flag': 'العلم الصاعد (شراء)', 'ascending_triangle': 'المثلث الصاعد (شراء)',
  'gap_retest_bull': 'الفجوة الصاعدة: عودة السعر إليها (شراء)', 'gap_retest_bear': 'الفجوة الهابطة: عودة السعر إليها (بيع)',
};

String describe(Cond cond, [String lang = 'en']) {
  if (lang == 'ar' && cond['id'] == 'chart_pattern') return 'كسر نموذج ${_chartPatternAr[cond['name']] ?? cond['name']}';
  var tpl = lang == 'ar' ? catalog[cond['id']]!.ar : catalog[cond['id']]!.en;
  for (final e in cond.entries) {
    if (e.key != 'id') tpl = tpl.replaceAll('{${e.key}}', '${e.value}');
  }
  return tpl;
}

const _expensive = {
  'near_support': 3, 'near_resistance': 3, 'breakout_up': 3, 'breakdown': 3, 'pattern': 2, 'chart_pattern': 3, //
  'trend_up': 2, 'trend_down': 2, 'trend_sideways': 2, 'market': 2,
};

/// Cheap conditions first (AND is order-independent, so the result is identical).
List<Cond> _byCost(List conds) {
  final l = [for (final c in conds) c as Cond];
  final idx = {for (var q = 0; q < l.length; q++) l[q]: q};
  l.sort((a, b) {
    final x = (_expensive[a['id']] ?? 0).compareTo(_expensive[b['id']] ?? 0);
    return x != 0 ? x : idx[a]!.compareTo(idx[b]!);
  });
  return l;
}

/// 'BUY' / 'SELL' / null at closed bar i. Vetoes block both sides; a bar matching both sides is skipped.
String? signalAt(FeatureSet fs, int i, Map definition) {
  if (!fs.ready(i)) return null;
  if ((definition['veto'] as List).any((c) => holds(fs, i, c as Cond))) return null;
  final longAll = definition['long']['all'] as List, shortAll = definition['short']['all'] as List;
  final longOk = longAll.isNotEmpty && _byCost(longAll).every((c) => holds(fs, i, c));
  final shortOk = shortAll.isNotEmpty && _byCost(shortAll).every((c) => holds(fs, i, c));
  if (longOk && !shortOk) return 'BUY';
  if (shortOk && !longOk) return 'SELL';
  return null;
}
