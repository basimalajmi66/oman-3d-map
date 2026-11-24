import 'dart:math' as math;

import 'dart:io';

import 'package:test/test.dart';
import 'package:uata_app/engine/analysis/analyzer.dart';
import 'package:uata_app/engine/local/local_engine_api.dart';
import 'package:uata_app/engine/signal/chart_read.dart';
import 'package:uata_app/engine/signal/setups.dart';
import 'package:uata_app/engine/strategy/features.dart';
import 'package:uata_app/l10n/strings.dart';

/// Candles as (open, high, low, close); a quiet random warm-up first so ATR and levels exist.
FeatureSet build(List<(double, double, double, double)> tail, {int warm = 60, double start = 100, double drift = 0}) {
  final r = math.Random(7);
  final o = <double>[], h = <double>[], l = <double>[], c = <double>[];
  var p = start;
  for (var q = 0; q < warm; q++) {
    final n = p + drift + (r.nextDouble() - 0.5) * 0.3;
    o.add(p);
    c.add(n);
    h.add(math.max(p, n) + 0.05);
    l.add(math.min(p, n) - 0.05);
    p = n;
  }
  for (final t in tail) {
    o.add(t.$1);
    h.add(t.$2);
    l.add(t.$3);
    c.add(t.$4);
  }
  return FeatureSet(o, h, l, c);
}

/// A falling run of `n` candles from `p` (each 0.4 lower) — the "decline before" a bullish reversal.
List<(double, double, double, double)> fall(double p, int n) =>
    [for (var q = 0; q < n; q++) (p - 0.4 * q, p - 0.4 * q + 0.05, p - 0.4 * (q + 1) - 0.05, p - 0.4 * (q + 1))];
List<(double, double, double, double)> rise(double p, int n) =>
    [for (var q = 0; q < n; q++) (p + 0.4 * q, p + 0.4 * (q + 1) + 0.05, p + 0.4 * q - 0.05, p + 0.4 * (q + 1))];

Set<String> names(FeatureSet fs) => {for (final h in detectSetups(fs)) h.name};

void main() {
  test('candle patterns are found in their context, with their side', () {
    final base = build([]);
    final p = base.c.last;
    // hammer after a decline → BUY; the same shape after a rise is a hanging man → SELL
    final d = fall(p, 10), lastD = d.last.$4;
    expect(names(build([...d, (lastD, lastD + 0.22, lastD - 1.0, lastD + 0.2)])), contains('hammer'));
    final u = rise(p, 10), lastU = u.last.$4;
    final hm = names(build([...u, (lastU, lastU + 0.22, lastU - 1.0, lastU + 0.2)]));
    expect(hm, contains('hanging_man'));
    expect(hm, isNot(contains('hammer')));
    // shooting star after a rise → SELL
    expect(names(build([...u, (lastU, lastU + 1.0, lastU - 0.22, lastU - 0.2)])), contains('shooting_star'));
    // bullish engulfing after a decline
    expect(names(build([...d, (lastD, lastD + 0.05, lastD - 0.35, lastD - 0.3), (lastD - 0.35, lastD + 0.5, lastD - 0.4, lastD + 0.45)])),
        contains('bullish_engulfing'));
    // three black crows
    final crows = [for (var q = 0; q < 3; q++) (p - 0.6 * q, p - 0.6 * q + 0.02, p - 0.6 * (q + 1) - 0.02, p - 0.6 * (q + 1))];
    expect(names(build(crows)), contains('three_black_crows'));
  });

  test('a chart pattern: triple bottom breaks its neckline → BUY', () {
    final p = 100.0;
    final legs = <(double, double, double, double)>[];
    void go(double from, double to, int n) {
      for (var q = 0; q < n; q++) {
        final a = from + (to - from) * q / n, b = from + (to - from) * (q + 1) / n;
        legs.add((a, math.max(a, b) + 0.05, math.min(a, b) - 0.05, b));
      }
    }
    go(p, p - 3, 6); // bottom 1
    go(p - 3, p - 1, 5);
    go(p - 1, p - 3, 5); // bottom 2
    go(p - 3, p - 1, 5);
    go(p - 1, p - 3, 5); // bottom 3
    go(p - 3, p - 1.1, 5);
    legs.add((p - 1.1, p - 0.2, p - 1.15, p - 0.3)); // close above the neckline (≈ p - 1)
    final fs = build(legs, start: p);
    expect(names(fs), contains('triple_bottom'));
    expect(detectSetups(fs).firstWhere((h) => h.name == 'triple_bottom').side, 'BUY');
  });

  test('the direct signal: one chart / price-action setup, or two candle patterns, and twice the other side', () {
    expect(setupSignal(const [SetupHit('triple_bottom', 'BUY', 'reversal')]), 'BUY');
    expect(setupSignal(const [SetupHit('hammer', 'BUY', 'candle')]), isNull); // one candle pattern alone is not enough
    expect(setupSignal(const [SetupHit('hammer', 'BUY', 'candle'), SetupHit('tweezer_bottom', 'BUY', 'candle')]), 'BUY');
    expect(setupSignal(const [SetupHit('triple_top', 'SELL', 'reversal'), SetupHit('hammer', 'BUY', 'candle')]), isNull);
    expect(setupSignal(const []), isNull);
  });

  test('every strategy has a name in Arabic and English, and a side', () {
    for (final e in allSetups.entries) {
      expect(hasString('c_${e.key}'), isTrue, reason: e.key);
      expect(tr('ar', 'c_${e.key}'), isNot(tr('en', 'c_${e.key}')), reason: e.key);
      expect(['BUY', 'SELL'], contains(e.value.$1));
    }
    expect(allSetups.length, greaterThanOrEqualTo(95));
  });

  test('on the phone engine: a pattern on the chart gives a direct BUY, recorded with its pattern; switched off → WAIT', () async {
    final p = 100.0;
    final legs = <(double, double, double, double)>[];
    void go(double from, double to, int n) {
      for (var q = 0; q < n; q++) {
        final a = from + (to - from) * q / n, b = from + (to - from) * (q + 1) / n;
        legs.add((a, math.max(a, b) + 0.05, math.min(a, b) - 0.05, b));
      }
    }
    go(p, p - 3, 6);
    go(p - 3, p - 1, 5);
    go(p - 1, p - 3, 5);
    go(p - 3, p - 1, 5);
    go(p - 1, p - 3, 5);
    go(p - 3, p - 1.1, 5);
    legs.add((p - 1.1, p - 0.2, p - 1.15, p - 0.3));
    final reading = readingOf(build(legs, start: p));
    final dir = Directory.systemTemp.createTempSync('uata_setups');
    final engine = await LocalEngine.open(dir.path, (v) => File('assets/schema/schema_v$v.sql').readAsString());
    engine.settings.update({'signal_cooldown_sec': 0});
    final out = engine.signals.evaluate(reading, analyzeReading(reading), 'test');
    expect(out['signal'], 'BUY', reason: '${out['reason_code']} ${out['read']}');
    expect(out['reason_code'], 'pattern_signal');
    expect(out['reasons'], contains('setup: triple_bottom'));
    expect(out['recorded'], true);
    expect(out['strategy'], isNull); // not a tested strategy
    engine.settings.update({'pattern_signals': false});
    final legs2 = [...legs, (p - 0.3, p - 0.25, p - 0.35, p - 0.3)];
    final off = engine.signals.evaluate(readingOf(build(legs2, start: p)), analyzeReading(readingOf(build(legs2, start: p))), 'test');
    expect(off['signal'], 'WAIT');
    engine.close();
    dir.deleteSync(recursive: true);
  });
}

/// The same candles as a chart reading (what the chart reader hands the engine).
Map<String, dynamic> readingOf(FeatureSet fs) => {
      'usable': true, 'data_quality': 0.9, 'timeframe_sec': null, 'abstain_reasons': [],
      'candles': [
        for (var i = 0; i < fs.n; i++)
          {'status': 'closed', 'rel_open': fs.o[i], 'rel_high': fs.h[i], 'rel_low': fs.l[i], 'rel_close': fs.c[i]},
        {'status': 'possibly_forming', 'rel_open': fs.c.last, 'rel_high': fs.c.last, 'rel_low': fs.c.last, 'rel_close': fs.c.last},
      ],
    };
