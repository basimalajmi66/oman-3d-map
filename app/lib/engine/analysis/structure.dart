/// Market structure (port of analysis/structure.py): confirmed pivots, trend,
/// support/resistance, supply/demand, liquidity pools, double tops/bottoms, sudden moves.
///
/// Pivots need `k` candles on each side, so a pivot at `j` is only known at `j + k` (no look-ahead).
library;

import 'dart:math' as math;

import '../util.dart';

class Level {
  Level(this.price, this.kind, this.touches, this.lastIndex, this.strength);
  final double price;
  final String kind; // support | resistance
  final int touches;
  final int lastIndex;
  final double strength;

  Map<String, dynamic> toJson() =>
      {'price': price, 'kind': kind, 'touches': touches, 'last_index': lastIndex, 'strength': strength};
}

class Zone {
  Zone(this.low, this.high, this.kind, this.originIndex, this.impulseAtr, this.fresh);
  final double low, high;
  final String kind; // demand | supply
  final int originIndex;
  final double impulseAtr;
  final bool fresh;

  Map<String, dynamic> toJson() => {
        'low': low, 'high': high, 'kind': kind, 'origin_index': originIndex, 'impulse_atr': impulseAtr,
        'fresh': fresh,
      };
}

class Pivots {
  Pivots(this.highs, this.lows);
  final List<int> highs, lows;
}

/// Indices of confirmed swing highs / lows known at bar `upto`.
/// A pivot must be the *first* extreme of its window (numpy argmax semantics).
Pivots pivots(List<double> high, List<double> low, int k, int upto) {
  final hs = <int>[], ls = <int>[];
  for (var j = k; j <= upto - k; j++) {
    var hiArg = j - k, loArg = j - k;
    for (var q = j - k; q <= j + k; q++) {
      if (high[q] > high[hiArg]) hiArg = q;
      if (low[q] < low[loArg]) loArg = q;
    }
    if (hiArg == j) hs.add(j);
    if (loArg == j) ls.add(j);
  }
  return Pivots(hs, ls);
}

/// Trend from (a) regression slope normalised by ATR and (b) swing structure.
Map<String, dynamic> trend(List<double> close, List<double> high, List<double> low, double atrI,
    {int k = 2, int window = 30}) {
  final n = close.length;
  final w = math.min(window, n);
  final m = mean(close.sublist(n - w));
  var num = 0.0, den = 0.0;
  for (var j = 0; j < w; j++) {
    final t = j - (w - 1) / 2;
    num += t * (close[n - w + j] - m);
    den += t * t;
  }
  final slope = num / math.max(den, 1e-12);
  final slopeAtr = atrI > 0 ? slope / atrI : 0.0;
  final p = pivots(high, low, k, n - 1);
  final hs = p.highs.where((j) => j >= n - w).toList();
  final ls = p.lows.where((j) => j >= n - w).toList();
  var struct = 'unclear';
  if (hs.length >= 2 && ls.length >= 2) {
    final hh = high[hs.last] > high[hs[hs.length - 2]];
    final hl = low[ls.last] > low[ls[ls.length - 2]];
    if (hh && hl) {
      struct = 'up';
    } else if (!hh && !hl) {
      struct = 'down';
    } else {
      struct = 'mixed';
    }
  }
  String direction;
  if (slopeAtr > 0.08 && const ['up', 'unclear', 'mixed'].contains(struct)) {
    direction = 'up';
  } else if (slopeAtr < -0.08 && const ['down', 'unclear', 'mixed'].contains(struct)) {
    direction = 'down';
  } else {
    direction = 'sideways';
  }
  if ((struct == 'up' || struct == 'down') && struct != direction && direction != 'sideways') direction = 'sideways';
  final strength = math.min(1.0, slopeAtr.abs() / 0.4) * (struct == direction ? 1.0 : 0.6);
  return {
    'direction': direction,
    'strength': roundTo(strength, 3),
    'slope_atr_per_bar': roundTo(slopeAtr, 4),
    'structure': struct,
  };
}

/// Cluster confirmed pivots within 0.5 ATR; more touches + recency = stronger.
List<Level> supportResistance(List<double> high, List<double> low, List<double> close, double atrI,
    {int k = 2, int maxLevels = 4}) {
  final n = close.length;
  final p = pivots(high, low, k, n - 1);
  var pts = [for (final j in p.highs) (high[j], j), for (final j in p.lows) (low[j], j)];
  if (pts.isEmpty || atrI <= 0) return [];
  pts = stableSorted(pts, (a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  final tol = 0.5 * atrI;
  // compare with the cluster centre (not its last member) so clusters cannot chain
  final clusters = <List<(double, int)>>[
    [pts.first]
  ];
  for (final q in pts.skip(1)) {
    final centre = mean(clusters.last.map((e) => e.$1));
    if ((q.$1 - centre).abs() <= tol) {
      clusters.last.add(q);
    } else {
      clusters.add([q]);
    }
  }
  final last = close.last;
  final levels = <Level>[];
  for (final cl in clusters.where((cl) => cl.length >= 2)) {
    final price = mean(cl.map((e) => e.$1));
    final lastIdx = cl.map((e) => e.$2).reduce(math.max);
    final recency = 1 - (n - 1 - lastIdx) / math.max(n, 1);
    final strength = math.min(1.0, 0.25 * cl.length + 0.3 * recency);
    levels.add(Level(price, price < last ? 'support' : 'resistance', cl.length, lastIdx, roundTo(strength, 3)));
  }
  // keep the strongest levels closest to price
  final ranked = stableSorted(levels, (a, b) => compareKeys([-a.strength, (a.price - last).abs()],
      [-b.strength, (b.price - last).abs()]));
  return stableSorted(ranked.take(maxLevels), (a, b) => a.price.compareTo(b.price));
}

/// A base (1 quiet candle) followed by an impulsive move of >= `impulse` ATR.
List<Zone> supplyDemand(List<double> o, List<double> high, List<double> low, List<double> close, List<double> atrArr,
    {double impulse = 2.0, int maxZones = 3}) {
  final n = close.length;
  final zones = <Zone>[];
  for (var j = 1; j < n - 1; j++) {
    final a = atrArr[j];
    if (a.isNaN || a <= 0) continue;
    final baseLo = low[j], baseHi = high[j];
    if (baseHi - baseLo > 1.0 * a) continue; // base must be a quiet candle
    final end = math.min(n, j + 4);
    final moveUp = maxOf(high, j + 1, end) - baseHi;
    final moveDn = baseLo - minOf(low, j + 1, end);
    if (moveUp >= impulse * a && close[j + 1] > o[j + 1]) {
      final fresh = end < n ? minOf(low, end, n) > baseHi : true;
      zones.add(Zone(baseLo, baseHi, 'demand', j, roundTo(moveUp / a, 2), fresh));
    } else if (moveDn >= impulse * a && close[j + 1] < o[j + 1]) {
      final fresh = end < n ? maxOf(high, end, n) < baseLo : true;
      zones.add(Zone(baseLo, baseHi, 'supply', j, roundTo(moveDn / a, 2), fresh));
    }
  }
  return stableSorted(zones, (a, b) => compareKeys([a.fresh ? 0 : 1, -a.originIndex], [b.fresh ? 0 : 1, -b.originIndex]))
      .take(maxZones)
      .toList();
}

/// Equal highs / equal lows (within 0.15 ATR): where stop orders tend to rest.
Map<String, List<double>> liquidityPools(List<double> high, List<double> low, double atrI, {int k = 2}) {
  final p = pivots(high, low, k, high.length - 1);
  final tol = 0.15 * atrI;
  List<double> equal(List<int> idx, List<double> arr) {
    final pools = <double>{};
    for (var a = 0; a < idx.length; a++) {
      for (var b = a + 1; b < idx.length; b++) {
        if ((arr[idx[a]] - arr[idx[b]]).abs() <= tol) pools.add(roundTo((arr[idx[a]] + arr[idx[b]]) / 2, 10));
      }
    }
    return pools.toList()..sort();
  }

  return {'equal_highs': equal(p.highs, high), 'equal_lows': equal(p.lows, low)};
}

/// Two comparable swing extremes with a meaningful pullback between them.
Map<String, dynamic>? doubleTopBottom(List<double> high, List<double> low, List<double> close, double atrI,
    {int k = 2}) {
  final n = close.length;
  final p = pivots(high, low, k, n - 1);
  if (p.highs.length >= 2) {
    final a = p.highs[p.highs.length - 2], b = p.highs.last;
    final trough = minOf(low, a, b + 1);
    if ((high[a] - high[b]).abs() <= 0.3 * atrI &&
        math.min(high[a], high[b]) - trough >= 1.5 * atrI &&
        b - a >= 4 &&
        close.last < high[b]) {
      return {'name': 'double_top', 'direction': 'bearish', 'neckline': trough, 'confirmed': close.last < trough};
    }
  }
  if (p.lows.length >= 2) {
    final a = p.lows[p.lows.length - 2], b = p.lows.last;
    final peak = maxOf(high, a, b + 1);
    if ((low[a] - low[b]).abs() <= 0.3 * atrI &&
        peak - math.max(low[a], low[b]) >= 1.5 * atrI &&
        b - a >= 4 &&
        close.last > low[b]) {
      return {'name': 'double_bottom', 'direction': 'bullish', 'neckline': peak, 'confirmed': close.last > peak};
    }
  }
  return null;
}

/// The last closed candle's range is unusually large relative to ATR (before it).
Map<String, dynamic>? suddenMove(List<double> high, List<double> low, List<double> close, List<double> atrArr,
    {double factor = 2.5}) {
  final n = close.length;
  if (n < 3 || atrArr[n - 2].isNaN || atrArr[n - 2] <= 0) return null;
  final ratio = (high[n - 1] - low[n - 1]) / atrArr[n - 2];
  if (ratio >= factor) {
    return {'range_atr': roundTo(ratio, 2), 'direction': close[n - 1] > close[n - 2] ? 'up' : 'down'};
  }
  return null;
}
