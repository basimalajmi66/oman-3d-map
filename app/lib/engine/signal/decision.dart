/// Decision engine: the 14 steps before BUY / SELL / WAIT (port of signal/engine.py).
///
/// A BUY/SELL can only come from an approved strategy whose current version passed an
/// out-of-sample backtest on real data on the same candle timeframe; conditions must hold on
/// the last closed candle; confluence and data quality must reach the user's thresholds; the
/// forming candle is never assumed closed. The confidence is an uncalibrated internal estimate.
/// Anything missing → WAIT with explicit reason codes.
library;

import 'dart:math' as math;

import '../strategy/conditions.dart';
import '../strategy/features.dart';
import '../util.dart';

const decisionEngineVersion = '1.0';

/// Python's `f"{x:.Nf}"`.
String pyFixed(num x, int n) => roundTo(x.toDouble(), n).toStringAsFixed(n);

class Decision {
  Decision({this.dataQuality, this.dataBasis = 'image_only'});
  String signal = 'WAIT';
  final reasonCodes = <String>[];
  var reasons = <String>[];
  var supporting = <String>[];
  var opposing = <String>[];
  double? confidence;
  final bool confidenceCalibrated = false;
  int? durationSec;
  double? dataQuality;
  String dataBasis;
  Map<String, dynamic>? strategy;
  final steps = <Map<String, dynamic>>[];

  void step(int n, String name, String status, [String detail = '']) =>
      steps.add({'n': n, 'name': name, 'status': status, 'detail': detail});

  Map<String, dynamic> toJson() => {
        'signal': signal, 'reason_codes': reasonCodes, 'reasons': reasons, 'supporting': supporting,
        'opposing': opposing, 'confidence': confidence, 'confidence_calibrated': confidenceCalibrated,
        'duration_sec': durationSec, 'data_quality': dataQuality, 'data_basis': dataBasis, 'strategy': strategy,
        'steps': steps, 'reason_code': reasonCodes.isEmpty ? null : reasonCodes.first,
        'engine_version': decisionEngineVersion,
      };
}

FeatureSet? _closedSeries(Map reading) {
  final closed = [for (final c in (reading['candles'] as List? ?? const [])) if ((c as Map)['status'] == 'closed') c];
  if (closed.isEmpty) return null;
  final prefix = closed.every((c) => c.containsKey('close')) ? '' : 'rel_';
  List<double> col(String k) => [for (final c in closed) (c['$prefix$k'] as num).toDouble()];
  return FeatureSet(col('open'), col('high'), col('low'), col('close'));
}

double _num(Object? v) => (v as num?)?.toDouble() ?? 0.0;

/// `strategies`: approved strategies with their `latest_backtest`.
Decision decide(Map reading, Map? technical, Map settings, List<Map> strategies, {List<Map>? knowledge}) {
  final d = Decision(
      dataQuality: (reading['data_quality'] as num?)?.toDouble(), dataBasis: reading['data_basis'] as String? ?? 'image_only');
  final tf = settings['candle_timeframe_sec'];

  // 1 — data validity
  final qMin = _num(settings['min_data_quality_to_signal']);
  if (reading['usable'] != true) {
    d.step(1, 'data_validity', 'fail', ((reading['abstain_reasons'] as List?) ?? const []).join(', '));
    d.reasonCodes.add('image_quality_insufficient');
    return d;
  }
  if ((d.dataQuality ?? 0) < qMin) {
    d.step(1, 'data_validity', 'fail', 'quality ${pyFixed(d.dataQuality ?? 0, 2)} < ${pyFixed(qMin, 2)}');
    d.reasonCodes.add('image_quality_insufficient');
    return d;
  }
  final shownTf = reading['timeframe_sec'];
  if (shownTf != null && shownTf != 0 && shownTf != tf) {
    d.step(1, 'data_validity', 'fail', 'chart timeframe ${shownTf}s ≠ settings ${tf}s');
    d.reasonCodes.add('timeframe_mismatch');
    return d;
  }
  d.step(1, 'data_validity', 'ok',
      'quality ${pyFixed(d.dataQuality ?? 0, 2)}${shownTf != null && shownTf != 0 ? '' : ', timeframe not shown in image'}');
  if (technical == null || technical['available'] != true) {
    d.step(2, 'trend', 'fail', (technical ?? const {})['reason'] as String? ?? 'no technical analysis');
    d.reasonCodes.add('insufficient_candles');
    return d;
  }

  // 2 — trend, 3 — strength
  final tr = technical['trend'] as Map;
  d.step(2, 'trend', 'info', '${tr['direction']} (${tr['structure']})');
  d.step(3, 'trend_strength', 'info', '${pyFixed(tr['strength'] as num, 2)}, market ${technical['market_condition']}');
  final factorList = [for (final f in technical['factors'] as List) f as Map];
  final factors = {for (final f in factorList) f['name']: f};

  // 4 — previous candles, 5 — forming candle without assuming its close
  final pa = factors['price_action'] ?? const {};
  d.step(4, 'previous_candles', 'info', '${pa['direction'] ?? 'n/a'} (${pa['code'] ?? ''})');
  final candles = [for (final c in (reading['candles'] as List? ?? const [])) c as Map];
  final forming = candles.reversed.where((c) => c['status'] == 'possibly_forming').firstOrNull;
  String? formingDir;
  if (forming != null) {
    final rng = _num(forming['rel_high']) - _num(forming['rel_low']);
    final body = _num(forming['rel_close']) - _num(forming['rel_open']);
    final ranges = [for (final c in candles) if (c['status'] == 'closed') _num(c['rel_high']) - _num(c['rel_low'])];
    final last14 = ranges.sublist(math.max(0, ranges.length - 14));
    final avg = last14.isEmpty ? 0.0 : mean(last14);
    if (avg > 0 && rng >= avg && body.abs() >= 0.5 * rng) formingDir = body > 0 ? 'bullish' : 'bearish';
    d.step(5, 'forming_candle', 'info', 'not assumed closed; strong move: ${formingDir ?? 'none'}');
  } else {
    d.step(5, 'forming_candle', 'info', 'none');
  }

  // 6 — indicators, 7 — support/resistance, 8 — supply/demand
  const indNames = ['moving_averages', 'rsi', 'macd', 'bollinger_bands', 'momentum'];
  d.step(6, 'indicators', 'info',
      [for (final n in indNames) if (factors[n] != null && factors[n]!['enabled'] == true) '$n=${factors[n]!['direction']}'].join(', '));
  d.step(7, 'support_resistance', 'info', '${(factors['support_resistance'] ?? const {})['code'] ?? ''}');
  d.step(8, 'supply_demand', 'info', '${(factors['supply_demand'] ?? const {})['code'] ?? ''}');

  // 9 — matching strategies from the library
  final usable = <Map>[];
  final skipped = <String>[];
  for (final s in strategies) {
    final bt = s['latest_backtest'] as Map?;
    if (s['status'] != 'approved' || bt == null || bt['qualifies'] != true || s['definition'] == null) continue;
    final sTf = (bt['params'] as Map?)?['timeframe_sec'];
    if (sTf != tf) {
      skipped.add('${s['name']} (tested on ${sTf}s)');
      continue;
    }
    usable.add(s);
  }
  if (usable.isEmpty) {
    d.step(9, 'strategy_lookup', 'fail',
        'no approved strategy for this timeframe${skipped.isNotEmpty ? '; skipped: ${skipped.join(', ')}' : ''}');
    d.reasonCodes.add('no_approved_strategy');
    return d;
  }
  d.step(9, 'strategy_lookup', 'ok', usable.map((s) => s['name']).join(', '));

  // 10 — strategy conditions on the last closed candle (causal)
  final fs = _closedSeries(reading);
  final last = fs == null ? -1 : fs.n - 1;
  if (fs == null || !fs.ready(last)) {
    d.step(10, 'strategy_conditions', 'fail', 'not enough closed candles to evaluate strategy conditions (need 50+)');
    d.reasonCodes.add('insufficient_history_for_strategies');
    return d;
  }
  final cond = technical['market_condition'];
  final fired = <(Map, String)>[];
  for (final s in usable) {
    final side = signalAt(fs, last, s['definition'] as Map);
    if (side != null) fired.add((s, side));
  }
  if (fired.isEmpty) {
    d.step(10, 'strategy_conditions', 'fail', "no strategy's conditions are met on the last closed candle");
    d.reasonCodes.add('strategy_conditions_not_met');
    return d;
  }
  final sides = {for (final f in fired) f.$2};
  if (sides.length > 1) {
    d.step(10, 'strategy_conditions', 'fail', 'approved strategies disagree (BUY and SELL)');
    d.reasonCodes.add('strategies_conflict');
    return d;
  }
  final side = sides.single;

  // choose the strategy with the best out-of-sample expectancy in the current market condition
  double score(Map s) {
    final oos = (s['latest_backtest']['out_of_sample'] as Map?) ?? const {};
    final bc = ((oos['by_condition'] as Map?) ?? const {})[cond] as Map? ?? const {};
    final byCond = ((bc['trades'] as num?) ?? 0) >= 10 ? (bc['expectancy_per_trade'] as num?) : null;
    if (byCond != null && byCond != 0) return byCond.toDouble(); // Python `or` skips 0 / None
    final all = oos['expectancy_per_trade'] as num?;
    return all != null && all != 0 ? all.toDouble() : 0.0;
  }

  var chosen = fired.first.$1;
  for (final f in fired.skip(1)) {
    if (score(f.$1) > score(chosen)) chosen = f.$1;
  }
  final oos = chosen['latest_backtest']['out_of_sample'] as Map;
  d.step(10, 'strategy_conditions', 'ok', '${chosen['name']} → $side');

  // 11 — opposing factors / confluence
  final want = side == 'BUY' ? 'bullish' : 'bearish';
  final against = want == 'bullish' ? 'bearish' : 'bullish';
  final active = factorList.where((f) => f['enabled'] == true && f['available'] == true).toList();
  final sup = active.where((f) => f['direction'] == want).toList();
  final opp = active.where((f) => f['direction'] == against).toList();
  if (formingDir == against) {
    opp.add({'name': 'forming_candle', 'code': 'forming_against', 'strength': 0.5, 'direction': against});
  }
  d.supporting = [for (final f in sup) '${f['name']}: ${f['code']}'];
  d.opposing = [for (final f in opp) '${f['name']}: ${f['code']}'];
  final supScore = sup.fold<double>(0, (a, f) => a + _num(f['strength']));
  final oppScore = opp.fold<double>(0, (a, f) => a + _num(f['strength']));
  final need = settings['min_confluence_factors'] as int;
  if (sup.length < need) {
    d.step(11, 'opposing_factors', 'fail', '${sup.length} supporting < $need required');
    d.reasonCodes.add('insufficient_confluence');
    return d;
  }
  if (oppScore >= supScore) {
    d.step(11, 'opposing_factors', 'fail', 'opposing ${pyFixed(oppScore, 2)} ≥ supporting ${pyFixed(supScore, 2)}');
    d.reasonCodes.add('opposing_factors_dominate');
    return d;
  }
  d.step(11, 'opposing_factors', 'ok', 'supporting ${pyFixed(supScore, 2)} vs opposing ${pyFixed(oppScore, 2)}');

  // 12 — opportunity quality (internal estimate, NOT a probability of profit)
  final agreement = supScore + oppScore > 0 ? supScore / (supScore + oppScore) : 0.0;
  final confidence = roundTo(0.5 * agreement + 0.3 * (d.dataQuality ?? 0) + 0.2 * math.min(1.0, sup.length / 6), 3);
  d.confidence = confidence;
  final minConf = _num(settings['min_confidence_to_signal']);
  if (confidence < minConf) {
    d.step(12, 'opportunity_quality', 'fail', 'estimate ${pyFixed(confidence, 2)} < ${pyFixed(minConf, 2)}');
    d.reasonCodes.add('low_confidence');
    return d;
  }
  d.step(12, 'opportunity_quality', 'ok', 'estimate ${pyFixed(confidence, 2)} (uncalibrated)');

  // 13 — duration: the tested duration, within the user's range
  final def = chosen['definition'] as Map;
  final dur = (def['duration_sec'] as num).toInt();
  final lo = settings['trade_duration_min_sec'], hi = settings['trade_duration_max_sec'];
  if (dur < (lo as num) || dur > (hi as num)) {
    d.step(13, 'duration', 'fail', 'strategy duration ${dur}s outside your range $lo–${hi}s');
    d.reasonCodes.add('duration_outside_settings');
    return d;
  }
  d.step(13, 'duration', 'ok', '${dur}s (as tested)');

  // 14 — reasons
  d
    ..signal = side
    ..durationSec = dur
    ..strategy = {
      'id': chosen['id'], 'name': chosen['name'], 'version': chosen['version'], 'oos_trades': oos['trades'],
      'oos_win_rate': oos['win_rate'], 'oos_win_rate_ci95': oos['win_rate_ci95'],
      'oos_expectancy': oos['expectancy_per_trade'], 'significant_edge': oos['significant_edge'] ?? false,
      'conditions': [for (final c in (def[side == 'BUY' ? 'long' : 'short'] as Map)['all'] as List) describe(c as Cond)],
    }
    ..reasons = [
      "approved strategy '${chosen['name']}' conditions met on the last closed candle",
      '${sup.length} supporting factor(s) vs ${opp.length} opposing',
      'market $cond, trend ${tr['direction']}',
      if (knowledge != null && knowledge.isNotEmpty)
        'related approved knowledge: ${knowledge.take(2).map((k) => k['title']).join('; ')}',
    ];
  d.reasonCodes
    ..clear()
    ..add('strategy_signal');
  d.step(14, 'reasons', 'ok', d.reasons.join('; '));
  return d;
}

/// Identity of the last closed candle: a repeat signal needs a new closed candle.
String fingerprint(Map reading) {
  final closed = [for (final c in (reading['candles'] as List? ?? const [])) if ((c as Map)['status'] == 'closed') c];
  if (closed.isEmpty) return '';
  final c = closed.last;
  return '${closed.length}:${c['y_open']}:${c['y_close']}:${c['y_high']}:${c['y_low']}';
}
