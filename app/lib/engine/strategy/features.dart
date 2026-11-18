/// Per-bar features for strategy evaluation and backtesting — strictly causal (port of strategy/features.py).
///
/// Indicator arrays are computed once; structural features at bar `i` use data up to `i` only.
/// Pivots are used only once confirmed (`j + k <= i`).
library;

import 'dart:math' as math;

import '../analysis/indicators.dart' as ind;
import '../analysis/patterns.dart' as pat;

const pivotK = 2;
const warmup = 50; // bars needed before features are meaningful (EMA50, ATR, MACD signal)

typedef LevelT = (double price, String kind, int touches);

class FeatureSet {
  FeatureSet(this.o, this.h, this.l, this.c, {this.v}) : n = c.length {
    atr = ind.atr(h, l, c, 14);
    rsi = ind.rsi(c, 14);
    final m = ind.macd(c);
    macd = m.line;
    macdSig = m.signal;
    macdHist = m.hist;
    final bb = ind.bollinger(c, n: 20, k: 2.0);
    bbLo = bb.lower;
    bbMid = bb.mid;
    bbHi = bb.upper;
    ema = {9: ind.ema(c, 9), 21: ind.ema(c, 21), 50: ind.ema(c, 50)};
    slope = ind.linregSlope(c, 20);
    slope10 = ind.linregSlope(c, 10);
    atrPct = [for (var i = 0; i < n; i++) atr[i] / c[i].abs()];
    const k = pivotK;
    for (var j = k; j < n - k; j++) {
      var hiArg = j - k, loArg = j - k;
      for (var q = j - k; q <= j + k; q++) {
        if (h[q] > h[hiArg]) hiArg = q;
        if (l[q] < l[loArg]) loArg = q;
      }
      if (hiArg == j) pivHi.add(j);
      if (loArg == j) pivLo.add(j);
    }
  }

  final List<double> o, h, l, c;
  final List<double>? v;
  final int n;
  late final List<double> atr, rsi, macd, macdSig, macdHist, bbLo, bbMid, bbHi, slope, slope10, atrPct;
  late final Map<int, List<double>> ema;
  final pivHi = <int>[], pivLo = <int>[];
  final Map<int, List<LevelT>> _levelsCache = {};

  /// The last `last` pivots confirmed at bar i (j + K <= i). `pivs` is sorted → binary search.
  List<int> _confirmed(List<int> pivs, int i, [int last = 30]) {
    final limit = i - pivotK;
    var lo = 0, hi = pivs.length; // bisect_right
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (pivs[mid] <= limit) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return pivs.sublist(math.max(0, lo - last), lo);
  }

  String trend(int i) {
    final a = atr[i];
    if (slope[i].isNaN || a.isNaN || a <= 0) return 'unclear';
    final s = slope[i] / a;
    final hs = _confirmed(pivHi, i, 4), ls = _confirmed(pivLo, i, 4);
    String? struct;
    if (hs.length >= 2 && ls.length >= 2) {
      final hh = h[hs.last] > h[hs[hs.length - 2]], hl = l[ls.last] > l[ls[ls.length - 2]];
      struct = hh && hl ? 'up' : (!hh && !hl) ? 'down' : 'mixed';
    }
    if (s > 0.08 && struct != 'down') return 'up';
    if (s < -0.08 && struct != 'up') return 'down';
    return 'sideways';
  }

  String _patternTrend(int i) {
    final j = i - 1;
    if (j < 9 || slope10[j].isNaN || atr[j].isNaN || atr[j] <= 0) return 'unclear';
    final s = slope10[j] / atr[j];
    return s > 0.08 ? 'up' : s < -0.08 ? 'down' : 'sideways';
  }

  Set<String> patterns(int i) {
    final a = atr[i].isNaN ? h[i] - l[i] : atr[i];
    return {for (final p in pat.detectAt(o, h, l, c, i, a, _patternTrend(i))) p.name};
  }

  /// (price, kind, touches) from confirmed pivots up to i, clustered within 0.5 ATR, >= 2 touches.
  List<LevelT> levels(int i) {
    final hit = _levelsCache[i];
    if (hit != null) return hit;
    if (_levelsCache.length > 4) _levelsCache.clear(); // a backtest walks forward
    return _levelsCache[i] = _levels(i);
  }

  List<LevelT> _levels(int i) {
    final a = atr[i];
    if (a.isNaN || a <= 0) return const [];
    final pts = [for (final j in _confirmed(pivHi, i)) h[j], for (final j in _confirmed(pivLo, i)) l[j]]..sort();
    final sums = <double>[], counts = <int>[]; // running mean, same result as the Python version
    for (final p in pts) {
      if (sums.isNotEmpty && (p - sums.last / counts.last).abs() <= 0.5 * a) {
        sums[sums.length - 1] += p;
        counts[counts.length - 1] += 1;
      } else {
        sums.add(p);
        counts.add(1);
      }
    }
    return [
      for (var q = 0; q < sums.length; q++)
        if (counts[q] >= 2) (sums[q] / counts[q], sums[q] / counts[q] < c[i] ? 'support' : 'resistance', counts[q])
    ];
  }

  String marketCondition(int i) {
    final hist = [for (var q = math.max(0, i - 200); q <= i; q++) if (!atrPct[q].isNaN) atrPct[q]];
    if (hist.length > 10 && hist.where((x) => x < atrPct[i]).length / hist.length >= 0.85) return 'volatile';
    final a = atr[i];
    if (!slope[i].isNaN && a > 0 && (slope[i] / a).abs() >= 0.2) return 'trending';
    return 'ranging';
  }

  bool ready(int i) => i >= warmup && !atr[i].isNaN && !macdSig[i].isNaN;
}
