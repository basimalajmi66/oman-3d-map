/// On-device services — ports of control_service, records_service, signal_service, strategy_service and
/// stats_service. Errors are EngineExceptions with the same HTTP-style codes as the computer engine.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../core/engine_api.dart';
import '../signal/chart_read.dart';
import '../signal/decision.dart';
import '../strategy/backtest.dart' as bt;
import '../strategy/conditions.dart' as cnd;
import '../strategy/datasets.dart' as ds;
import '../strategy/features.dart';
import '../util.dart';
import 'db.dart';
import 'settings.dart';

EngineException badRequest(String m) => EngineException(400, m);
EngineException notFound(String what) => EngineException(404, 'not found: $what');

// ---------------------------------------------------------------- analysis control
const inputModes = ['upload', 'screenshot', 'screen_region', 'continuous_screen', 'price_feed'];
const screenModes = {'screenshot', 'screen_region', 'continuous_screen'};

/// What the phone engine can do. Knowledge and video learning are not on the phone (yet).
const phoneComponents = {
  'chart_vision': true,
  'technical_analysis': true,
  'knowledge_rag': false,
  'video_learning': false,
  'strategy_engine': true,
  'signal_engine': true,
};

class ControlService {
  ControlService(this.db);
  final LocalDb db;
  bool halted = false;
  Map<String, dynamic>? lastDecision;

  Map<String, dynamic> start(String inputMode, int timeframeSec, String? asset, bool screenAllowed) {
    if (!inputModes.contains(inputMode)) throw badRequest('input_mode must be one of $inputModes');
    if (screenModes.contains(inputMode) && !screenAllowed) {
      throw EngineException(403, 'screen capture permission has not been granted by the user');
    }
    return db.session((d) {
      halted = false;
      d.execute("UPDATE analysis_sessions SET status='stopped', stopped_at=?, stop_reason='superseded' WHERE status='running'",
          [utcnow()]);
      d.execute("INSERT INTO analysis_sessions(input_mode, asset, timeframe_sec, status, started_at) VALUES (?,?,?,'running',?)",
          [inputMode, asset, timeframeSec, utcnow()]);
      final id = d.lastInsertRowId;
      audit(d, 'user', 'analysis.start', {'session_id': id, 'input_mode': inputMode});
      return firstRow(d.select('SELECT * FROM analysis_sessions WHERE id=?', [id]))!;
    });
  }

  int stop({String reason = 'user_stop', bool emergency = false}) {
    lastDecision = null;
    return db.session((d) {
      if (emergency) halted = true;
      d.execute("UPDATE analysis_sessions SET status='stopped', stopped_at=?, stop_reason=? WHERE status='running'",
          [utcnow(), reason]);
      final n = d.updatedRows;
      audit(d, 'user', emergency ? 'analysis.emergency_stop' : 'analysis.stop', {'stopped': n});
      return n;
    });
  }

  Map<String, dynamic>? currentSession() =>
      db.session((d) => firstRow(d.select("SELECT * FROM analysis_sessions WHERE status='running' ORDER BY id DESC LIMIT 1")));

  Map<String, dynamic> status() {
    final session = currentSession();
    final engineReady = ['chart_vision', 'technical_analysis', 'strategy_engine', 'signal_engine'].every((k) => phoneComponents[k]!);
    String state;
    String? reason;
    if (halted) {
      (state, reason) = ('halted', 'emergency_stop_active');
    } else if (session == null) {
      (state, reason) = ('idle', 'analysis_not_running');
    } else {
      (state, reason) = ('analyzing', null);
    }
    Map<String, dynamic>? decision;
    if (session != null && !halted && lastDecision != null) {
      decision = lastDecision;
      reason = decision!['reason_code'] as String?;
    }
    final dd = decision ?? const <String, dynamic>{};
    return {
      'state': state, 'halted': halted, 'session': session, 'engine_available': engineReady,
      'components': phoneComponents, 'screen_watch': null,
      'recommendation': {
        'signal': dd['signal'] ?? 'WAIT', 'reason_code': reason, 'reasons': dd['reasons'] ?? [],
        'supporting': dd['supporting'] ?? [], 'opposing': dd['opposing'] ?? [], 'steps': dd['steps'] ?? [],
        'strategy': dd['strategy'], 'data_quality': dd['data_quality'], 'data_basis': dd['data_basis'],
        'confidence': dd['confidence'], 'confidence_calibrated': false, 'duration_sec': dd['duration_sec'],
      },
    };
  }
}

// ---------------------------------------------------------------- signals & results
const accountTypes = ['simulation', 'demo', 'real'];
const outcomes = ['win', 'loss', 'draw', 'cancelled'];
const engineVersion = '0.1.0';

class RecordsService {
  RecordsService(this.db);
  final LocalDb db;

  Map<String, dynamic> recordSignal({
    required String signal,
    required int timeframeSec,
    required String dataBasis,
    required List reasons,
    required List supporting,
    required List opposing,
    double? dataQuality,
    double? confidence,
    int? durationSec,
    String? asset,
    int? strategyId,
    int? sessionId,
    int minConfluence = 3,
    String? marketCondition,
  }) {
    if (!const ['BUY', 'SELL', 'WAIT'].contains(signal)) throw badRequest('signal must be BUY, SELL or WAIT');
    if (signal != 'WAIT') {
      if (durationSec == null) throw badRequest('BUY/SELL require a suggested duration');
      if (supporting.length < minConfluence) throw badRequest('BUY/SELL require at least $minConfluence supporting factors');
      if (reasons.isEmpty) throw badRequest('BUY/SELL require stated reasons');
    }
    return db.session((d) {
      d.execute(
          'INSERT INTO signals(session_id,created_at,asset,timeframe_sec,signal,confidence_score,confidence_calibrated,'
          'duration_sec,strategy_id,reasons_json,supporting_json,opposing_json,data_quality,data_basis,engine_version,'
          'market_condition) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
          [sessionId, utcnow(), asset, timeframeSec, signal, confidence, 0, durationSec, strategyId, jsonEncode(reasons),
            jsonEncode(supporting), jsonEncode(opposing), dataQuality, dataBasis, engineVersion, marketCondition]);
      final id = d.lastInsertRowId;
      audit(d, 'system', 'signal.record', {'signal_id': id, 'signal': signal});
      return firstRow(d.select('SELECT * FROM signals WHERE id=?', [id]))!;
    });
  }

  List<Map<String, dynamic>> listSignals({int limit = 100}) =>
      db.session((d) => [for (final r in d.select('SELECT * FROM signals ORDER BY id DESC LIMIT ?', [limit])) rowToMap(r)]);

  static const _resultCols = [
    'signal_id', 'account_type', 'asset', 'timeframe_sec', 'strategy_id', 'signal_type', 'signal_time', 'duration_sec', //
    'outcome', 'pnl', 'market_condition', 'notes', 'confidence', 'data_quality',
  ];

  Map<String, dynamic> addResult(Map<String, dynamic> data) {
    const required = ['account_type', 'asset', 'timeframe_sec', 'signal_type', 'signal_time', 'duration_sec', 'outcome'];
    final missing = [for (final k in required) if (data[k] == null || data[k] == '') k];
    if (missing.isNotEmpty) throw badRequest('missing fields: $missing');
    if (!accountTypes.contains(data['account_type'])) throw badRequest('account_type must be one of $accountTypes');
    if (!outcomes.contains(data['outcome'])) throw badRequest('outcome must be one of $outcomes');
    if (!const ['BUY', 'SELL'].contains(data['signal_type'])) throw badRequest('signal_type must be BUY or SELL');
    return db.session((d) {
      d.execute(
          'INSERT INTO trade_results(${_resultCols.join(',')},created_at) VALUES (${List.filled(_resultCols.length + 1, '?').join(',')})',
          [for (final c in _resultCols) data[c], utcnow()]);
      final id = d.lastInsertRowId;
      audit(d, 'user', 'result.add', {'result_id': id, 'account_type': data['account_type']});
      return firstRow(d.select('SELECT * FROM trade_results WHERE id=?', [id]))!;
    });
  }

  Map<String, dynamic> resultFromSignal(int signalId, String accountType, String outcome, {String? asset, double? pnl, String? notes}) {
    final (sig, dup) = db.session((d) => (
          firstRow(d.select('SELECT * FROM signals WHERE id=?', [signalId])),
          d.select('SELECT id FROM trade_results WHERE signal_id=?', [signalId]).isNotEmpty
        ));
    if (sig == null) throw EngineException(404, 'signal not found');
    if (sig['signal'] == 'WAIT') throw badRequest('a WAIT signal has no trade to record');
    if (dup) throw badRequest('a result is already recorded for this signal');
    return addResult({
      'signal_id': signalId, 'account_type': accountType, 'asset': asset ?? sig['asset'] ?? 'UNKNOWN',
      'timeframe_sec': sig['timeframe_sec'], 'strategy_id': sig['strategy_id'], 'signal_type': sig['signal'],
      'signal_time': sig['created_at'], 'duration_sec': sig['duration_sec'], 'outcome': outcome, 'pnl': pnl,
      'market_condition': sig['market_condition'], 'notes': notes, 'confidence': sig['confidence_score'],
      'data_quality': sig['data_quality'],
    });
  }

  List<Map<String, dynamic>> listResults({String? accountType, int limit = 200}) => db.session((d) => [
        for (final r in accountType == null
            ? d.select('SELECT * FROM trade_results ORDER BY id DESC LIMIT ?', [limit])
            : d.select('SELECT * FROM trade_results WHERE account_type=? ORDER BY id DESC LIMIT ?', [accountType, limit]))
          rowToMap(r)
      ]);

  bool deleteResult(int id) => db.session((d) {
        d.execute('DELETE FROM trade_results WHERE id=?', [id]);
        final n = d.updatedRows;
        if (n > 0) audit(d, 'user', 'result.delete', {'result_id': id});
        return n > 0;
      });

  Map<String, dynamic> summary() => db.session((d) {
        final sig = {for (final r in d.select('SELECT signal, count(*) AS n FROM signals GROUP BY signal')) r['signal']: r['n'] as int};
        final byAccount = <String, dynamic>{};
        for (final acct in accountTypes) {
          final rows = {
            for (final r in d.select('SELECT outcome, count(*) AS n FROM trade_results WHERE account_type=? GROUP BY outcome', [acct]))
              r['outcome']: r['n'] as int
          };
          final decided = (rows['win'] ?? 0) + (rows['loss'] ?? 0);
          byAccount[acct] = {
            'total': rows.values.fold(0, (a, b) => a + b), 'wins': rows['win'] ?? 0, 'losses': rows['loss'] ?? 0,
            'draws': rows['draw'] ?? 0, 'cancelled': rows['cancelled'] ?? 0,
            'win_rate': decided > 0 ? (rows['win'] ?? 0) / decided : null, 'sample_size': decided,
          };
        }
        return {
          'signals': {
            'total': sig.values.fold(0, (a, b) => a + b), 'BUY': sig['BUY'] ?? 0, 'SELL': sig['SELL'] ?? 0,
            'WAIT': sig['WAIT'] ?? 0,
          },
          'results_by_account': byAccount,
        };
      });
}

/// Runs the decision engine and records each NEW market analysis; cooldown after BUY/SELL.
class SignalService {
  SignalService(this.records, this.strategies, this.settings);
  final RecordsService records;
  final StrategyService strategies;
  final SettingsStore settings;
  final _lastFp = <String, String>{};
  final _clock = Stopwatch()..start();
  Duration? _lastTradeSignalAt; // null = no trade signal yet

  Map<String, dynamic> evaluate(Map<String, dynamic> reading, Map<String, dynamic>? technical, String stream,
      {int? sessionId, String? asset, List<Map>? knowledge}) {
    final s = settings.get();
    final approved = [for (final x in strategies.list()) if (x['status'] == 'approved') x];
    final d = decide(reading, technical, s, approved, knowledge: knowledge);
    final fp = fingerprint(reading);
    final out = d.toJson();
    final repeated = fp.isNotEmpty && _lastFp[stream] == fp;
    final inCooldown =
        _lastTradeSignalAt != null && (_clock.elapsed - _lastTradeSignalAt!).inMilliseconds < (s['signal_cooldown_sec'] as int) * 1000;
    if (d.signal != 'WAIT' && inCooldown) {
      out
        ..['signal'] = 'WAIT'
        ..['reason_code'] = 'cooldown'
        ..['reason_codes'] = ['cooldown', ...(out['reason_codes'] as List)]
        ..['duration_sec'] = null;
    }
    out['repeated'] = repeated;
    out['recorded'] = false;
    // the chart's own reading (direction + next step), shown apart from the strategy signal
    final read = chartRead(reading, technical, durationSec: s['trade_duration_min_sec'] as int?);
    out['read'] = read;
    // a collected strategy (pattern) on the last closed candle gives a direct BUY / SELL when no tested strategy did
    // (setting "pattern_signals"); the chart itself must be valid (step 1 passed), and the repeat cooldown applies
    final chartValid = !const ['image_quality_insufficient', 'timeframe_mismatch'].contains(d.reasonCodes.firstOrNull);
    if (s['pattern_signals'] == true && out['signal'] == 'WAIT' && read['signal'] != null && chartValid && !inCooldown) {
      final hits = [for (final h in read['setups'] as List) h as Map];
      out
        ..['signal'] = read['signal']
        ..['reason_code'] = 'pattern_signal'
        ..['reason_codes'] = ['pattern_signal', ...(out['reason_codes'] as List)]
        ..['reasons'] = [for (final h in hits) if (h['side'] == read['signal']) 'setup: ${h['name']}']
        ..['duration_sec'] = s['trade_duration_min_sec']
        ..['supporting'] = [...(read[read['signal'] == 'BUY' ? 'bullish' : 'bearish'] as List)]
        ..['opposing'] = [...(read[read['signal'] == 'BUY' ? 'bearish' : 'bullish'] as List)]
        ..['pattern_signal'] = true;
    }
    if (!repeated && reading['usable'] == true) {
      _lastFp[stream] = fp;
      final reasons = (out['reasons'] as List).isEmpty ? [out['reason_code'] ?? 'wait'] : out['reasons'] as List;
      final rec = records.recordSignal(
          signal: out['signal'] as String, timeframeSec: s['candle_timeframe_sec'] as int, dataBasis: out['data_basis'] as String,
          reasons: reasons, supporting: out['supporting'] as List, opposing: out['opposing'] as List,
          dataQuality: (out['data_quality'] as num?)?.toDouble(), confidence: (out['confidence'] as num?)?.toDouble(),
          durationSec: out['duration_sec'] as int?, asset: asset, strategyId: (out['strategy'] as Map?)?['id'] as int?,
          sessionId: sessionId,
          // the factor minimum guards tested-strategy signals; a pattern signal stands on its pattern, and
          // "strategy conditions alone" on the tested strategy
          minConfluence: out['pattern_signal'] == true || s['strategy_only_signals'] == true ? 1 : s['min_confluence_factors'] as int,
          marketCondition: technical?['market_condition'] as String?);
      out['signal_id'] = rec['id'];
      out['recorded'] = true;
      if (out['signal'] != 'WAIT') _lastTradeSignalAt = _clock.elapsed;
    }
    return out;
  }
}

// ---------------------------------------------------------------- strategies & datasets
class StrategyService {
  StrategyService(this.db, this.filesDir);
  final LocalDb db;
  final String filesDir;
  final _fsCache = <int, (FeatureSet, Map<String, dynamic>)>{};
  void clearCache() => _fsCache.clear(); // after a restore or wipe, dataset ids mean other data

  Map<String, dynamic> _storeDataset(String name, String? asset, ds.OhlcData d, bool synthetic) {
    final id = db.session((x) {
      x.execute(
          'INSERT INTO datasets(name,asset,timeframe_sec,rows,first_time,last_time,has_volume,is_synthetic,stored_path,created_at) '
          "VALUES (?,?,?,?,?,?,?,?,'',?)",
          [name, asset, d.timeframeSec, d.rows, d.time.first, d.time.last, d.volume != null ? 1 : 0, synthetic ? 1 : 0, utcnow()]);
      final did = x.lastInsertRowId;
      final rel = 'datasets/$did.csv';
      File('$filesDir/$rel')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(ds.toCsv(d));
      x.execute('UPDATE datasets SET stored_path=? WHERE id=?', [rel, did]);
      audit(x, 'user', 'dataset.add', {'dataset_id': did, 'rows': d.rows, 'synthetic': synthetic});
      return did;
    });
    return getDataset(id);
  }

  Map<String, dynamic> importCsv(String name, String text, {String? asset}) {
    try {
      return _storeDataset(name, asset, ds.parseCsv(text), false);
    } on ds.DatasetError catch (e) {
      throw badRequest(e.message);
    }
  }

  Map<String, dynamic> createSynthetic({int n = 3000, int timeframeSec = 30, int seed = 0}) {
    if (n < 200 || n > 200000) throw badRequest('n must be between 200 and 200000');
    return _storeDataset('SYNTHETIC (seed $seed)', 'SIMULATED', ds.synthetic(n: n, timeframeSec: timeframeSec, seed: seed), true);
  }

  List<Map<String, dynamic>> listDatasets() =>
      db.session((d) => [for (final r in d.select('SELECT * FROM datasets ORDER BY id DESC')) rowToMap(r)]);

  Map<String, dynamic> getDataset(int id) =>
      db.session((d) => firstRow(d.select('SELECT * FROM datasets WHERE id=?', [id]))) ?? (throw notFound('dataset $id'));

  void deleteDataset(int id) {
    final d = getDataset(id);
    db.session((x) {
      x.execute('DELETE FROM datasets WHERE id=?', [id]);
      audit(x, 'user', 'dataset.delete', {'dataset_id': id});
    });
    final f = File('$filesDir/${d['stored_path']}');
    if (f.existsSync()) f.deleteSync();
    _fsCache.remove(id);
  }

  (FeatureSet, Map<String, dynamic>) features(int id) => _fsCache.putIfAbsent(id, () {
        final meta = getDataset(id);
        final d = ds.parseCsv(File('$filesDir/${meta['stored_path']}').readAsStringSync());
        return (FeatureSet(d.open, d.high, d.low, d.close, v: d.volume), meta);
      });

  Map<String, dynamic> _card(Map<String, dynamic> s) {
    final def = s['definition'] as Map?;
    if (def != null) {
      List<String> side(String k, String lang) =>
          [for (final c in (k == 'veto' ? def['veto'] : def[k]['all']) as List) cnd.describe((c as Map).cast<String, dynamic>(), lang)];
      s['readable'] = {for (final k in const ['long', 'short', 'veto']) k: side(k, 'en')};
      s['readable_ar'] = {for (final k in const ['long', 'short', 'veto']) k: side(k, 'ar')};
    }
    final runs = db.session((d) => [
          for (final r in d.select('SELECT * FROM backtest_runs WHERE strategy_id=? ORDER BY id DESC LIMIT 10', [s['id']])) _runSummary(rowToMap(r))
        ]);
    s['backtests'] = runs;
    s['latest_backtest'] = runs.where((b) => b['strategy_version'] == s['version']).firstOrNull;
    s['examples'] = db.session(
        (d) => [for (final r in d.select('SELECT * FROM strategy_examples WHERE strategy_id=? ORDER BY id', [s['id']])) rowToMap(r)]);
    return s;
  }

  static Map<String, dynamic> _runSummary(Map<String, dynamic> d) {
    final m = (d.remove('metrics') as Map?) ?? const {};
    d['in_sample'] = {for (final e in ((m['in_sample'] as Map?) ?? const {}).entries) if (e.key != 'equity_curve') e.key: e.value};
    d['out_of_sample'] = m['out_of_sample'];
    d['bars_per_trade'] = m['bars_per_trade'];
    d['payout'] = m['payout'];
    return d;
  }

  List<Map<String, dynamic>> list() =>
      [for (final r in db.session((d) => [for (final r in d.select('SELECT * FROM strategies ORDER BY id DESC')) rowToMap(r)])) _card(r)];

  Map<String, dynamic> get(int id) =>
      _card(db.session((d) => firstRow(d.select('SELECT * FROM strategies WHERE id=?', [id]))) ?? (throw notFound('strategy $id')));

  Map<String, dynamic> _validated(Map definition) {
    try {
      return cnd.validateDefinition(definition);
    } on cnd.StrategyError catch (e) {
      throw badRequest(e.message);
    }
  }

  Map<String, dynamic> create(String name, Map definition, {String description = '', int? sourceId}) {
    final d = _validated(definition);
    final id = db.session((x) {
      if (x.select('SELECT 1 FROM strategies WHERE name=?', [name]).isNotEmpty) throw badRequest('a strategy with this name already exists');
      final ids = {for (final side in const ['long', 'short']) for (final c in d[side]['all'] as List) c['id'] as String}.toList()..sort();
      x.execute(
          'INSERT INTO strategies(name,description,source_id,definition_json,timeframes_json,indicators_json,status,created_at,updated_at) '
          "VALUES (?,?,?,?,?,?,'draft',?,?)",
          [name, description, sourceId, jsonEncode(d), '[]', jsonEncode(ids), utcnow(), utcnow()]);
      final sid = x.lastInsertRowId;
      audit(x, 'user', 'strategy.create', {'strategy_id': sid});
      return sid;
    });
    return get(id);
  }

  Map<String, dynamic> update(int id, Map<String, dynamic> patch) {
    final bad = patch.keys.toSet().difference({'name', 'description', 'definition'}).toList()..sort();
    if (bad.isNotEmpty) throw badRequest('cannot update fields: $bad');
    final cur = get(id);
    final sets = <String>[], args = <Object?>[];
    if (patch.containsKey('name')) {
      sets.add('name=?');
      args.add(patch['name']);
    }
    if (patch.containsKey('description')) {
      sets.add('description=?');
      args.add(patch['description']);
    }
    if (patch.containsKey('definition')) {
      // a new definition is a new version: back to draft, previous tests no longer count
      sets.addAll(['definition_json=?', 'version=?', "status='draft'", 'approved_at=NULL']);
      args.addAll([jsonEncode(_validated(patch['definition'] as Map)), (cur['version'] as int) + 1]);
    }
    db.session((x) {
      x.execute('UPDATE strategies SET ${sets.join(', ')}, updated_at=? WHERE id=?', [...args, utcnow(), id]);
      audit(x, 'user', 'strategy.update', {'strategy_id': id, 'fields': patch.keys.toList()..sort()});
    });
    return get(id);
  }

  void delete(int id) {
    get(id);
    db.session((x) {
      x.execute('DELETE FROM strategies WHERE id=?', [id]);
      audit(x, 'user', 'strategy.delete', {'strategy_id': id});
    });
  }

  Map<String, dynamic> backtest(int id, int datasetId, {double payout = 0.85, double inSample = 0.7}) {
    final s = get(id);
    final def = s['definition'] as Map?;
    if (def == null) throw badRequest('strategy has no testable definition yet');
    final (fs, meta) = features(datasetId);
    Map<String, dynamic> result;
    try {
      result = bt.runBacktest(fs, def, meta['timeframe_sec'] as int, payout: payout, inSample: inSample);
    } on cnd.StrategyError catch (e) {
      throw badRequest(e.message);
    }
    final synthetic = meta['is_synthetic'] == 1;
    final reasons = bt.gate(result, synthetic: synthetic);
    final t0 = (meta['first_time'] as num).toDouble(), t1 = (meta['last_time'] as num).toDouble();
    final splitT = t0 + (t1 - t0) * inSample;
    String pyStr(double v) => v == v.truncateToDouble() ? v.toStringAsFixed(1) : '$v';
    final rid = db.session((x) {
      x.execute(
          'INSERT INTO backtest_runs(strategy_id,strategy_version,dataset,dataset_id,params_json,in_sample_from,in_sample_to,'
          'out_sample_from,out_sample_to,costs_json,metrics_json,qualifies,gate_reasons_json,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
          [
            id, s['version'], meta['name'], datasetId,
            jsonEncode({'in_sample': inSample, 'duration_sec': def['duration_sec'], 'timeframe_sec': meta['timeframe_sec']}),
            pyStr(t0), pyStr(splitT), pyStr(splitT), pyStr(t1), jsonEncode({'payout': payout, 'model': 'fixed_time'}),
            jsonEncode(result), reasons.isEmpty ? 1 : 0, jsonEncode(reasons), utcnow(),
          ]);
      final r = x.lastInsertRowId;
      if (s['status'] == 'draft') x.execute("UPDATE strategies SET status='testing', updated_at=? WHERE id=?", [utcnow(), id]);
      audit(x, 'system', 'strategy.backtest', {'strategy_id': id, 'run_id': r, 'qualifies': reasons.isEmpty});
      return r;
    });
    return {'run_id': rid, 'qualifies': reasons.isEmpty, 'gate_reasons': reasons, 'synthetic': synthetic, ...result};
  }

  Map<String, dynamic> approve(int id) {
    final s = get(id);
    final latest = s['latest_backtest'] as Map?;
    if (latest == null) {
      throw EngineException(409, 'strategy does not qualify for approval', reasons: ['no_backtest_for_current_version']);
    }
    if (latest['qualifies'] != 1 && latest['qualifies'] != true) {
      throw EngineException(409, 'strategy does not qualify for approval', reasons: (latest['gate_reasons'] as List).cast<String>());
    }
    db.session((x) {
      x.execute("UPDATE strategies SET status='approved', approved_at=?, updated_at=? WHERE id=?", [utcnow(), utcnow(), id]);
      audit(x, 'user', 'strategy.approve', {'strategy_id': id, 'run_id': latest['id'], 'version': s['version']});
    });
    return get(id);
  }

  Map<String, dynamic> retire(int id) {
    get(id);
    db.session((x) {
      x.execute("UPDATE strategies SET status='retired', updated_at=? WHERE id=?", [utcnow(), id]);
      audit(x, 'user', 'strategy.retire', {'strategy_id': id});
    });
    return get(id);
  }

  List<Map<String, dynamic>> compare(List<int> ids, int datasetId, {double payout = 0.85}) {
    final rows = <Map<String, dynamic>>[];
    for (final sid in ids) {
      final r = backtest(sid, datasetId, payout: payout);
      final oos = r['out_of_sample'] as Map;
      rows.add({
        'strategy_id': sid, 'name': get(sid)['name'], 'run_id': r['run_id'], 'qualifies': r['qualifies'],
        'gate_reasons': r['gate_reasons'],
        for (final k in const ['trades', 'win_rate', 'win_rate_ci95', 'expectancy_per_trade', 'profit_factor', 'max_drawdown_units', 'significant_edge'])
          k: oos[k],
      });
    }
    return stableSorted(rows, (a, b) {
      final ea = a['expectancy_per_trade'] as num?, eb = b['expectancy_per_trade'] as num?;
      return compareKeys([ea == null ? 1 : 0, -(ea ?? 0)], [eb == null ? 1 : 0, -(eb ?? 0)]);
    });
  }

  List<Map<String, dynamic>> catalog() => [
        for (final e in cnd.catalog.entries) {'id': e.key, 'params': e.value.params, 'ar': e.value.ar, 'en': e.value.en}
      ];
}

// ---------------------------------------------------------------- statistics
const minGroup = 10;
const minReview = 30;

Map<String, dynamic> _rate(List<Map<String, dynamic>> rows) {
  final wins = rows.where((r) => r['outcome'] == 'win').length;
  final losses = rows.where((r) => r['outcome'] == 'loss').length;
  final decided = wins + losses;
  final (lo, hi) = bt.wilson(wins, decided);
  final pnl = [for (final r in rows) if (r['pnl'] != null) (r['pnl'] as num).toDouble()];
  return {
    'trades': rows.length, 'wins': wins, 'losses': losses, 'draws': rows.where((r) => r['outcome'] == 'draw').length,
    'cancelled': rows.where((r) => r['outcome'] == 'cancelled').length, 'decided': decided,
    'win_rate': decided > 0 ? roundTo(wins / decided, 4) : null,
    'win_rate_ci95': decided > 0 ? [roundTo(lo, 4), roundTo(hi, 4)] : null,
    'pnl_total': pnl.isEmpty ? null : roundTo(pnl.reduce((a, b) => a + b), 2), 'sufficient_sample': decided >= minGroup,
  };
}

String _bucket(Object? v) {
  if (v == null) return 'unknown';
  final x = (v as num).toDouble();
  var lo = 0.0;
  for (final e in const [0.5, 0.6, 0.7, 0.8, 0.9]) {
    if (x < e) return '${lo.toStringAsFixed(1)}-${e.toStringAsFixed(1)}';
    lo = e;
  }
  return '${lo.toStringAsFixed(1)}-1.0';
}

String _hour(Object? ts) {
  final t = DateTime.tryParse('${ts ?? ''}'.replaceAll('Z', '+00:00'));
  return t == null ? 'unknown' : t.toUtc().hour.toString().padLeft(2, '0');
}

class StatsService {
  StatsService(this.db);
  final LocalDb db;

  List<Map<String, dynamic>> _results(String account) => db.session((d) => [
        for (final r in d.select(
            'SELECT r.*, s.name AS strategy_name FROM trade_results r LEFT JOIN strategies s ON s.id=r.strategy_id '
            'WHERE r.account_type=? ORDER BY r.id',
            [account]))
          rowToMap(r)
      ]);

  static List<Map<String, dynamic>> _group(List<Map<String, dynamic>> rows, String Function(Map<String, dynamic>) key) {
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      groups.putIfAbsent(key(r), () => []).add(r);
    }
    final out = [for (final e in groups.entries) {'key': e.key, ..._rate(e.value)}];
    return stableSorted(out, (a, b) => compareKeys([-(a['decided'] as int), a['key'] as String], [-(b['decided'] as int), b['key'] as String]));
  }

  Map<String, dynamic> dashboard(String account) {
    if (!accountTypes.contains(account)) throw badRequest('account_type must be one of $accountTypes');
    final rows = _results(account);
    final (sig, runs) = db.session((d) => (
          {for (final r in d.select('SELECT signal, count(*) AS n FROM signals GROUP BY signal')) r['signal']: r['n'] as int},
          [
            for (final r in d.select(
                'SELECT b.id, b.strategy_id, s.name AS strategy_name, b.strategy_version, b.dataset, b.qualifies, b.created_at, '
                'b.metrics_json FROM backtest_runs b LEFT JOIN strategies s ON s.id=b.strategy_id ORDER BY b.id DESC LIMIT 20'))
              rowToMap(r)
          ]
        ));
    final training = [
      for (final r in runs)
        () {
          final m = ((r['metrics'] as Map?)?['out_of_sample'] as Map?) ?? const {};
          return {
            'id': r['id'], 'strategy_id': r['strategy_id'], 'strategy_name': r['strategy_name'], 'version': r['strategy_version'],
            'dataset': r['dataset'], 'qualifies': r['qualifies'] == 1, 'created_at': r['created_at'], 'oos_trades': m['trades'],
            'oos_expectancy': m['expectancy_per_trade'], 'oos_win_rate': m['win_rate'],
          };
        }()
    ];
    return {
      'account_type': account,
      'signals': {
        'total': sig.values.fold(0, (a, b) => a + b), 'BUY': sig['BUY'] ?? 0, 'SELL': sig['SELL'] ?? 0, 'WAIT': sig['WAIT'] ?? 0,
      },
      'results': _rate(rows),
      'by_strategy': _group(rows, (r) => (r['strategy_name'] as String?) ?? 'manual / none'),
      'by_asset': _group(rows, (r) => '${r['asset']}'),
      'by_timeframe': _group(rows, (r) => '${r['timeframe_sec']}s'),
      'by_condition': _group(rows, (r) => (r['market_condition'] as String?) ?? 'unknown'),
      'by_direction': _group(rows, (r) => '${r['signal_type']}'),
      'by_hour': _group(rows, (r) => _hour(r['signal_time'])),
      'by_confidence': _group(rows, (r) => _bucket(r['confidence'])),
      'by_data_quality': _group(rows, (r) => _bucket(r['data_quality'])),
      'training_log': training,
      'min_group_sample': minGroup,
    };
  }

  List<Map<String, dynamic>> insights(String account) {
    final d = dashboard(account);
    final overall = d['results'] as Map;
    final out = <Map<String, dynamic>>[];
    if ((overall['decided'] as int) < minGroup) {
      return [{'code': 'insufficient_sample', 'sample': overall['decided'], 'needed': minGroup}];
    }
    final base = (overall['win_rate'] as num).toDouble();
    void compare(String group, String better, String worse) {
      for (final g in (d[group] as List).cast<Map<String, dynamic>>()) {
        if (g['sufficient_sample'] != true || g['key'] == 'unknown') continue;
        final ci = (g['win_rate_ci95'] as List).cast<num>();
        // only differences outside the group's own 95% interval are reported
        if (ci[0] > base) {
          out.add({'code': better, 'group': group, 'key': g['key'], 'win_rate': g['win_rate'], 'ci95': g['win_rate_ci95'], 'sample': g['decided'], 'overall': base});
        } else if (ci[1] < base) {
          out.add({'code': worse, 'group': group, 'key': g['key'], 'win_rate': g['win_rate'], 'ci95': g['win_rate_ci95'], 'sample': g['decided'], 'overall': base});
        }
      }
    }

    compare('by_strategy', 'strategy_better', 'strategy_worse');
    compare('by_condition', 'condition_better', 'condition_worse');
    compare('by_asset', 'asset_better', 'asset_worse');
    compare('by_hour', 'hour_better', 'hour_worse');
    compare('by_data_quality', 'quality_better', 'quality_worse');
    final conf = stableSorted(
        [for (final g in (d['by_confidence'] as List).cast<Map<String, dynamic>>()) if (g['sufficient_sample'] == true && g['key'] != 'unknown') g],
        (a, b) => (a['key'] as String).compareTo(b['key'] as String));
    if (conf.length >= 2) {
      var ordered = true;
      for (var i = 1; i < conf.length; i++) {
        if ((conf[i - 1]['win_rate'] as num) > (conf[i]['win_rate'] as num)) ordered = false;
      }
      out.add({
        'code': ordered ? 'confidence_consistent' : 'confidence_inconsistent',
        'buckets': [for (final g in conf) {'key': g['key'], 'win_rate': g['win_rate'], 'sample': g['decided']}],
      });
    }
    final rows = _results(account);
    var streak = 0, longest = 0;
    for (final r in rows) {
      if (r['outcome'] == 'loss') {
        streak++;
        longest = math.max(longest, streak);
      } else if (r['outcome'] == 'win') {
        streak = 0;
      }
    }
    if (longest >= 5) out.add({'code': 'losing_streak', 'length': longest});
    final losses = rows.where((r) => r['outcome'] == 'loss').toList();
    if (losses.length >= minGroup) {
      for (final field in const ['market_condition', 'asset', 'strategy_name']) {
        final counts = <String, int>{};
        for (final r in losses) {
          final k = (r[field] as String?) ?? 'unknown';
          counts[k] = (counts[k] ?? 0) + 1;
        }
        var key = counts.keys.first, n = counts[key]!;
        for (final e in counts.entries) {
          if (e.value > n) (key, n) = (e.key, e.value);
        }
        final totalWithKey =
            rows.where((r) => ((r[field] as String?) ?? 'unknown') == key && (r['outcome'] == 'win' || r['outcome'] == 'loss')).length;
        final share = n / losses.length;
        if (key != 'unknown' && share >= 0.6 && totalWithKey > 0 && n / totalWithKey > 1 - base) {
          out.add({'code': 'losses_concentrated', 'field': field, 'key': key, 'share': roundTo(share, 2), 'losses': n});
        }
      }
    }
    out.addAll(_strategyReviews(rows));
    return out;
  }

  List<Map<String, dynamic>> _strategyReviews(List<Map<String, dynamic>> rows) => db.session((d) {
        final out = <Map<String, dynamic>>[];
        for (final s in d.select("SELECT id, name, version FROM strategies WHERE status='approved'")) {
          final m = _rate([for (final r in rows) if (r['strategy_id'] == s['id']) r]);
          final run = d.select(
              'SELECT metrics_json FROM backtest_runs WHERE strategy_id=? AND strategy_version=? AND qualifies=1 ORDER BY id DESC LIMIT 1',
              [s['id'], s['version']]);
          if (run.isEmpty) continue;
          final oos = (jsonDecode(run.first['metrics_json'] as String) as Map)['out_of_sample'] as Map;
          if ((m['decided'] as int) < minReview) {
            out.add({'code': 'strategy_review_pending_sample', 'strategy_id': s['id'], 'name': s['name'], 'sample': m['decided'], 'needed': minReview});
            continue;
          }
          final oosCi = oos['win_rate_ci95'] as List?;
          if (oosCi != null && ((m['win_rate_ci95'] as List)[1] as num) < (oosCi[0] as num)) {
            out.add({
              'code': 'strategy_review_suggested', 'strategy_id': s['id'], 'name': s['name'], 'live_win_rate': m['win_rate'],
              'live_ci95': m['win_rate_ci95'], 'sample': m['decided'], 'backtest_win_rate': oos['win_rate'], 'backtest_ci95': oosCi,
            });
          }
        }
        return out;
      });
}
