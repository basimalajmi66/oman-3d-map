import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/core/window_controller.dart';
import 'package:uata_app/platform/android_overlay.dart';

/// In-memory engine used by widget tests. Behaves like the real engine for the
/// rules the UI depends on (WAIT without engine, permission gate, approval gate).
class FakeEngine implements EngineApi {
  bool online = true;
  Json settings = {
    'candle_timeframe_sec': 30,
    'trade_duration_min_sec': 60,
    'trade_duration_max_sec': 180,
    'trading_mode': 'manual',
    'continuous_analysis': false,
    'min_confidence_to_signal': 0.65,
    'min_data_quality_to_signal': 0.6,
    'min_confluence_factors': 3,
    'signal_cooldown_sec': 30,
    'indicators': {for (final n in ['rsi', 'macd', 'trend']) n: true},
    'language': 'ar',
    'theme': 'system',
    'panel_always_on_top': true,
    'panel_opacity': 0.95,
    'screen_capture_allowed': false,
    'capture_region': null,
    'capture_interval_sec': 5,
    'external_data_sources_allowed': false,
  };
  Json? session;
  bool halted = false;
  final List<Json> sources = [];
  final List<Json> results = [];
  final List<Json> signals = [];
  final List<String> calls = [];
  int _id = 0;

  void _check() {
    if (!online) throw EngineException(0, 'offline');
  }

  @override
  Future<bool> health() async => online;

  @override
  Future<Json> getSettings() async {
    _check();
    return Map.of(settings);
  }

  @override
  Future<Json> patchSettings(Json patch) async {
    _check();
    calls.add('patch:${patch.keys.join(',')}');
    if (patch['trading_mode'] != null && patch['trading_mode'] != 'manual') {
      throw EngineException(422, 'manual only');
    }
    if (patch['indicators'] is Map) {
      patch = {...patch, 'indicators': {...settings['indicators'] as Map, ...patch['indicators'] as Map}};
    }
    settings = {...settings, ...patch};
    return Map.of(settings);
  }

  @override
  Future<Json> resetSettings() async => getSettings();

  @override
  Future<Json> status() async {
    _check();
    final reason = halted ? 'emergency_stop_active' : session == null ? 'analysis_not_running' : 'analysis_engine_not_installed';
    return {
      'state': halted ? 'halted' : session == null ? 'idle' : 'running_no_engine',
      'halted': halted,
      'session': session,
      'engine_available': false,
      'components': {'chart_vision': true, 'signal_engine': false},
      'screen_watch': screenWatch,
      'recommendation': {'signal': 'WAIT', 'reason_code': reason, 'confidence': null, 'duration_sec': null},
    };
  }

  @override
  Future<Json> start({String inputMode = 'upload', String? asset}) async {
    _check();
    calls.add('start:$inputMode');
    if (inputMode.contains('screen') && settings['screen_capture_allowed'] != true) {
      throw EngineException(403, 'permission');
    }
    halted = false;
    session = {'id': ++_id, 'timeframe_sec': settings['candle_timeframe_sec'], 'input_mode': inputMode};
    return status();
  }

  @override
  Future<Json> stop() async {
    calls.add('stop');
    session = null;
    return status();
  }

  @override
  Future<Json> emergencyStop() async {
    calls.add('emergency');
    session = null;
    halted = true;
    settings = {...settings, 'screen_capture_allowed': false, 'continuous_analysis': false};
    return status();
  }

  // ---------------------------------------------------------------- chart inputs
  final List<Json> chartInputs = [];

  @override
  Future<Json> submitChartImage(UploadFile image, {String inputMode = 'upload'}) async {
    _check();
    calls.add('chart:$inputMode:${image.name}');
    if (halted) throw EngineException(409, 'halted');
    if (!image.name.endsWith('.png') && !image.name.endsWith('.jpg')) throw EngineException(422, 'not an image');
    final input = {'id': ++_id, 'input_mode': inputMode, 'width': 800, 'height': 450,
      'created_at': '2026-11-17T10:00:00.000+00:00'};
    chartInputs.add(input);
    return {'input': input, 'analysis': _analysis()};
  }

  @override
  Future<List<Json>> listChartInputs({int limit = 50}) async => chartInputs.reversed.toList();

  Json reading = {
    'usable': true, 'abstain_reasons': <String>[], 'data_quality': 0.93, 'candles': 50, 'closed_candles': 49,
    'bullish': 27, 'bearish': 22, 'last_closed_direction': 'up', 'last_closed_close': 1.10234,
    'prices_read': true, 'timeframe_sec': 30, 'timeframe_label': '30s', 'warnings': <String>[],
  };

  @override
  Future<Json> captureScreen() async {
    calls.add('capture');
    if (settings['screen_capture_allowed'] != true) throw EngineException(403, 'permission');
    final input = {'id': ++_id, 'input_mode': 'screenshot', 'width': 1920, 'height': 1080};
    chartInputs.add(input);
    return {'input': input, 'analysis': _analysis()};
  }

  Json? technical = {
    'available': true, 'units': 'price', 'candles_used': 49, 'market_condition': 'trending',
    'trend': {'direction': 'up', 'strength': 0.7, 'structure': 'up'},
    'supporting_bullish': [
      {'name': 'trend', 'code': 'trend_up', 'strength': 0.7, 'params': {}},
      {'name': 'macd', 'code': 'macd_cross_up', 'strength': 0.65, 'params': {}},
    ],
    'supporting_bearish': [
      {'name': 'rsi', 'code': 'rsi_overbought', 'strength': 0.5, 'params': {'value': 74.0}},
    ],
    'neutral': ['atr'], 'disabled': ['volatility'], 'unavailable': ['volume'],
    'bullish_score': 1.35, 'bearish_score': 0.5,
    'levels': [
      {'price': 1.1012, 'kind': 'support', 'touches': 3, 'last_index': 40, 'strength': 0.9},
    ],
    'patterns': <String>[], 'warnings': ['no_volume_data'],
  };

  List<Json> knowledge = [
    {'item_id': 501, 'title': 'Trend rule', 'snippet': 'Trade with the trend', 'location': 'p.2', 'source_id': 9,
      'source_title': 'strategy.pdf', 'item_type': 'rule', 'score': 0.03},
  ];

  Json _analysis() => {
        'knowledge': knowledge,
        'technical': technical,
        'signal': 'WAIT',
        'reason_code': reading['usable'] == true ? 'signal_engine_not_installed' : 'image_quality_insufficient',
        'data_basis': 'image_only', 'confidence': null, 'data_quality': reading['data_quality'], 'reading': reading,
      };

  @override
  Future<List<int>> chartAnnotated(int inputId) async {
    calls.add('annotated:$inputId');
    // 1x1 transparent PNG
    return const [
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196,
      137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1, 13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68,
      174, 66, 96, 130,
    ];
  }

  Json? screenWatch;

  // ---------------------------------------------------------------- knowledge
  @override
  Future<List<Json>> listSources({String? kind, String? category}) async {
    _check();
    return sources.reversed
        .map((s) => {
              ...s,
              'pending_count': (s['items'] as List).where((i) => (i as Map)['status'] == 'pending_review').length,
            })
        .toList();
  }

  @override
  Future<Json> getSource(int id) async => sources.firstWhere((s) => s['id'] == id);

  @override
  Future<void> deleteSource(int id) async => sources.removeWhere((s) => s['id'] == id);

  Json _newSource(String kind, String title, {String? content, String? category, String status = 'done'}) {
    final id = ++_id;
    final s = <String, dynamic>{
      'id': id,
      'kind': kind,
      'title': title,
      'category': category,
      'tags': <String>[],
      'created_at': '2026-11-17T10:00:00.000+00:00',
      'extraction_status': status,
      'items': [
        if (content != null)
          {'id': ++_id, 'source_id': id, 'item_type': 'note', 'title': title, 'content': content, 'status': 'pending_review'}
      ],
    };
    sources.add(s);
    return s;
  }

  @override
  Future<Json> addNote(
      {required String title, required String content, String? category, List<String> tags = const [], String itemType = 'note'}) async {
    calls.add('note:$title');
    return _newSource('note', title, content: content, category: category);
  }

  @override
  Future<Json> addUrl({required String url, String? title, String? notes}) async =>
      _newSource('url', title ?? url, status: 'unsupported_yet');

  @override
  Future<Json> uploadFile(UploadFile file, {String? title, String? category, List<String> tags = const []}) async {
    calls.add('upload:${file.name}');
    if (sources.any((s) => s['title'] == file.name)) throw EngineException(409, 'dup');
    return _newSource(file.name.endsWith('.txt') ? 'txt' : 'pdf', file.name,
        status: file.name.endsWith('.txt') ? 'done' : 'unsupported_yet');
  }

  @override
  Future<Json> decideItem(int itemId, String decision) async {
    calls.add('$decision:$itemId');
    for (final s in sources) {
      for (final i in (s['items'] as List).cast<Map>()) {
        if (i['id'] == itemId) {
          i['status'] = decision == 'approve' ? 'approved' : 'rejected';
          return i.cast<String, dynamic>();
        }
      }
    }
    throw EngineException(404, 'nf');
  }

  @override
  Future<List<Json>> search(String query, {bool approvedOnly = false}) async => [
        for (final s in sources)
          for (final i in (s['items'] as List).cast<Map>())
            if ((i['content'] as String).contains(query))
              {...i.cast<String, dynamic>(), 'source_title': s['title'], 'snippet': i['content']}
      ];

  // ---------------------------------------------------------------- learning reports
  List<Json> reports = [];

  @override
  Future<List<Json>> listReports({String? status}) async =>
      reports.where((r) => status == null || r['status'] == status).toList();

  @override
  Future<Json> decideReport(int reportId, String decision) async {
    calls.add('report:$decision:$reportId');
    for (final p in videoPages.values) {
      final rep = p['report'] as Map?;
      if (rep != null && rep['id'] == reportId) {
        rep['status'] = decision == 'approve' ? 'approved' : 'rejected';
        return rep.cast<String, dynamic>();
      }
    }
    final r = reports.firstWhere((r) => r['id'] == reportId);
    r['status'] = decision == 'approve' ? 'approved' : 'rejected';
    return r;
  }

  // ---------------------------------------------------------------- strategies (phase 7)
  List<Json> strategies = [];
  List<Json> datasets = [];
  Json backtestResult = {};
  List<String> approveRefusal = [];

  @override
  Future<List<Json>> strategyCatalog() async => [
        {'id': 'rsi_below', 'params': {'value': 30}, 'ar': 'RSI أقل من {value}', 'en': 'RSI below {value}'},
        {'id': 'bullish_candle', 'params': {}, 'ar': 'شمعة صاعدة', 'en': 'bullish candle'},
      ];
  @override
  Future<List<Json>> listStrategies() async => strategies;
  @override
  Future<Json> getStrategy(int id) async => strategies.firstWhere((s) => s['id'] == id);
  @override
  Future<Json> createStrategy(String name, Json definition, {String description = ''}) async {
    calls.add('create_strategy:$name');
    final s = {'id': ++_id, 'name': name, 'status': 'draft', 'version': 1, 'definition': definition,
      'description': description, 'readable_ar': {'long': ['شمعة صاعدة'], 'short': [], 'veto': []},
      'readable': {'long': ['bullish candle'], 'short': [], 'veto': []}, 'latest_backtest': null};
    strategies.add(s);
    return s;
  }

  @override
  Future<Json> updateStrategy(int id, Json patch) async => getStrategy(id);
  @override
  Future<void> deleteStrategy(int id) async => strategies.removeWhere((s) => s['id'] == id);
  @override
  Future<Json> backtest(int strategyId, int datasetId, {double payout = 0.85, double inSample = 0.7}) async {
    calls.add('backtest:$strategyId:$datasetId');
    return backtestResult;
  }

  @override
  Future<Json> approveStrategy(int id) async {
    calls.add('approve_strategy:$id');
    if (approveRefusal.isNotEmpty) {
      throw EngineException(409, 'strategy does not qualify for approval', reasons: approveRefusal);
    }
    final s = await getStrategy(id);
    s['status'] = 'approved';
    return s;
  }

  @override
  Future<Json> retireStrategy(int id) async => getStrategy(id);
  @override
  Future<List<Json>> compareStrategies(List<int> ids, int datasetId, {double payout = 0.85}) async {
    calls.add('compare:${ids.join(',')}:$datasetId');
    return [
      for (final id in ids)
        {'strategy_id': id, 'name': 'S$id', 'trades': 40, 'win_rate': 0.6, 'expectancy_per_trade': 0.1,
          'profit_factor': 1.3, 'qualifies': id == ids.first},
    ];
  }

  @override
  Future<List<Json>> listDatasets() async => datasets;
  @override
  Future<Json> importDataset(UploadFile csv, {String? name, String? asset}) async {
    calls.add('import:${csv.name}');
    final d = {'id': ++_id, 'name': csv.name, 'rows': 1500, 'timeframe_sec': 30, 'is_synthetic': 0};
    datasets.add(d);
    return d;
  }

  @override
  Future<Json> syntheticDataset({int rows = 3000, int timeframeSec = 30, int seed = 0}) async {
    final d = {'id': ++_id, 'name': 'SYNTHETIC', 'rows': rows, 'timeframe_sec': timeframeSec, 'is_synthetic': 1};
    datasets.add(d);
    return d;
  }

  @override
  Future<void> deleteDataset(int id) async => datasets.removeWhere((d) => d['id'] == id);

  // ---------------------------------------------------------------- videos
  List<Json> videos = [];
  Map<int, Json> videoPages = {};

  @override
  Future<List<Json>> listVideos() async => videos;
  @override
  Future<Json> videoPage(int sourceId) async => videoPages[sourceId]!;
  @override
  Future<Json> uploadSubtitles(int sourceId, UploadFile subtitles) async {
    calls.add('subtitles:$sourceId:${subtitles.name}');
    videoPages[sourceId]!['transcript_source'] = 'subtitles';
    videoPages[sourceId]!['warnings'] = <String>[];
    return videoPages[sourceId]!;
  }

  @override
  Future<Json> reanalyzeVideo(int sourceId) async {
    calls.add('reanalyze:$sourceId');
    return videoPages[sourceId]!;
  }

  // ---------------------------------------------------------------- records
  @override
  Future<List<Json>> listSignals({int limit = 100}) async => signals;

  @override
  Future<Json> summary() async => {
        'signals': {'total': signals.length, 'BUY': 0, 'SELL': 0, 'WAIT': signals.length},
        'results_by_account': {
          for (final a in ['simulation', 'demo', 'real'])
            a: {
              'total': results.where((r) => r['account_type'] == a).length,
              'wins': results.where((r) => r['account_type'] == a && r['outcome'] == 'win').length,
              'losses': results.where((r) => r['account_type'] == a && r['outcome'] == 'loss').length,
              'win_rate': null,
              'sample_size': results.where((r) => r['account_type'] == a).length,
            }
        },
      };

  @override
  Future<List<Json>> listResults({String? accountType}) async => results;

  @override
  Future<Json> addResult(Json result) async {
    final r = {...result, 'id': ++_id};
    results.add(r);
    return r;
  }

  @override
  Future<void> deleteResult(int id) async => results.removeWhere((r) => r['id'] == id);

  // ---------------------------------------------------------------- backup
  final List<Json> backups = [];

  @override
  Future<List<Json>> listBackups() async => backups;

  @override
  Future<Json> createBackup(String passphrase) async {
    calls.add('backup');
    final b = {'name': 'uata-backup-${backups.length}.uatabak', 'size_bytes': 1234};
    backups.add(b);
    return b;
  }

  @override
  Future<Json> restoreBackup(UploadFile file, String passphrase) async => {'restored': true};

  @override
  Future<void> wipe({bool includeBackups = false}) async {
    calls.add('wipe:$includeBackups');
    sources.clear();
    results.clear();
  }
}

class FakeWindow implements WindowController {
  final List<String> calls = [];
  @override
  bool get isDesktop => false;
  @override
  Future<void> setExpanded(bool expanded) async => calls.add('expanded:$expanded');
  @override
  Future<void> setAlwaysOnTop(bool value) async {}
  @override
  Future<void> setOpacity(double value) async {}
  @override
  Future<void> minimize() async {}
  @override
  Future<void> close() async {}
}

class FakeOverlay implements OverlayController {
  bool granted = false;
  bool grantOnRequest = true;
  bool active = false;
  final List<Json> pushed = [];
  @override
  bool get supported => true;
  @override
  Future<bool> hasPermission() async => granted;
  @override
  Future<bool> requestPermission() async => granted = grantOnRequest;
  @override
  Future<bool> isActive() async => active;
  @override
  Future<void> show() async => active = true;
  @override
  Future<void> hide() async => active = false;
  @override
  Future<void> push(Json payload) async => pushed.add(payload);
}
