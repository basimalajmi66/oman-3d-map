// Engine scenarios shared by the contract tests of BOTH engines: the Python engine over HTTP
// (engine_contract_test.dart) and the on-device Dart engine (engine/local_engine_test.dart).
// The same expectations must hold for both. Chart fixtures are rendered by the Python generator.
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uata_app/core/engine_api.dart';

void engineScenarios(EngineApi Function() apiOf,
    {required String? backend, required Directory Function() dataDir, required Object skip}) {
  late EngineApi api;
  setUp(() => api = apiOf());
  test('settings defaults and update round-trip', () async {
    final s = await api.getSettings();
    expect(s['candle_timeframe_sec'], 30);
    expect(s['trading_mode'], 'manual');
    final u = await api.patchSettings({'language': 'en', 'indicators': {'rsi': false}});
    expect(u['language'], 'en');
    expect((u['indicators'] as Map)['rsi'], false);
    expect(() => api.patchSettings({'trading_mode': 'auto'}), throwsA(isA<EngineException>()));
  }, skip: skip);

  test('analysis control is honest without engine', () async {
    final st = await api.start();
    expect(st['state'], 'analyzing'); // all engine components exist since Phase 8
    expect((st['recommendation'] as Map)['signal'], 'WAIT');
    await expectLater(api.start(inputMode: 'continuous_screen'),
        throwsA(predicate((e) => e is EngineException && e.isPermission)));
    final halted = await api.emergencyStop();
    expect(halted['state'], 'halted');
  }, skip: skip);

  test('chart image: real PNG decoded by the engine, honest WAIT, permission gate', () async {
    await api.start(); // clears the emergency stop from the earlier test
    final bytes = _png(160, 90);
    UploadFile up(String name) => UploadFile(name: name, length: bytes.length, openRead: () => Stream.value(bytes));
    final r = await api.submitChartImage(up('chart.png'), inputMode: 'share');
    expect((r['input'] as Map)['width'], 160);
    expect((r['input'] as Map)['height'], 90);
    expect((r['analysis'] as Map)['signal'], 'WAIT');
    expect((r['analysis'] as Map)['data_basis'], 'image_only');
    expect(await api.listChartInputs(), hasLength(1));
    await expectLater(api.submitChartImage(up('s.png'), inputMode: 'screenshot'),
        throwsA(predicate((e) => e is EngineException && e.isPermission)));
    final junk = 'not an image'.codeUnits;
    await expectLater(
        api.submitChartImage(UploadFile(name: 'x.png', length: junk.length, openRead: () => Stream.value(junk))),
        throwsA(predicate((e) => e is EngineException && e.statusCode == 422)));
  }, skip: skip);

  test('phase 3: real chart image is read by the engine (candles, prices, annotated preview)', () async {
    final chart = File(p.join(dataDir().path, 'chart_fixture.png'));
    final gen = await Process.run('python3', [
      '-c',
      'import cv2,sys; from uata.vision.synthetic import render_chart, random_walk_ohlc; '
          'cv2.imwrite(sys.argv[1], render_chart(random_walk_ohlc(45, seed=3), style="light_tv").image)',
      chart.path,
    ], workingDirectory: backend);
    expect(gen.exitCode, 0, reason: '${gen.stderr}');
    final r = await api.submitChartImage(
        UploadFile(name: 'chart.png', length: await chart.length(), openRead: chart.openRead),
        inputMode: 'upload');
    final reading = (r['analysis'] as Map)['reading'] as Map;
    expect(reading['usable'], true);
    expect(reading['candles'], 45);
    expect(reading['closed_candles'], 44);
    expect((r['analysis'] as Map)['reason_code'], 'no_approved_strategy');
    final technical = (r['analysis'] as Map)['technical'] as Map;
    expect(technical['available'], true);
    expect(technical['candles_used'], 44); // closed candles only
    expect(['trending', 'ranging', 'volatile'], contains(technical['market_condition']));
    final png = await api.chartAnnotated((r['input'] as Map)['id'] as int);
    expect(png.take(4), [0x89, 0x50, 0x4E, 0x47]);
  }, skip: skip);

  test('phase 7: CSV import → strategy → leak-free backtest → gated approval → new version back to draft', () async {
    final buf = StringBuffer('time,open,high,low,close\n');
    var p0 = 1.0;
    for (var i = 0; i < 1500; i++) {
      final o = p0;
      final c = o + 0.0004 + ((i * 7919) % 13 - 6) * 0.00002; // steady up-drift: a real, testable edge
      buf.writeln('${1700000000 + i * 30},$o,${(c > o ? c : o) + 0.0001},${(c < o ? c : o) - 0.0001},$c');
      p0 = c;
    }
    final bytes = buf.toString().codeUnits;
    final ds = await api.importDataset(UploadFile(name: 'up.csv', length: bytes.length, openRead: () => Stream.value(bytes)),
        name: 'Uptrend', asset: 'TEST');
    expect(ds['is_synthetic'], 0);
    expect(ds['timeframe_sec'], 30);
    final s = await api.createStrategy('Contract bull', {
      'long': {'all': [{'id': 'bullish_candle'}]}, 'duration_sec': 60,
    });
    await expectLater(api.approveStrategy(s['id'] as int),
        throwsA(predicate((e) => e is EngineException && e.statusCode == 409 && e.reasons.contains('no_backtest_for_current_version'))));
    final r = await api.backtest(s['id'] as int, ds['id'] as int);
    expect(r['qualifies'], true, reason: '${r['gate_reasons']}');
    expect((r['out_of_sample'] as Map)['trades'], greaterThanOrEqualTo(30));
    final approved = await api.approveStrategy(s['id'] as int);
    expect(approved['status'], 'approved');
    final edited = await api.updateStrategy(s['id'] as int, {
      'definition': {'long': {'all': [{'id': 'bullish_candle'}, {'id': 'trend_up'}]}, 'duration_sec': 60},
    });
    expect(edited['status'], 'draft');
    expect(edited['version'], 2);
  }, skip: skip);

  test('phase 8: approved strategy + uptrend chart → BUY with 14 steps, recorded once', () async {
    // the phase-7 test above approved 'Contract bull' then edited it (now draft v2) → approve a fresh one
    final ds = (await api.listDatasets()).firstWhere((d) => d['name'] == 'Uptrend');
    final s = await api.createStrategy('Contract signal', {'long': {'all': [{'id': 'bullish_candle'}]}, 'duration_sec': 60});
    expect((await api.backtest(s['id'] as int, ds['id'] as int))['qualifies'], true);
    await api.approveStrategy(s['id'] as int);
    final chart = File(p.join(dataDir().path, 'up_chart.png'));
    final gen = await Process.run('python3', [
      '-c',
      'import cv2,sys; from uata.vision.synthetic import render_chart, uptrend_ohlc; '
          'cv2.imwrite(sys.argv[1], render_chart(uptrend_ohlc(), style="dark_tv").image)',
      chart.path,
    ], workingDirectory: backend);
    expect(gen.exitCode, 0, reason: '${gen.stderr}');
    await api.patchSettings({'signal_cooldown_sec': 0});
    final r = await api.submitChartImage(UploadFile(name: 'up.png', length: await chart.length(), openRead: chart.openRead));
    final a = r['analysis'] as Map;
    expect(a['signal'], 'BUY', reason: '${a['reason_code']} ${a['steps']}');
    expect((a['steps'] as List), hasLength(14));
    expect(a['confidence_calibrated'], false);
    expect((a['strategy'] as Map)['name'], 'Contract signal');
    final before = (await api.listSignals()).length;
    final again = await api.submitChartImage(UploadFile(name: 'up.png', length: await chart.length(), openRead: chart.openRead));
    expect((again['analysis'] as Map)['repeated'], true);
    expect((await api.listSignals()).length, before);
  }, skip: skip);

  test('phase 9: result from the BUY signal → per-account dashboard and insights', () async {
    final buy = (await api.listSignals()).firstWhere((s) => s['signal'] == 'BUY');
    final res = await api.resultFromSignal(buy['id'] as int, accountType: 'demo', outcome: 'win', asset: 'EURUSD');
    expect(res['signal_type'], 'BUY');
    expect(res['strategy_id'], buy['strategy_id']);
    final demo = await api.dashboard('demo');
    expect((demo['results'] as Map)['wins'], greaterThanOrEqualTo(1));
    final real = await api.dashboard('real');
    expect((real['results'] as Map)['trades'], 0); // never mixed
    final ins = await api.insights('real');
    expect(ins.single['code'], 'insufficient_sample');
  }, skip: skip);
}

Uint8List _png(int w, int h) {
  int crc(List<int> data) {
    var c = 0xffffffff;
    for (final b in data) {
      c ^= b;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
      }
    }
    return c ^ 0xffffffff;
  }

  List<int> u32(int v) => [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255];
  List<int> chunk(String type, List<int> data) {
    final td = [...type.codeUnits, ...data];
    return [...u32(data.length), ...td, ...u32(crc(td))];
  }

  final raw = <int>[];
  for (var y = 0; y < h; y++) {
    raw.add(0);
    for (var x = 0; x < w; x++) {
      raw.addAll([20, x < w ~/ 2 ? 180 : 40, 60]);
    }
  }
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ...chunk('IHDR', [...u32(w), ...u32(h), 8, 2, 0, 0, 0]),
    ...chunk('IDAT', ZLibCodec().encode(raw)),
    ...chunk('IEND', const []),
  ]);

}
