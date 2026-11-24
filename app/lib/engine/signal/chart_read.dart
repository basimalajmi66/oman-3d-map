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

import '../strategy/features.dart';
import 'setups.dart';

double _n(Object? v) => (v as num?)?.toDouble() ?? 0.0;

/// Every collected strategy (setup) that shows on the last closed candle (empty with fewer than 30 candles).
List<SetupHit> readingSetups(Map reading) {
  final closed = [for (final c in (reading['candles'] as List? ?? const [])) if ((c as Map)['status'] == 'closed') c];
  if (closed.length < 30) return const [];
  final prefix = closed.every((c) => c.containsKey('close')) ? '' : 'rel_';
  List<double> col(String k) => [for (final c in closed) _n(c['$prefix$k'])];
  return detectSetups(FeatureSet(col('open'), col('high'), col('low'), col('close')));
}

/// The direct signal from the setups (chart / price-action setups weigh 1.0, candle patterns 0.6): a side needs at
/// least 1.0 (one chart / price-action setup, or two candle patterns) and twice the weight of the other side.
String? setupSignal(List<SetupHit> hits) {
  var buy = 0.0, sell = 0.0;
  for (final h in hits) {
    if (h.side == 'BUY') {
      buy += h.weight;
    } else {
      sell += h.weight;
    }
  }
  if (buy >= 1.0 && buy >= 2 * sell) return 'BUY';
  if (sell >= 1.0 && sell >= 2 * buy) return 'SELL';
  return null;
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
  // the collected strategies (candle patterns, chart patterns, price action) on the last closed candle
  final hits = readingSetups(reading);
  for (final h in hits) {
    if (h.side == 'BUY') {
      up += 1.5 * h.weight;
      forUp.insert(0, 'setup: ${h.name}');
    } else {
      down += 1.5 * h.weight;
      forDown.insert(0, 'setup: ${h.name}');
    }
  }
  final signal = setupSignal(hits);
  final total = up + down;
  final margin = total == 0 ? 0.0 : (up - down) / total; // −1 … +1
  // a setup gives the direction directly; otherwise the balance of the factors
  final bias = signal == 'BUY' ? 'up' : signal == 'SELL' ? 'down' : margin >= 0.2 ? 'up' : margin <= -0.2 ? 'down' : 'unclear';
  final m = margin.abs();
  final strength = bias == 'unclear'
      ? 'weak'
      : (m >= 0.6 && total >= 2.0) || (signal != null && m >= 0.35) ? 'strong' : m >= 0.35 || signal != null ? 'medium' : 'weak';

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
    'signal': signal, // BUY / SELL when a collected strategy shows on the last closed candle
    'setups': [for (final h in hits) h.toJson()],
    'market': technical['market_condition'],
    'trend': (technical['trend'] as Map?)?['direction'],
  };
}
