@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:uata_app/data/market_data.dart';
import 'package:uata_app/data/paper_trading.dart';
import 'package:uata_app/engine/local/local_engine_api.dart';
import 'package:uata_app/engine/strategy/backtest.dart';
import 'package:uata_app/engine/strategy/conditions.dart' as cnd;
import 'package:uata_app/engine/strategy/features.dart';

const tf = 30;
final t0 = DateTime.utc(2026, 11, 2, 8).millisecondsSinceEpoch ~/ 1000; // a Monday morning

/// A deterministic "market": one closed candle every 30 s from t0 - 1 day.
final market = () {
  final r = math.Random(5);
  final bars = <Bar>[];
  var p = 1.08;
  for (var i = 0; i < 4 * 2880; i++) {
    final o = p, c = o + (r.nextDouble() - 0.495) * 0.0004;
    bars.add(Bar(t0 - 86400 + i * tf, o, math.max(o, c) + 0.0001, math.min(o, c) - 0.0001, c, 1));
    p = c;
  }
  return bars;
}();

/// Serves the market like Dukascopy would: only candles closed by `to`.
class FakeMarket extends MarketDataClient {
  int calls = 0;
  @override
  Future<List<Bar>> fetchBars(MarketAsset asset, int timeframeSec, DateTime from, DateTime to, {Progress? onProgress}) async {
    calls++;
    final a = from.millisecondsSinceEpoch ~/ 1000, b = to.millisecondsSinceEpoch ~/ 1000;
    return [for (final x in market) if (x.time >= a && x.time + timeframeSec <= b) Bar(x.time, x.open, x.high, x.low, x.close, x.volume)];
  }
}

FeatureSet fsOf(List<Bar> b) => FeatureSet([for (final x in b) x.open], [for (final x in b) x.high], [for (final x in b) x.low], [for (final x in b) x.close]);

final defn = cnd.validateDefinition({
  'long': {'all': [{'id': 'bullish_candle'}, {'id': 'rsi_below', 'value': 55}]},
  'short': {'all': [{'id': 'bearish_candle'}, {'id': 'rsi_above', 'value': 45}]},
  'duration_sec': 120,
});

void main() {
  test('forward trades are exactly the backtest trades from the start candle (same mechanics, no look-ahead)', () {
    final bars = market.sublist(0, 3000);
    final fs = fsOf(bars);
    final times = [for (final b in bars) b.time];
    const start = 1200;
    final (fwd, pending) = forwardTrades(fs, times, defn, tf, times[start]);
    final bt = runBacktest(fs, defn, tf, start: start, inSample: 0.3);
    final all = [...(bt['trades_sample'] as List)]; // last 50 trades of the backtest
    expect(fwd.length, (bt['all'] as Map)['trades']);
    final tail = fwd.sublist(fwd.length - all.length);
    for (var k = 0; k < all.length; k++) {
      expect(tail[k].signalIndex, all[k]['signal_bar']);
      expect(tail[k].side, all[k]['side']);
      expect(tail[k].outcome, all[k]['outcome']);
    }
    expect(fwd.every((t) => t.signalIndex >= start), isTrue);
    expect(pending == null || pending >= start, isTrue);
  });

  test('a trade across a market close is void; short quiet gaps are filled with flat candles', () {
    final feed = <Bar>[];
    mergeFeed(feed, [Bar(0, 1, 1, 1, 1, 0), Bar(30, 1, 1.1, 0.9, 1.05, 0)], tf);
    mergeFeed(feed, [Bar(120, 1.05, 1.06, 1.04, 1.06, 0)], tf); // two quiet slots
    expect([for (final b in feed) b.time], [0, 30, 60, 90, 120]);
    expect(feed[2].close, 1.05);
    mergeFeed(feed, [Bar(120 + 3600, 1, 1, 1, 1, 0)], tf); // market closed for an hour: not filled
    expect(feed.length, 6);
    mergeFeed(feed, [Bar(30, 9, 9, 9, 9, 0)], tf); // older candles are ignored
    expect(feed.length, 6);
  });

  group('sessions on the phone engine', () {
    late Directory dir;
    late LocalEngine engine;
    late LocalEngineApi api;
    late int sid;
    setUp(() async {
      dir = Directory.systemTemp.createTempSync('uata_paper');
      engine = await LocalEngine.open('${dir.path}/engine', (v) => File('assets/schema/schema_v$v.sql').readAsString());
      api = LocalEngineApi(engine);
      sid = (await api.createStrategy('Paper test', defn))['id'] as int;
    });
    tearDown(() {
      engine.close();
      dir.deleteSync(recursive: true);
    });

    test('catching up once after a day = updating every 10 minutes; results recorded once, as simulation', () async {
      final asset = marketAssets.first;
      var now = DateTime.fromMillisecondsSinceEpoch(t0 * 1000, isUtc: true);
      final often = PaperTrader('${dir.path}/often', client: FakeMarket.new, now: () => now);
      final s1 = await often.start(api, asset, tf, 0.85, [sid]);
      expect(s1.trades, isEmpty); // nothing before the start
      for (var k = 0; k < 6 * 24; k++) {
        now = now.add(const Duration(minutes: 10));
        await often.update(api, often.sessions().single);
      }
      final frequent = often.sessions().single;

      final api2 = LocalEngineApi(await LocalEngine.open('${dir.path}/engine2', (v) => File('assets/schema/schema_v$v.sql').readAsString()));
      final sid2 = (await api2.createStrategy('Paper test', defn))['id'] as int;
      now = DateTime.fromMillisecondsSinceEpoch(t0 * 1000, isUtc: true);
      final once = PaperTrader('${dir.path}/once', client: FakeMarket.new, now: () => now);
      await once.start(api2, asset, tf, 0.85, [sid2]);
      now = now.add(const Duration(days: 1));
      final caught = await once.update(api2, once.sessions().single);

      expect(frequent.trades.length, greaterThan(50));
      expect({for (final t in caught.trades.values) '${t['time']}:${t['side']}:${t['outcome']}'},
          {for (final t in frequent.trades.values) '${t['time']}:${t['side']}:${t['outcome']}'});

      // recorded as simulation results, once each, even after extra updates
      await often.update(api, often.sessions().single);
      final results = await api.listResults(accountType: 'simulation'); // the newest 200
      expect(results.length, math.min(200, frequent.trades.length));
      expect(results.every((r) => (r['notes'] as String).startsWith('paper-auto')), isTrue);
      expect(await api.listResults(accountType: 'demo'), isEmpty); // never mixed
      expect(results.every((r) => DateTime.parse(r['signal_time'] as String).millisecondsSinceEpoch ~/ 1000 >= t0), isTrue);
      final dash = await api.dashboard('simulation');
      expect((dash['results'] as Map)['trades'], frequent.trades.length);
      final sum = frequent.summary().single;
      expect(sum['trades'], frequent.trades.length);
      expect(sum['wins'] + sum['losses'] <= sum['trades'], isTrue);
    });

    test('live: a fresh signal is announced once, at the candle close, and becomes the same trade later', () async {
      final asset = marketAssets.first;
      var now = DateTime.fromMillisecondsSinceEpoch((t0 + 5) * 1000, isUtc: true);
      final p = PaperTrader('${dir.path}/live', client: FakeMarket.new, now: () => now);
      await p.start(api, asset, tf, 0.85, [sid]);
      final events = <PaperEvent>[];
      for (var k = 0; k < 240; k++) {
        now = now.add(const Duration(seconds: tf)); // a check 5 s after every candle close
        await p.updateAll(api, onEvent: events.add);
        if (k % 7 == 0) await p.updateAll(api, onEvent: events.add); // an extra check: nothing announced twice
      }
      final signals = events.where((e) => e.isSignal).toList();
      expect(signals.length, greaterThan(10));
      expect(signals.every((e) => e.ageSec == 5), isTrue);
      expect({for (final e in signals) e.signalTime}.length, signals.length);
      final trades = p.sessions().single.trades;
      final settled = signals.where((e) => e.signalTime + e.durationSec < now.millisecondsSinceEpoch ~/ 1000 - tf);
      for (final e in settled) {
        expect(trades['$sid:${e.signalTime}']?['side'], e.side, reason: 'the alert matched the recorded trade');
      }
      expect(events.where((e) => !e.isSignal).length, trades.length);

      // catching up late (prices an hour behind) never sends an "act now" alert for old candles
      final late = <PaperEvent>[];
      var now2 = DateTime.fromMillisecondsSinceEpoch(t0 * 1000, isUtc: true);
      final q = PaperTrader('${dir.path}/late', client: _HourLate.new, now: () => now2);
      await q.start(api, asset, tf, 0.85, [sid]);
      now2 = now2.add(const Duration(hours: 3)); // the source only has candles up to an hour ago
      await q.updateAll(api, onEvent: late.add);
      expect(late.where((e) => e.isSignal), isEmpty);
      expect(late.where((e) => !e.isSignal), isNotEmpty);
      expect(isFreshSignal(30, 30), isTrue);
      expect(isFreshSignal(31, 30), isFalse);
      expect(isFreshSignal(165, 300), isTrue);
    });

    test('an update never undoes a stop or a delete made meanwhile (screen and service share the files)', () async {
      final asset = marketAssets.first;
      var now = DateTime.fromMillisecondsSinceEpoch(t0 * 1000, isUtc: true);
      final p = PaperTrader('${dir.path}/share', client: FakeMarket.new, now: () => now);
      final s = await p.start(api, asset, tf, 0.85, [sid]);
      final other = PaperTrader('${dir.path}/share', client: FakeMarket.new, now: () => now); // the other isolate
      other.stop(s.id);
      now = now.add(const Duration(hours: 1));
      await p.update(api, s); // s still says "running"
      expect(p.sessions().single.status, 'stopped');
      other.delete(s.id);
      await p.update(api, s);
      expect(p.sessions(), isEmpty);
    });

    test('stopping, deleting and data-service errors', () async {
      final asset = marketAssets.first;
      var now = DateTime.fromMillisecondsSinceEpoch(t0 * 1000, isUtc: true);
      final p = PaperTrader('${dir.path}/p', client: FakeMarket.new, now: () => now);
      final s = await p.start(api, asset, tf, 0.85, [sid]);
      p.stop(s.id);
      now = now.add(const Duration(hours: 3));
      await p.updateAll(api); // stopped sessions are not updated
      expect(p.sessions().single.trades, isEmpty);
      final failing = PaperTrader('${dir.path}/f', client: _Failing.new, now: () => now);
      final f = await failing.start(api, asset, tf, 0.85, [sid]);
      expect(f.lastError, contains('not answering'));
      p.delete(s.id);
      expect(p.sessions(), isEmpty);
      await expectLater(p.start(api, asset, tf, 0.85, []), throwsA(isA<MarketDataException>()));
    });
  });
}

/// Like the free forex source: candles become available about an hour after they close.
class _HourLate extends FakeMarket {
  @override
  Future<List<Bar>> fetchBars(MarketAsset asset, int timeframeSec, DateTime from, DateTime to, {Progress? onProgress}) =>
      super.fetchBars(asset, timeframeSec, from, to.subtract(const Duration(hours: 1)));
}

class _Failing extends MarketDataClient {
  @override
  Future<List<Bar>> fetchBars(MarketAsset asset, int timeframeSec, DateTime from, DateTime to, {Progress? onProgress}) async =>
      throw MarketDataException('the data service is not answering');
}
