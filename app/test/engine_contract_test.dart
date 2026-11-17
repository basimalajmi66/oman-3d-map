// Contract test: the Dart client against the REAL Python engine.
// Runs when UATA_BACKEND_DIR points at the backend folder (and python3 + deps
// are installed); otherwise skipped. See docs/TEST_PLAN.md.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uata_app/core/companion.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/core/engine_locator.dart';
import 'package:uata_app/core/http_engine_api.dart';

void main() {
  final backend = Platform.environment['UATA_BACKEND_DIR'];
  final skip = backend == null ? 'set UATA_BACKEND_DIR to run against the real engine' : false;

  late Process proc;
  late Directory dataDir;
  late HttpEngineApi api;

  setUpAll(() async {
    if (backend == null) return;
    dataDir = await Directory.systemTemp.createTemp('uata_contract');
    const port = '8791';
    proc = await Process.start('python3', ['-m', 'uata', '--port', port, '--data-dir', dataDir.path],
        workingDirectory: backend);
    final locator = EngineLocator(environment: {'UATA_DATA_DIR': dataDir.path});
    api = HttpEngineApi(baseUrl: Uri.parse('http://127.0.0.1:$port'), tokenProvider: locator.readToken);
    for (var i = 0; i < 60 && !await api.health(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  });

  tearDownAll(() async {
    if (backend == null) return;
    proc.kill();
    await proc.exitCode;
    await dataDir.delete(recursive: true);
  });

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

  test('knowledge: note, upload, approve, search, delete', () async {
    final note = await api.addNote(title: 'Engulfing', content: 'Bullish engulfing at support', itemType: 'rule');
    final itemId = ((note['items'] as List).first as Map)['id'] as int;
    expect(await api.search('engulfing', approvedOnly: true), isEmpty);
    await api.decideItem(itemId, 'approve');
    expect(await api.search('engulfing', approvedOnly: true), hasLength(1));

    final bytes = 'RSI divergence rules\n\nWait for candle close.'.codeUnits;
    final up = await api.uploadFile(UploadFile(name: 'rsi.txt', length: bytes.length, openRead: () => Stream.value(bytes)),
        category: 'momentum', tags: ['rsi']);
    expect(up['extraction_status'], 'done');
    await expectLater(
        api.uploadFile(UploadFile(name: 'again.txt', length: bytes.length, openRead: () => Stream.value(bytes))),
        throwsA(predicate((e) => e is EngineException && e.statusCode == 409)));
    await api.deleteSource(up['id'] as int);
    expect((await api.listSources()).map((s) => s['id']), isNot(contains(up['id'])));
  }, skip: skip);

  test('results, backup and wipe', () async {
    await api.addResult({
      'account_type': 'demo', 'asset': 'EURUSD', 'timeframe_sec': 30, 'signal_type': 'BUY',
      'signal_time': DateTime.now().toUtc().toIso8601String(), 'duration_sec': 120, 'outcome': 'win',
    });
    final sum = await api.summary();
    expect(((sum['results_by_account'] as Map)['demo'] as Map)['wins'], 1);
    final b = await api.createBackup('a long enough passphrase');
    expect((await api.listBackups()).single['name'], b['name']);
    final file = File(p.join(dataDir.path, 'backups', b['name'] as String));
    await api.wipe();
    expect(await api.listSources(), isEmpty);
    final restored = await api.restoreBackup(
        UploadFile(name: file.uri.pathSegments.last, length: await file.length(), openRead: file.openRead),
        'a long enough passphrase');
    expect(restored['restored'], true);
    expect(await api.listSources(), isNotEmpty);
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
    final chart = File(p.join(dataDir.path, 'chart_fixture.png'));
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

  test('phase 5: note with a rule → learning report → approve → bilingual search', () async {
    final note = await api.addNote(title: 'قاعدة الارتداد', content: 'إذا كان مؤشر القوة النسبية في التشبع البيعي عند الدعم فادخل شراء.');
    final report = note['report'] as Map;
    expect(report['status'], 'pending_review');
    expect(((report['extracted'] as Map)['rules'] as List), hasLength(1));
    final pending = await api.listReports(status: 'pending_review');
    expect(pending.map((r) => r['id']), contains(report['id']));
    expect(await api.search('RSI oversold', approvedOnly: true), isEmpty); // not approved yet
    final decided = await api.decideReport(report['id'] as int, 'approve');
    expect(decided['status'], 'approved');
    final hits = await api.search('RSI oversold', approvedOnly: true); // English query, Arabic note
    expect(hits.first['source_title'], 'قاعدة الارتداد');
  }, skip: skip);

  test('phase 6: real video + subtitles → background analysis → timestamped rules, draft strategy', () async {
    final video = File(p.join(dataDir.path, 'lesson.mp4'));
    final srt = File(p.join(dataDir.path, 'lesson.srt'));
    final gen = await Process.run('python3', [
      '-c',
      'import sys; from pathlib import Path; from uata.video.synthetic import write_video, SRT; '
          'write_video(Path(sys.argv[1])); Path(sys.argv[2]).write_text(SRT, encoding="utf-8")',
      video.path, srt.path,
    ], workingDirectory: backend);
    expect(gen.exitCode, 0, reason: '${gen.stderr}');
    final src = await api.uploadFile(UploadFile(name: 'lesson.mp4', length: await video.length(), openRead: video.openRead));
    expect(src['kind'], 'video');
    final id = src['id'] as int;
    await api.uploadSubtitles(id, UploadFile(name: 'lesson.srt', length: await srt.length(), openRead: srt.openRead));
    Map<String, dynamic> page = await api.videoPage(id);
    for (var i = 0; i < 120 && page['status'] != 'done' && page['status'] != 'failed'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      page = await api.videoPage(id);
    }
    expect(page['status'], 'done', reason: '${page['error']}');
    expect(page['transcript_source'], 'subtitles');
    final times = (page['rules'] as List).map((r) => (r as Map)['location']).toSet();
    expect(times, containsAll(['00:04', '00:16']));
    expect((page['strategy'] as Map)['status'], 'draft');
    expect((await api.listVideos()).map((v) => v['source_id']), contains(id));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

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
    final chart = File(p.join(dataDir.path, 'up_chart.png'));
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

  test('token is required', () async {
    final bad = HttpEngineApi(baseUrl: api.baseUrl, tokenProvider: () async => 'wrong');
    await expectLater(bad.getSettings(), throwsA(predicate((e) => e is EngineException && e.statusCode == 401)));
  }, skip: skip);

  test('companion: TLS pinning, one-time pairing, allow-list (phone ↔ real engine)', () async {
    expect((await api.companionStatus())['running'], false); // off by default
    await api.patchSettings({'companion_enabled': true, 'companion_port': 8792});
    final st = await api.companionStatus();
    expect(st['running'], true, reason: '${st['error']}');
    final pairing = await api.companionPairing();
    final link = PairingLink.tryParse(pairing['uri'] as String)!;
    final local = PairingLink(host: '127.0.0.1', port: link.port, fingerprint: link.fingerprint, code: link.code);

    // a different fingerprint (someone else's certificate) is refused before anything is sent
    final wrong = PairingLink(host: '127.0.0.1', port: link.port, fingerprint: 'ab' * 32, code: link.code);
    await expectLater(pairWithComputer(wrong, 'evil'), throwsA(isA<EngineException>()));

    final paired = await pairWithComputer(local, 'Contract phone');
    await expectLater(pairWithComputer(local, 'again'), // the code is one-time
        throwsA(predicate((e) => e is EngineException && e.statusCode == 401)));

    final phone = await RemoteEngineHost(paired).connect();
    expect(await phone.health(), true);
    expect((await phone.status())['state'], isNotNull);
    expect((await phone.getSettings())['trading_mode'], 'manual');
    // dangerous operations are refused from the phone
    await expectLater(phone.patchSettings({'language': 'ar'}),
        throwsA(predicate((e) => e is EngineException && e.statusCode == 403)));
    await expectLater(phone.listBackups(), throwsA(predicate((e) => e is EngineException && e.statusCode == 403)));
    await expectLater(phone.companionStatus(), throwsA(predicate((e) => e is EngineException && e.statusCode == 403)));

    final devices = ((await api.companionStatus())['devices'] as List).cast<Map>();
    expect(devices.single['name'], 'Contract phone');
    await api.revokeCompanionDevice(devices.single['id'] as int);
    await expectLater(phone.status(), throwsA(predicate((e) => e is EngineException && e.statusCode == 401)));
    await api.patchSettings({'companion_enabled': false});
    expect((await api.companionStatus())['running'], false);
  }, skip: skip);
}

/// Minimal valid RGB PNG (solid colour) built with dart:io zlib — no extra packages.
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
