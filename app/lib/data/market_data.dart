/// Real historical prices from public sources, downloaded on the user's own device and only after the user
/// allowed external data sources. Only the asset name and dates are sent — nothing about the user.
///
/// * Dukascopy (forex, metals): tick files (`.bi5`, LZMA) aggregated into candles of any timeframe.
/// * Binance (crypto): public klines; sub-minute timeframes are built from 1-second klines.
///
/// The result is a CSV in the engine's import format (time,open,high,low,close[,volume]) — real data, so a
/// strategy tested on it can qualify for approval (unlike synthetic practice data).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

class MarketAsset {
  const MarketAsset(this.symbol, this.ar, this.en, this.source, {this.pointDivisor = 100000});
  final String symbol;
  final String ar, en;
  final String source; // dukascopy | binance
  final int pointDivisor; // Dukascopy integer price scale
}

const marketAssets = <MarketAsset>[
  MarketAsset('EURUSD', 'يورو / دولار', 'EUR/USD', 'dukascopy'),
  MarketAsset('GBPUSD', 'جنيه / دولار', 'GBP/USD', 'dukascopy'),
  MarketAsset('USDJPY', 'دولار / ين', 'USD/JPY', 'dukascopy', pointDivisor: 1000),
  MarketAsset('AUDUSD', 'دولار أسترالي / دولار', 'AUD/USD', 'dukascopy'),
  MarketAsset('USDCAD', 'دولار / دولار كندي', 'USD/CAD', 'dukascopy'),
  MarketAsset('EURJPY', 'يورو / ين', 'EUR/JPY', 'dukascopy', pointDivisor: 1000),
  MarketAsset('XAUUSD', 'ذهب / دولار', 'Gold / USD', 'dukascopy', pointDivisor: 1000),
  MarketAsset('BTCUSDT', 'بيتكوين', 'Bitcoin', 'binance'),
  MarketAsset('ETHUSDT', 'إيثريوم', 'Ethereum', 'binance'),
];

class MarketDataException implements Exception {
  MarketDataException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef Progress = void Function(double fraction);

/// One aggregated candle.
class Bar {
  Bar(this.time, this.open, this.high, this.low, this.close, this.volume);
  final int time; // epoch seconds, start of the candle
  double open, high, low, close, volume;
}

/// Decode a Dukascopy `.bi5` hour file: LZMA ("alone" format) of 20-byte big-endian records
/// (ms offset int32, ask int32, bid int32, ask volume float32, bid volume float32).
List<(int msOffset, double bid, double volume)> decodeBi5(Uint8List data, int pointDivisor) {
  if (data.isEmpty) return const []; // no ticks in that hour (weekend, holiday)
  if (data.length < 13) throw MarketDataException('corrupt tick file');
  final props = data[0];
  final dictSize = data[1] | (data[2] << 8) | (data[3] << 16) | (data[4] << 24);
  var size = 0;
  for (var i = 0; i < 8; i++) {
    size |= data[5 + i] << (8 * i);
  }
  // size -1 = unknown (the stream then ends with an end marker): decode up to a generous bound
  final known = size != -1;
  if (known && (size <= 0 || size > 64 * 1024 * 1024)) throw MarketDataException('unexpected tick file size');
  final bound = known ? size : (data.length * 40).clamp(4096, 64 * 1024 * 1024);
  final decoder = LzmaDecoder()
    ..dictionaryLimit = dictSize < 4096 ? 4096 : dictSize
    ..reset(literalContextBits: props % 9, literalPositionBits: props ~/ 9 % 5, positionBits: props ~/ 45, resetDictionary: true);
  final Uint8List raw;
  try {
    raw = decoder.decode(InputMemoryStream(data.sublist(13)), bound);
  } catch (e) {
    throw MarketDataException('corrupt tick file: $e');
  }
  final bd = ByteData.sublistView(raw);
  return [
    for (var o = 0; o + 20 <= raw.length; o += 20)
      (bd.getInt32(o), bd.getInt32(o + 8) / pointDivisor, bd.getFloat32(o + 16).toDouble())
  ];
}

/// Group (epoch-ms, price, volume) ticks into candles of `timeframeSec`.
List<Bar> aggregateTicks(Iterable<(int ms, double price, double volume)> ticks, int timeframeSec) {
  final bars = <Bar>[];
  for (final (ms, p, v) in ticks) {
    final t = (ms ~/ 1000) ~/ timeframeSec * timeframeSec;
    if (bars.isNotEmpty && bars.last.time == t) {
      final b = bars.last;
      if (p > b.high) b.high = p;
      if (p < b.low) b.low = p;
      b.close = p;
      b.volume += v;
    } else if (bars.isEmpty || t > bars.last.time) {
      bars.add(Bar(t, p, p, p, p, v));
    }
  }
  return bars;
}

/// Merge finer candles (e.g. 1-second klines) into `timeframeSec` candles.
List<Bar> aggregateBars(Iterable<Bar> fine, int timeframeSec) {
  final out = <Bar>[];
  for (final f in fine) {
    final t = f.time ~/ timeframeSec * timeframeSec;
    if (out.isNotEmpty && out.last.time == t) {
      final b = out.last;
      if (f.high > b.high) b.high = f.high;
      if (f.low < b.low) b.low = f.low;
      b.close = f.close;
      b.volume += f.volume;
    } else if (out.isEmpty || t > out.last.time) {
      out.add(Bar(t, f.open, f.high, f.low, f.close, f.volume));
    }
  }
  return out;
}

/// Append `more` (later in time) to `bars`, merging a candle that spans both (timeframes above one hour).
void mergeBars(List<Bar> bars, List<Bar> more) {
  for (final b in more) {
    if (bars.isNotEmpty && bars.last.time == b.time) {
      final x = bars.last;
      if (b.high > x.high) x.high = b.high;
      if (b.low < x.low) x.low = b.low;
      x.close = b.close;
      x.volume += b.volume;
    } else if (bars.isEmpty || b.time > bars.last.time) {
      bars.add(b);
    }
  }
}

String barsToCsv(List<Bar> bars, {bool volume = true}) {
  final b = StringBuffer(volume ? 'time,open,high,low,close,volume\n' : 'time,open,high,low,close\n');
  for (final x in bars) {
    b.write('${x.time},${x.open},${x.high},${x.low},${x.close}');
    if (volume) b.write(',${x.volume}');
    b.write('\n');
  }
  return b.toString();
}

class MarketDataClient {
  MarketDataClient({http.Client? client}) : _http = client ?? http.Client();
  final http.Client _http;
  bool _cancelled = false;
  void cancel() => _cancelled = true;

  Future<http.Response> _get(Uri u) async {
    for (var attempt = 0;; attempt++) {
      try {
        final r = await _http.get(u, headers: {'User-Agent': 'UATA'}).timeout(const Duration(seconds: 30));
        if (r.statusCode == 200 || r.statusCode == 404) return r;
        if (attempt >= 2) throw MarketDataException('download failed (${r.statusCode}) for ${u.host}');
      } on MarketDataException {
        rethrow;
      } catch (e) {
        if (attempt >= 2) throw MarketDataException('no connection to ${u.host}: $e');
      }
      await Future<void>.delayed(Duration(seconds: 1 + attempt * 2));
    }
  }

  /// Candles of `timeframeSec` for the last `days` days (complete hours / candles only), as CSV.
  Future<String> download(MarketAsset asset, int timeframeSec, {int days = 14, DateTime? until, Progress? onProgress}) async {
    _cancelled = false;
    final end = (until ?? DateTime.now().toUtc()).toUtc();
    final start = end.subtract(Duration(days: days));
    final bars = asset.source == 'dukascopy'
        ? await _dukascopy(asset, timeframeSec, start, end, onProgress)
        : await _binance(asset, timeframeSec, start, end, onProgress);
    if (bars.length < 100) throw MarketDataException('too little data returned (${bars.length} candles) — try a longer period');
    return barsToCsv(bars, volume: true);
  }

  Future<List<Bar>> _dukascopy(MarketAsset a, int tf, DateTime start, DateTime end, Progress? onProgress) async {
    final hours = <DateTime>[];
    for (var h = DateTime.utc(start.year, start.month, start.day, start.hour);
        h.isBefore(end.subtract(const Duration(hours: 1)));
        h = h.add(const Duration(hours: 1))) {
      if (h.weekday == DateTime.saturday) continue; // the market is closed: skip the empty files
      hours.add(h);
    }
    final bars = <Bar>[];
    const parallel = 6;
    for (var i = 0; i < hours.length; i += parallel) {
      if (_cancelled) throw MarketDataException('cancelled');
      final batch = hours.sublist(i, i + parallel > hours.length ? hours.length : i + parallel);
      final files = await Future.wait(batch.map((h) => _get(Uri.parse('https://datafeed.dukascopy.com/datafeed/${a.symbol}/'
          '${h.year}/${(h.month - 1).toString().padLeft(2, '0')}/${h.day.toString().padLeft(2, '0')}/'
          '${h.hour.toString().padLeft(2, '0')}h_ticks.bi5'))));
      for (var k = 0; k < batch.length; k++) {
        if (files[k].statusCode != 200) continue;
        final base = batch[k].millisecondsSinceEpoch;
        // aggregate each hour right away (a phone must not hold millions of ticks)
        final hourBars = aggregateTicks([for (final (ms, bid, vol) in decodeBi5(files[k].bodyBytes, a.pointDivisor)) (base + ms, bid, vol)], tf);
        mergeBars(bars, hourBars);
      }
      onProgress?.call((i + batch.length) / hours.length);
    }
    // the last candle may still be forming at download time
    return bars.isEmpty ? bars : bars.sublist(0, bars.length - 1);
  }

  static const _binanceIntervals = {60: '1m', 180: '3m', 300: '5m', 900: '15m', 1800: '30m', 3600: '1h', 14400: '4h', 86400: '1d'};

  Future<List<Bar>> _binance(MarketAsset a, int tf, DateTime start, DateTime end, Progress? onProgress) async {
    final interval = _binanceIntervals[tf] ?? '1s';
    final stepSec = interval == '1s' ? 1 : tf;
    final bars = <Bar>[];
    var from = start.millisecondsSinceEpoch;
    final to = end.millisecondsSinceEpoch;
    while (from < to) {
      if (_cancelled) throw MarketDataException('cancelled');
      final r = await _get(Uri.https('data-api.binance.vision', '/api/v3/klines',
          {'symbol': a.symbol, 'interval': interval, 'startTime': '$from', 'endTime': '$to', 'limit': '1000'}));
      final rows = jsonDecode(r.body) as List;
      if (rows.isEmpty) break;
      final chunk = [
        for (final k in rows.cast<List>())
          Bar((k[0] as int) ~/ 1000, double.parse(k[1] as String), double.parse(k[2] as String),
              double.parse(k[3] as String), double.parse(k[4] as String), double.parse(k[5] as String))
      ];
      mergeBars(bars, interval == '1s' ? aggregateBars(chunk, tf) : chunk); // 1-second klines → candles right away
      from = ((rows.last as List)[0] as int) + stepSec * 1000;
      onProgress?.call(((from - start.millisecondsSinceEpoch) / (to - start.millisecondsSinceEpoch)).clamp(0, 1).toDouble());
    }
    return bars.isEmpty ? bars : bars.sublist(0, bars.length - 1);
  }

  void close() => _http.close();
}
