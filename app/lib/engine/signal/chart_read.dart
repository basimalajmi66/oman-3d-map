/// Direct chart reading: what the chart itself says about the next candles and what to do next —
/// without needing an approved strategy.
///
/// It weighs every enabled factor of the technical analysis (trend, moving averages, RSI, MACD, Bollinger,
/// momentum, candle patterns, support/resistance, supply/demand, chart patterns) plus the chart-pattern breaks
/// on the last closed candle, and turns the balance into:
/// * `bias`: up / down / unclear, and `strength`: strong / medium / weak (a balance of factors — NOT a probability);
/// * `next`: the next step — buy / sell now, or a plan "wait: a break above X = buy, below Y = sell";
/// * the reasons for and against, and the nearest levels.
///
/// It is a reading, not a tested strategy: the UI shows it apart from the strategy signal.
library;

import 'dart:math' as math;

import '../strategy/chart_patterns.dart';
import '../strategy/features.dart';

const _patternSide = {
  'double_top': 'down', 'double_bottom': 'up', 'head_shoulders': 'down', //
  'bull_flag': 'up', 'ascending_triangle': 'up', 'gap_retest_bull': 'up', 'gap_retest_bear': 'down',
};

double _n(Object? v) => (v as num?)?.toDouble() ?? 0.0;

/// Chart-pattern breaks on the last closed candle (empty when there are too few candles).
List<String> patternBreaks(Map reading) {
  final closed = [for (final c in (reading['candles'] as List? ?? const [])) if ((c as Map)['status'] == 'closed') c];
  if (closed.length < 30) return const [];
  final prefix = closed.every((c) => c.containsKey('close')) ? '' : 'rel_';
  List<double> col(String k) => [for (final c in closed) _n(c['$prefix$k'])];
  final fs = FeatureSet(col('open'), col('high'), col('low'), col('close'));
  final i = fs.n - 1;
  return [for (final e in chartPatterns.entries) if (e.value(fs, i)) e.key];
}

Map<String, dynamic> chartRead(Map reading, Map? technical, {int? durationSec}) {
  if (reading['usable'] != true || technical == null || technical['available'] != true) {
    return {'bias': 'unclear', 'strength': 'none', 'next': {'action': 'none'}, 'bullish': <String>[], 'bearish': <String>[],
      'reason': reading['usable'] != true ? 'reading_not_usable' : 'too_few_candles'};
  }
  final factors = [
    for (final f in technical['factors'] as List)
      if ((f as Map)['enabled'] == true && f['available'] == true && (f['direction'] == 'bullish' || f['direction'] == 'bearish')) f
  ];
  var up = 0.0, down = 0.0;
  final forUp = <String>[], forDown = <String>[];
  for (final f in factors) {
    final s = _n(f['strength']).clamp(0.05, 1.0);
    final label = '${f['name']}: ${f['code']}';
    if (f['direction'] == 'bullish') {
      up += s;
      forUp.add(label);
    } else {
      down += s;
      forDown.add(label);
    }
  }
  // a chart pattern breaking on the last closed candle is the strongest single clue
  final breaks = patternBreaks(reading);
  for (final b in breaks) {
    if (_patternSide[b] == 'up') {
      up += 1.5;
      forUp.insert(0, 'chart_pattern: $b');
    } else {
      down += 1.5;
      forDown.insert(0, 'chart_pattern: $b');
    }
  }
  final total = up + down;
  final margin = total == 0 ? 0.0 : (up - down) / total; // −1 … +1
  final bias = margin >= 0.2 ? 'up' : margin <= -0.2 ? 'down' : 'unclear';
  final m = margin.abs();
  final strength = bias == 'unclear' ? 'weak' : m >= 0.6 && total >= 2.0 ? 'strong' : m >= 0.35 ? 'medium' : 'weak';

  // nearest levels above / below the last close (only meaningful when prices were read)
  final priced = technical['units'] == 'price';
  final closes = [
    for (final c in (reading['candles'] as List? ?? const []))
      if ((c as Map)['status'] == 'closed') _n(c[c.containsKey('close') ? 'close' : 'rel_close'])
  ];
  final last = closes.isEmpty ? null : closes.last;
  double? above, below;
  if (last != null) {
    for (final lv in (technical['levels'] as List? ?? const [])) {
      final p = _n((lv as Map)['price']);
      if (p > last && (above == null || p < above)) above = p;
      if (p < last && (below == null || p > below)) below = p;
    }
  }
  num? show(double? p) => p == null || !priced ? null : double.parse(p.toStringAsPrecision(math.max(6, '${p.round()}'.length + 3)));

  final next = switch (bias) {
    'up' => {'action': 'buy', 'duration_sec': durationSec, 'watch': show(above)}, // watch: the resistance in the way
    'down' => {'action': 'sell', 'duration_sec': durationSec, 'watch': show(below)}, // watch: the support in the way
    _ => {'action': 'wait_break', 'above': show(above), 'below': show(below)},
  };
  return {
    'bias': bias, 'strength': strength, 'margin': double.parse(margin.toStringAsFixed(3)),
    'next': next,
    'bullish': forUp,
    'bearish': forDown,
    'patterns': breaks,
    'market': technical['market_condition'],
    'trend': (technical['trend'] as Map?)?['direction'],
  };
}
