/// Small helpers shared by the on-device engine (Python-compatible semantics).
library;

import 'dart:math' as math;

import 'package:collection/collection.dart' show mergeSort;

/// Python's `round(x, n)`: rounds the *exact* binary value of `x` (so 0.9135, stored as
/// 0.91349999…, gives 0.913), with ties to even like Python.
double roundTo(double x, int n) {
  if (x.isNaN || x.isInfinite) return x;
  // exact tie? (the exact decimal expansion continues with '5' and then only zeros)
  final digits = math.min(20, n + 15);
  final exact = x.abs().toStringAsFixed(digits);
  final tail = exact.substring(exact.length - (digits - n));
  if (RegExp(r'^50*$').hasMatch(tail)) {
    final kept = exact.substring(0, exact.length - (digits - n)).replaceAll('.', '');
    final lastDigit = int.parse(kept[kept.length - 1]);
    final down = double.parse(exact.substring(0, exact.length - (digits - n) - (n == 0 ? 1 : 0)));
    final v = lastDigit.isEven ? down : down + math.pow(10, -n);
    return double.parse((x < 0 ? -v : v).toStringAsFixed(n));
  }
  return double.parse(x.toStringAsFixed(n)); // correctly rounded from the exact value
}

/// Stable sort (Python's `sorted` is stable; Dart's `List.sort` is not guaranteed to be).
List<T> stableSorted<T>(Iterable<T> items, int Function(T a, T b) compare) {
  final l = items.toList();
  mergeSort(l, compare: compare);
  return l;
}

/// Lexicographic comparison of key tuples, like Python's sort keys.
int compareKeys(List<Comparable> a, List<Comparable> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    final c = a[i].compareTo(b[i]);
    if (c != 0) return c;
  }
  return a.length.compareTo(b.length);
}

double mean(Iterable<double> xs) {
  var s = 0.0, n = 0;
  for (final x in xs) {
    s += x;
    n++;
  }
  return n == 0 ? double.nan : s / n;
}

double maxOf(List<double> x, int from, int to) {
  var m = double.negativeInfinity;
  for (var i = from; i < to; i++) {
    if (x[i] > m) m = x[i];
  }
  return m;
}

double minOf(List<double> x, int from, int to) {
  var m = double.infinity;
  for (var i = from; i < to; i++) {
    if (x[i] < m) m = x[i];
  }
  return m;
}
