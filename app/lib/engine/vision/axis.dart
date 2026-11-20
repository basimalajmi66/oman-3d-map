/// Price axis and timeframe from the chart's own labels (port of vision/axis.py, same acceptance rules).
///
/// The phone's OCR (Tesseract, on the device) reads one text line at a time, so the axis strip is first cut into
/// label lines here (pure Dart, runs in the reading isolate); the OCR then reads each line image. Prices are only
/// reported when the labels fit a straight, falling-upwards line almost perfectly (r² ≥ 0.9995) after dropping
/// OCR outliers — otherwise the reading stays in relative units and says so. Prices are never guessed.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as im;

import '../util.dart';
import 'imgops.dart';
import 'reader.dart';

/// Reads the text of one prepared line image (PNG, dark text on white). `digits`: axis labels (0-9 . , -).
typedef LineOcr = Future<String> Function(Uint8List png, {required bool digits});

final numRe = RegExp(r'^-?\d{1,7}(?:[.,]\d{1,8})?$');
final tfRe = RegExp(r'(?<![\w.])(\d{1,3})\s*(s|sec|secs|m|min|mins|h|hr|d|D|w|W)(?![\w])|(?<![\w])([MHDW])(\d{1,3})(?![\w])');
const tfUnitSec = {
  's': 1, 'sec': 1, 'secs': 1, 'm': 60, 'min': 60, 'mins': 60, 'h': 3600, 'hr': 3600, 'd': 86400, 'D': 86400, //
  'w': 604800, 'W': 604800,
};

/// One label line cut from an axis strip: its vertical centre on the chart image and the prepared picture.
class AxisLine {
  AxisLine(this.yCentre, this.png);
  final double yCentre;
  final Uint8List png;
}

/// What the OCR has to read for one chart: label lines of the right / left axis strips and the top strip.
class AxisJob {
  AxisJob(this.sides, this.top);
  final Map<String, List<AxisLine>> sides; // 'right', 'left' (in that order of preference)
  final Uint8List? top; // timeframe label strip
  bool get isEmpty => sides.values.every((l) => l.isEmpty) && top == null;
}

/// Grey (OpenCV weights) → ×scale cubic → dark text on white → Otsu, like `_prep` on the computer.
Uint8List prepLine(RgbImage img, int x0, int y0, int x1, int y1, {int scale = 3}) {
  final w = x1 - x0, h = y1 - y0;
  final grey = im.Image(width: w, height: h, numChannels: 1);
  var sum = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = ((y0 + y) * img.width + x0 + x) * 3;
      final g = (img.rgb[i] * 9798 + img.rgb[i + 1] * 19235 + img.rgb[i + 2] * 3735 + 16384) >> 15;
      grey.setPixelR(x, y, g);
      sum += g;
    }
  }
  final big = im.copyResize(grey, width: w * scale, height: h * scale, interpolation: im.Interpolation.cubic);
  final invert = sum / (w * h) < 128; // dark theme: make the text dark on light
  final hist = List<int>.filled(256, 0);
  for (final p in big) {
    final v = invert ? 255 - p.r.toInt() : p.r.toInt();
    hist[v]++;
  }
  final t = otsu(hist);
  const margin = 12; // Tesseract finds text much more reliably with a white margin
  final out = im.Image(width: big.width + 2 * margin, height: big.height + 2 * margin, numChannels: 1)..clear(im.ColorUint8.rgb(255, 255, 255));
  for (final p in big) {
    final v = invert ? 255 - p.r.toInt() : p.r.toInt();
    out.setPixelR(p.x + margin, p.y + margin, v > t ? 255 : 0);
  }
  return im.encodePng(out);
}

/// Otsu threshold of a 256-bin histogram.
int otsu(List<int> hist) {
  final total = hist.fold<int>(0, (a, b) => a + b);
  var sumAll = 0.0;
  for (var i = 0; i < 256; i++) {
    sumAll += i * hist[i];
  }
  var sumB = 0.0, wB = 0, best = 0.0, t = 0;
  for (var i = 0; i < 256; i++) {
    wB += hist[i];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += i * hist[i];
    final mB = sumB / wB, mF = (sumAll - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > best) {
      best = between;
      t = i;
    }
  }
  return t;
}

/// The label column of an axis strip: from the first column with ink next to the chart, up to the first gap of
/// 25 empty columns (beyond it: other panels, buttons). `fromRight`: walk leftwards (left axis).
(int, int) labelColumn(RgbImage img, int x0, int x1, {bool fromRight = false}) {
  final w = x1 - x0, h = img.height;
  if (w < 4) return (x0, x1);
  final mask = inkMask(img, x0, x1);
  final colInk = List<int>.filled(w, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      colInk[x] += mask[y * w + x];
    }
  }
  final order = fromRight ? [for (var x = w - 1; x >= 0; x--) x] : [for (var x = 0; x < w; x++) x];
  int? start, end;
  var gap = 0;
  for (final x in order) {
    if (colInk[x] >= 2) {
      start ??= x;
      end = x;
      gap = 0;
    } else if (start != null && ++gap >= 25) {
      break;
    }
  }
  if (start == null) return (x0, x1);
  final a = fromRight ? end! : start, b = fromRight ? start : end!;
  return (x0 + math.max(0, a - 2), x0 + math.min(w, b + 3));
}

/// Text-like ink in the strip x0..x1: sharp edges, without straight lines (unbroken runs of 60 px or more).
Uint8List inkMask(RgbImage img, int x0, int x1) {
  final w = x1 - x0, h = img.height;
  final grey = toGreyStrip(img, x0, x1);
  // text = sharp edges (a jump of > 45 grey levels within 2 px): soft backgrounds (photos behind the chart,
  // gradients) have none, whatever their colour
  final ink = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final g = grey[y * w + x];
      var e = 0;
      if (x >= 2) e = math.max(e, (g - grey[y * w + x - 2]).abs());
      if (x + 2 < w) e = math.max(e, (g - grey[y * w + x + 2]).abs());
      if (y >= 2) e = math.max(e, (g - grey[(y - 2) * w + x]).abs());
      if (y + 2 < h) e = math.max(e, (g - grey[(y + 2) * w + x]).abs());
      if (e > 45) ink[y * w + x] = 1;
    }
  }
  // straight lines (grid, axes, price lines) are long unbroken runs; characters are short
  const maxRun = 60;
  for (var y = 0; y < h; y++) {
    var x = 0;
    while (x < w) {
      if (ink[y * w + x] == 0) {
        x++;
        continue;
      }
      var e = x;
      while (e + 1 < w && ink[y * w + e + 1] != 0) {
        e++;
      }
      if (e - x + 1 >= maxRun) ink.fillRange(y * w + x, y * w + e + 1, 0);
      x = e + 1;
    }
  }
  for (var x = 0; x < w; x++) {
    var y = 0;
    while (y < h) {
      if (ink[y * w + x] == 0) {
        y++;
        continue;
      }
      var e = y;
      while (e + 1 < h && ink[(e + 1) * w + x] != 0) {
        e++;
      }
      if (e - y + 1 >= maxRun) {
        for (var q = y; q <= e; q++) {
          ink[q * w + x] = 0;
        }
      }
      y = e + 1;
    }
  }
  return ink;
}

Uint8List toGreyStrip(RgbImage img, int x0, int x1) {
  final w = x1 - x0, h = img.height;
  final grey = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * img.width + x0 + x) * 3;
      grey[y * w + x] = (img.rgb[i] * 9798 + img.rgb[i + 1] * 19235 + img.rgb[i + 2] * 3735 + 16384) >> 15;
    }
  }
  return grey;
}


/// Column groups with ink in the strip (separated by >= 25 empty columns), left to right.
List<(int, int)> columnGroups(RgbImage img, int x0, int x1) {
  final w = x1 - x0, h = img.height;
  if (w < 4) return [];
  final mask = inkMask(img, x0, x1);
  final colInk = List<int>.filled(w, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      colInk[x] += mask[y * w + x];
    }
  }
  final out = <(int, int)>[];
  int? start;
  var end = 0, gap = 0;
  for (var x = 0; x < w; x++) {
    if (colInk[x] >= 2) {
      start ??= x;
      end = x;
      gap = 0;
    } else if (start != null && ++gap >= 25) {
      out.add((x0 + math.max(0, start - 2), x0 + math.min(w, end + 3)));
      start = null;
    }
  }
  if (start != null) out.add((x0 + math.max(0, start - 2), x0 + math.min(w, end + 3)));
  return out;
}

/// Text lines in the strip x0..x1: rows that differ from the strip's background, grouped into bands 5–60 px tall,
/// each cut to its own ink columns. Returns (top, bottom, left, right) in image coordinates (inclusive).
List<(int, int, int, int)> textBands(RgbImage img, int x0, int x1) {
  final w = x1 - x0, h = img.height;
  if (w < 4) return [];
  final mask = inkMask(img, x0, x1);
  bool ink(int x, int y) => mask[y * w + x] != 0;
  final rowInk = [for (var y = 0; y < h; y++) [for (var x = 0; x < w; x++) if (ink(x, y)) 1].length];
  final out = <(int, int, int, int)>[];
  var y = 0;
  while (y < h) {
    if (rowInk[y] < 2) {
      y++;
      continue;
    }
    var e = y;
    while (e + 1 < h && (rowInk[e + 1] >= 2 || (e + 2 < h && rowInk[e + 2] >= 2))) {
      e++;
    }
    final bh = e - y + 1;
    if (bh >= 5 && bh <= 60) {
      var l = w, r = -1;
      for (var yy = y; yy <= e; yy++) {
        for (var x = 0; x < w; x++) {
          if (ink(x, yy)) {
            if (x < l) l = x;
            if (x > r) r = x;
          }
        }
      }
      if (r - l >= 4) out.add((y, e, x0 + l, x0 + r));
    }
    y = e + 1;
  }
  return out;
}

/// Cut the label lines (pure Dart; safe in an isolate). `plotLeft` / `plotRight`: the candles' horizontal extent.
AxisJob prepareAxisJob(RgbImage img, int plotLeft, int plotRight) {
  final sides = <String, List<AxisLine>>{};
  final h = img.height, w = img.width;
  for (final (side, sx0, sx1) in [
    if (w - plotRight > 25) ('right', plotRight + 3, w),
    if (plotLeft > 25) ('left', 0, math.max(1, plotLeft - 3)),
  ]) {
    // the price axis is the column group with the most text lines (not e.g. the timer next to the last candle)
    var bands = <(int, int, int, int)>[];
    for (final (gx0, gx1) in columnGroups(img, sx0, sx1)) {
      final b = textBands(img, gx0, gx1);
      if (b.length > bands.length) bands = b;
    }
    // each line is one OCR call on the phone: at most 12, spread over the whole axis
    final pick = bands.length <= 12 ? bands : [for (var i = 0; i < 12; i++) bands[(i * (bands.length - 1) / 11).round()]];
    sides[side] = [
      for (final (top, bottom, left, right) in pick)
        AxisLine((top + bottom) / 2, prepLine(img, math.max(0, left - 3), math.max(0, top - 3), math.min(w, right + 4),
            math.min(h, bottom + 4)))
    ];
  }
  final stripH = math.max(30, h ~/ 8);
  final top = h >= 10 ? prepLine(img, 0, 0, w, math.min(h, stripH), scale: 2) : null;
  return AxisJob(sides, top);
}

/// Least-squares line through (y, value) points: (slope, intercept, r²); null below 3 points or < 20 px of spread.
(double, double, double)? fitLine(List<(double, double, int)> pts) {
  if (pts.length < 3) return null;
  final ys = [for (final p in pts) p.$1], vs = [for (final p in pts) p.$2];
  if (ys.reduce(math.max) - ys.reduce(math.min) < 20) return null;
  final n = pts.length;
  final my = ys.reduce((a, b) => a + b) / n, mv = vs.reduce((a, b) => a + b) / n;
  var sxy = 0.0, sxx = 0.0;
  for (var i = 0; i < n; i++) {
    sxy += (ys[i] - my) * (vs[i] - mv);
    sxx += (ys[i] - my) * (ys[i] - my);
  }
  if (sxx == 0) return null;
  final slope = sxy / sxx, intercept = mv - slope * my;
  var ssRes = 0.0, ssTot = 0.0;
  for (var i = 0; i < n; i++) {
    final pr = slope * ys[i] + intercept;
    ssRes += (vs[i] - pr) * (vs[i] - pr);
    ssTot += (vs[i] - mv) * (vs[i] - mv);
  }
  if (ssTot == 0) ssTot = 1e-12;
  return (slope, intercept, 1 - ssRes / ssTot);
}

/// (y, text) labels → a price scale, dropping the worst outlier until the fit is near-perfect (or too few remain).
/// An OCR'd axis label as a number string: spaces dropped, ',' → '.', and the letter look-alikes a general-purpose
/// OCR returns for digits (O → 0, l/I/| → 1, S → 5). Anything still not a number is rejected by [numRe].
String normaliseLabel(String raw) {
  var t = raw.trim().replaceAll(RegExp(r'\s+'), '');
  if (RegExp(r'\d').hasMatch(t)) {
    t = t.replaceAll(RegExp('[Oo]'), '0').replaceAll(RegExp('[lI|]'), '1').replaceAll('S', '5');
  }
  return thousandsAware(t);
}

/// '3,568.000' and '12,500' use ',' for thousands; '1,0915' uses it as the decimal point.
String thousandsAware(String t) {
  if (t.contains(',') && t.contains('.')) return t.replaceAll(',', '');
  if (RegExp(r'^-?\d{1,3}(,\d{3}){2,}$').hasMatch(t)) return t.replaceAll(',', '');
  return t.replaceAll(',', '.');
}

PriceScale? scaleFromLabels(List<(double, String)> labels, String side) {
  final pts = <(double, double, int)>[];
  for (final (y, raw) in labels) {
    final t = normaliseLabel(raw);
    if (t.isEmpty || !numRe.hasMatch(t)) continue;
    pts.add((y, double.parse(t), t.contains('.') ? t.split('.')[1].length : 0));
  }
  while (pts.length >= 3) {
    final fit = fitLine(pts);
    if (fit == null) break;
    final (slope, intercept, r2) = fit;
    if (slope < 0 && r2 >= 0.9995) {
      return PriceScale(slope, intercept, pts.length, roundTo(r2, 6), pts.map((p) => p.$3).reduce(math.max), side);
    }
    // drop the label whose removal fits best (the largest residual can belong to a good label: a wrong reading
    // pulls the least-squares line towards itself)
    var worst = 0;
    var bestR2 = double.negativeInfinity;
    for (var i = 0; i < pts.length; i++) {
      final rest = [...pts]..removeAt(i);
      final f = fitLine(rest);
      final r = f == null ? double.negativeInfinity : f.$3;
      if (r > bestR2) {
        bestR2 = r;
        worst = i;
      }
    }
    pts.removeAt(worst);
  }
  return null;
}

/// The first timeframe label in a text, like `read_timeframe` on the computer: (seconds, label) or (null, null).
(int?, String?) timeframeFromText(String text) {
  for (final m in tfRe.allMatches(text)) {
    int n;
    String unit;
    if (m[1] != null) {
      n = int.parse(m[1]!);
      unit = m[2]!;
    } else {
      unit = const {'M': 'm', 'H': 'h', 'D': 'd', 'W': 'w'}[m[3]]!;
      n = int.parse(m[4]!);
    }
    if (n == 0) continue;
    return (n * tfUnitSec[unit]!, m[0]!.trim());
  }
  return (null, null);
}

/// OCR every line of the job (main isolate: the OCR is a platform plugin) → (price scale, timeframe, diagnostics).
Future<(PriceScale?, int?, String?, Map<String, dynamic>)> runAxisJob(AxisJob job, LineOcr ocr) async {
  final diag = <String, dynamic>{'ocr': true, 'engine': 'phone'};
  PriceScale? scale;
  for (final e in job.sides.entries) {
    final labels = <(double, String)>[];
    for (final line in e.value) {
      try {
        labels.add((line.yCentre, await ocr(line.png, digits: true)));
      } catch (_) {
        // one unreadable line is not fatal: the fit decides
      }
    }
    diag['${e.key}_labels'] = labels.where((l) => numRe.hasMatch(normaliseLabel(l.$2))).length;
    scale = scaleFromLabels(labels, e.key);
    if (scale != null) break;
  }
  int? tfSec;
  String? tfLabel;
  if (job.top != null) {
    try {
      (tfSec, tfLabel) = timeframeFromText(await ocr(job.top!, digits: false));
    } catch (_) {}
  }
  return (scale, tfSec, tfLabel, diag);
}

/// Put prices read from the axis into a reading made without them (candles, summary, warnings).
Map<String, dynamic> applyAxis(Map<String, dynamic> reading, PriceScale? scale, int? tfSec, String? tfLabel, Map diag) {
  final out = Map<String, dynamic>.from(reading);
  final detection = Map<String, dynamic>.from(reading['detection'] as Map? ?? const {})..['axis'] = diag;
  out['detection'] = detection;
  final warnings = [...(reading['warnings'] as List? ?? const [])];
  if (scale != null) {
    warnings.remove('price_axis_not_read_relative_units_only');
    warnings.remove('ocr_not_installed_relative_units_only');
    out['candles'] = [
      for (final c in (reading['candles'] as List? ?? const []).cast<Map>())
        {
          ...c.cast<String, dynamic>(),
          'high': scale.price(c['y_high'] as int), 'low': scale.price(c['y_low'] as int),
          'open': scale.price(c['y_open'] as int), 'close': scale.price(c['y_close'] as int),
        }
    ];
    out['price_scale'] = scale.toJson();
  } else if (warnings.remove('ocr_not_installed_relative_units_only')) {
    warnings.add('price_axis_not_read_relative_units_only'); // OCR ran but the axis did not fit
  }
  if (tfSec != null) {
    out['timeframe_sec'] = tfSec;
    out['timeframe_label'] = tfLabel;
  }
  out['warnings'] = warnings;
  final cds = (out['candles'] as List).cast<Map>();
  final closed = cds.isEmpty ? const <Map>[] : cds.sublist(0, cds.length - 1);
  out['summary'] = {
    ...((reading['summary'] as Map?)?.cast<String, dynamic>() ?? const {}),
    'prices_read': out['price_scale'] != null,
    'last_closed_close': closed.isEmpty ? null : closed.last['close'],
    'timeframe_sec': out['timeframe_sec'],
    'timeframe_label': out['timeframe_label'],
    'warnings': warnings,
  };
  return out;
}

/// The same pipeline behind the reader's [ChartOcr] hook (used where everything runs in one isolate, e.g. tests).
class LineOcrChartOcr implements ChartOcr {
  LineOcrChartOcr(this.ocr);
  final LineOcr ocr;
  (int?, String?) _tf = (null, null);
  @override
  bool get available => true;
  @override
  Future<PriceScale?> priceScale(RgbImage img, int plotLeft, int plotRight) async {
    final (scale, tfSec, tfLabel, _) = await runAxisJob(prepareAxisJob(img, plotLeft, plotRight), ocr);
    _tf = (tfSec, tfLabel);
    return scale;
  }

  @override
  Future<(int?, String?)> timeframe(RgbImage img) async => _tf;
}
