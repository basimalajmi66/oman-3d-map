/// Classic chart patterns as testable, causal *break* events at a closed bar `i`
/// (port of strategy/chart_patterns.py, operation for operation — checked by the parity test).
///
/// Each pattern is built only from swing pivots already confirmed at bar `i - 1`; the event fires on the
/// candle whose close crosses the pattern's line (neckline, flag top, triangle top). Sizes are in ATR.
library;

import 'dart:math' as math;

import 'features.dart';

const _maxAge = 30;

double? _atr(FeatureSet fs, int i) {
  final a = fs.atr[i];
  return a.isNaN || a <= 0 ? null : a;
}

List<int> _between(List<int> pivs, int a, int b) => [for (final j in pivs) if (a < j && j < b) j];

bool doubleTop(FeatureSet fs, int i) {
  final a = _atr(fs, i);
  if (a == null || i < 1) return false;
  final hs = fs.confirmed(fs.pivHi, i - 1, 2);
  if (hs.length < 2) return false;
  final h1 = hs[0], h2 = hs[1];
  if (h2 - h1 < 3 || i - h2 > _maxAge || (fs.h[h1] - fs.h[h2]).abs() > 0.5 * a) return false;
  final lows = _between(fs.pivLo, h1, h2);
  if (lows.isEmpty) return false;
  final neck = lows.map((j) => fs.l[j]).reduce(math.min);
  if (math.max(fs.h[h1], fs.h[h2]) - neck < a) return false;
  return fs.c[i - 1] >= neck && neck > fs.c[i];
}

bool doubleBottom(FeatureSet fs, int i) {
  final a = _atr(fs, i);
  if (a == null || i < 1) return false;
  final ls = fs.confirmed(fs.pivLo, i - 1, 2);
  if (ls.length < 2) return false;
  final l1 = ls[0], l2 = ls[1];
  if (l2 - l1 < 3 || i - l2 > _maxAge || (fs.l[l1] - fs.l[l2]).abs() > 0.5 * a) return false;
  final highs = _between(fs.pivHi, l1, l2);
  if (highs.isEmpty) return false;
  final neck = highs.map((j) => fs.h[j]).reduce(math.max);
  if (neck - math.min(fs.l[l1], fs.l[l2]) < a) return false;
  return fs.c[i - 1] <= neck && neck < fs.c[i];
}

double _neckAt(int x1, double y1, int x2, double y2, int x) => y1 + (y2 - y1) * (x - x1) / (x2 - x1);

int _lowest(FeatureSet fs, List<int> js) {
  var best = js.first;
  for (final j in js.skip(1)) {
    if (fs.l[j] < fs.l[best]) best = j;
  }
  return best;
}

bool headShoulders(FeatureSet fs, int i) {
  final a = _atr(fs, i);
  if (a == null || i < 1) return false;
  final hs = fs.confirmed(fs.pivHi, i - 1, 3);
  if (hs.length < 3) return false;
  final ls = hs[0], hd = hs[1], rs = hs[2];
  if (i - rs > _maxAge) return false;
  final hl = fs.h[ls], hh = fs.h[hd], hr = fs.h[rs];
  if (hh - math.max(hl, hr) < 0.5 * a || (hl - hr).abs() > a) return false;
  final low1 = _between(fs.pivLo, ls, hd), low2 = _between(fs.pivLo, hd, rs);
  if (low1.isEmpty || low2.isEmpty) return false;
  final j1 = _lowest(fs, low1), j2 = _lowest(fs, low2);
  final y1 = fs.l[j1], y2 = fs.l[j2];
  if (hh - math.max(y1, y2) < 1.5 * a) return false;
  return fs.c[i - 1] >= _neckAt(j1, y1, j2, y2, i - 1) && fs.c[i] < _neckAt(j1, y1, j2, y2, i);
}

bool bullFlag(FeatureSet fs, int i) {
  final a = _atr(fs, i);
  if (a == null || i < 1) return false;
  final hs = fs.confirmed(fs.pivHi, i - 1, 1);
  if (hs.isEmpty) return false;
  final p = hs[0];
  if (i - p < 3 || i - p > 15 || p < 10) return false;
  final top = fs.h[p];
  var base = fs.l[p - 10];
  for (var j = p - 9; j <= p; j++) {
    base = math.min(base, fs.l[j]);
  }
  final pole = top - base;
  if (pole < 3 * a) return false;
  var hiAfter = fs.h[p + 1], loAfter = fs.l[p + 1];
  for (var j = p + 2; j < i; j++) {
    hiAfter = math.max(hiAfter, fs.h[j]);
    loAfter = math.min(loAfter, fs.l[j]);
  }
  if (hiAfter > top) return false;
  final dip = top - loAfter;
  if (dip <= 0 || dip > 0.5 * pole) return false;
  return fs.c[i - 1] <= top && top < fs.c[i];
}

bool ascendingTriangle(FeatureSet fs, int i) {
  final a = _atr(fs, i);
  if (a == null || i < 1) return false;
  final hs = fs.confirmed(fs.pivHi, i - 1, 2), ls = fs.confirmed(fs.pivLo, i - 1, 2);
  if (hs.length < 2 || ls.length < 2) return false;
  final h1 = hs[0], h2 = hs[1], l1 = ls[0], l2 = ls[1];
  if (i - h2 > _maxAge || h2 - h1 < 3 || (fs.h[h1] - fs.h[h2]).abs() > 0.3 * a) return false;
  if (!(l1 < h2 && l2 > h1) || fs.l[l2] - fs.l[l1] < 0.3 * a) return false;
  final top = math.max(fs.h[h1], fs.h[h2]);
  if (top - fs.l[l1] < a) return false;
  return fs.c[i - 1] <= top && top < fs.c[i];
}

bool _gapRetest(FeatureSet fs, int i, bool up) {
  final a = _atr(fs, i);
  if (a == null || i < 3) return false;
  for (var j = i - 1; j >= math.max(2, i - 20); j--) {
    if (up) {
      final lo = fs.h[j - 2], hi = fs.l[j];
      if (hi - lo < 0.3 * a || !(fs.c[j - 1] > fs.o[j - 1])) continue;
      var touched = false;
      for (var q = j + 1; q < i; q++) {
        if (fs.l[q] <= hi) touched = true;
      }
      if (touched) continue;
      if (fs.l[i] <= hi && fs.c[i] > lo) return true;
      continue;
    }
    final lo = fs.h[j], hi = fs.l[j - 2];
    if (hi - lo < 0.3 * a || !(fs.c[j - 1] < fs.o[j - 1])) continue;
    var touched = false;
    for (var q = j + 1; q < i; q++) {
      if (fs.h[q] >= lo) touched = true;
    }
    if (touched) continue;
    if (fs.h[i] >= lo && fs.c[i] < hi) return true;
  }
  return false;
}

const chartPatternNames = ['double_top', 'double_bottom', 'head_shoulders', 'bull_flag', 'ascending_triangle', 'gap_retest_bull', 'gap_retest_bear'];

final Map<String, bool Function(FeatureSet, int)> chartPatterns = {
  'double_top': doubleTop, 'double_bottom': doubleBottom, 'head_shoulders': headShoulders, //
  'bull_flag': bullFlag, 'ascending_triangle': ascendingTriangle,
  'gap_retest_bull': (fs, i) => _gapRetest(fs, i, true), 'gap_retest_bear': (fs, i) => _gapRetest(fs, i, false),
};
