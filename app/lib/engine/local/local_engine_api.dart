/// The engine running entirely on the phone / tablet — same [EngineApi] as the computer engine, so every
/// screen works unchanged. Nothing leaves the device. Features not available on the phone yet (knowledge
/// library, educational videos, encrypted backups, companion pairing) are reported in [capabilities] so the
/// UI hides them; calling them anyway returns 501 — never a fake result.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/engine_api.dart';
import 'chart_inputs.dart';
import 'db.dart';
import 'services.dart';
import 'settings.dart';

class LocalEngine {
  LocalEngine._(this.root, this.db, this.schema) {
    settings = SettingsStore(db);
    control = ControlService(db);
    records = RecordsService(db);
    strategies = StrategyService(db, filesDir);
    signals = SignalService(records, strategies, settings);
    stats = StatsService(db);
    charts = ChartInputService(db, filesDir, signals);
  }

  final String root;
  final LocalDb db;
  final SchemaLoader schema;
  late final SettingsStore settings;
  late final ControlService control;
  late final RecordsService records;
  late final StrategyService strategies;
  late final SignalService signals;
  late final StatsService stats;
  late final ChartInputService charts;
  final notices = <Map<String, dynamic>>[];

  String get filesDir => '$root/files';

  /// Open (or create) the on-device engine in `root`. A corrupt database is kept aside, never overwritten.
  static Future<LocalEngine> open(String root, SchemaLoader schema) async {
    Directory('$root/files').createSync(recursive: true);
    final path = '$root/uata.sqlite3';
    final notices = <Map<String, dynamic>>[];
    if (File(path).existsSync()) {
      LocalDb? probe;
      var ok = false;
      try {
        probe = await LocalDb.open(path, schema);
        ok = probe.integrityOk();
      } catch (_) {
        ok = false;
      } finally {
        probe?.close();
      }
      if (!ok) {
        final kept = '$path.corrupt-${DateTime.now().toUtc().millisecondsSinceEpoch}';
        File(path).renameSync(kept);
        for (final s in ['-wal', '-shm']) {
          if (File('$path$s').existsSync()) File('$path$s').renameSync('$kept$s');
        }
        notices.add({'code': 'database_was_corrupt', 'kept_as': kept.split('/').last, 'advice': 'restore your latest backup'});
      }
    }
    final e = LocalEngine._(root, await LocalDb.open(path, schema), schema);
    e.notices.addAll(notices);
    return e;
  }

  Future<void> wipe() async {
    control.stop(reason: 'wipe', emergency: true);
    await db.recreate(schema);
    final files = Directory(filesDir);
    if (files.existsSync()) files.deleteSync(recursive: true);
    files.createSync(recursive: true);
  }

  void close() => db.close();
}

class LocalEngineApi implements EngineApi {
  LocalEngineApi(this.engine);
  final LocalEngine engine;

  static const wipeConfirmation = 'DELETE ALL MY DATA';

  Future<T> _notOnPhone<T>(String feature) =>
      Future<T>.error(EngineException(501, '$feature is not available on this device yet — use the computer app'));

  /// Run synchronously-implemented services with the same error codes as the HTTP engine.
  Future<T> _run<T>(FutureOr<T> Function() fn) async {
    try {
      return await fn();
    } on EngineException {
      rethrow;
    } on SettingsError catch (e) {
      throw EngineException(422, e.message);
    } on FormatException catch (e) {
      throw EngineException(400, e.message);
    }
  }

  static Future<Uint8List> _bytes(UploadFile f) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in f.openRead()) {
      b.add(chunk);
      if (b.length > maxImageBytes + 1) break;
    }
    return b.takeBytes();
  }

  // ------------------------------------------------------------ health
  @override
  Future<bool> health() async => true;
  @override
  Future<List<Json>> notices() async => [...engine.notices];
  @override
  Future<Json> capabilities() async => {
        'engine': 'phone', 'ocr': false, 'ocr_languages': <String>[], 'speech_to_text': false, 'ffmpeg': false,
        'screen_capture': false, 'knowledge': false, 'videos': false, 'backups': false, 'companion': false,
      };

  @override
  Future<Json> companionStatus() => _notOnPhone('companion pairing');
  @override
  Future<Json> companionPairing() => _notOnPhone('companion pairing');
  @override
  Future<void> cancelCompanionPairing() async {}
  @override
  Future<Json> revokeCompanionDevice(int id) => _notOnPhone('companion pairing');

  // ------------------------------------------------------------ settings
  @override
  Future<Json> getSettings() => _run(engine.settings.get);
  @override
  Future<Json> patchSettings(Json patch) => _run(() => engine.settings.update(patch));
  @override
  Future<Json> resetSettings() => _run(engine.settings.reset);

  // ------------------------------------------------------------ analysis control
  @override
  Future<Json> status() => _run(engine.control.status);

  @override
  Future<Json> start({String inputMode = 'upload', String? asset}) => _run(() {
        final s = engine.settings.get();
        engine.control.start(inputMode, s['candle_timeframe_sec'] as int, asset, s['screen_capture_allowed'] as bool);
        return engine.control.status();
      });

  @override
  Future<Json> stop() => _run(() {
        engine.control.stop();
        return engine.control.status();
      });

  @override
  Future<Json> emergencyStop() => _run(() {
        engine.control.stop(reason: 'emergency_stop', emergency: true);
        engine.settings.update({'continuous_analysis': false, 'screen_capture_allowed': false});
        return engine.control.status();
      });

  @override
  Future<Json> submitChartImage(UploadFile image, {String inputMode = 'upload'}) => _run(() async {
        if (engine.control.halted) throw EngineException(409, 'emergency stop is active; start analysis again first');
        final session = engine.control.currentSession();
        final s = engine.settings.get();
        final out = await engine.charts.submit(await _bytes(image), image.name, inputMode,
            screenAllowed: s['screen_capture_allowed'] as bool, sessionId: session?['id'] as int?,
            minQuality: (s['min_data_quality_to_signal'] as num).toDouble(),
            enabled: (s['indicators'] as Map).cast<String, bool>());
        engine.control.lastDecision = (out['analysis'] as Map).cast<String, dynamic>();
        return out;
      });

  @override
  Future<List<Json>> listChartInputs({int limit = 50}) => _run(() => engine.charts.list(limit: limit));
  @override
  Future<Json> captureScreen() => _notOnPhone('screen capture');
  @override
  Future<List<int>> chartAnnotated(int inputId) => _run(() => engine.charts.annotatedPng(inputId));

  // ------------------------------------------------------------ knowledge & videos (computer only for now)
  @override
  Future<List<Json>> listSources({String? kind, String? category}) => _notOnPhone('the knowledge library');
  @override
  Future<Json> getSource(int id) => _notOnPhone('the knowledge library');
  @override
  Future<void> deleteSource(int id) => _notOnPhone('the knowledge library');
  @override
  Future<Json> addNote({required String title, required String content, String? category, List<String> tags = const [], String itemType = 'note'}) =>
      _notOnPhone('the knowledge library');
  @override
  Future<Json> addUrl({required String url, String? title, String? notes}) => _notOnPhone('the knowledge library');
  @override
  Future<Json> uploadFile(UploadFile file, {String? title, String? category, List<String> tags = const []}) =>
      _notOnPhone('the knowledge library');
  @override
  Future<Json> decideItem(int itemId, String decision) => _notOnPhone('the knowledge library');
  @override
  Future<List<Json>> search(String query, {bool approvedOnly = false}) => _notOnPhone('the knowledge library');
  @override
  Future<List<Json>> listReports({String? status}) => _notOnPhone('the knowledge library');
  @override
  Future<Json> decideReport(int reportId, String decision) => _notOnPhone('the knowledge library');
  @override
  Future<List<Json>> listVideos() => _notOnPhone('video learning');
  @override
  Future<Json> videoPage(int sourceId) => _notOnPhone('video learning');
  @override
  Future<Json> uploadSubtitles(int sourceId, UploadFile subtitles) => _notOnPhone('video learning');
  @override
  Future<Json> reanalyzeVideo(int sourceId) => _notOnPhone('video learning');

  // ------------------------------------------------------------ strategies & training
  @override
  Future<List<Json>> strategyCatalog() => _run(engine.strategies.catalog);
  @override
  Future<List<Json>> listStrategies() => _run(engine.strategies.list);
  @override
  Future<Json> getStrategy(int id) => _run(() => engine.strategies.get(id));
  @override
  Future<Json> createStrategy(String name, Json definition, {String description = ''}) =>
      _run(() => engine.strategies.create(name, definition, description: description));
  @override
  Future<Json> updateStrategy(int id, Json patch) => _run(() => engine.strategies.update(id, patch));
  @override
  Future<void> deleteStrategy(int id) => _run(() => engine.strategies.delete(id));
  @override
  Future<Json> backtest(int strategyId, int datasetId, {double payout = 0.85, double inSample = 0.7}) =>
      _run(() => engine.strategies.backtest(strategyId, datasetId, payout: payout, inSample: inSample));
  @override
  Future<Json> approveStrategy(int id) => _run(() => engine.strategies.approve(id));
  @override
  Future<Json> retireStrategy(int id) => _run(() => engine.strategies.retire(id));
  @override
  Future<List<Json>> compareStrategies(List<int> ids, int datasetId, {double payout = 0.85}) =>
      _run(() => engine.strategies.compare(ids, datasetId, payout: payout));
  @override
  Future<List<Json>> listDatasets() => _run(engine.strategies.listDatasets);
  @override
  Future<Json> importDataset(UploadFile csv, {String? name, String? asset}) => _run(() async {
        final text = utf8.decode(await _bytes(csv), allowMalformed: true).replaceFirst('﻿', '');
        return engine.strategies.importCsv(name ?? csv.name, text, asset: asset);
      });
  @override
  Future<Json> syntheticDataset({int rows = 3000, int timeframeSec = 30, int seed = 0}) =>
      _run(() => engine.strategies.createSynthetic(n: rows, timeframeSec: timeframeSec, seed: seed));
  @override
  Future<void> deleteDataset(int id) => _run(() => engine.strategies.deleteDataset(id));

  // ------------------------------------------------------------ signals & results
  @override
  Future<List<Json>> listSignals({int limit = 100}) => _run(() => engine.records.listSignals(limit: limit));
  @override
  Future<Json> summary() => _run(engine.records.summary);
  @override
  Future<List<Json>> listResults({String? accountType}) => _run(() => engine.records.listResults(accountType: accountType));
  @override
  Future<Json> addResult(Json result) => _run(() => engine.records.addResult(result));
  @override
  Future<void> deleteResult(int id) => _run(() {
        if (!engine.records.deleteResult(id)) throw EngineException(404, 'result not found');
      });
  @override
  Future<Json> resultFromSignal(int signalId, {required String accountType, required String outcome, String? asset, String? notes}) =>
      _run(() => engine.records.resultFromSignal(signalId, accountType, outcome, asset: asset, notes: notes));
  @override
  Future<Json> dashboard(String accountType) => _run(() => engine.stats.dashboard(accountType));
  @override
  Future<List<Json>> insights(String accountType) => _run(() => engine.stats.insights(accountType));

  // ------------------------------------------------------------ backup & privacy
  @override
  Future<List<Json>> listBackups() async => const [];
  @override
  Future<Json> createBackup(String passphrase) => _notOnPhone('encrypted backup');
  @override
  Future<Json> restoreBackup(UploadFile file, String passphrase) => _notOnPhone('encrypted backup');
  @override
  Future<void> wipe({bool includeBackups = false}) => _run(engine.wipe);
}
