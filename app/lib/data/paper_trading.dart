/// Automatic PAPER trading (forward test): no real money, no broker connection — nothing is ever executed.
///
/// From the moment a session starts, every new closed candle of real market data (Dukascopy / Binance) is checked
/// against the chosen strategies with exactly the backtest mechanics: signal on a closed candle, entry at the next
/// candle's open, exit at the close `duration` later, one trade at a time per strategy, fixed payout. Each finished
/// virtual trade is recorded as a SIMULATION result (never mixed with demo or real).
///
/// The app does not have to stay open: on every update the session catches up from where it stopped and gets
/// exactly the same trades it would have had live (the data is history by then). Updates are idempotent.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../core/engine_api.dart';
import '../engine/strategy/backtest.dart' show wilson;
import '../engine/strategy/conditions.dart' as cnd;
import '../engine/strategy/features.dart';
import 'market_data.dart';

/// Quiet slots (no ticks) inside a trading session are filled with flat candles so candle index == time; longer
/// gaps (market closed) are not filled and trades across them are void.
const maxFilledGapSlots = 10;
const warmupCandles = 300;

class PaperTrade {
  PaperTrade(this.signalIndex, this.side, this.entry, this.exit, this.outcome, this.signalTime, this.condition);
  final int signalIndex;
  final String side;
  final double entry, exit;
  final String outcome;
  final int signalTime; // epoch seconds: close of the signal candle
  final String condition;
}

/// Forward trades of one strategy on `fs` (candle open times `times`), considering only signals on candles that
/// opened at or after `startTime`. Returns finished trades and the candle index of a signal whose trade is still
/// waiting for its expiry (null when none).
(List<PaperTrade>, int?) forwardTrades(FeatureSet fs, List<int> times, Map definition, int timeframeSec, int startTime) {
  final bars = math.max(1, ((definition['duration_sec'] as num) / timeframeSec).ceil());
  final out = <PaperTrade>[];
  var i = times.indexWhere((t) => t >= startTime);
  if (i < 0) return (out, null);
  while (i < fs.n) {
    final side = cnd.signalAt(fs, i, definition);
    if (side == null) {
      i++;
      continue;
    }
    if (i + bars >= fs.n) return (out, i); // signal seen, expiry candle not closed yet
    final eBar = i + 1, xBar = i + bars;
    if (times[xBar] - times[i] != bars * timeframeSec) {
      i++; // the market closed inside this trade: void, not counted
      continue;
    }
    final entry = fs.o[eBar], exit = fs.c[xBar];
    final move = side == 'BUY' ? exit - entry : entry - exit;
    out.add(PaperTrade(i, side, entry, exit, move > 0 ? 'win' : move < 0 ? 'loss' : 'draw', times[i] + timeframeSec,
        fs.marketCondition(i)));
    i = xBar; // one trade at a time, next decision on the expiry candle's close
  }
  return (out, null);
}

/// What a background check found: a fresh signal (the user may act on it) or a finished virtual trade.
class PaperEvent {
  PaperEvent.signal(this.session, this.strategyId, this.strategyName, this.side, this.durationSec, this.signalTime, this.ageSec)
      : outcome = null,
        pnl = null;
  PaperEvent.result(this.session, this.strategyId, this.strategyName, this.side, this.durationSec, this.signalTime,
      String this.outcome, double this.pnl)
      : ageSec = null;
  final PaperSession session;
  final int strategyId;
  final String strategyName;
  final String side; // BUY | SELL
  final int durationSec;
  final int signalTime; // epoch seconds: close of the signal candle (= when the trade would be entered)
  final int? ageSec; // signal: seconds between that close and the moment it was seen
  final String? outcome; // result: win | loss | draw
  final double? pnl;
  bool get isSignal => outcome == null;
}

/// A signal is only worth an alert while it can still be acted on: seen within half a candle (+15 s of data delay).
/// Older ones (e.g. forex prices, which the free source publishes an hour late) are never sent as "act now".
bool isFreshSignal(int ageSec, int timeframeSec) => ageSec >= 0 && ageSec <= timeframeSec ~/ 2 + 15;

/// Append newer candles, filling short quiet gaps with flat candles.
void mergeFeed(List<Bar> feed, List<Bar> fresh, int tf) {
  for (final b in fresh) {
    if (feed.isNotEmpty && b.time <= feed.last.time) continue;
    if (feed.isNotEmpty) {
      final gap = (b.time - feed.last.time) ~/ tf - 1;
      if (gap > 0 && gap <= maxFilledGapSlots) {
        final p = feed.last.close;
        for (var k = 1; k <= gap; k++) {
          feed.add(Bar(feed.last.time + tf, p, p, p, p, 0));
        }
      }
    }
    feed.add(b);
  }
}

class PaperSession {
  PaperSession({
    required this.id,
    required this.asset,
    required this.timeframeSec,
    required this.payout,
    required this.strategyIds,
    required this.startedAt,
    this.status = 'running',
    this.lastUpdate,
    this.lastError,
    this.waiting = 0,
    Map<String, Map<String, dynamic>>? trades,
    List<String>? alerted,
  })  : trades = trades ?? {},
        alerted = alerted ?? [];

  final String id;
  final String asset;
  final int timeframeSec;
  final double payout;
  final List<int> strategyIds;
  final int startedAt; // epoch seconds
  String status; // running | stopped
  String? lastUpdate;
  String? lastError;
  int waiting; // strategies with a trade waiting for its expiry
  final Map<String, Map<String, dynamic>> trades; // key → {strategy_id, name, side, outcome, pnl, time}
  final List<String> alerted; // signal keys already announced (never twice), newest last

  Map<String, dynamic> toJson() => {
        'id': id, 'asset': asset, 'timeframe_sec': timeframeSec, 'payout': payout, 'strategy_ids': strategyIds,
        'started_at': startedAt, 'status': status, 'last_update': lastUpdate, 'last_error': lastError, 'waiting': waiting,
        'trades': trades, 'alerted': alerted,
      };

  factory PaperSession.fromJson(Map j) => PaperSession(
        id: j['id'] as String,
        asset: j['asset'] as String,
        timeframeSec: j['timeframe_sec'] as int,
        payout: (j['payout'] as num).toDouble(),
        strategyIds: (j['strategy_ids'] as List).cast<int>(),
        startedAt: j['started_at'] as int,
        status: j['status'] as String? ?? 'running',
        lastUpdate: j['last_update'] as String?,
        lastError: j['last_error'] as String?,
        waiting: j['waiting'] as int? ?? 0,
        alerted: ((j['alerted'] as List?) ?? const []).cast<String>(),
        trades: {for (final e in ((j['trades'] as Map?) ?? const {}).entries) e.key as String: (e.value as Map).cast<String, dynamic>()},
      );

  /// Per-strategy results: trades, wins, losses, win rate with its 95% interval, net result in stakes.
  List<Map<String, dynamic>> summary() {
    final by = <int, List<Map<String, dynamic>>>{};
    for (final t in trades.values) {
      by.putIfAbsent(t['strategy_id'] as int, () => []).add(t);
    }
    return [
      for (final e in by.entries)
        () {
          final wins = e.value.where((t) => t['outcome'] == 'win').length;
          final losses = e.value.where((t) => t['outcome'] == 'loss').length;
          final (lo, hi) = wilson(wins, wins + losses);
          return {
            'strategy_id': e.key, 'name': e.value.last['name'], 'trades': e.value.length, 'wins': wins, 'losses': losses,
            'win_rate': wins + losses == 0 ? null : wins / (wins + losses),
            'ci95': wins + losses == 0 ? null : [lo, hi],
            'net': e.value.fold<double>(0, (s, t) => s + (t['pnl'] as num).toDouble()),
          };
        }()
    ]..sort((a, b) => (b['net'] as double).compareTo(a['net'] as double));
  }
}

class PaperTrader {
  PaperTrader(this.dir, {MarketDataClient Function()? client, DateTime Function()? now})
      : _client = client ?? MarketDataClient.new,
        _now = now ?? DateTime.now;
  final String dir;
  final MarketDataClient Function() _client;
  final DateTime Function() _now;
  bool _busy = false;

  File get _index => File('$dir/sessions.json');
  File _feed(String id) => File('$dir/feeds/$id.csv');

  List<PaperSession> sessions() {
    if (!_index.existsSync()) return [];
    try {
      return [for (final j in jsonDecode(_index.readAsStringSync()) as List) PaperSession.fromJson(j as Map)];
    } catch (_) {
      return [];
    }
  }

  void _save(List<PaperSession> all) {
    _index.parent.createSync(recursive: true);
    final tmp = File('${_index.path}.part')..writeAsStringSync(jsonEncode([for (final s in all) s.toJson()]));
    tmp.renameSync(_index.path);
  }

  void _put(PaperSession s) {
    final all = sessions();
    final i = all.indexWhere((x) => x.id == s.id);
    i >= 0 ? all[i] = s : all.insert(0, s);
    _save(all);
  }

  /// Save an update without undoing what the screen did meanwhile (the background service shares these files):
  /// a session stopped meanwhile stays stopped, a deleted one is not brought back. False if it was deleted.
  bool _putUpdate(PaperSession s) {
    final all = sessions();
    final i = all.indexWhere((x) => x.id == s.id);
    if (i < 0) return false;
    if (all[i].status == 'stopped') s.status = 'stopped';
    all[i] = s;
    _save(all);
    return true;
  }

  List<Bar> _loadFeed(String id) {
    final f = _feed(id);
    if (!f.existsSync()) return [];
    return [
      for (final line in f.readAsLinesSync().skip(1))
        if (line.trim().isNotEmpty)
          () {
            final v = line.split(',');
            return Bar(int.parse(v[0]), double.parse(v[1]), double.parse(v[2]), double.parse(v[3]), double.parse(v[4]), 0);
          }()
    ];
  }

  void _saveFeed(String id, List<Bar> feed) {
    final f = _feed(id)..parent.createSync(recursive: true);
    f.writeAsStringSync(barsToCsv(feed, volume: false));
  }

  Future<PaperSession> start(EngineApi api, MarketAsset asset, int timeframeSec, double payout, List<int> strategyIds) async {
    if (strategyIds.isEmpty) throw MarketDataException('choose at least one strategy');
    final now = _now().toUtc();
    final s = PaperSession(
        id: '${now.millisecondsSinceEpoch}',
        asset: asset.symbol,
        timeframeSec: timeframeSec,
        payout: payout,
        strategyIds: strategyIds,
        startedAt: now.millisecondsSinceEpoch ~/ 1000);
    _put(s);
    return update(api, s);
  }

  void stop(String id) {
    final s = sessions().firstWhere((x) => x.id == id);
    s.status = 'stopped';
    _put(s);
  }

  void delete(String id) {
    _save([for (final s in sessions()) if (s.id != id) s]);
    final f = _feed(id);
    if (f.existsSync()) f.deleteSync();
  }

  /// Download the new closed candles and record every virtual trade that finished. Safe to call any time.
  Future<PaperSession> update(EngineApi api, PaperSession s, {void Function(PaperEvent e)? onEvent}) async {
    final asset = marketAssets.firstWhere((a) => a.symbol == s.asset);
    final client = _client();
    try {
      final feed = _loadFeed(s.id);
      final now = _now().toUtc();
      final from = feed.isEmpty
          ? DateTime.fromMillisecondsSinceEpoch((s.startedAt - warmupCandles * s.timeframeSec) * 1000, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch((feed.last.time + s.timeframeSec) * 1000, isUtc: true);
      if (now.difference(from).inSeconds >= s.timeframeSec) {
        mergeFeed(feed, await client.fetchBars(asset, s.timeframeSec, from, now), s.timeframeSec);
        _saveFeed(s.id, feed);
      }
      s.waiting = 0;
      if (feed.length > warmupFeatures) {
        final fs = FeatureSet([for (final b in feed) b.open], [for (final b in feed) b.high], [for (final b in feed) b.low],
            [for (final b in feed) b.close]);
        final times = [for (final b in feed) b.time];
        for (final sid in s.strategyIds) {
          final Json strat;
          try {
            strat = await api.getStrategy(sid);
          } on EngineException {
            continue; // deleted meanwhile
          }
          final def = strat['definition'] as Map?;
          if (def == null) continue;
          final (trades, pending) = forwardTrades(fs, times, def, s.timeframeSec, s.startedAt);
          final duration = (def['duration_sec'] as num).toInt();
          final name = strat['name'] as String? ?? '#$sid';
          if (pending != null) {
            s.waiting++;
            final signalTime = times[pending] + s.timeframeSec;
            final key = '$sid:$signalTime';
            final age = now.millisecondsSinceEpoch ~/ 1000 - signalTime;
            if (!s.alerted.contains(key) && isFreshSignal(age, s.timeframeSec)) {
              s.alerted.add(key);
              if (s.alerted.length > 200) s.alerted.removeRange(0, s.alerted.length - 200);
              onEvent?.call(PaperEvent.signal(s, sid, name, cnd.signalAt(fs, pending, def)!, duration, signalTime, age));
            }
          }
          for (final t in trades) {
            final key = '$sid:${t.signalTime}';
            if (s.trades.containsKey(key)) continue;
            final pnl = t.outcome == 'win' ? s.payout : t.outcome == 'loss' ? -1.0 : 0.0;
            await api.addResult({
              'account_type': 'simulation', 'asset': s.asset, 'timeframe_sec': s.timeframeSec, 'strategy_id': sid,
              'signal_type': t.side, 'signal_time': _iso(t.signalTime), 'duration_sec': (def['duration_sec'] as num).toInt(),
              'outcome': t.outcome, 'pnl': pnl, 'market_condition': t.condition,
              'notes': 'paper-auto · ${asset.source == 'dukascopy' ? 'Dukascopy' : 'Binance'} · ${t.entry} → ${t.exit}',
            });
            s.trades[key] = {'strategy_id': sid, 'name': strat['name'], 'side': t.side, 'outcome': t.outcome, 'pnl': pnl, 'time': t.signalTime};
            if (!_putUpdate(s)) return s; // deleted meanwhile: record nothing more
            // after every recorded trade: an interruption can never record a trade twice
            onEvent?.call(PaperEvent.result(s, sid, name, t.side, duration, t.signalTime, t.outcome, pnl));
          }
        }
      }
      s.lastUpdate = _iso(now.millisecondsSinceEpoch ~/ 1000);
      s.lastError = null;
    } on MarketDataException catch (e) {
      s.lastError = e.message;
    } finally {
      client.close();
    }
    _putUpdate(s);
    return s;
  }

  /// Catch up every running session (called on app start and periodically). Never runs twice at once.
  Future<void> updateAll(EngineApi api, {void Function(PaperEvent e)? onEvent}) async {
    if (_busy) return;
    _busy = true;
    try {
      for (final s in sessions().where((x) => x.status == 'running')) {
        await update(api, s, onEvent: onEvent);
      }
    } finally {
      _busy = false;
    }
  }

  static String _iso(int epochSec) {
    final t = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000, isUtc: true);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:${two(t.second)}+00:00';
  }
}

/// Candles needed before features are meaningful (EMA50, ATR, MACD signal).
const warmupFeatures = warmup + 10;
