@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/engine/local/local_engine_api.dart';
import 'package:uata_app/engine/strategy/discovery.dart';
import 'package:uata_app/engine/strategy/features.dart';

/// Random walk; with `persistence` > 0.5 a candle tends to have the colour of the previous one (a real, plantable edge).
(List<double>, List<double>, List<double>, List<double>) walk(int n, int seed, {double persistence = 0.5}) {
  final r = math.Random(seed);
  final o = <double>[], h = <double>[], l = <double>[], c = <double>[];
  var p = 1.1;
  var up = true;
  for (var i = 0; i < n; i++) {
    up = r.nextDouble() < persistence ? up : !up;
    final size = 0.00005 + r.nextDouble() * 0.0002;
    final op = p, cl = op + (up ? size : -size);
    o.add(op);
    c.add(cl);
    h.add(math.max(op, cl) + r.nextDouble() * 0.00008);
    l.add(math.min(op, cl) - r.nextDouble() * 0.00008);
    p = cl;
  }
  return (o, h, l, c);
}

void main() {
  test('375 mirrored candidates, durations of 2 / 4 / 6 candles', () {
    final cs = candidates(30);
    expect(cs, hasLength(375));
    expect({for (final c in cs) c.definition['duration_sec']}, {60, 120, 180});
    expect(cs.every((c) => ((c.definition['long'] as Map)['all'] as List).isNotEmpty &&
        ((c.definition['short'] as Map)['all'] as List).isNotEmpty), isTrue);
  });

  test('random prices: nothing is called significant (no invented edge)', () {
    for (final seed in [1, 2]) {
      final (o, h, l, c) = walk(15000, seed);
      final rep = discover(FeatureSet(o, h, l, c), 30);
      expect((rep['results'] as List).where((x) => (x as Map)['verdict'] == 'significant'), isEmpty, reason: 'seed $seed');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a real (planted) edge is found and confirmed on the unseen data', () {
    final (o, h, l, c) = walk(15000, 3, persistence: 0.62);
    final rep = discover(FeatureSet(o, h, l, c), 30);
    final sig = (rep['results'] as List).cast<Map>().where((x) => x['verdict'] == 'significant').toList();
    expect(sig, isNotEmpty);
    expect(((sig.first['holdout'] as Map)['expectancy_per_trade'] as num) > 0, isTrue);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('on the phone engine: runs on a stored dataset in the background', () async {
    final dir = Directory.systemTemp.createTempSync('uata_disc');
    final engine = await LocalEngine.open(dir.path, (v) => File('assets/schema/schema_v$v.sql').readAsString());
    final api = LocalEngineApi(engine);
    final (o, h, l, c) = walk(4000, 5);
    final t0 = DateTime.utc(2026, 11, 2).millisecondsSinceEpoch ~/ 1000;
    final csv = StringBuffer('time,open,high,low,close\n');
    for (var i = 0; i < o.length; i++) {
      csv.writeln('${t0 + 30 * i},${o[i]},${h[i]},${l[i]},${c[i]}');
    }
    final bytes = utf8.encode(csv.toString());
    final d = await api.importDataset(UploadFile(name: 'x.csv', length: bytes.length, openRead: () => Stream.value(bytes)), name: 'test');
    final rep = await api.discoverStrategies(d['id'] as int, payout: 0.88);
    expect(rep['candidates_tested'], 375);
    expect((rep['dataset'] as Map)['timeframe_sec'], 30);
    expect(rep['breakeven_win_rate'], closeTo(1 / 1.88, 1e-4));
    engine.close();
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
