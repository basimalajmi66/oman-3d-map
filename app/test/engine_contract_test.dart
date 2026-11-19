// Contract test: the Dart client against the REAL Python engine.
// Runs when UATA_BACKEND_DIR points at the backend folder (and python3 + deps
// are installed); otherwise skipped. See docs/TEST_PLAN.md.
@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:uata_app/core/companion.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/core/engine_locator.dart';
import 'package:uata_app/core/http_engine_api.dart';

import 'engine_scenarios.dart';

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



  libraryScenarios(() => api, skip: skip);

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




  engineScenarios(() => api, backend: backend, dataDir: () => dataDir, skip: skip);

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

    // the first address does not answer (TEST-NET): the phone moves on to the next one
    final multi = PairingLink(
        host: '192.0.2.1', hosts: ['192.0.2.1', '127.0.0.1'], port: link.port, fingerprint: link.fingerprint,
        code: link.code);
    final paired = await pairWithComputer(multi, 'Contract phone');
    expect(paired.host, '127.0.0.1');
    expect(paired.hosts, ['127.0.0.1', '192.0.2.1']);
    final stale = CompanionPairing(
        host: '192.0.2.1', hosts: ['192.0.2.1', '127.0.0.1'], port: link.port, fingerprint: link.fingerprint,
        token: paired.token);
    expect(await reachableHost(stale), '127.0.0.1');
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
