import 'dart:convert';

import 'package:http/http.dart' as http;

import 'engine_api.dart';

/// [EngineApi] over loopback HTTP. The per-launch token is read through
/// [tokenProvider] and re-read once on 401 (the engine rotates it on restart).
class HttpEngineApi implements EngineApi {
  HttpEngineApi({
    Uri? baseUrl,
    required this.tokenProvider,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.authHeader = 'X-UATA-Token',
  })  : baseUrl = baseUrl ?? Uri.parse('http://127.0.0.1:8765'),
        _client = client ?? http.Client();

  final Uri baseUrl;
  final Future<String?> Function() tokenProvider;
  final Duration timeout;
  /// `X-UATA-Token` for the engine on this computer, `X-UATA-Device` for a paired phone.
  final String authHeader;
  final http.Client _client;
  String? _token;

  Uri _u(String path, [Map<String, String?>? query]) {
    final q = <String, String>{};
    query?.forEach((k, v) {
      if (v != null) q[k] = v;
    });
    return baseUrl.replace(path: path, queryParameters: q.isEmpty ? null : q);
  }

  Future<Map<String, String>> _headers({bool json = false}) async {
    _token ??= await tokenProvider();
    return {
      authHeader: ?_token,
      if (json) 'content-type': 'application/json',
    };
  }

  Future<dynamic> _send(Future<http.Response> Function(Map<String, String> h) call, {bool json = false}) async {
    http.Response r;
    try {
      r = await call(await _headers(json: json)).timeout(timeout);
      if (r.statusCode == 401) {
        _token = await tokenProvider();
        r = await call(await _headers(json: json)).timeout(timeout);
      }
    } on EngineException {
      rethrow;
    } catch (e) {
      throw EngineException(0, 'engine unreachable: $e');
    }
    final body = r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 400) {
      final detail = body is Map ? body['detail'] : body;
      final reasons = body is Map && body['reasons'] is List ? (body['reasons'] as List).cast<String>() : const <String>[];
      throw EngineException(r.statusCode, detail is String ? detail : jsonEncode(detail), reasons: reasons);
    }
    return body;
  }

  Future<dynamic> _get(String p, [Map<String, String?>? q]) => _send((h) => _client.get(_u(p, q), headers: h));
  Future<dynamic> _post(String p, [Object? body]) =>
      _send((h) => _client.post(_u(p), headers: h, body: body == null ? null : jsonEncode(body)), json: true);
  Future<dynamic> _patch(String p, Object body) =>
      _send((h) => _client.patch(_u(p), headers: h, body: jsonEncode(body)), json: true);
  Future<dynamic> _delete(String p) => _send((h) => _client.delete(_u(p), headers: h));

  Future<dynamic> _multipart(String p, UploadFile f, Map<String, String> fields) {
    return _send((h) async {
      final req = http.MultipartRequest('POST', _u(p))
        ..headers.addAll(h)
        ..fields.addAll(fields)
        ..files.add(http.MultipartFile('file', f.openRead(), f.length, filename: f.name));
      return http.Response.fromStream(await _client.send(req));
    });
  }

  static List<Json> _list(dynamic v) => (v as List).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
  static Json _map(dynamic v) => (v as Map).cast<String, dynamic>();

  @override
  Future<bool> health() async {
    try {
      final r = await _client.get(_u('/health')).timeout(const Duration(seconds: 3));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Json> companionStatus() async => _map(await _get('/companion'));
  @override
  Future<Json> companionPairing() async => _map(await _post('/companion/pairing'));
  @override
  Future<void> cancelCompanionPairing() async => _delete('/companion/pairing');
  @override
  Future<Json> revokeCompanionDevice(int id) async => _map(await _delete('/companion/devices/$id'));

  @override
  Future<Json> capabilities() async {
    try {
      final r = await _client.get(_u('/health')).timeout(const Duration(seconds: 3));
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      return _map((body as Map)['capabilities'] ?? const {});
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<List<Json>> notices() async {
    try {
      final r = await _client.get(_u('/health')).timeout(const Duration(seconds: 3));
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      return _list((body as Map)['notices'] ?? const []);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<Json> getSettings() async => _map(await _get('/settings'));
  @override
  Future<Json> patchSettings(Json patch) async => _map(await _patch('/settings', patch));
  @override
  Future<Json> resetSettings() async => _map(await _post('/settings/reset'));

  @override
  Future<Json> status() async => _map(await _get('/analysis/status'));
  @override
  Future<Json> start({String inputMode = 'upload', String? asset}) async =>
      _map(await _post('/analysis/start', {'input_mode': inputMode, 'asset': asset}));
  @override
  Future<Json> stop() async => _map(await _post('/analysis/stop'));
  @override
  Future<Json> emergencyStop() async => _map(await _post('/analysis/emergency-stop'));

  @override
  Future<Json> submitChartImage(UploadFile image, {String inputMode = 'upload', bool readPrices = true}) async =>
      _map(await _multipart('/analysis/inputs', image, {'input_mode': inputMode}));
  @override
  Future<List<Json>> listChartInputs({int limit = 50}) async =>
      _list(await _get('/analysis/inputs', {'limit': '$limit'}));

  @override
  Future<Json> captureScreen() async => _map(await _post('/analysis/capture'));
  @override
  Future<List<int>> chartAnnotated(int inputId) async {
    final h = await _headers();
    try {
      final r = await _client.get(_u('/analysis/inputs/$inputId/annotated'), headers: h).timeout(timeout);
      if (r.statusCode != 200) throw EngineException(r.statusCode, 'annotated image unavailable');
      return r.bodyBytes;
    } on EngineException {
      rethrow;
    } catch (e) {
      throw EngineException(0, 'engine unreachable: $e');
    }
  }

  @override
  Future<List<Json>> listSources({String? kind, String? category}) async =>
      _list(await _get('/knowledge/sources', {'kind': kind, 'category': category}));
  @override
  Future<Json> getSource(int id) async => _map(await _get('/knowledge/sources/$id'));
  @override
  Future<String> sourceText(int id) async => (_map(await _get('/knowledge/sources/$id/text'))['text'] as String?) ?? '';
  @override
  Future<void> deleteSource(int id) async => _delete('/knowledge/sources/$id');
  @override
  Future<Json> addNote({
    required String title,
    required String content,
    String? category,
    List<String> tags = const [],
    String itemType = 'note',
  }) async =>
      _map(await _post('/knowledge/notes',
          {'title': title, 'content': content, 'category': category, 'tags': tags, 'item_type': itemType}));
  @override
  Future<Json> addUrl({required String url, String? title, String? notes}) async =>
      _map(await _post('/knowledge/urls', {'url': url, 'title': title, 'notes': notes}));
  @override
  Future<Json> uploadFile(UploadFile file, {String? title, String? category, List<String> tags = const []}) async =>
      _map(await _multipart('/knowledge/files', file, {
        if (title != null && title.isNotEmpty) 'title': title,
        if (category != null && category.isNotEmpty) 'category': category,
        if (tags.isNotEmpty) 'tags': tags.join(','),
      }));
  @override
  Future<Json> decideItem(int itemId, String decision) async =>
      _map(await _post('/knowledge/items/$itemId/decision', {'decision': decision}));
  @override
  Future<List<Json>> search(String query, {bool approvedOnly = false}) async =>
      _list(await _get('/knowledge/search', {'q': query, 'approved_only': '$approvedOnly'}));

  @override
  Future<List<Json>> listReports({String? status}) async => _list(await _get('/knowledge/reports', {'status': status}));
  @override
  Future<Json> decideReport(int reportId, String decision) async =>
      _map(await _post('/knowledge/reports/$reportId/decision', {'decision': decision}));

  @override
  Future<List<Json>> strategyCatalog() async => _list(await _get('/strategies/catalog'));
  @override
  Future<List<Json>> listStrategies() async => _list(await _get('/strategies'));
  @override
  Future<Json> getStrategy(int id) async => _map(await _get('/strategies/$id'));
  @override
  Future<Json> createStrategy(String name, Json definition, {String description = ''}) async =>
      _map(await _post('/strategies', {'name': name, 'definition': definition, 'description': description}));
  @override
  Future<Json> updateStrategy(int id, Json patch) async => _map(await _patch('/strategies/$id', patch));
  @override
  Future<void> deleteStrategy(int id) async => _delete('/strategies/$id');
  @override
  Future<Json> backtest(int strategyId, int datasetId, {double payout = 0.85, double inSample = 0.7}) async =>
      _map(await _post('/strategies/$strategyId/backtest', {'dataset_id': datasetId, 'payout': payout, 'in_sample': inSample}));
  @override
  Future<Json> approveStrategy(int id) async => _map(await _post('/strategies/$id/approve'));
  @override
  Future<Json> retireStrategy(int id) async => _map(await _post('/strategies/$id/retire'));
  @override
  Future<List<Json>> compareStrategies(List<int> ids, int datasetId, {double payout = 0.85}) async =>
      _list(await _post('/strategies/compare', {'strategy_ids': ids, 'dataset_id': datasetId, 'payout': payout}));
  @override
  Future<List<Json>> listDatasets() async => _list(await _get('/datasets'));
  @override
  Future<Json> importDataset(UploadFile csv, {String? name, String? asset}) async =>
      _map(await _multipart('/datasets/csv', csv, {'name': ?name, 'asset': ?asset}));
  @override
  Future<Json> syntheticDataset({int rows = 3000, int timeframeSec = 30, int seed = 0}) async =>
      _map(await _post('/datasets/synthetic', {'rows': rows, 'timeframe_sec': timeframeSec, 'seed': seed}));
  @override
  Future<void> deleteDataset(int id) async => _delete('/datasets/$id');

  @override
  Future<List<Json>> listVideos() async => _list(await _get('/videos'));
  @override
  Future<Json> videoPage(int sourceId) async => _map(await _get('/videos/$sourceId'));
  @override
  Future<Json> uploadSubtitles(int sourceId, UploadFile subtitles) async =>
      _map(await _multipart('/videos/$sourceId/subtitles', subtitles, const {}));
  @override
  Future<Json> reanalyzeVideo(int sourceId) async => _map(await _post('/videos/$sourceId/reanalyze'));

  @override
  Future<List<Json>> listSignals({int limit = 100}) async => _list(await _get('/signals', {'limit': '$limit'}));
  @override
  Future<Json> summary() async => _map(await _get('/stats/summary'));
  @override
  Future<List<Json>> listResults({String? accountType}) async =>
      _list(await _get('/results', {'account_type': accountType}));
  @override
  Future<Json> addResult(Json result) async => _map(await _post('/results', result));
  @override
  Future<void> deleteResult(int id) async => _delete('/results/$id');

  @override
  Future<Json> resultFromSignal(int signalId, {required String accountType, required String outcome, String? asset, String? notes}) async =>
      _map(await _post('/signals/$signalId/result',
          {'account_type': accountType, 'outcome': outcome, 'asset': asset, 'notes': notes}));
  @override
  Future<Json> dashboard(String accountType) async => _map(await _get('/stats/dashboard', {'account_type': accountType}));
  @override
  Future<List<Json>> insights(String accountType) async => _list(await _get('/stats/insights', {'account_type': accountType}));

  @override
  Future<List<Json>> listBackups() async => _list(await _get('/backups'));
  @override
  Future<Json> createBackup(String passphrase) async => _map(await _post('/backups', {'passphrase': passphrase}));
  @override
  Future<Json> restoreBackup(UploadFile file, String passphrase) async =>
      _map(await _multipart('/backups/restore', file, {'passphrase': passphrase}));
  @override
  Future<List<int>> backupBytes(String name) async {
    final h = await _headers();
    try {
      final r = await _client.get(_u('/backups/${Uri.encodeComponent(name)}'), headers: h).timeout(const Duration(minutes: 5));
      if (r.statusCode != 200) throw EngineException(r.statusCode, 'backup not found');
      return r.bodyBytes;
    } on EngineException {
      rethrow;
    } catch (e) {
      throw EngineException(0, 'engine unreachable: $e');
    }
  }

  @override
  Future<void> wipe({bool includeBackups = false}) async =>
      _post('/privacy/wipe', {'confirm': 'DELETE ALL MY DATA', 'include_backups': includeBackups});
}
