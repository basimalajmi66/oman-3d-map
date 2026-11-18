/// Japanese candlestick patterns on *closed* candles (port of analysis/patterns.py).
library;

import 'dart:math' as math;

class Pattern {
  Pattern(this.name, this.index, this.direction, this.strength);
  final String name;
  final int index; // index of the last candle of the pattern
  final String direction; // bullish | bearish | neutral
  final double strength; // 0..1
}

/// Patterns completed at candle `i`. `trend` is the context before the pattern.
List<Pattern> detectAt(List<double> o, List<double> h, List<double> low, List<double> c, int i, double atrI,
    String trend) {
  final out = <Pattern>[];
  final rng = math.max(h[i] - low[i], 1e-12);
  final body = (c[i] - o[i]).abs();
  final up = h[i] - math.max(o[i], c[i]);
  final lo = math.min(o[i], c[i]) - low[i];
  final big = atrI > 0 && rng >= 0.5 * atrI; // ignore patterns on insignificant candles

  if (body <= 0.1 * rng && big) out.add(Pattern('doji', i, 'neutral', 0.3));
  if (big && lo >= 2 * body && up <= 0.25 * rng && body > 0.02 * rng) {
    // hammer after a decline is bullish; the same shape after a rise is a hanging man
    if (trend == 'down') {
      out.add(Pattern('hammer', i, 'bullish', 0.6));
    } else if (trend == 'up') {
      out.add(Pattern('hanging_man', i, 'bearish', 0.45));
    }
  }
  if (big && up >= 2 * body && lo <= 0.25 * rng && body > 0.02 * rng) {
    if (trend == 'up') {
      out.add(Pattern('shooting_star', i, 'bearish', 0.6));
    } else if (trend == 'down') {
      out.add(Pattern('inverted_hammer', i, 'bullish', 0.45));
    }
  }
  if (big && body >= 0.9 * rng) out.add(Pattern('marubozu', i, c[i] > o[i] ? 'bullish' : 'bearish', 0.5));

  if (i >= 1) {
    final po = o[i - 1], pc = c[i - 1];
    final pBody = (pc - po).abs();
    if (pc < po && c[i] > o[i] && o[i] <= pc && c[i] >= po && body > pBody && big) {
      out.add(Pattern('bullish_engulfing', i, 'bullish', trend == 'down' ? 0.75 : 0.55));
    }
    if (pc > po && c[i] < o[i] && o[i] >= pc && c[i] <= po && body > pBody && big) {
      out.add(Pattern('bearish_engulfing', i, 'bearish', trend == 'up' ? 0.75 : 0.55));
    }
    if (h[i] <= h[i - 1] && low[i] >= low[i - 1]) out.add(Pattern('inside_bar', i, 'neutral', 0.25));
  }

  if (i >= 2) {
    final o1 = o[i - 2], c1 = c[i - 2], o2 = o[i - 1], c2 = c[i - 1];
    final r1 = math.max(h[i - 2] - low[i - 2], 1e-12);
    final smallMid = (c2 - o2).abs() <= 0.3 * math.max(h[i - 1] - low[i - 1], 1e-12);
    if (c1 < o1 && (c1 - o1).abs() >= 0.6 * r1 && smallMid && c[i] > o[i] && c[i] >= (o1 + c1) / 2 &&
        trend == 'down') {
      out.add(Pattern('morning_star', i, 'bullish', 0.8));
    }
    if (c1 > o1 && (c1 - o1).abs() >= 0.6 * r1 && smallMid && c[i] < o[i] && c[i] <= (o1 + c1) / 2 &&
        trend == 'up') {
      out.add(Pattern('evening_star', i, 'bearish', 0.8));
    }
  }
  return out;
}

/// Patterns completed on the last `lookback` closed candles.
List<Pattern> recentPatterns(List<double> o, List<double> h, List<double> low, List<double> c, List<double> atrArr,
    String Function(int) trendAt,
    {int lookback = 3}) {
  final n = c.length;
  final out = <Pattern>[];
  for (var i = math.max(0, n - lookback); i < n; i++) {
    final a = atrArr[i].isNaN ? h[i] - low[i] : atrArr[i];
    out.addAll(detectAt(o, h, low, c, i, a, trendAt(i)));
  }
  return out;
}
