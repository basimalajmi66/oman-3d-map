/// Historical price datasets: CSV import (the user's real data) and labelled synthetic data
/// (port of strategy/datasets.py). Synthetic data can never qualify a strategy for approval.
library;

import 'dart:math' as math;

import '../util.dart';

const timeCols = ['time', 'date', 'datetime', 'timestamp', 'date_time', 'open_time'];

class DatasetError implements Exception {
  DatasetError(this.message);
  final String message;
  @override
  String toString() => message;
}

class OhlcData {
  OhlcData(this.time, this.open, this.high, this.low, this.close, this.volume, this.timeframeSec);
  final List<double> time, open, high, low, close;
  final List<double>? volume;
  final int timeframeSec;
  int get rows => time.length;

  Map<String, dynamic> toJson() => {
        'time': time, 'open': open, 'high': high, 'low': low, 'close': close, 'volume': volume,
        'timeframe_sec': timeframeSec, 'rows': rows,
      };

  factory OhlcData.fromJson(Map j) {
    List<double> l(String k) => [for (final v in j[k] as List) (v as num).toDouble()];
    return OhlcData(l('time'), l('open'), l('high'), l('low'), l('close'), j['volume'] == null ? null : l('volume'),
        (j['timeframe_sec'] as num).toInt());
  }
}

final _patterns = <RegExp, DateTime Function(Match)>{
  // %Y-%m-%d %H:%M:%S / T / %Y.%m.%d, optional seconds
  RegExp(r'^(\d{4})[-.](\d{1,2})[-.](\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?$'): (m) => DateTime.utc(
      int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4] ?? '0'), int.parse(m[5] ?? '0'),
      int.parse(m[6] ?? '0')),
  // %d/%m/%Y %H:%M(:%S)
  RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4}) (\d{1,2}):(\d{2})(?::(\d{2}))?$'): (m) => DateTime.utc(int.parse(m[3]!),
      int.parse(m[2]!), int.parse(m[1]!), int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6] ?? '0')),
};

double parseTime(String s) {
  s = s.trim();
  final v = double.tryParse(s);
  if (v != null) return v > 1e11 ? v / 1000 : v; // epoch ms or s
  final noZ = s.replaceAll('Z', '');
  for (final e in _patterns.entries) {
    final m = e.key.firstMatch(noZ);
    if (m != null) return e.value(m).millisecondsSinceEpoch / 1000;
  }
  final iso = DateTime.tryParse(s);
  if (iso != null) return iso.millisecondsSinceEpoch / 1000;
  throw DatasetError("unrecognised time value: '$s'");
}

List<String> _splitCsvLine(String line, String delim) {
  final out = <String>[];
  final buf = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      if (quoted && i + 1 < line.length && line[i + 1] == '"') {
        buf.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (ch == delim && !quoted) {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  out.add(buf.toString());
  return out;
}

OhlcData parseCsv(String text, {int maxRows = 500000}) {
  final sample = text.substring(0, math.min(4096, text.length));
  final delim = ';'.allMatches(sample).length > ','.allMatches(sample).length ? ';' : ',';
  final lines = text.split(RegExp(r'\r?\n'));
  final header = lines.isEmpty
      ? <String>[]
      : [for (final h in _splitCsvLine(lines.first, delim)) h.trim().toLowerCase().replaceAll(RegExp(r'^<|>$'), '')];
  final idx = {for (final k in const ['open', 'high', 'low', 'close', 'volume']) if (header.contains(k)) k: header.indexOf(k)};
  final tc = timeCols.where(header.contains).map(header.indexOf).firstOrNull;
  final missing = [for (final k in const ['open', 'high', 'low', 'close']) if (!idx.containsKey(k)) k];
  if (missing.isNotEmpty || tc == null) {
    throw DatasetError('CSV needs a time column and open/high/low/close (missing: ${missing.isEmpty ? ['time'] : missing})');
  }
  final t = <double>[], o = <double>[], h = <double>[], l = <double>[], c = <double>[];
  final v = <double?>[];
  for (var r = 1; r < lines.length; r++) {
    final row = _splitCsvLine(lines[r], delim);
    if (row.every((x) => x.trim().isEmpty)) continue;
    if (t.length >= maxRows) throw DatasetError('too many rows (max $maxRows)');
    final n = r + 1;
    double num(String k) {
      final raw = row[idx[k]!].trim();
      final val = double.tryParse(delim == ';' ? raw.replaceAll(',', '.') : raw);
      if (val == null) throw DatasetError("row $n: could not convert string to float: '$raw'");
      return val;
    }

    double ts, oo, hh, ll, cc;
    double? vv;
    try {
      ts = parseTime(row[tc]);
      oo = num('open');
      hh = num('high');
      ll = num('low');
      cc = num('close');
      vv = idx.containsKey('volume') && row[idx['volume']!].trim().isNotEmpty ? num('volume') : null;
    } on RangeError {
      throw DatasetError('row $n: list index out of range');
    } on DatasetError catch (e) {
      throw e.message.startsWith('row ') ? e : DatasetError('row $n: ${e.message}');
    }
    if (!(ll <= math.min(oo, cc) && hh >= math.max(oo, cc))) {
      throw DatasetError('row $n: inconsistent candle (low <= open/close <= high required)');
    }
    t.add(ts);
    o.add(oo);
    h.add(hh);
    l.add(ll);
    c.add(cc);
    v.add(vv);
  }
  if (t.length < 100) throw DatasetError('at least 100 candles are needed for a meaningful test');
  final diffs = [for (var i = 1; i < t.length; i++) t[i] - t[i - 1]];
  if (diffs.any((d) => d <= 0)) throw DatasetError('time must be strictly increasing (sorted, no duplicates)');
  final sorted = [...diffs]..sort();
  final mid = sorted.length ~/ 2;
  final median = sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  final hasVol = v.every((x) => x != null);
  return OhlcData(t, o, h, l, c, hasVol ? [for (final x in v) x!] : null, median.round());
}

/// Regime-switching random walk (trending / ranging / volatile). Labelled synthetic — never market data.
OhlcData synthetic({int n = 3000, int timeframeSec = 30, int seed = 0, double start = 1.1}) {
  final rng = math.Random(seed);
  double gauss() => math.sqrt(-2 * math.log(1 - rng.nextDouble())) * math.cos(2 * math.pi * rng.nextDouble());
  const t0 = 1700000000;
  final t = <double>[], o = <double>[], h = <double>[], l = <double>[], c = <double>[];
  var p = start;
  var regime = 'ranging';
  var left = 0;
  const regimes = ['trending_up', 'trending_down', 'ranging', 'volatile'];
  for (var i = 0; i < n; i++) {
    if (left <= 0) {
      regime = regimes[rng.nextInt(4)];
      left = 80 + rng.nextInt(220);
    }
    left -= 1;
    final drift = regime == 'trending_up' ? 0.00015 : regime == 'trending_down' ? -0.00015 : 0.0;
    final vol = regime == 'volatile' ? 0.0012 : 0.0005;
    final oo = p;
    final cc = oo + drift + gauss() * vol;
    t.add((t0 + i * timeframeSec).toDouble());
    o.add(roundTo(oo, 6));
    h.add(roundTo(math.max(oo, cc) + (gauss() * vol * 0.5).abs(), 6));
    l.add(roundTo(math.min(oo, cc) - (gauss() * vol * 0.5).abs(), 6));
    c.add(roundTo(cc, 6));
    p = cc;
  }
  return OhlcData(t, o, h, l, c, null, timeframeSec);
}

String toCsv(OhlcData d) {
  final b = StringBuffer('time,open,high,low,close,volume\r\n');
  for (var i = 0; i < d.rows; i++) {
    b.write('${_num(d.time[i])},${d.open[i]},${d.high[i]},${d.low[i]},${d.close[i]},${d.volume?[i] ?? ''}\r\n');
  }
  return b.toString();
}

String _num(double x) => x == x.truncateToDouble() ? x.toInt().toString() : x.toString();
