@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/engine/local/local_engine_api.dart';

import 'parity.dart';

Future<String> schema(int v) => File('assets/schema/schema_v$v.sql').readAsString();
const pass = 'a long enough passphrase';

UploadFile upload(File f) => UploadFile(name: f.uri.pathSegments.last, length: f.lengthSync(), openRead: f.openRead);

void main() {
  late Directory dir;
  late LocalEngine engine;
  late LocalEngineApi api;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('uata_backup');
    engine = await LocalEngine.open(dir.path, schema);
    api = LocalEngineApi(engine);
  });
  tearDown(() {
    engine.close();
    dir.deleteSync(recursive: true);
  });

  Future<File> backupWithData() async {
    await api.createStrategy('Phone strategy', {'long': {'all': [{'id': 'bullish_candle'}]}, 'duration_sec': 60});
    await api.syntheticDataset(rows: 500);
    await api.patchSettings({'language': 'en'});
    // paper-trading sessions live inside the engine's files (platform/paper_location.dart)
    File('${engine.filesDir}/paper/sessions.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('[{"id":"s1"}]');
    final b = await api.createBackup(pass);
    expect(b['name'], matches(RegExp(r'^uata-backup-\d{8}T\d{6}\.uatabak$')));
    expect((await api.listBackups()).single['name'], b['name']);
    return File('${engine.backupsDir}/${b['name']}');
  }

  test('backup → wipe → restore brings everything back (database and files)', () async {
    final f = await backupWithData();
    expect(f.readAsBytesSync().take(8), 'UATABAK1'.codeUnits);
    expect(String.fromCharCodes(f.readAsBytesSync()).contains('Phone strategy'), isFalse); // encrypted
    await api.wipe();
    expect(await api.listStrategies(), isEmpty);
    expect(File('${engine.filesDir}/paper/sessions.json').existsSync(), isFalse); // "delete all data" includes them
    expect(await api.listBackups(), hasLength(1)); // backups survive a normal wipe
    final r = await api.restoreBackup(upload(f), pass);
    expect(r['restored'], true);
    expect((r['manifest'] as Map)['created_on'], 'phone');
    expect((await api.listStrategies()).single['name'], 'Phone strategy');
    final ds = (await api.listDatasets()).single;
    expect(File('${engine.filesDir}/${ds['stored_path']}').existsSync(), isTrue);
    expect((await api.getSettings())['language'], 'en');
    expect(File('${engine.filesDir}/paper/sessions.json').readAsStringSync(), '[{"id":"s1"}]'); // paper sessions too
    // the restored dataset is usable again (no stale cache)
    final s = (await api.listStrategies()).single;
    expect((await api.backtest(s['id'] as int, ds['id'] as int))['synthetic'], true);
  });

  test('wrong passphrase, tampering and truncation are all refused — nothing is replaced', () async {
    final f = await backupWithData();
    Future<void> refused(File bad, String p, String why) async {
      await expectLater(api.restoreBackup(upload(bad), p),
          throwsA(predicate((e) => e is EngineException && e.statusCode == 400 && e.message.contains(why))), reason: why);
      expect((await api.listStrategies()).single['name'], 'Phone strategy'); // data untouched
    }

    await refused(f, 'not the passphrase!', 'wrong passphrase');
    final bytes = f.readAsBytesSync();
    final tampered = File('${dir.path}/t.uatabak')..writeAsBytesSync([...bytes]..[bytes.length - 40] ^= 1);
    await refused(tampered, pass, 'wrong passphrase or corrupted');
    final truncated = File('${dir.path}/c.uatabak')..writeAsBytesSync(bytes.sublist(0, bytes.length - 100));
    await refused(truncated, pass, 'truncated');
    final junk = File('${dir.path}/j.uatabak')..writeAsStringSync('hello');
    await refused(junk, pass, 'not a UATA backup');
  });

  test('short passphrase refused; backup files cannot be read outside the backups folder', () async {
    await expectLater(api.createBackup('short'), throwsA(predicate((e) => e is EngineException && e.statusCode == 400)));
    await expectLater(api.backupBytes('../uata.sqlite3'), throwsA(predicate((e) => e is EngineException && e.statusCode == 404)));
    final f = await backupWithData();
    expect(await api.backupBytes(f.uri.pathSegments.last), f.readAsBytesSync());
    await api.wipe(includeBackups: true);
    expect(await api.listBackups(), isEmpty);
  });

  test('a backup made on the PHONE opens with the COMPUTER engine\'s code', () async {
    final f = await backupWithData();
    final py = await python({'op': 'backup_read', 'path': f.path, 'passphrase': pass}) as Map;
    expect(py['integrity'], 'ok');
    expect(py['strategies'], ['Phone strategy']);
    expect((py['manifest'] as Map)['format'], 1);
    expect((py['names'] as List).where((n) => (n as String).startsWith('files/datasets/')), isNotEmpty);
  }, skip: paritySkip);

  test('a backup made on the COMPUTER restores on the phone', () async {
    final pcDir = Directory('${dir.path}/pc');
    final made = await python({'op': 'backup_make', 'dir': pcDir.path, 'passphrase': pass}) as Map;
    final r = await api.restoreBackup(upload(File(made['path'] as String)), pass);
    expect(r['restored'], true);
    expect((await api.listStrategies()).single['name'], 'From the computer');
    expect((await api.getSettings())['language'], 'en');
    expect(File('${engine.filesDir}/datasets/note.txt').readAsStringSync(), 'hello from the computer');
  }, skip: paritySkip);
}
