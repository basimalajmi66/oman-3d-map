@TestOn('vm')
library;

import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:uata_app/data/starter_strategies.dart';
import 'package:uata_app/engine/strategy/backtest.dart';
import 'package:uata_app/engine/strategy/conditions.dart' as cnd;
import 'package:uata_app/engine/strategy/features.dart';

void main() {
  test('every community strategy actually trades on realistic prices (its conditions can all be met)', () {
    final r = math.Random(11);
    final o = <double>[], h = <double>[], l = <double>[], c = <double>[];
    var p = 2400.0, drift = 0.0;
    for (var i = 0; i < 20000; i++) {
      if (i % 400 == 0) drift = (r.nextDouble() - 0.5) * 0.15; // alternating trends and ranges
      final op = p, cl = op + drift + (r.nextDouble() - 0.5) * 1.2;
      o.add(op);
      c.add(cl);
      h.add(math.max(op, cl) + r.nextDouble() * 0.4);
      l.add(math.min(op, cl) - r.nextDouble() * 0.4);
      p = cl;
    }
    final fs = FeatureSet(o, h, l, c);
    for (final s in starterStrategies.where((s) => s.name.startsWith('مجتمع'))) {
      final res = runBacktest(fs, cnd.validateDefinition(s.definition), 30);
      final n = (res['in_sample'] as Map)['trades'] as int;
      expect(n, greaterThan(5), reason: '${s.name} never triggers');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
