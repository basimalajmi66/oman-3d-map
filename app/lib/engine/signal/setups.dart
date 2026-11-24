/// Every strategy collected from the user's videos and images (docs/strategies/COLLECTED_STRATEGIES.md), as a
/// detector on the LAST CLOSED candle: candlestick patterns, reversal and continuation chart patterns, and
/// price-action / smart-money setups. Each hit has a side (BUY / SELL); the chart reading turns them into a direct
/// signal.
///
/// Rules shared by all of them (section 12 of the file):
/// * context first — a reversal pattern counts only after a move the other way (a hammer after a decline,
///   a shooting star after a rise), or at a support / resistance;
/// * everything is judged on closed candles, and only with data up to the last closed candle (no look-ahead);
/// * sizes are in ATR so the same rules fit any asset and timeframe.
///
/// These are the patterns as the sources describe them — NOT tested strategies.
library;

import 'dart:math' as math;

import '../strategy/chart_patterns.dart';
import '../strategy/features.dart';

class SetupHit {
  const SetupHit(this.name, this.side, this.kind);
  final String name;
  final String side; // BUY | SELL
  final String kind; // candle | reversal | continuation | price_action
  double get weight => switch (kind) { 'candle' => 0.6, _ => 1.0 };
  Map<String, dynamic> toJson() => {'name': name, 'side': side, 'kind': kind};
}

class _K {
  _K(this.fs) : i = fs.n - 1;
  final FeatureSet fs;
  final int i;
  List<double> get o => fs.o;
  List<double> get h => fs.h;
  List<double> get l => fs.l;
  List<double> get c => fs.c;

  double get a {
    final v = fs.atr[i];
    return v.isNaN || v <= 0 ? math.max(1e-12, rng(i)) : v;
  }

  double body(int j) => (c[j] - o[j]).abs();
  double rng(int j) => math.max(1e-12, h[j] - l[j]);
  double upper(int j) => h[j] - math.max(o[j], c[j]);
  double lower(int j) => math.min(o[j], c[j]) - l[j];
  bool green(int j) => c[j] > o[j];
  bool red(int j) => c[j] < o[j];
  double topB(int j) => math.max(o[j], c[j]);
  double botB(int j) => math.min(o[j], c[j]);
  double mid(int j) => (o[j] + c[j]) / 2;

  double avgBody(int j) {
    var s = 0.0, n = 0;
    for (var q = math.max(0, j - 10); q < j; q++) {
      s += body(q);
      n++;
    }
    return n == 0 ? body(j) : math.max(1e-12, s / n);
  }

  bool big(int j) => body(j) >= avgBody(j) * 1.2 && body(j) >= 0.5 * rng(j);
  bool small(int j) => body(j) <= avgBody(j) * 0.6;
  bool doji(int j) => body(j) <= 0.1 * rng(j);

  /// The move into candle `start`: down / up over the 8 candles before it (or price at a support / resistance).
  bool fellInto(int start) {
    final s = start - 1, b = start - 9;
    if (b < 0) return false;
    if (c[s] - c[b] < -0.8 * a) return true;
    return nearLevel(l[start], 'support');
  }

  bool roseInto(int start) {
    final s = start - 1, b = start - 9;
    if (b < 0) return false;
    if (c[s] - c[b] > 0.8 * a) return true;
    return nearLevel(h[start], 'resistance');
  }

  bool nearLevel(double price, String kind) =>
      fs.levels(math.max(0, i - 1)).any((lv) => lv.$2 == kind && (lv.$1 - price).abs() <= 0.3 * a);

  List<int> piv(List<int> p, [int last = 6]) => fs.confirmed(p, i - 1, last);

  /// y of the line through (x1, y1), (x2, y2) at x.
  double line(int x1, double y1, int x2, double y2, int x) => y1 + (y2 - y1) * (x - x1) / (x2 - x1);
}

typedef _Rule = bool Function(_K k);

// ------------------------------------------------------------------ candlestick patterns
final Map<String, (String, _Rule)> _candles = {
  'dragonfly_doji': ('BUY', (k) {
    final i = k.i, r = k.rng(i);
    return k.doji(i) && k.upper(i) <= 0.1 * r && k.lower(i) >= 0.6 * r && r >= 0.5 * k.a && k.fellInto(i);
  }),
  'gravestone_doji': ('SELL', (k) {
    final i = k.i, r = k.rng(i);
    return k.doji(i) && k.lower(i) <= 0.1 * r && k.upper(i) >= 0.6 * r && r >= 0.5 * k.a && k.roseInto(i);
  }),
  'hammer': ('BUY', (k) => _hammerShape(k) && k.fellInto(k.i)),
  'hanging_man': ('SELL', (k) => _hammerShape(k) && k.roseInto(k.i)),
  'inverted_hammer': ('BUY', (k) => _starShape(k) && k.fellInto(k.i)),
  'shooting_star': ('SELL', (k) => _starShape(k) && k.roseInto(k.i)),
  'bullish_engulfing': ('BUY', (k) {
    final i = k.i;
    return k.red(i - 1) && k.green(i) && k.c[i] >= k.o[i - 1] && k.o[i] <= k.c[i - 1] && k.body(i) > k.body(i - 1) &&
        k.body(i) >= 1.2 * k.avgBody(i) && k.body(i - 1) >= 0.5 * k.avgBody(i - 1) && k.fellInto(i - 1);
  }),
  'bearish_engulfing': ('SELL', (k) {
    final i = k.i;
    return k.green(i - 1) && k.red(i) && k.c[i] <= k.o[i - 1] && k.o[i] >= k.c[i - 1] && k.body(i) > k.body(i - 1) &&
        k.body(i) >= 1.2 * k.avgBody(i) && k.body(i - 1) >= 0.5 * k.avgBody(i - 1) && k.roseInto(i - 1);
  }),
  'bullish_harami': ('BUY', (k) => _harami(k, k.i, true) && !k.doji(k.i) && k.green(k.i) && k.fellInto(k.i - 1)),
  'bearish_harami': ('SELL', (k) => _harami(k, k.i, false) && !k.doji(k.i) && k.red(k.i) && k.roseInto(k.i - 1)),
  'bullish_harami_cross': ('BUY', (k) => _harami(k, k.i, true) && k.doji(k.i) && k.fellInto(k.i - 1)),
  'bearish_harami_cross': ('SELL', (k) => _harami(k, k.i, false) && k.doji(k.i) && k.roseInto(k.i - 1)),
  'three_inside_up': ('BUY', (k) {
    final i = k.i;
    return _harami(k, i - 1, true) && k.green(i - 1) && k.green(i) && k.c[i] > k.o[i - 2] && k.fellInto(i - 2);
  }),
  'three_inside_down': ('SELL', (k) {
    final i = k.i;
    return _harami(k, i - 1, false) && k.red(i - 1) && k.red(i) && k.c[i] < k.o[i - 2] && k.roseInto(i - 2);
  }),
  'three_outside_up': ('BUY', (k) {
    final i = k.i, j = i - 1;
    final engulf = k.red(j - 1) && k.green(j) && k.c[j] >= k.o[j - 1] && k.o[j] <= k.c[j - 1] && k.body(j) > k.body(j - 1);
    return engulf && k.body(j) >= 1.2 * k.avgBody(j) && k.green(i) && k.c[i] > k.h[j] && k.fellInto(j - 1);
  }),
  'three_outside_down': ('SELL', (k) {
    final i = k.i, j = i - 1;
    final engulf = k.green(j - 1) && k.red(j) && k.c[j] <= k.o[j - 1] && k.o[j] >= k.c[j - 1] && k.body(j) > k.body(j - 1);
    return engulf && k.body(j) >= 1.2 * k.avgBody(j) && k.red(i) && k.c[i] < k.l[j] && k.roseInto(j - 1);
  }),
  'three_white_soldiers': ('BUY', (k) {
    final i = k.i;
    for (var j = i - 2; j <= i; j++) {
      if (!k.green(j) || k.body(j) < 0.6 * k.rng(j) || k.body(j) < 0.8 * k.avgBody(i - 2)) return false;
      if (j > i - 2 && (k.c[j] <= k.c[j - 1] || k.o[j] < k.botB(j - 1))) return false;
    }
    return true;
  }),
  'three_black_crows': ('SELL', (k) {
    final i = k.i;
    for (var j = i - 2; j <= i; j++) {
      if (!k.red(j) || k.body(j) < 0.6 * k.rng(j) || k.body(j) < 0.8 * k.avgBody(i - 2)) return false;
      if (j > i - 2 && (k.c[j] >= k.c[j - 1] || k.o[j] > k.topB(j - 1))) return false;
    }
    return true;
  }),
  'morning_star': ('BUY', (k) {
    final i = k.i;
    return k.red(i - 2) && k.big(i - 2) && k.body(i - 1) <= 0.35 * k.body(i - 2) && k.topB(i - 1) <= k.c[i - 2] + 0.1 * k.a &&
        k.green(i) && k.c[i] > k.mid(i - 2) && k.fellInto(i - 2);
  }),
  'evening_star': ('SELL', (k) {
    final i = k.i;
    return k.green(i - 2) && k.big(i - 2) && k.body(i - 1) <= 0.35 * k.body(i - 2) && k.botB(i - 1) >= k.c[i - 2] - 0.1 * k.a &&
        k.red(i) && k.c[i] < k.mid(i - 2) && k.roseInto(i - 2);
  }),
  'bullish_abandoned_baby': ('BUY', (k) {
    final i = k.i;
    return k.red(i - 2) && k.doji(i - 1) && k.h[i - 1] < k.l[i - 2] && k.h[i - 1] < k.l[i] && k.green(i);
  }),
  'bearish_abandoned_baby': ('SELL', (k) {
    final i = k.i;
    return k.green(i - 2) && k.doji(i - 1) && k.l[i - 1] > k.h[i - 2] && k.l[i - 1] > k.h[i] && k.red(i);
  }),
  'piercing_line': ('BUY', (k) {
    final i = k.i;
    return k.red(i - 1) && k.big(i - 1) && k.green(i) && k.o[i] <= k.c[i - 1] && k.c[i] > k.mid(i - 1) && k.c[i] < k.o[i - 1] &&
        k.fellInto(i - 1);
  }),
  'dark_cloud_cover': ('SELL', (k) {
    final i = k.i;
    return k.green(i - 1) && k.big(i - 1) && k.red(i) && k.o[i] >= k.c[i - 1] && k.c[i] < k.mid(i - 1) && k.c[i] > k.o[i - 1] &&
        k.roseInto(i - 1);
  }),
  'bullish_marubozu': ('BUY', (k) => k.green(k.i) && k.body(k.i) >= 0.9 * k.rng(k.i) && k.body(k.i) >= 1.5 * k.avgBody(k.i)),
  'bearish_marubozu': ('SELL', (k) => k.red(k.i) && k.body(k.i) >= 0.9 * k.rng(k.i) && k.body(k.i) >= 1.5 * k.avgBody(k.i)),
  'bullish_spinning_top': ('BUY', (k) => _spinning(k) && k.fellInto(k.i) && k.nearLevel(k.l[k.i], 'support')),
  'bearish_spinning_top': ('SELL', (k) => _spinning(k) && k.roseInto(k.i) && k.nearLevel(k.h[k.i], 'resistance')),
  'bullish_kicker': ('BUY', (k) {
    final i = k.i;
    return k.red(i - 1) && k.green(i) && k.o[i] >= k.o[i - 1] && k.big(i) && k.big(i - 1);
  }),
  'bearish_kicker': ('SELL', (k) {
    final i = k.i;
    return k.green(i - 1) && k.red(i) && k.o[i] <= k.o[i - 1] && k.big(i) && k.big(i - 1);
  }),
  'tweezer_bottom': ('BUY', (k) {
    final i = k.i;
    return k.red(i - 1) && k.green(i) && (k.l[i] - k.l[i - 1]).abs() <= 0.05 * k.a && k.rng(i) >= 0.6 * k.a && k.rng(i - 1) >= 0.6 * k.a &&
        k.fellInto(i - 1);
  }),
  'tweezer_top': ('SELL', (k) {
    final i = k.i;
    return k.green(i - 1) && k.red(i) && (k.h[i] - k.h[i - 1]).abs() <= 0.05 * k.a && k.rng(i) >= 0.6 * k.a && k.rng(i - 1) >= 0.6 * k.a &&
        k.roseInto(i - 1);
  }),
  'bullish_breakaway': ('BUY', (k) {
    final i = k.i;
    if (!(k.red(i - 4) && k.big(i - 4))) return false;
    for (var j = i - 3; j < i; j++) {
      if (!k.small(j) || k.c[j] > k.c[j - 1] + 0.1 * k.a) return false;
    }
    return k.green(i) && k.big(i) && k.c[i] > k.o[i - 3];
  }),
  'bearish_breakaway': ('SELL', (k) {
    final i = k.i;
    if (!(k.green(i - 4) && k.big(i - 4))) return false;
    for (var j = i - 3; j < i; j++) {
      if (!k.small(j) || k.c[j] < k.c[j - 1] - 0.1 * k.a) return false;
    }
    return k.red(i) && k.big(i) && k.c[i] < k.o[i - 3];
  }),
  'rising_three_methods': ('BUY', (k) {
    final i = k.i, f = i - 4;
    if (!(k.green(f) && k.big(f))) return false;
    for (var j = f + 1; j < i; j++) {
      if (!k.small(j) || k.h[j] > k.h[f] || k.l[j] < k.l[f]) return false;
    }
    return k.green(i) && k.c[i] > k.c[f];
  }),
  'falling_three_methods': ('SELL', (k) {
    final i = k.i, f = i - 4;
    if (!(k.red(f) && k.big(f))) return false;
    for (var j = f + 1; j < i; j++) {
      if (!k.small(j) || k.h[j] > k.h[f] || k.l[j] < k.l[f]) return false;
    }
    return k.red(i) && k.c[i] < k.c[f];
  }),
  'upside_tasuki_gap': ('BUY', (k) {
    final i = k.i;
    return k.green(i - 2) && k.green(i - 1) && k.l[i - 1] > k.h[i - 2] && k.red(i) && k.o[i] < k.c[i - 1] && k.o[i] > k.o[i - 1] &&
        k.c[i] > k.h[i - 2];
  }),
  'downside_tasuki_gap': ('SELL', (k) {
    final i = k.i;
    return k.red(i - 2) && k.red(i - 1) && k.h[i - 1] < k.l[i - 2] && k.green(i) && k.o[i] > k.c[i - 1] && k.o[i] < k.o[i - 1] &&
        k.c[i] < k.l[i - 2];
  }),
  'exhaustion_impulse_up': ('BUY', (k) {
    final i = k.i;
    for (var j = i - 3; j < i; j++) {
      if (k.rng(j) > 0.6 * k.a) return false;
    }
    return k.green(i) && k.body(i) >= 1.0 * k.a;
  }),
  'exhaustion_impulse_down': ('SELL', (k) {
    final i = k.i;
    for (var j = i - 3; j < i; j++) {
      if (k.rng(j) > 0.6 * k.a) return false;
    }
    return k.red(i) && k.body(i) >= 1.0 * k.a;
  }),
};

bool _hammerShape(_K k) {
  final i = k.i, b = k.body(i), r = k.rng(i);
  return b >= 0.05 * r && k.lower(i) >= 2 * b && k.upper(i) <= 0.15 * r && r >= 0.5 * k.a;
}

bool _starShape(_K k) {
  final i = k.i, b = k.body(i), r = k.rng(i);
  return b >= 0.05 * r && k.upper(i) >= 2 * b && k.lower(i) <= 0.15 * r && r >= 0.5 * k.a;
}

bool _spinning(_K k) {
  final i = k.i, b = k.body(i), r = k.rng(i);
  return b > 0.1 * r && b <= 0.3 * r && k.upper(i) >= b && k.lower(i) >= b && r >= 0.5 * k.a;
}

/// candle j inside the body of a big candle j-1 of the opposite colour (bull: j-1 red).
bool _harami(_K k, int j, bool bull) {
  final p = j - 1;
  if (!(bull ? k.red(p) : k.green(p)) || !k.big(p)) return false;
  return k.topB(j) <= k.topB(p) && k.botB(j) >= k.botB(p) && k.body(j) <= 0.6 * k.body(p);
}

// ------------------------------------------------------------------ chart patterns (reversal / continuation)
final Map<String, (String, String, _Rule)> _charts = {
  'inverse_head_shoulders': ('BUY', 'reversal', (k) {
    final ls = k.piv(k.fs.pivLo, 3);
    if (ls.length < 3 || k.i - ls[2] > 30) return false;
    final l1 = k.l[ls[0]], hd = k.l[ls[1]], r1 = k.l[ls[2]];
    if (math.min(l1, r1) - hd < 0.5 * k.a || (l1 - r1).abs() > k.a) return false;
    final hs1 = [for (final j in k.fs.pivHi) if (ls[0] < j && j < ls[1]) j];
    final hs2 = [for (final j in k.fs.pivHi) if (ls[1] < j && j < ls[2]) j];
    if (hs1.isEmpty || hs2.isEmpty) return false;
    final j1 = hs1.reduce((a, b) => k.h[b] > k.h[a] ? b : a), j2 = hs2.reduce((a, b) => k.h[b] > k.h[a] ? b : a);
    final n0 = k.line(j1, k.h[j1], j2, k.h[j2], k.i - 1), n1 = k.line(j1, k.h[j1], j2, k.h[j2], k.i);
    return k.c[k.i - 1] <= n0 && k.c[k.i] > n1;
  }),
  'triple_top': ('SELL', 'reversal', (k) {
    final hs = k.piv(k.fs.pivHi, 3);
    if (hs.length < 3 || k.i - hs[2] > 30) return false;
    final top = [for (final j in hs) k.h[j]];
    if (top.reduce(math.max) - top.reduce(math.min) > 0.5 * k.a) return false;
    final lows = [for (final j in k.fs.pivLo) if (hs[0] < j && j < hs[2]) k.l[j]];
    if (lows.isEmpty) return false;
    final neck = lows.reduce(math.min);
    return top.reduce(math.max) - neck >= k.a && k.c[k.i - 1] >= neck && k.c[k.i] < neck;
  }),
  'triple_bottom': ('BUY', 'reversal', (k) {
    final ls = k.piv(k.fs.pivLo, 3);
    if (ls.length < 3 || k.i - ls[2] > 30) return false;
    final bot = [for (final j in ls) k.l[j]];
    if (bot.reduce(math.max) - bot.reduce(math.min) > 0.5 * k.a) return false;
    final highs = [for (final j in k.fs.pivHi) if (ls[0] < j && j < ls[2]) k.h[j]];
    if (highs.isEmpty) return false;
    final neck = highs.reduce(math.max);
    return neck - bot.reduce(math.min) >= k.a && k.c[k.i - 1] <= neck && k.c[k.i] > neck;
  }),
  'rising_wedge': ('SELL', 'reversal', (k) => _wedge(k, rising: true)),
  'falling_wedge': ('BUY', 'reversal', (k) => _wedge(k, rising: false)),
  'diamond_top': ('SELL', 'reversal', (k) => _diamond(k, top: true)),
  'diamond_bottom': ('BUY', 'reversal', (k) => _diamond(k, top: false)),
  'rounding_top': ('SELL', 'reversal', (k) => _rounding(k, top: true)),
  'rounding_bottom': ('BUY', 'reversal', (k) => _rounding(k, top: false)),
  'three_drive_bearish': ('SELL', 'reversal', (k) {
    final hs = k.piv(k.fs.pivHi, 3);
    if (hs.length < 3 || k.i - hs[2] > 20) return false;
    if (!(k.h[hs[1]] > k.h[hs[0]] + 0.2 * k.a && k.h[hs[2]] > k.h[hs[1]] + 0.2 * k.a)) return false;
    final g1 = hs[1] - hs[0], g2 = hs[2] - hs[1];
    if (g1 < 3 || g2 < 3 || (g1 - g2).abs() > math.max(g1, g2) * 0.6) return false;
    final lows = [for (final j in k.fs.pivLo) if (hs[1] < j && j < hs[2]) k.l[j]];
    if (lows.isEmpty) return false;
    final neck = lows.reduce(math.min);
    return k.c[k.i - 1] >= neck && k.c[k.i] < neck;
  }),
  'three_drive_bullish': ('BUY', 'reversal', (k) {
    final ls = k.piv(k.fs.pivLo, 3);
    if (ls.length < 3 || k.i - ls[2] > 20) return false;
    if (!(k.l[ls[1]] < k.l[ls[0]] - 0.2 * k.a && k.l[ls[2]] < k.l[ls[1]] - 0.2 * k.a)) return false;
    final g1 = ls[1] - ls[0], g2 = ls[2] - ls[1];
    if (g1 < 3 || g2 < 3 || (g1 - g2).abs() > math.max(g1, g2) * 0.6) return false;
    final highs = [for (final j in k.fs.pivHi) if (ls[1] < j && j < ls[2]) k.h[j]];
    if (highs.isEmpty) return false;
    final neck = highs.reduce(math.max);
    return k.c[k.i - 1] <= neck && k.c[k.i] > neck;
  }),
  'bear_flag': ('SELL', 'continuation', (k) {
    final i = k.i, ls = k.piv(k.fs.pivLo, 1);
    if (ls.isEmpty) return false;
    final p = ls[0];
    if (i - p < 3 || i - p > 15 || p < 10) return false;
    final bottom = k.l[p];
    var top = k.h[p - 10];
    for (var j = p - 9; j <= p; j++) {
      top = math.max(top, k.h[j]);
    }
    final pole = top - bottom;
    if (pole < 3 * k.a) return false;
    var loAfter = k.l[p + 1], hiAfter = k.h[p + 1];
    for (var j = p + 2; j < i; j++) {
      loAfter = math.min(loAfter, k.l[j]);
      hiAfter = math.max(hiAfter, k.h[j]);
    }
    if (loAfter < bottom) return false;
    final bounce = hiAfter - bottom;
    if (bounce <= 0 || bounce > 0.5 * pole) return false;
    return k.c[i - 1] >= bottom && bottom > k.c[i];
  }),
  'bullish_pennant': ('BUY', 'continuation', (k) => _pennant(k, bull: true)),
  'bearish_pennant': ('SELL', 'continuation', (k) => _pennant(k, bull: false)),
  'descending_triangle': ('SELL', 'continuation', (k) {
    final hs = k.piv(k.fs.pivHi, 2), ls = k.piv(k.fs.pivLo, 2);
    if (hs.length < 2 || ls.length < 2) return false;
    final h1 = hs[0], h2 = hs[1], l1 = ls[0], l2 = ls[1];
    if (k.i - l2 > 30 || l2 - l1 < 3 || (k.l[l1] - k.l[l2]).abs() > 0.3 * k.a) return false;
    if (!(h1 < l2 && h2 > l1) || k.h[h1] - k.h[h2] < 0.3 * k.a) return false;
    final floor = math.min(k.l[l1], k.l[l2]);
    if (k.h[h1] - floor < k.a) return false;
    return k.c[k.i - 1] >= floor && floor > k.c[k.i];
  }),
  'symmetrical_triangle_up': ('BUY', 'continuation', (k) => _symTriangle(k) == 'BUY'),
  'symmetrical_triangle_down': ('SELL', 'continuation', (k) => _symTriangle(k) == 'SELL'),
  'bullish_rectangle': ('BUY', 'continuation', (k) => _rectangle(k) == 'BUY'),
  'bearish_rectangle': ('SELL', 'continuation', (k) => _rectangle(k) == 'SELL'),
  'cup_and_handle': ('BUY', 'continuation', (k) {
    final i = k.i, hs = k.piv(k.fs.pivHi, 6);
    if (hs.length < 2) return false;
    final rimR = hs.last; // right rim (the handle starts after it)
    if (i - rimR < 2 || i - rimR > 10) return false;
    // left rim: an earlier pivot high at about the same height, with a rounded dip of 2+ ATR between them
    for (final rimL in hs.reversed.skip(1)) {
      if (rimR - rimL < 15 || rimR - rimL > 80) continue;
      if ((k.h[rimL] - k.h[rimR]).abs() > 0.5 * k.a) continue;
      var lo = rimL, j = rimL;
      for (j = rimL; j <= rimR; j++) {
        if (k.l[j] < k.l[lo]) lo = j;
      }
      final depth = math.min(k.h[rimL], k.h[rimR]) - k.l[lo];
      final third = (rimR - rimL) / 3;
      if (depth < 2 * k.a || lo < rimL + third || lo > rimR - third) continue; // bottom in the middle third: rounded
      var handleLow = k.l[rimR + 1];
      for (j = rimR + 1; j < i; j++) {
        handleLow = math.min(handleLow, k.l[j]);
      }
      final rim = math.max(k.h[rimL], k.h[rimR]);
      if (rim - handleLow > 0.5 * depth || rim - handleLow <= 0) continue;
      return k.c[i - 1] <= rim && k.c[i] > rim;
    }
    return false;
  }),
  'ascending_channel_bounce': ('BUY', 'continuation', (k) => _channel(k) == 'bounce_up'),
  'ascending_channel_breakout': ('BUY', 'continuation', (k) => _channel(k) == 'break_up'),
  'descending_channel_bounce': ('SELL', 'continuation', (k) => _channel(k) == 'bounce_down'),
  'descending_channel_breakdown': ('SELL', 'continuation', (k) => _channel(k) == 'break_down'),
  'ascending_triangle_breakdown': ('SELL', 'continuation', (k) {
    final hs = k.piv(k.fs.pivHi, 2), ls = k.piv(k.fs.pivLo, 2);
    if (hs.length < 2 || ls.length < 2) return false;
    final h1 = hs[0], h2 = hs[1], l1 = ls[0], l2 = ls[1];
    if (k.i - l2 > 30 || (k.h[h1] - k.h[h2]).abs() > 0.3 * k.a || k.l[l2] - k.l[l1] < 0.3 * k.a || l2 - l1 < 3) return false;
    final s0 = k.line(l1, k.l[l1], l2, k.l[l2], k.i - 1), s1 = k.line(l1, k.l[l1], l2, k.l[l2], k.i);
    return k.c[k.i - 1] >= s0 && k.c[k.i] < s1;
  }),
};

bool _wedge(_K k, {required bool rising}) {
  final hs = k.piv(k.fs.pivHi, 3), ls = k.piv(k.fs.pivLo, 3);
  if (hs.length < 2 || ls.length < 2) return false;
  final h1 = hs[hs.length - 2], h2 = hs.last, l1 = ls[ls.length - 2], l2 = ls.last;
  if (k.i - math.max(h2, l2) > 25 || h2 - h1 < 3 || l2 - l1 < 3) return false;
  final sh = (k.h[h2] - k.h[h1]) / (h2 - h1), sl = (k.l[l2] - k.l[l1]) / (l2 - l1);
  if (rising) {
    if (!(sh > 0 && sl > 0 && sl > sh)) return false; // both up, lower line steeper: converging
    final s0 = k.line(l1, k.l[l1], l2, k.l[l2], k.i - 1), s1 = k.line(l1, k.l[l1], l2, k.l[l2], k.i);
    return k.c[k.i - 1] >= s0 && k.c[k.i] < s1;
  }
  if (!(sh < 0 && sl < 0 && sh < sl)) return false; // both down, upper line steeper
  final r0 = k.line(h1, k.h[h1], h2, k.h[h2], k.i - 1), r1 = k.line(h1, k.h[h1], h2, k.h[h2], k.i);
  return k.c[k.i - 1] <= r0 && k.c[k.i] > r1;
}

bool _diamond(_K k, {required bool top}) {
  final hs = k.piv(k.fs.pivHi, 3), ls = k.piv(k.fs.pivLo, 3);
  if (hs.length < 3 || ls.length < 3 || k.i - math.max(hs.last, ls.last) > 20) return false;
  final hh = [for (final j in hs) k.h[j]], ll = [for (final j in ls) k.l[j]];
  // widening then narrowing: the middle high is the highest and the middle low the lowest
  if (!(hh[1] > hh[0] && hh[1] > hh[2] && ll[1] < ll[0] && ll[1] < ll[2])) return false;
  if (hh[1] - ll[1] < 2 * k.a) return false;
  final prior = k.fs.trend(math.max(0, math.min(hs[0], ls[0]) - 1));
  if (top) {
    if (prior != 'up') return false;
    final s0 = k.line(ls[1], ll[1], ls[2], ll[2], k.i - 1), s1 = k.line(ls[1], ll[1], ls[2], ll[2], k.i);
    return k.c[k.i - 1] >= s0 && k.c[k.i] < s1;
  }
  if (prior != 'down') return false;
  final r0 = k.line(hs[1], hh[1], hs[2], hh[2], k.i - 1), r1 = k.line(hs[1], hh[1], hs[2], hh[2], k.i);
  return k.c[k.i - 1] <= r0 && k.c[k.i] > r1;
}

bool _rounding(_K k, {required bool top}) {
  final i = k.i;
  if (i < 41) return false;
  final s = i - 40; // the arc: the last 40 closed candles before this one
  var ext = s;
  for (var j = s; j < i; j++) {
    if (top ? k.h[j] > k.h[ext] : k.l[j] < k.l[ext]) ext = j;
  }
  if (ext < s + 12 || ext > i - 12) return false; // extreme in the middle
  // smooth: halfway between each end and the extreme the price is between them (no V shape)
  final m1 = (s + ext) ~/ 2, m2 = (ext + i) ~/ 2;
  if (top) {
    final depth = k.h[ext] - math.max(k.c[s], k.c[i - 1]);
    if (depth < 2 * k.a) return false;
    if (!(k.c[m1] > k.c[s] && k.c[m2] > k.c[i - 1])) return false;
    var base = k.l[s];
    for (var j = s; j <= m1; j++) {
      base = math.min(base, k.l[j]);
    }
    return k.c[i - 1] >= base && k.c[i] < base; // the left base broken
  }
  final depth = math.min(k.c[s], k.c[i - 1]) - k.l[ext];
  if (depth < 2 * k.a) return false;
  if (!(k.c[m1] < k.c[s] && k.c[m2] < k.c[i - 1])) return false;
  var rim = k.h[s];
  for (var j = s; j <= m1; j++) {
    rim = math.max(rim, k.h[j]);
  }
  return k.c[i - 1] <= rim && k.c[i] > rim;
}

bool _pennant(_K k, {required bool bull}) {
  final i = k.i, hs = k.piv(k.fs.pivHi, 2), ls = k.piv(k.fs.pivLo, 2);
  if (hs.length < 2 || ls.length < 2) return false;
  final h1 = hs[0], h2 = hs[1], l1 = ls[0], l2 = ls[1];
  final start = math.min(h1, l1);
  if (i - start > 20 || start < 10) return false;
  if (!(k.h[h2] < k.h[h1] && k.l[l2] > k.l[l1])) return false; // converging
  final width = k.h[h1] - k.l[l1];
  final pole = bull ? k.h[h1] - k.l[start - 10] : k.h[start - 10] - k.l[l1];
  if (pole < 3 * k.a || width > 0.5 * pole) return false;
  if (bull) {
    final r0 = k.line(h1, k.h[h1], h2, k.h[h2], i - 1), r1 = k.line(h1, k.h[h1], h2, k.h[h2], i);
    return k.c[i - 1] <= r0 && k.c[i] > r1;
  }
  final s0 = k.line(l1, k.l[l1], l2, k.l[l2], i - 1), s1 = k.line(l1, k.l[l1], l2, k.l[l2], i);
  return k.c[i - 1] >= s0 && k.c[i] < s1;
}

String? _symTriangle(_K k) {
  final i = k.i, hs = k.piv(k.fs.pivHi, 2), ls = k.piv(k.fs.pivLo, 2);
  if (hs.length < 2 || ls.length < 2) return null;
  final h1 = hs[0], h2 = hs[1], l1 = ls[0], l2 = ls[1];
  if (i - math.max(h2, l2) > 25 || h2 - h1 < 3 || l2 - l1 < 3) return null;
  if (!(k.h[h1] - k.h[h2] >= 0.3 * k.a && k.l[l2] - k.l[l1] >= 0.3 * k.a)) return null;
  final r0 = k.line(h1, k.h[h1], h2, k.h[h2], i - 1), r1 = k.line(h1, k.h[h1], h2, k.h[h2], i);
  final s0 = k.line(l1, k.l[l1], l2, k.l[l2], i - 1), s1 = k.line(l1, k.l[l1], l2, k.l[l2], i);
  if (k.c[i - 1] <= r0 && k.c[i] > r1) return 'BUY';
  if (k.c[i - 1] >= s0 && k.c[i] < s1) return 'SELL';
  return null;
}

String? _rectangle(_K k) {
  final i = k.i, hs = k.piv(k.fs.pivHi, 2), ls = k.piv(k.fs.pivLo, 2);
  if (hs.length < 2 || ls.length < 2) return null;
  if (i - math.max(hs[1], ls[1]) > 25) return null;
  if ((k.h[hs[0]] - k.h[hs[1]]).abs() > 0.4 * k.a || (k.l[ls[0]] - k.l[ls[1]]).abs() > 0.4 * k.a) return null;
  final top = math.max(k.h[hs[0]], k.h[hs[1]]), bot = math.min(k.l[ls[0]], k.l[ls[1]]);
  if (top - bot < k.a || top - bot > 6 * k.a) return null;
  if (k.c[i - 1] <= top && k.c[i] > top) return 'BUY';
  if (k.c[i - 1] >= bot && k.c[i] < bot) return 'SELL';
  return null;
}

String? _channel(_K k) {
  final i = k.i, hs = k.piv(k.fs.pivHi, 2), ls = k.piv(k.fs.pivLo, 2);
  if (hs.length < 2 || ls.length < 2) return null;
  final h1 = hs[0], h2 = hs[1], l1 = ls[0], l2 = ls[1];
  if (h2 - h1 < 3 || l2 - l1 < 3 || i - math.max(h2, l2) > 25) return null;
  final sh = (k.h[h2] - k.h[h1]) / (h2 - h1), sl = (k.l[l2] - k.l[l1]) / (l2 - l1);
  final up = sh > 0 && sl > 0, down = sh < 0 && sl < 0;
  if (!up && !down) return null;
  if ((sh - sl).abs() > 0.5 * math.max(sh.abs(), sl.abs())) return null; // roughly parallel
  final r0 = k.line(h1, k.h[h1], h2, k.h[h2], i - 1), r1 = k.line(h1, k.h[h1], h2, k.h[h2], i);
  final s1 = k.line(l1, k.l[l1], l2, k.l[l2], i), s0 = k.line(l1, k.l[l1], l2, k.l[l2], i - 1);
  if (r1 - s1 < k.a) return null;
  if (up) {
    if (k.c[i - 1] <= r0 && k.c[i] > r1) return 'break_up';
    if (k.l[i] <= s1 + 0.15 * k.a && k.c[i] > s1 && k.green(i) && k.lower(i) >= k.body(i)) return 'bounce_up';
  } else {
    if (k.c[i - 1] >= s0 && k.c[i] < s1) return 'break_down';
    if (k.h[i] >= r1 - 0.15 * k.a && k.c[i] < r1 && k.red(i) && k.upper(i) >= k.body(i)) return 'bounce_down';
  }
  return null;
}

// ------------------------------------------------------------------ price action / smart money
final Map<String, (String, _Rule)> _priceAction = {
  'support_bounce': ('BUY', (k) {
    final i = k.i;
    return k.green(i) && k.lower(i) >= 1.5 * k.body(i) && k.rng(i) >= 0.6 * k.a && k.nearLevel(k.l[i], 'support');
  }),
  'resistance_rejection': ('SELL', (k) {
    final i = k.i;
    return k.red(i) && k.upper(i) >= 1.5 * k.body(i) && k.rng(i) >= 0.6 * k.a && k.nearLevel(k.h[i], 'resistance');
  }),
  'breakout_retest_buy': ('BUY', (k) => _retest(k, up: true)),
  'breakout_retest_sell': ('SELL', (k) => _retest(k, up: false)),
  'bullish_fakeout': ('BUY', (k) => _fakeout(k, bull: true)),
  'bearish_fakeout': ('SELL', (k) => _fakeout(k, bull: false)),
  'trendline_bounce_up': ('BUY', (k) {
    final ls = k.piv(k.fs.pivLo, 2);
    if (ls.length < 2 || ls[1] - ls[0] < 6 || k.l[ls[1]] <= k.l[ls[0]]) return false;
    final y = k.line(ls[0], k.l[ls[0]], ls[1], k.l[ls[1]], k.i);
    return k.i - ls[1] >= 4 && k.l[k.i] <= y + 0.15 * k.a && k.c[k.i] > y && k.green(k.i) && k.lower(k.i) >= k.body(k.i);
  }),
  'trendline_bounce_down': ('SELL', (k) {
    final hs = k.piv(k.fs.pivHi, 2);
    if (hs.length < 2 || hs[1] - hs[0] < 6 || k.h[hs[1]] >= k.h[hs[0]]) return false;
    final y = k.line(hs[0], k.h[hs[0]], hs[1], k.h[hs[1]], k.i);
    return k.i - hs[1] >= 4 && k.h[k.i] >= y - 0.15 * k.a && k.c[k.i] < y && k.red(k.i) && k.upper(k.i) >= k.body(k.i);
  }),
  'trendline_break_down': ('SELL', (k) {
    final ls = k.piv(k.fs.pivLo, 2);
    if (ls.length < 2 || ls[1] - ls[0] < 6 || k.l[ls[1]] <= k.l[ls[0]]) return false;
    final y0 = k.line(ls[0], k.l[ls[0]], ls[1], k.l[ls[1]], k.i - 1), y1 = k.line(ls[0], k.l[ls[0]], ls[1], k.l[ls[1]], k.i);
    return k.c[k.i - 1] >= y0 && k.c[k.i] < y1 - 0.1 * k.a && k.red(k.i) && k.body(k.i) >= k.avgBody(k.i);
  }),
  'trendline_break_up': ('BUY', (k) {
    final hs = k.piv(k.fs.pivHi, 2);
    if (hs.length < 2 || hs[1] - hs[0] < 6 || k.h[hs[1]] >= k.h[hs[0]]) return false;
    final y0 = k.line(hs[0], k.h[hs[0]], hs[1], k.h[hs[1]], k.i - 1), y1 = k.line(hs[0], k.h[hs[0]], hs[1], k.h[hs[1]], k.i);
    return k.c[k.i - 1] <= y0 && k.c[k.i] > y1 + 0.1 * k.a && k.green(k.i) && k.body(k.i) >= k.avgBody(k.i);
  }),
  'ema_bounce_up': ('BUY', (k) {
    final i = k.i, e = k.fs.ema[21]!, e50 = k.fs.ema[50]!;
    return e[i] > e[i - 5] && e[i] > e50[i] && k.l[i] <= e[i] && k.c[i] > e[i] && k.green(i) && k.lower(i) >= k.body(i);
  }),
  'ema_bounce_down': ('SELL', (k) {
    final i = k.i, e = k.fs.ema[21]!, e50 = k.fs.ema[50]!;
    return e[i] < e[i - 5] && e[i] < e50[i] && k.h[i] >= e[i] && k.c[i] < e[i] && k.red(i) && k.upper(i) >= k.body(i);
  }),
  'order_block_buy': ('BUY', (k) => _orderBlock(k, bull: true)),
  'order_block_sell': ('SELL', (k) => _orderBlock(k, bull: false)),
  'break_of_structure_up': ('BUY', (k) {
    final hs = k.piv(k.fs.pivHi, 2), ls = k.piv(k.fs.pivLo, 2);
    if (hs.length < 2 || ls.length < 2) return false;
    if (!(k.h[hs[1]] > k.h[hs[0]] && k.l[ls[1]] > k.l[ls[0]])) return false; // HH + HL
    final lvl = k.h[hs[1]];
    return k.c[k.i - 1] <= lvl && k.c[k.i] > lvl + 0.1 * k.a && k.body(k.i) >= k.avgBody(k.i);
  }),
  'break_of_structure_down': ('SELL', (k) {
    final hs = k.piv(k.fs.pivHi, 2), ls = k.piv(k.fs.pivLo, 2);
    if (hs.length < 2 || ls.length < 2) return false;
    if (!(k.h[hs[1]] < k.h[hs[0]] && k.l[ls[1]] < k.l[ls[0]])) return false; // LH + LL
    final lvl = k.l[ls[1]];
    return k.c[k.i - 1] >= lvl && k.c[k.i] < lvl - 0.1 * k.a && k.body(k.i) >= k.avgBody(k.i);
  }),
  'change_of_character_down': ('SELL', (k) {
    final hs = k.piv(k.fs.pivHi, 2), ls = k.piv(k.fs.pivLo, 2);
    if (hs.length < 2 || ls.length < 2) return false;
    if (!(k.h[hs[1]] > k.h[hs[0]] && k.l[ls[1]] > k.l[ls[0]])) return false; // was an uptrend
    final lvl = k.l[ls[1]];
    return k.c[k.i - 1] >= lvl && k.c[k.i] < lvl;
  }),
  'change_of_character_up': ('BUY', (k) {
    final hs = k.piv(k.fs.pivHi, 2), ls = k.piv(k.fs.pivLo, 2);
    if (hs.length < 2 || ls.length < 2) return false;
    if (!(k.h[hs[1]] < k.h[hs[0]] && k.l[ls[1]] < k.l[ls[0]])) return false; // was a downtrend
    final lvl = k.h[hs[1]];
    return k.c[k.i - 1] <= lvl && k.c[k.i] > lvl;
  }),
  'fvg_strong_follow_buy': ('BUY', (k) {
    final i = k.i, j = i - 1; // gap between candles j-1 and i... the impulse is j, i follows it strongly
    return k.l[i] > k.h[j - 1] && k.l[i] - k.h[j - 1] >= 0.3 * k.a && k.green(j) && k.big(j) && k.green(i) &&
        k.body(i) >= 0.6 * k.rng(i) && k.body(i) >= k.avgBody(i);
  }),
  'fvg_strong_follow_sell': ('SELL', (k) {
    final i = k.i, j = i - 1;
    return k.h[i] < k.l[j - 1] && k.l[j - 1] - k.h[i] >= 0.3 * k.a && k.red(j) && k.big(j) && k.red(i) &&
        k.body(i) >= 0.6 * k.rng(i) && k.body(i) >= k.avgBody(i);
  }),
  'discount_zone_buy': ('BUY', (k) => _zone(k, up: true, lo: 0.5, hi: 1.0) && !_zone(k, up: true, lo: 0.5, hi: 0.618)),
  'premium_zone_sell': ('SELL', (k) => _zone(k, up: false, lo: 0.5, hi: 1.0) && !_zone(k, up: false, lo: 0.5, hi: 0.618)),
  'fibonacci_golden_zone_buy': ('BUY', (k) => _zone(k, up: true, lo: 0.5, hi: 0.618)),
  'fibonacci_golden_zone_sell': ('SELL', (k) => _zone(k, up: false, lo: 0.5, hi: 0.618)),
};

/// A level broken in the last 10 candles, retested now (touch within 0.2 ATR) and held.
bool _retest(_K k, {required bool up}) {
  final i = k.i;
  for (final lv in k.fs.levels(math.max(0, i - 11))) {
    final p = lv.$1;
    var broke = -1;
    for (var j = i - 10; j < i; j++) {
      if (up ? (k.c[j - 1] <= p && k.c[j] > p) : (k.c[j - 1] >= p && k.c[j] < p)) broke = j;
    }
    if (broke < 0 || i - broke < 2 || k.body(broke) < k.avgBody(broke)) continue;
    var retested = false; // only the first return to the level counts
    for (var j = broke + 1; j < i; j++) {
      if (up ? k.l[j] <= p + 0.2 * k.a : k.h[j] >= p - 0.2 * k.a) retested = true;
    }
    if (retested) continue;
    if (up && k.l[i] <= p + 0.2 * k.a && k.c[i] > p && k.green(i)) return true;
    if (!up && k.h[i] >= p - 0.2 * k.a && k.c[i] < p && k.red(i)) return true;
  }
  return false;
}

/// A wick through a support / swing low (bull) that closes back above it — a liquidity sweep / fake break.
bool _fakeout(_K k, {required bool bull}) {
  final i = k.i;
  final prices = <double>[
    for (final lv in k.fs.levels(math.max(0, i - 1))) if (lv.$2 == (bull ? 'support' : 'resistance')) lv.$1,
  ];
  if (k.rng(i) < 0.6 * k.a) return false;
  for (final p in prices) {
    if (bull && k.l[i] < p - 0.1 * k.a && k.c[i] > p && k.lower(i) >= 1.5 * k.body(i)) return true;
    if (!bull && k.h[i] > p + 0.1 * k.a && k.c[i] < p && k.upper(i) >= 1.5 * k.body(i)) return true;
  }
  return false;
}

/// The last opposite candle before a strong impulse (body ≥ 2 ATR) in the last 60 candles; the first return into
/// it now, closing back on the impulse's side (order block / demand-supply zone / mitigation / POI).
bool _orderBlock(_K k, {required bool bull}) {
  final i = k.i;
  for (var imp = i - 3; imp >= math.max(2, i - 60); imp--) {
    final strong = bull ? (k.green(imp) && k.body(imp) >= 1.5 * k.a) : (k.red(imp) && k.body(imp) >= 1.5 * k.a);
    if (!strong) continue;
    var ob = imp - 1;
    while (ob > 0 && !(bull ? k.red(ob) : k.green(ob)) && imp - ob < 4) {
      ob--;
    }
    if (!(bull ? k.red(ob) : k.green(ob))) continue;
    final zoneHi = k.h[ob], zoneLo = k.l[ob];
    var touched = false;
    for (var j = imp + 1; j < i; j++) {
      if (bull ? k.l[j] <= zoneHi : k.h[j] >= zoneLo) touched = true;
    }
    if (touched) continue;
    if (bull) return k.l[i] <= zoneHi && k.c[i] > zoneLo && k.green(i);
    return k.h[i] >= zoneLo && k.c[i] < zoneHi && k.red(i);
  }
  return false;
}

/// Price in the retracement band [lo, hi] of the last swing (up swing: low → high, measured down from the high),
/// with a rejection candle closing back with the swing.
bool _zone(_K k, {required bool up, required double lo, required double hi}) {
  final i = k.i, hs = k.piv(k.fs.pivHi, 1), ls = k.piv(k.fs.pivLo, 1);
  if (hs.isEmpty || ls.isEmpty) return false;
  final top = k.h[hs[0]], bot = k.l[ls[0]], size = top - bot;
  if (size < 2 * k.a) return false;
  if (up) {
    if (!(ls[0] < hs[0])) return false; // the swing went up last
    final r = (top - k.l[i]) / size;
    return r >= lo && r <= hi && k.green(i) && k.lower(i) >= k.body(i) * 0.5 && k.c[i] > bot;
  }
  if (!(hs[0] < ls[0])) return false;
  final r = (k.h[i] - bot) / size;
  return r >= lo && r <= hi && k.red(i) && k.upper(i) >= k.body(i) * 0.5 && k.c[i] < top;
}

// ------------------------------------------------------------------ public
/// Names of every setup with its side and kind (for the UI and the tests).
final Map<String, (String side, String kind)> allSetups = {
  for (final e in _candles.entries) e.key: (e.value.$1, 'candle'),
  for (final e in _charts.entries) e.key: (e.value.$1, e.value.$2),
  for (final e in _priceAction.entries) e.key: (e.value.$1, 'price_action'),
  // already in the engine (strategy conditions) — reported here too
  'double_top': ('SELL', 'reversal'), 'double_bottom': ('BUY', 'reversal'), 'head_shoulders': ('SELL', 'reversal'),
  'bull_flag': ('BUY', 'continuation'), 'ascending_triangle': ('BUY', 'continuation'),
  'gap_retest_bull': ('BUY', 'price_action'), 'gap_retest_bear': ('SELL', 'price_action'),
};

/// Every setup that shows on the last candle of `fs` (needs 30+ closed candles).
List<SetupHit> detectSetups(FeatureSet fs) {
  if (fs.n < 30) return const [];
  final k = _K(fs);
  final out = <SetupHit>[];
  for (final e in _candles.entries) {
    if (e.value.$2(k)) out.add(SetupHit(e.key, e.value.$1, 'candle'));
  }
  for (final e in _charts.entries) {
    if (e.value.$3(k)) out.add(SetupHit(e.key, e.value.$1, e.value.$2));
  }
  for (final e in _priceAction.entries) {
    if (e.value.$2(k)) out.add(SetupHit(e.key, e.value.$1, 'price_action'));
  }
  for (final e in chartPatterns.entries) {
    if (e.value(fs, k.i)) out.add(SetupHit(e.key, allSetups[e.key]!.$1, allSetups[e.key]!.$2));
  }
  return out;
}
