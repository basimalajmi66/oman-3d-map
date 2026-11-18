@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:uata_app/engine/analysis/analyzer.dart';

import 'parity.dart';

void main() {
  final cases = <String, List<Map<String, double>>>{
    'uptrend': series(1, drift: 0.0004),
    'downtrend': series(2, drift: -0.0004),
    'range': series(3),
    'volatile': series(4, vol: 0.003),
    'short': series(5, n: 45),
    'too_short': series(6, n: 20),
    'big_prices': series(7, start: 42000, vol: 60, drift: 5),
    for (var s = 10; s < 30; s++) 'random_$s': series(s, drift: (s % 5 - 2) * 0.0002),
  };

  test('technical analysis matches the Python engine on ${cases.length} series', () async {
    final py = await python({'op': 'analyze', 'series': cases.values.toList()}) as List;
    var i = 0;
    for (final entry in cases.entries) {
      final dart = TechnicalAnalyzer().analyze([for (final c in entry.value) Candle.fromJson(c)]);
      expectSame(dart, py[i++], path: entry.key);
    }
  }, skip: paritySkip);

  test('disabled factors match too', () async {
    final enabled = {'rsi': false, 'macd': false, 'trend': false};
    final s = series(42, drift: 0.0003);
    final py = await python({'op': 'analyze', 'series': [s], 'enabled': enabled}) as List;
    expectSame(TechnicalAnalyzer().analyze([for (final c in s) Candle.fromJson(c)], enabled: enabled), py.first);
  }, skip: paritySkip);

  test('indicators are causal: appending candles never changes earlier results', () {
    final s = [for (final c in series(9, n: 120)) Candle.fromJson(c)];
    final a = TechnicalAnalyzer().analyze(s.sublist(0, 80));
    final b = TechnicalAnalyzer().analyze(s.sublist(0, 80));
    expect(a['indicators'], b['indicators']);
    expect(TechnicalAnalyzer().analyze(s.sublist(0, 20))['reason'], 'insufficient_candles');
  });
}
