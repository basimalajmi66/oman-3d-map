/// ChartReader (port of vision/quality.py + vision/reader.py): image → structured, honest reading.
///
/// `usable == false` means do not analyse (the reader abstains and says why). The right-most candle
/// is treated as possibly still forming. Prices only when a price-axis reader returns a reliable
/// linear scale — otherwise relative units, and the reading says so.
library;

import 'dart:math' as math;

import '../util.dart';
import 'candles.dart';
import 'imgops.dart';

const readerVersion = '1.0';
const minReaderCandles = 10;

double _ramp(double value, double bad, double good) =>
    value <= bad ? 0.0 : value >= good ? 1.0 : (value - bad) / (good - bad);

Map<String, dynamic> assessImage(RgbImage img) {
  final w = img.width, h = img.height;
  final grey = toGrey(img);
  final sharp = laplacianVariance(grey, w, h);
  final contrast = stdOf(grey);
  final qRes = _ramp(math.min(w, h).toDouble(), 200, 450);
  final qSharp = _ramp(sharp, 8, 120); // calibrated on synthetic charts
  final qCon = _ramp(contrast, 8, 30);
  return {
    'width': w, 'height': h, 'sharpness': roundTo(sharp, 1), 'contrast': roundTo(contrast, 1),
    'score': roundTo(math.min(qRes, 1.0) * 0.3 + qSharp * 0.45 + qCon * 0.25, 3),
    'issues': [if (qRes < 1) 'low_resolution', if (qSharp < 0.5) 'blurry', if (qCon < 0.5) 'low_contrast'],
  };
}

/// Linear price axis: price = slope * y + intercept.
class PriceScale {
  PriceScale(this.slope, this.intercept, this.labelsUsed, this.r2, this.decimals, this.side);
  final double slope, intercept, r2;
  final int labelsUsed, decimals;
  final String side;
  double price(int y) => roundTo(slope * y + intercept, decimals + 1);
  Map<String, dynamic> toJson() => {
        'slope': slope, 'intercept': intercept, 'labels_used': labelsUsed, 'r2': r2, 'decimals': decimals, 'side': side,
      };
}

/// Optional OCR hooks (e.g. on-device text recognition). Without them the reader works in relative units.
abstract class ChartOcr {
  bool get available;
  Future<PriceScale?> priceScale(RgbImage img, int plotLeft, int plotRight);
  Future<(int?, String?)> timeframe(RgbImage img);
}

class ChartReader {
  ChartReader({this.minQuality = 0.6, this.ocr});
  final double minQuality;
  final ChartOcr? ocr;

  Future<Map<String, dynamic>> read(RgbImage img) async {
    final iq = assessImage(img);
    final (candles, diag) = detectCandles(img);
    final reasons = <String>[];
    final warnings = <String>[...(iq['issues'] as List).cast<String>()];

    var missing = 0;
    var qDet = 0.0;
    if (candles.length >= 3) {
      final gaps = [for (var i = 1; i < candles.length; i++) candles[i].x - candles[i - 1].x];
      final sp = medianOf(gaps);
      for (final g in gaps) {
        if (g > 1.5 * sp) missing += math.max(0, roundTo(g / sp, 0).toInt() - 1);
      }
      final resolved = candles.where((c) => c.bodyResolved).length / candles.length;
      final qSpacing = math.max(0.0, 1 - ((diag['spacing_cv'] as num?) ?? 1.0) * 2);
      final qMissing = math.max(0.0, 1 - missing / math.max(1, candles.length) * 5);
      qDet = math.min(qSpacing, 1.0) * 0.4 + resolved * 0.3 + qMissing * 0.3;
      if (missing > 0) warnings.add('missing_candle_slots');
      if (resolved < 0.9) warnings.add('bodies_not_resolved');
    }
    if ((diag['bull_pixels'] as int) + (diag['bear_pixels'] as int) < 200) {
      reasons.add('no_candles_found_or_unsupported_colours');
    } else if (candles.length < minReaderCandles) {
      reasons.add('too_few_candles');
    }
    // the weaker of image quality and detection consistency dominates
    final iqs = (iq['score'] as num).toDouble();
    final weak = math.min(iqs, qDet), avg = (iqs + qDet) / 2;
    final quality = candles.isNotEmpty ? roundTo(weak * 0.6 + avg * 0.4, 3) : 0.0;
    if (quality < minQuality) reasons.add('image_quality_below_threshold');

    PriceScale? scale;
    int? tfSec;
    String? tfLabel;
    final o = ocr;
    if (candles.isNotEmpty && o != null && o.available) {
      scale = await o.priceScale(img, candles.map((c) => c.left).reduce(math.min), candles.map((c) => c.right).reduce(math.max));
      (tfSec, tfLabel) = await o.timeframe(img);
    }
    if (candles.isNotEmpty && scale == null) {
      warnings.add(o == null || o.available ? 'price_axis_not_read_relative_units_only' : 'ocr_not_installed_relative_units_only');
    }

    final yTop = candles.isEmpty ? 0 : candles.map((c) => c.yHigh).reduce(math.min);
    final yBot = candles.isEmpty ? 1 : candles.map((c) => c.yLow).reduce(math.max);
    final span = math.max(1, yBot - yTop);
    double rel(int y) => roundTo(1 - (y - yTop) / span, 4);
    final n = candles.length;
    final cds = [
      for (var i = 0; i < n; i++)
        {
          'index': i, 'x': candles[i].x, 'left': candles[i].left, 'right': candles[i].right,
          'y_high': candles[i].yHigh, 'y_low': candles[i].yLow, 'y_open': candles[i].yOpen, 'y_close': candles[i].yClose,
          'rel_high': rel(candles[i].yHigh), 'rel_low': rel(candles[i].yLow), 'rel_open': rel(candles[i].yOpen),
          'rel_close': rel(candles[i].yClose), 'bullish': candles[i].bullish, 'body_resolved': candles[i].bodyResolved,
          'status': i == n - 1 ? 'possibly_forming' : 'closed',
          if (scale != null) ...{
            'high': scale.price(candles[i].yHigh), 'low': scale.price(candles[i].yLow),
            'open': scale.price(candles[i].yOpen), 'close': scale.price(candles[i].yClose),
          },
        }
    ];
    final closed = cds.isEmpty ? <Map<String, dynamic>>[] : cds.sublist(0, cds.length - 1);
    final lastClosed = closed.isEmpty ? null : closed.last;
    final usable = reasons.isEmpty;
    return {
      'usable': usable, 'abstain_reasons': reasons, 'data_quality': quality, 'image': iq, 'detection': diag,
      'candles': cds, 'price_scale': scale?.toJson(), 'timeframe_sec': tfSec, 'timeframe_label': tfLabel,
      'missing_slots': missing, 'warnings': warnings, 'reader_version': readerVersion, 'data_basis': 'image_only',
      'summary': {
        'usable': usable, 'abstain_reasons': reasons, 'data_quality': quality, 'candles': n,
        'closed_candles': closed.length,
        'bullish': closed.where((c) => c['bullish'] == true).length,
        'bearish': closed.where((c) => c['bullish'] != true).length,
        'last_closed_direction': lastClosed == null ? null : (lastClosed['bullish'] == true ? 'up' : 'down'),
        'last_closed_close': lastClosed?['close'],
        'forming_direction': cds.isEmpty ? null : (cds.last['bullish'] == true ? 'up' : 'down'),
        'prices_read': scale != null, 'timeframe_sec': tfSec, 'timeframe_label': tfLabel, 'missing_slots': missing,
        'theme': diag['theme'], 'warnings': warnings,
      },
    };
  }
}

/// Keep only the newest `n` candles of a reading (the user's "candles to read" setting) — same as the computer
/// engine's `limit_candles`. Relative values are recomputed over the kept candles. `n` of 0 keeps everything.
Map<String, dynamic> limitCandles(Map<String, dynamic> reading, int n) {
  final candles = [for (final c in (reading['candles'] as List? ?? const [])) (c as Map).cast<String, dynamic>()];
  if (n <= 0 || candles.length <= n) return reading;
  final kept = candles.sublist(candles.length - n);
  final yTop = kept.map((c) => c['y_high'] as int).reduce(math.min);
  final yBot = kept.map((c) => c['y_low'] as int).reduce(math.max);
  final span = math.max(1, yBot - yTop);
  final fresh = [
    for (var i = 0; i < kept.length; i++)
      {
        ...kept[i],
        'index': i,
        for (final k in const ['high', 'low', 'open', 'close']) 'rel_$k': roundTo(1 - ((kept[i]['y_$k'] as int) - yTop) / span, 4),
      }
  ];
  final warnings = [...(reading['warnings'] as List? ?? const []), 'candles_limited'];
  final closed = fresh.sublist(0, fresh.length - 1);
  return {
    ...reading,
    'candles': fresh,
    'warnings': warnings,
    'candles_limit': {'kept': n, 'total': candles.length},
    'summary': {
      ...((reading['summary'] as Map?)?.cast<String, dynamic>() ?? const {}),
      'candles': fresh.length,
      'closed_candles': closed.length,
      'bullish': closed.where((c) => c['bullish'] == true).length,
      'bearish': closed.where((c) => c['bullish'] != true).length,
      'last_closed_direction': closed.isEmpty ? null : (closed.last['bullish'] == true ? 'up' : 'down'),
      'last_closed_close': closed.isEmpty ? null : closed.last['close'],
      'warnings': warnings,
    },
  };
}
