@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:uata_app/data/market_data.dart';
import 'package:uata_app/data/quick_start.dart';
import 'package:uata_app/data/starter_strategies.dart';
import 'package:uata_app/engine/local/local_engine_api.dart';

Future<String> schema(int v) => File('assets/schema/schema_v$v.sql').readAsString();

/// Stands in for the internet in unit tests (the live download is tested separately in CI).
class FakeData extends MarketDataClient {
  @override
  Future<String> download(MarketAsset asset, int timeframeSec, {int days = 14, DateTime? until, Progress? onProgress}) async {
    final r = math.Random(7);
    final b = StringBuffer('time,open,high,low,close\n');
    var p = 1.08;
    for (var i = 0; i < 6000; i++) {
      final o = p, c = o + (r.nextDouble() - 0.48) * 0.0004;
      b.writeln('${1700000000 + i * timeframeSec},$o,${math.max(o, c) + 0.0001},${math.min(o, c) - 0.0001},$c');
      p = c;
      if (i % 1000 == 0) onProgress?.call(i / 6000);
    }
    return b.toString();
  }
}

void main() {
  late Directory dir;
  late LocalEngine engine;
  late LocalEngineApi api;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('uata_qs');
    engine = await LocalEngine.open(dir.path, schema);
    api = LocalEngineApi(engine);
  });
  tearDown(() {
    engine.close();
    dir.deleteSync(recursive: true);
  });

  test('quick start: real-data import, 8 drafts, every one tested, nothing approved automatically', () async {
    final stages = <QuickStartStage>{};
    final r = await runQuickStart(api, FakeData(), marketAssets.first, 30, onStage: (s, _) => stages.add(s));
    expect(stages, containsAll(QuickStartStage.values));
    expect(r.dataset['is_synthetic'], 0);
    expect(r.outcomes, hasLength(starterStrategies.length));
    final strategies = await api.listStrategies();
    expect(strategies, hasLength(starterStrategies.length));
    expect(strategies.where((s) => s['status'] == 'approved'), isEmpty); // the user decides
    for (final o in r.outcomes) {
      expect(o.result['gate_reasons'], isA<List>());
      expect((o.oos['trades'] as int) >= 0, isTrue);
      expect(o.qualifies, (o.result['gate_reasons'] as List).isEmpty);
    }
    expect(strategies.first['description'], contains('not proven'));

    // running it again reuses the strategies (no duplicates) and tests them on the new data
    final again = await runQuickStart(api, FakeData(), marketAssets.first, 30);
    expect(await api.listStrategies(), hasLength(starterStrategies.length));
    expect(again.outcomes.map((o) => o.strategyId).toSet(), r.outcomes.map((o) => o.strategyId).toSet());
    expect(await api.listDatasets(), hasLength(2));
  });

  test('approval of a qualifying starter strategy is still the user\'s explicit action', () async {
    final r = await runQuickStart(api, FakeData(), marketAssets.first, 30);
    for (final o in r.outcomes) {
      if (o.qualifies) {
        expect((await api.approveStrategy(o.strategyId))['status'], 'approved');
      } else {
        await expectLater(api.approveStrategy(o.strategyId), throwsA(anything));
      }
    }
  });

  test('live: real prices from Dukascopy and Binance, then the full quick start on real data',
      () async {
    final client = MarketDataClient();
    final until = DateTime.now().toUtc().subtract(const Duration(days: 2));
    final fx = await client.download(marketAssets.first, 30, days: 3, until: until);
    final fxRows = fx.split('\n').where((l) => l.isNotEmpty).length - 1;
    expect(fxRows, greaterThan(1000), reason: 'EURUSD 30s candles');
    final btc = await client.download(marketAssets.firstWhere((a) => a.symbol == 'BTCUSDT'), 60, days: 1, until: until);
    expect(btc.split('\n').where((l) => l.isNotEmpty).length - 1, greaterThan(1000));

    for (final asset in [marketAssets.first, marketAssets.firstWhere((a) => a.symbol == 'XAUUSD')]) {
      final r = await runQuickStart(api, client, asset, 30, days: 14);
      // ignore: avoid_print
      print('${r.dataset['name']}: ${r.dataset['rows']} candles');
      for (final o in r.outcomes) {
        final oos = o.oos;
        // ignore: avoid_print
        print('  ${o.qualifies ? 'PASS' : 'fail'}  ${o.name} | trades ${oos['trades']} | win ${oos['win_rate']} '
            '${oos['win_rate_ci95']} | breakeven ${oos['breakeven_win_rate']} | exp ${oos['expectancy_per_trade']} '
            '| ${o.result['gate_reasons']}');
      }
    }
    client.close();
  }, skip: Platform.environment['UATA_NETWORK_TESTS'] == '1' ? false : 'set UATA_NETWORK_TESTS=1 (CI) for live downloads',
      timeout: const Timeout(Duration(minutes: 15)));
}
