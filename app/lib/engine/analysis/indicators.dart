/// Technical indicators — all strictly *causal* (port of backend/uata/analysis/indicators.py).
///
/// Element `i` is computed from elements `0..i` only (NaN until enough data exists), which
/// prevents look-ahead bias in live analysis and in backtests.
library;

import 'dart:math' as math;

const nan = double.nan;

List<double> _nans(int n) => List<double>.filled(n, nan);

List<double> sma(List<double> x, int n) {
  final out = _nans(x.length);
  if (x.length < n) return out;
  var s = 0.0;
  for (var i = 0; i < x.length; i++) {
    s += x[i];
    if (i >= n) s -= x[i - n];
    if (i >= n - 1) out[i] = s / n;
  }
  return out;
}

double _mean(List<double> x, int from, int to) {
  var s = 0.0;
  for (var i = from; i < to; i++) {
    s += x[i];
  }
  return s / (to - from);
}

/// EMA seeded with the SMA of the first `n` values (standard convention).
List<double> ema(List<double> x, int n) {
  final out = _nans(x.length);
  if (x.length < n) return out;
  final k = 2.0 / (n + 1);
  out[n - 1] = _mean(x, 0, n);
  for (var i = n; i < x.length; i++) {
    out[i] = x[i] * k + out[i - 1] * (1 - k);
  }
  return out;
}

List<double> _wilder(List<double> x, int n) {
  final out = _nans(x.length);
  if (x.length < n) return out;
  out[n - 1] = _mean(x, 0, n);
  for (var i = n; i < x.length; i++) {
    out[i] = (out[i - 1] * (n - 1) + x[i]) / n;
  }
  return out;
}

/// Wilder's RSI. Element i needs n price changes, i.e. i >= n.
List<double> rsi(List<double> c, [int n = 14]) {
  final out = _nans(c.length);
  if (c.length <= n) return out;
  final d = [for (var i = 1; i < c.length; i++) c[i] - c[i - 1]];
  final gain = _wilder([for (final v in d) v > 0 ? v : 0.0], n);
  final loss = _wilder([for (final v in d) v < 0 ? -v : 0.0], n);
  for (var j = 0; j < d.length; j++) {
    final g = gain[j], l = loss[j];
    double r;
    if (l == 0) {
      r = g == 0 ? 50.0 : 100.0;
    } else {
      r = 100 - 100 / (1 + g / l);
    }
    out[j + 1] = (g.isNaN || l.isNaN) ? nan : r;
  }
  return out;
}

class Macd {
  Macd(this.line, this.signal, this.hist);
  final List<double> line, signal, hist;
}

Macd macd(List<double> c, {int fast = 12, int slow = 26, int signal = 9}) {
  final ef = ema(c, fast), es = ema(c, slow);
  final line = [for (var i = 0; i < c.length; i++) ef[i] - es[i]];
  final sig = _nans(c.length);
  final start = line.indexWhere((v) => !v.isNaN);
  if (start >= 0 && line.length - start >= signal) {
    final e = ema(line.sublist(start), signal);
    for (var i = 0; i < e.length; i++) {
      sig[start + i] = e[i];
    }
  }
  return Macd(line, sig, [for (var i = 0; i < c.length; i++) line[i] - sig[i]]);
}

class Bands {
  Bands(this.lower, this.mid, this.upper);
  final List<double> lower, mid, upper;
}

Bands bollinger(List<double> c, {int n = 20, double k = 2.0}) {
  final mid = sma(c, n);
  final sd = _nans(c.length);
  for (var i = n - 1; i < c.length; i++) {
    final m = _mean(c, i - n + 1, i + 1);
    var v = 0.0;
    for (var j = i - n + 1; j <= i; j++) {
      v += (c[j] - m) * (c[j] - m);
    }
    sd[i] = math.sqrt(v / n); // population std, like numpy's default
  }
  return Bands([for (var i = 0; i < c.length; i++) mid[i] - k * sd[i]], mid,
      [for (var i = 0; i < c.length; i++) mid[i] + k * sd[i]]);
}

List<double> trueRange(List<double> h, List<double> lo, List<double> c) {
  final tr = List<double>.filled(c.length, 0);
  for (var i = 0; i < c.length; i++) {
    if (i == 0) {
      tr[i] = h[i] - lo[i];
    } else {
      final p = c[i - 1];
      tr[i] = math.max(h[i] - lo[i], math.max((h[i] - p).abs(), (lo[i] - p).abs()));
    }
  }
  return tr;
}

List<double> atr(List<double> h, List<double> lo, List<double> c, [int n = 14]) => _wilder(trueRange(h, lo, c), n);

/// Rate of change in % over n bars (momentum).
List<double> roc(List<double> c, [int n = 10]) {
  final out = _nans(c.length);
  for (var i = n; i < c.length; i++) {
    out[i] = (c[i] / c[i - n] - 1) * 100;
  }
  return out;
}

/// Slope of a least-squares line over the last n values (per bar).
List<double> linregSlope(List<double> x, int n) {
  final out = _nans(x.length);
  final t = [for (var j = 0; j < n; j++) j - (n - 1) / 2];
  final denom = t.fold<double>(0, (a, v) => a + v * v);
  for (var i = n - 1; i < x.length; i++) {
    final m = _mean(x, i - n + 1, i + 1);
    var s = 0.0;
    for (var j = 0; j < n; j++) {
      s += t[j] * (x[i - n + 1 + j] - m);
    }
    out[i] = s / denom;
  }
  return out;
}
