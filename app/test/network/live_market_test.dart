// Live downloads of real prices + the full quick start on real data. Network required:
// runs in CI as a separate, non-blocking step (flutter test --tags network).
@Tags(['network'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:uata_app/data/market_data.dart';
import 'package:uata_app/data/quick_start.dart';
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
}
