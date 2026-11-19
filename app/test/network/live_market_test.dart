// Live downloads of real prices + the full quick start on real data. Network required:
// runs in CI as a separate, non-blocking step (flutter test --tags network).
@Tags(['network'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:uata_app/data/market_data.dart';
import 'package:uata_app/data/paper_trading.dart';
import 'package:uata_app/data/quick_start.dart';
import 'package:uata_app/data/starter_strategies.dart';
import 'package:uata_app/engine/local/local_engine_api.dart';

Future<String> schema(int v) => File('assets/schema/schema_v$v.sql').readAsString();

void main() {
  late Directory dir;
  late LocalEngine engine;
  late LocalEngineApi api;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('uata_live');
    engine = await LocalEngine.open(dir.path, schema);
    api = LocalEngineApi(engine);
  });
  tearDown(() {
    engine.close();
    dir.deleteSync(recursive: true);
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
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('live: a paper session started 2 days ago catches up on real EURUSD prices in two steps', () async {
    final ids = <int>[];
    for (final st in starterStrategies.take(6)) {
      ids.add((await api.createStrategy(st.name, st.definition))['id'] as int);
    }
    // a weekday window well in the past, so every hour file exists
    var now = DateTime.now().toUtc().subtract(const Duration(days: 3));
    while (now.weekday == DateTime.saturday || now.weekday == DateTime.sunday || now.weekday == DateTime.monday) {
      now = now.subtract(const Duration(days: 1));
    }
    final startAt = now.subtract(const Duration(hours: 12));
    var clock = startAt;
    final p = PaperTrader('${dir.path}/paper', now: () => clock);
    final s = await p.start(api, marketAssets.first, 30, 0.85, ids);
    expect(s.lastError, isNull);
    clock = startAt.add(const Duration(hours: 6));
    await p.update(api, p.sessions().single);
    clock = now;
    final done = await p.update(api, p.sessions().single);
    expect(done.lastError, isNull);
    // ignore: avoid_print
    print('paper EURUSD 12h: ${done.trades.length} trades');
    for (final r in done.summary()) {
      // ignore: avoid_print
      print('  ${r['name']}: ${r['trades']} trades, win ${r['win_rate']}, net ${r['net']}');
    }
    expect(done.trades, isNotEmpty);
    final dash = await api.dashboard('simulation');
    expect((dash['results'] as Map)['trades'], done.trades.length);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
