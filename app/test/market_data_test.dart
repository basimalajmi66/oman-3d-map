import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uata_app/data/market_data.dart';

void main() {
  group('Dukascopy tick files', () {
    for (final f in ['ticks_known_size.bi5', 'ticks_unknown_size.bi5']) {
      test('decodes $f', () {
        final t = decodeBi5(File('test/fixtures/$f').readAsBytesSync(), 100000);
        expect(t.map((x) => x.$1), [1000, 15000, 31000]);
        expect(t.map((x) => x.$2), [1.0851, 1.0853, 1.0849]); // bid
        expect(t.last.$3, 0.75);
      });
    }

    test('empty hour = no ticks; garbage is refused', () {
      expect(decodeBi5(Uint8List(0), 100000), isEmpty);
      expect(() => decodeBi5(Uint8List.fromList(List.filled(40, 7)), 100000), throwsA(isA<MarketDataException>()));
    });
  });

  test('ticks → 30-second candles (open/high/low/close/volume)', () {
    final base = DateTime.utc(2026, 11, 2, 10).millisecondsSinceEpoch;
    final bars = aggregateTicks([
      (base + 1000, 1.10, 1.0), (base + 15000, 1.12, 1.0), (base + 29999, 1.09, 1.0), // candle 1
      (base + 30000, 1.11, 2.0), (base + 59000, 1.13, 1.0), // candle 2
    ], 30);
    expect(bars, hasLength(2));
    expect([bars[0].open, bars[0].high, bars[0].low, bars[0].close, bars[0].volume], [1.10, 1.12, 1.09, 1.09, 3.0]);
    expect(bars[1].time - bars[0].time, 30);
    expect([bars[1].open, bars[1].close], [1.11, 1.13]);
  });

  test('candles spanning two hour files are merged (4h timeframe)', () {
    final a = aggregateTicks([(0, 1.0, 1.0), (3599000, 1.2, 1.0)], 14400);
    final b = aggregateTicks([(3600000, 0.9, 1.0), (7199000, 1.1, 1.0)], 14400);
    final bars = <Bar>[];
    mergeBars(bars, a);
    mergeBars(bars, b);
    expect(bars, hasLength(1));
    expect([bars[0].open, bars[0].high, bars[0].low, bars[0].close], [1.0, 1.2, 0.9, 1.1]);
  });

  test('Binance: 1-second klines become 30-second candles; only symbol and dates are sent', () async {
    final seen = <Uri>[];
    final t0 = DateTime.utc(2026, 11, 2).millisecondsSinceEpoch;
    final client = MockClient((req) async {
      seen.add(req.url);
      final start = int.parse(req.url.queryParameters['startTime']!);
      if (start >= t0 + 200 * 30000) return http.Response('[]', 200);
      final rows = [
        for (var i = 0; i < 1000; i++)
          [start + i * 1000, '${100 + i}', '${101 + i}', '${99 + i}', '${100.5 + i}', '2', 0, '0', 0, '0', '0', '0']
      ];
      return http.Response(jsonEncode(rows), 200);
    });
    final csv = await MarketDataClient(client: client).download(marketAssets.firstWhere((a) => a.symbol == 'BTCUSDT'), 30,
        days: 1, until: DateTime.fromMillisecondsSinceEpoch(t0, isUtc: true).add(const Duration(days: 1)));
    final lines = const LineSplitter().convert(csv);
    expect(lines.first, 'time,open,high,low,close,volume');
    final first = lines[1].split(',');
    expect(int.parse(first[0]) % 30, 0);
    expect(double.parse(first[5]), 60); // 30 one-second klines × volume 2
    for (final u in seen) {
      expect(u.host, 'data-api.binance.vision');
      expect(u.queryParameters.keys.toSet(), {'symbol', 'interval', 'startTime', 'endTime', 'limit'});
      expect(u.queryParameters['interval'], '1s');
    }
  });

  test('a busy server (503) is retried patiently; a refused request (403) is not', () async {
    var calls = 0;
    final busy = MockClient((req) async => ++calls < 3 ? http.Response('busy', 503) : http.Response('[]', 200));
    final c = MarketDataClient(client: busy, backoff: (_) => Duration.zero);
    await expectLater(c.download(marketAssets.firstWhere((a) => a.symbol == 'BTCUSDT'), 60, days: 1),
        throwsA(predicate((e) => e is MarketDataException && e.message.contains('too little data'))));
    expect(calls, 3); // two busy answers, then success (empty) — no error from the retries themselves
    var refused = 0;
    final forbidden = MockClient((req) async {
      refused++;
      return http.Response('no', 403);
    });
    await expectLater(MarketDataClient(client: forbidden, backoff: (_) => Duration.zero).download(marketAssets.firstWhere((a) => a.symbol == 'BTCUSDT'), 60, days: 1),
        throwsA(predicate((e) => e is MarketDataException && e.message.contains('403'))));
    expect(refused, 1);
  });

  test('Dukascopy: a few missing hours are tolerated, a dead service is reported', () async {
    final hourBytes = File('test/fixtures/ticks_known_size.bi5').readAsBytesSync();
    var n = 0;
    final flaky = MockClient((req) async => (++n % 40 == 0) ? http.Response('busy', 503) : http.Response.bytes(hourBytes, 200));
    final until = DateTime.utc(2026, 11, 6, 12); // a Friday: no Saturday skip inside the window
    final csv = await MarketDataClient(client: flaky, backoff: (_) => Duration.zero).download(marketAssets.first, 30, days: 4, until: until);
    expect(csv.split('\n').where((l) => l.isNotEmpty).length - 1, greaterThan(100));
    final dead = MockClient((req) async => http.Response('down', 503));
    await expectLater(MarketDataClient(client: dead, backoff: (_) => Duration.zero).download(marketAssets.first, 30, days: 4, until: until),
        throwsA(predicate((e) => e is MarketDataException && e.message.contains('not answering'))));
  });
}
