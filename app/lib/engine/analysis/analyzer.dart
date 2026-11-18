/// TechnicalAnalyzer (port of analysis/engine.py): closed candles → independent, explainable factors.
///
/// Closed candles only; works on prices or on the relative units of the chart reader (thresholds are
/// relative to ATR or %). Each factor maps 1:1 to a user setting and can be disabled. This module does
/// not emit BUY/SELL; it reports confluence for the decision engine.
library;

import 'dart:math' as math;

import '../util.dart';
import 'indicators.dart' as ind;
import 'patterns.dart' as pat;
import 'structure.dart' as st;

const analyzerVersion = '1.0';
const minCandles = 30;

class Factor {
  Factor(this.name,
      {this.enabled = true,
      this.available = true,
      this.direction = 'neutral',
      this.strength = 0.0,
      this.code = '',
      Map<String, dynamic>? params})
      : params = params ?? {};
  final String name;
  bool enabled;
  bool available;
  String direction;
  double strength;
  String code;
  Map<String, dynamic> params;

  Map<String, dynamic> toJson() => {
        'name': name, 'enabled': enabled, 'available': available, 'direction': direction,
        'strength': roundTo(strength, 3), 'code': code, 'params': params,
      };
}

class Candle {
  const Candle(this.open, this.high, this.low, this.close, [this.volume]);
  final double open, high, low, close;
  final double? volume;

  factory Candle.fromJson(Map j) => Candle((j['open'] as num).toDouble(), (j['high'] as num).toDouble(),
      (j['low'] as num).toDouble(), (j['close'] as num).toDouble(), (j['volume'] as num?)?.toDouble());
}

double? _f(double? x) => x == null || x.isNaN ? null : roundTo(x, 6);

double _percentile(List<double> v, double p) {
  final s = [...v]..sort();
  final pos = p / 100 * (s.length - 1);
  final lo = pos.floor(), hi = pos.ceil();
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
}

class TechnicalAnalyzer {
  Map<String, dynamic> analyze(List<Candle> candles, {Map<String, bool>? enabled, bool hasVolume = false}) {
    enabled ??= const {};
    final n = candles.length;
    if (n < minCandles) {
      return {
        'available': false, 'reason': 'insufficient_candles', 'candles_used': n, 'min_candles': minCandles,
        'analyzer_version': analyzerVersion,
      };
    }
    final o = [for (final x in candles) x.open];
    final h = [for (final x in candles) x.high];
    final lo = [for (final x in candles) x.low];
    final c = [for (final x in candles) x.close];
    final vol = hasVolume ? [for (final x in candles) x.volume ?? double.nan] : null;

    final atrArr = ind.atr(h, lo, c, 14);
    final a = atrArr.last;
    final rsiArr = ind.rsi(c, 14);
    final m = ind.macd(c);
    final bb = ind.bollinger(c, n: 20, k: 2.0);
    final e9 = ind.ema(c, 9), e21 = ind.ema(c, 21), e50 = ind.ema(c, 50);
    final rocArr = ind.roc(c, 10);

    final tr = st.trend(c, h, lo, a);
    final slope = ind.linregSlope(c, 10);
    String trendAt(int i) {
      final j = i - 1;
      if (j < 9 || slope[j].isNaN || atrArr[j].isNaN || atrArr[j] <= 0) return 'unclear';
      final s = slope[j] / atrArr[j];
      return s > 0.08 ? 'up' : s < -0.08 ? 'down' : 'sideways';
    }

    final levels = st.supportResistance(h, lo, c, a);
    final zones = st.supplyDemand(o, h, lo, c, atrArr);
    final pools = st.liquidityPools(h, lo, a);
    final dtb = st.doubleTopBottom(h, lo, c, a);
    final sudden = st.suddenMove(h, lo, c, atrArr);
    final recent = pat.recentPatterns(o, h, lo, c, atrArr, trendAt, lookback: 3);

    final atrPct = [for (var i = 0; i < n; i++) c[i] == 0 ? double.nan : atrArr[i] / c[i].abs()];
    final hist = atrPct.where((v) => !v.isNaN).toList();
    final volPctile = hist.length > 5 ? hist.where((v) => v < atrPct.last).length / hist.length : 0.5;
    final width = [for (var i = 0; i < n; i++) bb.mid[i] == 0 ? double.nan : (bb.upper[i] - bb.lower[i]) / bb.mid[i].abs()];
    final wv = width.where((v) => !v.isNaN).toList();
    final squeeze = wv.length > 10 && width.last <= _percentile(wv, 20);

    final factors = <Factor>[
      _priceAction(o, h, lo, c, a, sudden),
      _candles(recent),
      _sr(levels, c, a),
      Factor('trend',
          direction: const {'up': 'bullish', 'down': 'bearish'}[tr['direction']] ?? 'neutral',
          strength: (tr['strength'] as num).toDouble(),
          code: 'trend_${tr['direction']}',
          params: {'structure': tr['structure']}),
      _sd(zones, c, a),
      _liquidity(pools, h, lo, c),
      _ma(c, e9, e21, e50),
      _rsi(rsiArr),
      _macd(m),
      _bb(c, bb, squeeze),
      Factor('atr', code: 'atr_value', params: {'atr': _f(a), 'percentile': roundTo(volPctile, 2)}),
      _volume(vol),
      _momentum(rocArr, c, a),
      Factor('volatility',
          code: volPctile >= 0.8 ? 'vol_high' : volPctile <= 0.2 ? 'vol_low' : 'vol_normal',
          params: {'percentile': roundTo(volPctile, 2)}),
      _chartPattern(dtb),
    ];
    for (final f in factors) {
      if (!(enabled[f.name] ?? true)) {
        f
          ..enabled = false
          ..direction = 'neutral'
          ..strength = 0.0;
      }
    }

    final String condition;
    if (sudden != null || volPctile >= 0.85) {
      condition = 'volatile';
    } else if (tr['direction'] != 'sideways' && (tr['strength'] as num) >= 0.5) {
      condition = 'trending';
    } else {
      condition = 'ranging';
    }

    final active = factors.where((f) => f.enabled && f.available).toList();
    final bull = active.where((f) => f.direction == 'bullish').toList();
    final bear = active.where((f) => f.direction == 'bearish').toList();
    return {
      'available': true,
      'analyzer_version': analyzerVersion,
      'candles_used': n,
      'market_condition': condition,
      'trend': tr,
      'levels': [for (final lv in levels) lv.toJson()],
      'zones': [for (final z in zones) z.toJson()],
      'liquidity': pools,
      'chart_pattern': dtb,
      'patterns': [
        for (final p in recent) {'name': p.name, 'index': p.index, 'direction': p.direction, 'strength': p.strength}
      ],
      'sudden_move': sudden,
      'indicators': {
        'rsi': _f(rsiArr.last), 'macd': _f(m.line.last), 'macd_signal': _f(m.signal.last),
        'macd_hist': _f(m.hist.last), 'bb_lower': _f(bb.lower.last), 'bb_mid': _f(bb.mid.last),
        'bb_upper': _f(bb.upper.last), 'ema9': _f(e9.last), 'ema21': _f(e21.last), 'ema50': _f(e50.last),
        'atr': _f(a), 'roc10': _f(rocArr.last), 'squeeze': squeeze,
      },
      'factors': [for (final f in factors) f.toJson()],
      'confluence': {
        'bullish': [for (final f in bull) f.name],
        'bearish': [for (final f in bear) f.name],
        'neutral': [for (final f in active) if (f.direction == 'neutral') f.name],
        'disabled': [for (final f in factors) if (!f.enabled) f.name],
        'unavailable': [for (final f in factors) if (f.enabled && !f.available) f.name],
        'bullish_score': roundTo(bull.fold<double>(0, (s, f) => s + f.strength), 3),
        'bearish_score': roundTo(bear.fold<double>(0, (s, f) => s + f.strength), 3),
      },
      'warnings': [if (sudden != null) 'sudden_move', if (!hasVolume) 'no_volume_data'],
    };
  }

  static Factor _priceAction(List<double> o, List<double> h, List<double> lo, List<double> c, double a,
      Map<String, dynamic>? sudden) {
    final n = c.length;
    final last3 = c[n - 1] - o[n - 3];
    final pos = (c[n - 1] - lo[n - 1]) / math.max(h[n - 1] - lo[n - 1], 1e-12);
    final score = (a > 0 ? (last3 / (2 * a)).clamp(-1.0, 1.0) : 0.0) * 0.6 + (pos - 0.5) * 0.8;
    final d = score > 0.15 ? 'bullish' : score < -0.15 ? 'bearish' : 'neutral';
    return Factor('price_action',
        direction: d,
        strength: math.min(1.0, score.abs()),
        code: 'pa_$d',
        params: {'close_position': roundTo(pos, 2), if (sudden != null) 'sudden_move_atr': sudden['range_atr']});
  }

  static Factor _candles(List<pat.Pattern> recent) {
    final directional = recent.where((p) => p.direction != 'neutral').toList();
    final names = [for (final p in recent) p.name];
    if (directional.isEmpty) {
      return Factor('candlesticks', code: names.isEmpty ? 'pattern_none' : 'pattern_neutral', params: {'patterns': names});
    }
    var best = directional.first; // Python max(): first of equal keys wins
    for (final p in directional.skip(1)) {
      if (compareKeys([p.index, p.strength], [best.index, best.strength]) > 0) best = p;
    }
    return Factor('candlesticks',
        direction: best.direction, strength: best.strength, code: 'pattern_${best.name}', params: {'patterns': names});
  }

  static Factor _sr(List<st.Level> levels, List<double> c, double a) {
    if (levels.isEmpty || a <= 0) return Factor('support_resistance', code: 'sr_none');
    final last = c.last, prev = c[c.length - 2];
    for (final lv in levels) {
      if (prev < lv.price && lv.price < last && lv.kind == 'support' && last - lv.price < 1.5 * a) {
        return Factor('support_resistance',
            direction: 'bullish', strength: 0.6 * lv.strength + 0.3, code: 'sr_breakout_up', params: {'level': lv.price});
      }
      if (prev > lv.price && lv.price > last && lv.kind == 'resistance' && lv.price - last < 1.5 * a) {
        return Factor('support_resistance',
            direction: 'bearish', strength: 0.6 * lv.strength + 0.3, code: 'sr_breakdown', params: {'level': lv.price});
      }
    }
    var near = levels.first;
    for (final lv in levels.skip(1)) {
      if ((lv.price - last).abs() < (near.price - last).abs()) near = lv;
    }
    final dist = (near.price - last).abs() / a;
    if (dist <= 0.6) {
      return Factor('support_resistance',
          direction: near.kind == 'support' ? 'bullish' : 'bearish',
          strength: near.strength * (1 - dist / 0.6 * 0.5),
          code: 'sr_near_${near.kind}',
          params: {'level': near.price, 'touches': near.touches});
    }
    return Factor('support_resistance', code: 'sr_between', params: {'nearest': near.price});
  }

  static Factor _sd(List<st.Zone> zones, List<double> c, double a) {
    final last = c.last;
    for (final z in zones) {
      if (z.low - 0.3 * a <= last && last <= z.high + 0.3 * a) {
        return Factor('supply_demand',
            direction: z.kind == 'demand' ? 'bullish' : 'bearish',
            strength: math.min(1.0, 0.3 + 0.15 * z.impulseAtr) * (z.fresh ? 1 : 0.6),
            code: 'sd_in_${z.kind}',
            params: {'low': z.low, 'high': z.high, 'fresh': z.fresh});
      }
    }
    return Factor('supply_demand', code: zones.isEmpty ? 'sd_none' : 'sd_away', params: {'zones': zones.length});
  }

  static Factor _liquidity(Map<String, List<double>> pools, List<double> h, List<double> lo, List<double> c) {
    for (final p in pools['equal_lows']!) {
      if (lo.last < p && p < c.last) {
        return Factor('liquidity_zones', direction: 'bullish', strength: 0.55, code: 'liq_sweep_lows', params: {'level': p});
      }
    }
    for (final p in pools['equal_highs']!) {
      if (h.last > p && p > c.last) {
        return Factor('liquidity_zones', direction: 'bearish', strength: 0.55, code: 'liq_sweep_highs', params: {'level': p});
      }
    }
    return Factor('liquidity_zones',
        code: 'liq_none',
        params: {'equal_highs': pools['equal_highs']!.length, 'equal_lows': pools['equal_lows']!.length});
  }

  static Factor _ma(List<double> c, List<double> e9, List<double> e21, List<double> e50) {
    if (e21.last.isNaN) return Factor('moving_averages', available: false, code: 'insufficient_data');
    final up = c.last > e9.last && e9.last > e21.last;
    final down = c.last < e9.last && e9.last < e21.last;
    final with50 = !e50.last.isNaN;
    if (up) {
      return Factor('moving_averages',
          direction: 'bullish', strength: 0.5 + (with50 && e21.last > e50.last ? 0.3 : 0), code: 'ma_bull_alignment');
    }
    if (down) {
      return Factor('moving_averages',
          direction: 'bearish', strength: 0.5 + (with50 && e21.last < e50.last ? 0.3 : 0), code: 'ma_bear_alignment');
    }
    return Factor('moving_averages', code: 'ma_mixed');
  }

  static Factor _rsi(List<double> r) {
    final v = r.last;
    if (v.isNaN) return Factor('rsi', available: false, code: 'insufficient_data');
    final p = {'value': roundTo(v, 1)};
    if (v >= 70) {
      return Factor('rsi', direction: 'bearish', strength: math.min(1.0, 0.4 + (v - 70) / 30), code: 'rsi_overbought', params: p);
    }
    if (v <= 30) {
      return Factor('rsi', direction: 'bullish', strength: math.min(1.0, 0.4 + (30 - v) / 30), code: 'rsi_oversold', params: p);
    }
    if (v >= 55) return Factor('rsi', direction: 'bullish', strength: 0.2, code: 'rsi_bull_zone', params: p);
    if (v <= 45) return Factor('rsi', direction: 'bearish', strength: 0.2, code: 'rsi_bear_zone', params: p);
    return Factor('rsi', code: 'rsi_neutral', params: p);
  }

  static Factor _macd(ind.Macd m) {
    final n = m.signal.length;
    if (m.signal[n - 1].isNaN || m.signal[n - 2].isNaN) return Factor('macd', available: false, code: 'insufficient_data');
    final h1 = m.hist[n - 1], h2 = m.hist[n - 2];
    if (h2 <= 0 && 0 < h1) return Factor('macd', direction: 'bullish', strength: 0.65, code: 'macd_cross_up');
    if (h2 >= 0 && 0 > h1) return Factor('macd', direction: 'bearish', strength: 0.65, code: 'macd_cross_down');
    final rising = h1 > h2;
    if (h1 > 0) return Factor('macd', direction: 'bullish', strength: rising ? 0.4 : 0.2, code: 'macd_positive');
    return Factor('macd', direction: 'bearish', strength: !rising ? 0.4 : 0.2, code: 'macd_negative');
  }

  static Factor _bb(List<double> c, ind.Bands bb, bool squeeze) {
    if (bb.upper.last.isNaN) return Factor('bollinger_bands', available: false, code: 'insufficient_data');
    if (c.last > bb.upper.last) return Factor('bollinger_bands', direction: 'bearish', strength: 0.45, code: 'bb_above_upper');
    if (c.last < bb.lower.last) return Factor('bollinger_bands', direction: 'bullish', strength: 0.45, code: 'bb_below_lower');
    return Factor('bollinger_bands', code: squeeze ? 'bb_squeeze' : 'bb_inside');
  }

  static Factor _volume(List<double>? vol) {
    if (vol == null || vol.sublist(math.max(0, vol.length - 20)).any((v) => v.isNaN)) {
      return Factor('volume', available: false, code: 'volume_unavailable');
    }
    final n = vol.length;
    final avg = mean(vol.sublist(math.max(0, n - 21), n - 1));
    final ratio = avg > 0 ? vol.last / avg : 1.0;
    return Factor('volume', code: ratio >= 1.8 ? 'volume_high' : 'volume_normal', params: {'ratio': roundTo(ratio, 2)});
  }

  static Factor _momentum(List<double> rocArr, List<double> c, double a) {
    if (rocArr.last.isNaN || a <= 0) return Factor('momentum', available: false, code: 'insufficient_data');
    final moveAtr = (c.last - c[c.length - 11]) / a;
    final d = moveAtr > 1 ? 'bullish' : moveAtr < -1 ? 'bearish' : 'neutral';
    return Factor('momentum',
        direction: d,
        strength: d != 'neutral' ? math.min(1.0, moveAtr.abs() / 4) : 0.0,
        code: 'mom_$d',
        params: {'move_atr': roundTo(moveAtr, 2)});
  }

  static Factor _chartPattern(Map<String, dynamic>? dtb) {
    if (dtb == null) return Factor('chart_patterns', code: 'cp_none');
    final confirmed = dtb['confirmed'] as bool;
    return Factor('chart_patterns',
        direction: dtb['direction'] as String,
        strength: confirmed ? 0.7 : 0.4,
        code: 'cp_${dtb['name']}${confirmed ? '_confirmed' : ''}',
        params: {'neckline': dtb['neckline']});
  }
}

/// Closed candles from a chart reading, in prices when the axis was read, else relative units.
(List<Candle>, String) candlesFromReading(Map<String, dynamic> reading) {
  final closed = [
    for (final c in (reading['candles'] as List? ?? const [])) if ((c as Map)['status'] == 'closed') c
  ];
  if (closed.isNotEmpty && closed.every((c) => c.containsKey('close'))) {
    return ([for (final c in closed) Candle.fromJson(c)], 'price');
  }
  return (
    [
      for (final c in closed)
        Candle((c['rel_open'] as num).toDouble(), (c['rel_high'] as num).toDouble(), (c['rel_low'] as num).toDouble(),
            (c['rel_close'] as num).toDouble())
    ],
    'relative'
  );
}

/// Technical analysis of a usable chart reading (image only, no volume).
Map<String, dynamic> analyzeReading(Map<String, dynamic> reading, {Map<String, bool>? enabled}) {
  if (reading['usable'] != true) return {'available': false, 'reason': 'reading_not_usable'};
  final (candles, units) = candlesFromReading(reading);
  return TechnicalAnalyzer().analyze(candles, enabled: enabled)..['units'] = units;
}
