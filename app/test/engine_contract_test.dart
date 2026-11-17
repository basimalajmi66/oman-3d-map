// Contract test: the Dart client against the REAL Python engine.
// Runs when UATA_BACKEND_DIR points at the backend folder (and python3 + deps
// are installed); otherwise skipped. See docs/TEST_PLAN.md.
@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
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
    expect(st['state'], 'running_no_engine');
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

  test('token is required', () async {
    final bad = HttpEngineApi(baseUrl: api.baseUrl, tokenProvider: () async => 'wrong');
    await expectLater(bad.getSettings(), throwsA(predicate((e) => e is EngineException && e.statusCode == 401)));
  }, skip: skip);
}
