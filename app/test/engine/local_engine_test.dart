@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/engine/local/local_engine_api.dart';

import '../engine_scenarios.dart';
import 'parity.dart';

Future<String> schemaFromAssets(int v) => File('assets/schema/schema_v$v.sql').readAsString();

void main() {
  late Directory dir;
  late LocalEngine engine;
  late LocalEngineApi api;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('uata_local');
    engine = await LocalEngine.open(dir.path, schemaFromAssets);
    api = LocalEngineApi(engine);
  });
  tearDownAll(() {
    engine.close();
    dir.deleteSync(recursive: true);
  });

  test('the phone uses the very same database schema as the computer engine', () {
    if (backendDir == null) return;
    for (final f in Directory('$backendDir/uata/db').listSync().whereType<File>().where((f) => f.path.endsWith('.sql'))) {
      final name = f.uri.pathSegments.last;
      expect(File('assets/schema/$name').readAsStringSync(), f.readAsStringSync(), reason: '$name differs — copy it to assets/schema');
    }
  });

  // the same scenarios as the Python engine's contract test
  engineScenarios(() => api, backend: backendDir, dataDir: () => dir, skip: paritySkip);

  test('features not on the phone yet say so (501) instead of pretending', () async {
    final caps = await api.capabilities();
    expect(caps['engine'], 'phone');
    for (final k in ['knowledge', 'videos', 'backups', 'companion', 'screen_capture', 'ocr']) {
      expect(caps[k], false, reason: k);
    }
    for (final call in <Future<Object?> Function()>[
      () => api.listSources(),
      () => api.listVideos(),
      () => api.createBackup('a long enough passphrase'),
      () => api.captureScreen(),
      () => api.companionPairing(),
    ]) {
      await expectLater(call(), throwsA(predicate((e) => e is EngineException && e.statusCode == 501)));
    }
    expect(await api.listBackups(), isEmpty);
  });

  test('validation errors use the same codes as the computer engine', () async {
    await expectLater(api.patchSettings({'trading_mode': 'auto'}), throwsA(predicate((e) => e is EngineException && e.statusCode == 422)));
    await expectLater(api.patchSettings({'indicators': {for (final k in ['price_action', 'candlesticks', 'support_resistance', 'trend', 'supply_demand', 'liquidity_zones', 'moving_averages', 'rsi', 'macd', 'bollinger_bands', 'atr', 'volume', 'momentum', 'volatility', 'chart_patterns']) k: k == 'rsi'}}),
        throwsA(predicate((e) => e is EngineException && e.statusCode == 422)));
    await expectLater(api.createStrategy('bad', {'long': {'all': [{'id': 'nope'}]}}),
        throwsA(predicate((e) => e is EngineException && e.statusCode == 400)));
    await expectLater(api.getStrategy(9999), throwsA(predicate((e) => e is EngineException && e.statusCode == 404)));
    final junk = 'time,open\n1,2'.codeUnits;
    await expectLater(api.importDataset(UploadFile(name: 'x.csv', length: junk.length, openRead: () => Stream.value(junk))),
        throwsA(predicate((e) => e is EngineException && e.statusCode == 400)));
  });

  test('synthetic data can never qualify a strategy (and is labelled)', () async {
    final ds = await api.syntheticDataset(rows: 2000);
    expect(ds['is_synthetic'], 1);
    final s = await api.createStrategy('Synthetic only', {'long': {'all': [{'id': 'bullish_candle'}]}, 'duration_sec': 60});
    final r = await api.backtest(s['id'] as int, ds['id'] as int);
    expect(r['qualifies'], false);
    expect(r['gate_reasons'], contains('tested_on_synthetic_data_only'));
    await expectLater(api.approveStrategy(s['id'] as int), throwsA(predicate((e) => e is EngineException && e.statusCode == 409)));
  });

  test('delete all my data empties the phone engine', () async {
    await api.wipe();
    expect(await api.listStrategies(), isEmpty);
    expect(await api.listSignals(), isEmpty);
    expect(await api.listDatasets(), isEmpty);
    expect((await api.getSettings())['language'], 'ar');
    expect((await api.status())['state'], 'halted');
  });

  test('a corrupt database is kept aside and a fresh one is started', () async {
    final d = Directory.systemTemp.createTempSync('uata_corrupt');
    File('${d.path}/uata.sqlite3').writeAsBytesSync(List.filled(4096, 7));
    final e = await LocalEngine.open(d.path, schemaFromAssets);
    final n = await LocalEngineApi(e).notices();
    expect(n.single['code'], 'database_was_corrupt');
    expect(File('${d.path}/${n.single['kept_as']}').readAsBytesSync().take(3), [7, 7, 7]);
    expect((await LocalEngineApi(e).getSettings())['trading_mode'], 'manual');
    e.close();
    d.deleteSync(recursive: true);
  });
}
