/// Candlestick detection from a chart image (port of vision/candles.py; same steps, same thresholds).
///
/// Background colour → theme; HSV masks for bullish (green..teal) and bearish (red..magenta) hues;
/// vertical opening removes overlay lines; connected components merged per column; geometry measured
/// on the original mask; wide boxes (price tags), duplicate columns and label runs dropped; tiny
/// candles erased by the opening recovered in empty grid slots.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'imgops.dart';

const satMin = 70;
const valMin = 60;
const bullHues = (35, 93); // OpenCV hue range 0..179
const bearHuesLow = (0, 12);
const bearHuesHigh = (160, 179);
const maxWickGap = 4;

class DetectedCandle {
  DetectedCandle(this.x, this.left, this.right, this.yHigh, this.yLow, this.yOpen, this.yClose, this.bullish,
      this.bodyResolved);
  final int x, left, right, yHigh, yLow, yOpen, yClose;
  final bool bullish, bodyResolved;
}

/// Most frequent quantised colour of a downscaled copy, returned as (b, g, r) like OpenCV.
(int, int, int) backgroundColor(RgbImage img) {
  final small = resizeNearest(img, math.min(200, img.width), math.min(120, img.height));
  final counts = <int, int>{};
  for (var i = 0; i < small.width * small.height; i++) {
    final key = (small.rgb[i * 3 + 2] ~/ 16) * 256 + (small.rgb[i * 3 + 1] ~/ 16) * 16 + small.rgb[i * 3] ~/ 16;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  var best = -1, bestN = -1;
  for (final e in counts.entries) {
    if (e.value > bestN || (e.value == bestN && e.key < best)) {
      best = e.key;
      bestN = e.value;
    }
  }
  return ((best ~/ 256) * 16 + 8, ((best ~/ 16) % 16) * 16 + 8, (best % 16) * 16 + 8);
}

(Mask, Mask) colourMasks(RgbImage img, (Uint8List, Uint8List, Uint8List) hsv, {int sMin = satMin, int vMin = valMin}) {
  final (h, s, v) = hsv;
  final n = img.width * img.height;
  final bull = Mask(img.width, img.height), bear = Mask(img.width, img.height);
  for (var i = 0; i < n; i++) {
    if (s[i] < sMin || v[i] < vMin) continue;
    final hh = h[i];
    if (hh >= bullHues.$1 && hh <= bullHues.$2) bull.data[i] = 1;
    if ((hh >= bearHuesLow.$1 && hh <= bearHuesLow.$2) || (hh >= bearHuesHigh.$1 && hh <= bearHuesHigh.$2)) {
      bear.data[i] = 1;
    }
  }
  return (bull, bear);
}

class _Comp {
  _Comp(this.x, this.y, this.w, this.h, this.m);
  int x, y, w, h;
  List<List<bool>> m; // rows × cols inside the bounding box
}

List<_Comp> _components(Mask mask, int minH) {
  final lab = components8(mask);
  return [
    for (final c in lab.components)
      if (c.h >= minH && c.area >= 3) _Comp(c.x, c.y, c.w, c.h, lab.crop(c))
  ];
}

List<_Comp> _mergeSameColumn(List<_Comp> comps) {
  final sorted = [...comps];
  // stable sort by x (Python's sorted)
  final idx = {for (var i = 0; i < sorted.length; i++) sorted[i]: i};
  sorted.sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : idx[a]!.compareTo(idx[b]!));
  final merged = <_Comp>[];
  for (final c in sorted) {
    if (merged.isNotEmpty) {
      final p = merged.last;
      final overlap = math.min(p.x + p.w, c.x + c.w) - math.max(p.x, c.x);
      final vOverlap = math.min(p.y + p.h, c.y + c.h) - math.max(p.y, c.y);
      if (overlap >= 0.5 * math.min(p.w, c.w) ||
          (overlap >= -2 && vOverlap >= 0.5 * math.min(p.h, c.h) && math.min(p.w, c.w) <= 2)) {
        final nx = math.min(p.x, c.x), ny = math.min(p.y, c.y);
        final nw = math.max(p.x + p.w, c.x + c.w) - nx, nh = math.max(p.y + p.h, c.y + c.h) - ny;
        final nm = List.generate(nh, (_) => List<bool>.filled(nw, false));
        for (final part in [p, c]) {
          for (var r = 0; r < part.h; r++) {
            for (var q = 0; q < part.w; q++) {
              if (part.m[r][q]) nm[part.y - ny + r][part.x - nx + q] = true;
            }
          }
        }
        merged[merged.length - 1] = _Comp(nx, ny, nw, nh, nm);
        continue;
      }
    }
    merged.add(c);
  }
  return merged;
}

int _argmaxColSum(List<List<bool>> m) {
  final w = m.first.length;
  var best = 0, bestN = -1;
  for (var q = 0; q < w; q++) {
    var n = 0;
    for (final row in m) {
      if (row[q]) n++;
    }
    if (n > bestN) {
      best = q;
      bestN = n;
    }
  }
  return best;
}

/// Follow the wick column beyond `y` across gaps of at most maxWickGap px.
int _extend(Mask m, int col, int y, int step) {
  final cols = [for (final c in [col - 1, col, col + 1]) if (c >= 0 && c < m.width) c];
  var best = y, gap = 0, yy = y + step;
  while (yy >= 0 && yy < m.height && gap <= maxWickGap) {
    if (cols.any((c) => m.at(c, yy))) {
      best = yy;
      gap = 0;
    } else {
      gap++;
    }
    yy += step;
  }
  return best;
}

DetectedCandle _measure(Mask orig, Mask loose, _Comp c, int loCol, int hiCol, bool bullish) {
  final rows = [for (var r = 0; r < c.h; r++) if (c.m[r].contains(true)) r];
  var yHigh = c.y + rows.first, yLow = c.y + rows.last;
  final wick = c.x + _argmaxColSum(c.m);
  yHigh = _extend(loose, wick, yHigh, -1);
  yLow = _extend(loose, wick, yLow, 1);
  final n = yLow - yHigh + 1;
  final runL = List<int>.filled(n, wick), runR = List<int>.filled(n, wick);
  for (var k = 0; k < n; k++) {
    final yy = yHigh + k;
    if (!orig.at(wick, yy)) continue;
    var l = wick;
    while (l - 1 >= loCol && orig.at(l - 1, yy)) {
      l--;
    }
    var r = wick;
    while (r + 1 <= hiCol && orig.at(r + 1, yy)) {
      r++;
    }
    runL[k] = l;
    runR[k] = r;
  }
  final widths = [for (var k = 0; k < n; k++) runR[k] - runL[k] + 1];
  final maxW = widths.reduce(math.max);
  final resolved = maxW >= 3;
  int bTop, bBot, left, right;
  if (resolved) {
    final thr = math.max(2, 0.6 * maxW);
    final body = [for (var k = 0; k < n; k++) if (widths[k] >= thr) k];
    bTop = yHigh + body.first;
    bBot = yHigh + body.last;
    left = body.map((k) => runL[k]).reduce(math.min);
    right = body.map((k) => runR[k]).reduce(math.max);
  } else {
    bTop = yHigh;
    bBot = yLow;
    left = wick;
    right = wick;
  }
  final (yOpen, yClose) = bullish ? (bBot, bTop) : (bTop, bBot);
  return DetectedCandle((left + right) ~/ 2, left, right, yHigh, yLow, yOpen, yClose, bullish, resolved);
}

class _Found {
  _Found(this.cx, this.c, this.bullish, this.orig, this.loose);
  final int cx;
  final _Comp c;
  final bool bullish;
  final Mask orig, loose;
}

List<T> _stableSortBy<T>(List<T> l, int Function(T) key) {
  final idx = {for (var i = 0; i < l.length; i++) l[i]: i};
  return [...l]..sort((a, b) {
      final x = key(a).compareTo(key(b));
      return x != 0 ? x : idx[a]!.compareTo(idx[b]!);
    });
}

/// Candles sorted left→right plus diagnostics (same keys as the Python reader).
(List<DetectedCandle>, Map<String, dynamic>) detectCandles(RgbImage img) {
  final hImg = img.height;
  final bg = backgroundColor(img);
  final theme = (bg.$1 + bg.$2 + bg.$3) / 3 < 128 ? 'dark' : 'light';
  final hsv = toHsv(img);
  final (bullM, bearM) = colourMasks(img, hsv);
  final (bullL, bearL) = colourMasks(img, hsv, sMin: 35, vMin: 45);
  final openH = math.max(5, hImg ~/ 120);
  final minH = openH;
  var found = <_Found>[];
  for (final (mask, loose, bullish) in [(bullM, bullL, true), (bearM, bearL, false)]) {
    for (final c in _mergeSameColumn(_components(openVertical(mask, openH), minH))) {
      found.add(_Found(c.x + _argmaxColSum(c.m), c, bullish, mask, loose));
    }
  }
  found = _stableSortBy(found, (f) => f.cx);
  final nFound = found.length;
  if (found.length >= 3) {
    final sp = medianOf([for (var i = 1; i < found.length; i++) found[i].cx - found[i - 1].cx]);
    found = [for (final f in found) if (f.c.w <= math.max(3.0, 1.3 * sp)) f];
  }
  final droppedBox = nFound - found.length;
  final centres = [for (final f in found) f.cx];
  final spacing = centres.length >= 3 ? medianOf([for (var i = 1; i < centres.length; i++) centres[i] - centres[i - 1]]) : 20.0;
  final reach = math.max(2, (spacing * 0.45).truncate());
  var raw = <DetectedCandle>[];
  for (var i = 0; i < found.length; i++) {
    final f = found[i];
    final loCol = [0, f.cx - reach, i > 0 ? (centres[i - 1] + f.cx) ~/ 2 + 1 : 0].reduce(math.max);
    final hiCol =
        [img.width - 1, f.cx + reach, i + 1 < found.length ? (centres[i + 1] + f.cx) ~/ 2 - 1 : 1000000000].reduce(math.min);
    raw.add(_measure(f.orig, f.loose, f.c, loCol, hiCol, f.bullish));
  }
  raw = _stableSortBy(raw, (c) => c.x);

  final diag = <String, dynamic>{
    'background_bgr': [bg.$1, bg.$2, bg.$3], 'theme': theme, 'bull_pixels': bullM.count(),
    'bear_pixels': bearM.count(), 'raw_components': raw.length, 'dropped_wide': droppedBox, 'dropped_label_runs': 0,
  };
  if (raw.isEmpty) return ([], diag);
  final first = _finish(raw, diag, bullM, bearM, minH, openH);
  final candles = first.$1;
  if ((diag['dropped_wide'] as int) >= overlayTrigger) {
    // many wide blobs: indicator lines / labels in the candle colours glue candles together (SuperTrend, signal
    // labels). Read again body-first and keep that reading only when it is clearly more consistent.
    final widths = [for (final c in raw) if (c.bodyResolved) c.right - c.left + 1];
    final medW = widths.isNotEmpty ? medianOf(widths) : 1.0;
    final altRaw = _bodiesFirst(bullM, bearM, bullL, bearL, medW, spacing, hImg);
    if (altRaw.isNotEmpty) {
      final altDiag = Map<String, dynamic>.from(diag)
        ..['raw_components'] = altRaw.length
        ..['dropped_wide'] = 0
        ..['dropped_label_runs'] = 0;
      final (alt, _) = _finish(altRaw, altDiag, bullM, bearM, minH, openH);
      final altSp = alt.length >= 3 ? medianOf([for (var i = 1; i < alt.length; i++) alt[i].x - alt[i - 1].x]) : 0.0;
      if (altSp > 0 &&
          alt.length >= 1.15 * candles.length &&
          missingSlots([for (final c in alt) c.x], altSp) < missingSlots([for (final c in candles) c.x], altSp)) {
        altDiag['mode'] = 'bodies_first';
        altDiag['first_pass_candles'] = candles.length;
        return (alt, altDiag);
      }
    }
  }
  return (candles, diag);
}

const overlayTrigger = 3;

/// Empty grid slots between detected candles (the reader's rule), on the given or their own spacing.
int missingSlots(List<int> xs, [double? sp]) {
  if (xs.length < 3) return 0;
  final gaps = [for (var i = 1; i < xs.length; i++) xs[i] - xs[i - 1]];
  final s = sp ?? medianOf(gaps);
  var n = 0;
  for (final g in gaps) {
    if (g > 1.5 * s) n += math.max(0, (g / s + 0.5).floor() - 1);
  }
  return n;
}

/// Body box of a component: only rows at least 80% as wide as the widest row.
(int, int, int, int) _trimRows(List<List<bool>> m, int c0, int c1, int x, int y) {
  final widths = [
    for (final row in m) [for (var q = c0; q <= c1; q++) if (row[q]) 1].length
  ];
  final mx = widths.reduce(math.max);
  final full = [for (var r = 0; r < widths.length; r++) if (widths[r] >= 0.8 * mx) r];
  return (x, y + full.first, c1 - c0 + 1, full.last - full.first + 1);
}

/// Boxes made of horizontal runs longer than 2 candle slots, grouped across the text rows that break them.
List<(int, int, int, int)> _labelBoxes(Mask mask, double sp) {
  final minRun = (2 * sp).truncate() + 1;
  final w = mask.width, h = mask.height;
  final runs = Mask(w, h);
  for (var yy = 0; yy < h; yy++) {
    var sum = 0;
    for (var xx = 0; xx < w; xx++) {
      sum += mask.data[yy * w + xx];
    }
    if (sum < minRun) continue;
    var xx = 0;
    while (xx < w) {
      if (mask.data[yy * w + xx] == 0) {
        xx++;
        continue;
      }
      var e = xx;
      while (e + 1 < w && mask.data[yy * w + e + 1] != 0) {
        e++;
      }
      if (e - xx + 1 >= minRun) {
        for (var q = xx; q <= e; q++) {
          runs.data[yy * w + q] = 1;
        }
      }
      xx = e + 1;
    }
  }
  final parts = [for (final c in components8(runs).components) (c.y, c.x, c.w, c.h)]
    ..sort((a, b) => a.$1 != b.$1
        ? a.$1.compareTo(b.$1)
        : a.$2 != b.$2
            ? a.$2.compareTo(b.$2)
            : a.$3 != b.$3
                ? a.$3.compareTo(b.$3)
                : a.$4.compareTo(b.$4));
  final groups = <List<int>>[]; // [x0, y0, x1, y1]
  for (final (y, x, pw, ph) in parts) {
    var placed = false;
    for (final g in groups) {
      final overlap = math.min(g[2], x + pw - 1) - math.max(g[0], x) + 1;
      if (overlap >= 0.5 * math.min(g[2] - g[0] + 1, pw) && y - g[3] - 1 <= 1.5 * sp) {
        g[0] = math.min(g[0], x);
        g[1] = math.min(g[1], y);
        g[2] = math.max(g[2], x + pw - 1);
        g[3] = math.max(g[3], y + ph - 1);
        placed = true;
        break;
      }
    }
    if (!placed) groups.add([x, y, x + pw - 1, y + ph - 1]);
  }
  return [for (final g in groups) if (g[3] - g[1] + 1 >= 5) (g[0], g[1], g[2] - g[0] + 1, g[3] - g[1] + 1)];
}

/// Candles from their bodies: a k×k opening (k = half a body) erases lines thinner than k in every direction
/// (indicator lines, wicks) and keeps bodies; wicks are then followed up and down from the body centre.
List<DetectedCandle> _bodiesFirst(Mask bullM, Mask bearM, Mask bullL, Mask bearL, double medW, double spIn, int hImg) {
  final k = math.max(3, (medW * 0.5).truncate());
  var sp = spIn;
  final centres = <int>[];
  for (final mask in [bullM, bearM]) {
    for (final c in components8(openRect(mask, k, k)).components) {
      if (k <= c.w && c.w <= 2.2 * medW) centres.add(c.x + c.w ~/ 2);
    }
  }
  centres.sort();
  if (centres.length >= 5) {
    sp = medianOf([for (var i = 1; i < centres.length; i++) centres[i] - centres[i - 1]]);
    sp = math.max(sp, k.toDouble());
  }
  var out = <DetectedCandle>[];
  for (final (mask0, loose0, bullish) in [(bullM, bullL, true), (bearM, bearL, false)]) {
    var mask = mask0, loose = loose0;
    final boxes = _labelBoxes(mask0, sp);
    if (boxes.isNotEmpty) {
      mask = Mask.from(mask0.width, mask0.height, Uint8List.fromList(mask0.data));
      loose = Mask.from(loose0.width, loose0.height, Uint8List.fromList(loose0.data));
      for (final (bx, by, bw, bh) in boxes) {
        for (var yy = by; yy < by + bh; yy++) {
          for (var xx = bx; xx < bx + bw; xx++) {
            mask.data[yy * mask.width + xx] = 0;
            loose.data[yy * mask.width + xx] = 0;
          }
        }
      }
    }
    final lab = components8(openRect(mask, k, k));
    final bodies = <(int, int, int, int)>[];
    for (final c in lab.components) {
      final x = c.x, y = c.y, w = c.w, h = c.h;
      if (k <= w && w <= 1.3 * sp) {
        bodies.add(_trimRows(lab.crop(c), 0, w - 1, x, y));
      } else if (w > 1.3 * sp && h >= w) {
        // a body with a thick piece of line still attached (or two bodies joined by one): keep the body columns
        final m = lab.crop(c);
        final cols = [for (var q = 0; q < w; q++) m.where((row) => row[q]).length];
        final mx = cols.reduce(math.max);
        final strong = [for (final v in cols) v >= 0.5 * mx];
        var j = 0;
        while (j < w) {
          if (!strong[j]) {
            j++;
            continue;
          }
          var e = j;
          while (e + 1 < w && strong[e + 1]) {
            e++;
          }
          if (k <= e - j + 1 && e - j + 1 <= 1.3 * sp) {
            // rows of the column slice that hold pixels define its extent before trimming
            final rowsAny = [for (var r = 0; r < h; r++) if ([for (var q = j; q <= e; q++) m[r][q]].contains(true)) r];
            final sub = m.sublist(rowsAny.first, rowsAny.last + 1);
            final t = _trimRows(sub, j, e, x + j, y + rowsAny.first);
            bodies.add(t);
          }
          j = e + 1;
        }
      }
    }
    for (final (x, y, w, h) in bodies) {
      final cx = x + w ~/ 2;
      final yHigh = _extend(loose, cx, y, -1), yLow = _extend(loose, cx, y + h - 1, 1);
      final (yo, yc) = bullish ? (y + h - 1, y) : (y, y + h - 1);
      out.add(DetectedCandle(cx, x, x + w - 1, yHigh, yLow, yo, yc, bullish, true));
    }
  }
  out = _stableSortBy(out, (c) => c.x);
  final keep = <DetectedCandle>[];
  for (var i = 0; i < out.length; i++) {
    final c = out[i];
    final nb = [
      for (final o in [...out.sublist(math.max(0, i - 4), i), ...out.sublist(i + 1, math.min(out.length, i + 5))])
        (o.yHigh + o.yLow) / 2
    ];
    if (nb.isNotEmpty && ((c.yHigh + c.yLow) / 2 - medianOf(nb)).abs() > 0.2 * hImg) continue;
    keep.add(c);
  }
  final grid = <DetectedCandle>[];
  for (final c in keep) {
    if (grid.isNotEmpty && c.x - grid.last.x < 0.6 * sp) {
      if (c.yLow - c.yHigh > grid.last.yLow - grid.last.yHigh) grid[grid.length - 1] = c;
      continue;
    }
    grid.add(c);
  }
  while (grid.length >= 5 && grid.last.x - grid[grid.length - 2].x > 5 * sp) {
    grid.removeLast();
  }
  while (grid.length >= 5 && grid[1].x - grid[0].x > 5 * sp) {
    grid.removeAt(0);
  }
  if (grid.length < 5) return grid;
  // flat candles (body shorter than k) were erased with the lines: a k-wide, >= 2 px tall body in each empty slot
  final flats = <(int, int, int, int, bool, Mask)>[];
  for (final (mask, loose, bullish) in [(bullM, bullL, true), (bearM, bearL, false)]) {
    for (final c in components8(openRect(mask, k, 2)).components) {
      if (k <= c.w && c.w <= 1.3 * sp && c.h < k) flats.add((c.x, c.y, c.w, c.h, bullish, loose));
    }
  }
  final filled = <DetectedCandle>[];
  for (var i = 0; i + 1 < grid.length; i++) {
    final a = grid[i], b = grid[i + 1];
    filled.add(a);
    final gap = b.x - a.x;
    final slots = (gap / sp + 0.5).floor() - 1;
    if (gap <= 1.5 * sp || slots < 1) continue;
    final loY = math.min(a.yHigh, b.yHigh) - 3 * sp, hiY = math.max(a.yLow, b.yLow) + 3 * sp;
    for (var j = 1; j <= slots; j++) {
      final want = a.x + gap * j / (slots + 1);
      (int, int, int, int, bool, Mask)? best;
      for (final f in flats) {
        final fx = f.$1 + f.$3 ~/ 2;
        if ((fx - want).abs() <= 0.35 * sp && loY <= f.$2 && f.$2 + f.$4 <= hiY) {
          if (best == null || (fx - want).abs() < (best.$1 + best.$3 ~/ 2 - want).abs()) best = f;
        }
      }
      if (best != null) {
        final (x, y, w, h, bullish, loose) = best;
        final cx = x + w ~/ 2;
        final (yo, yc) = bullish ? (y + h - 1, y) : (y, y + h - 1);
        filled.add(DetectedCandle(cx, x, x + w - 1, _extend(loose, cx, y, -1), _extend(loose, cx, y + h - 1, 1), yo, yc,
            bullish, true));
      }
    }
  }
  filled.add(grid.last);
  return filled;
}

/// Common clean-up of a raw candle list: wide boxes, tiny candles, duplicates, label boxes and fragments.
(List<DetectedCandle>, Map<String, dynamic>) _finish(
    List<DetectedCandle> raw, Map<String, dynamic> diag, Mask bullM, Mask bearM, int minH, int openH) {
  final resolvedWidths = [for (final c in raw) if (c.bodyResolved) c.right - c.left + 1];
  final medW = medianOf(resolvedWidths.isEmpty ? [1] : resolvedWidths);
  var candles = <DetectedCandle>[];
  for (final c in raw) {
    if (c.bodyResolved && c.right - c.left + 1 > 2.2 * medW) {
      diag['dropped_wide'] = (diag['dropped_wide'] as int) + 1;
      continue;
    }
    candles.add(c);
  }

  // second pass: tiny candles erased by the vertical opening, recovered in empty grid slots
  if (candles.length >= 5) {
    final sp = medianOf([for (var i = 1; i < candles.length; i++) candles[i].x - candles[i - 1].x]);
    final taken = [for (final c in candles) c.x];
    final yMin = candles.map((c) => c.yHigh).reduce(math.min) - 2 * sp;
    final yMax = candles.map((c) => c.yLow).reduce(math.max) + 2 * sp;
    final xMax = candles.map((c) => c.right).reduce(math.max);
    for (final (mask, bullish) in [(bullM, true), (bearM, false)]) {
      final lab = components8(mask);
      for (final comp in lab.components) {
        final x = comp.x, y = comp.y, w = comp.w, h = comp.h;
        final cx = x + w ~/ 2;
        if (!(2 <= h && h < minH + openH && w >= math.max(2, 0.5 * medW) && w <= 1.3 * sp)) continue;
        if (y < yMin || y + h > yMax || cx > xMax + sp) continue;
        final m = lab.crop(comp);
        final rowSums = [for (final row in m) row.where((b) => b).length];
        if (rowSums.reduce(math.max) < math.max(2, 0.5 * medW)) continue;
        if (taken.map((t) => (t - cx).abs()).reduce(math.min) < 0.6 * sp) continue;
        final rows = [for (var r = 0; r < h; r++) if (rowSums[r] > 0) r];
        final yh = y + rows.first, yl = y + rows.last;
        final thr = math.max(2, 0.6 * w);
        final bodyRows = [for (var r = 0; r < h; r++) if (rowSums[r] >= thr) r];
        final (bt, bb) = bodyRows.isNotEmpty ? (y + bodyRows.first, y + bodyRows.last) : (yh, yl);
        final (yo, yc) = bullish ? (bb, bt) : (bt, bb);
        candles.add(DetectedCandle(cx, x, x + w - 1, yh, yl, yo, yc, bullish, true));
        taken.add(cx);
        diag['recovered_small'] = ((diag['recovered_small'] as int?) ?? 0) + 1;
      }
    }
    candles = _stableSortBy(candles, (c) => c.x);
  }

  // same column detected in both colours → keep the taller one
  var dedup = <DetectedCandle>[];
  for (final c in candles) {
    if (dedup.isNotEmpty && (c.x - dedup.last.x).abs() < math.max(2, medW * 0.5)) {
      if (c.yLow - c.yHigh > dedup.last.yLow - dedup.last.yHigh) dedup[dedup.length - 1] = c;
      continue;
    }
    dedup.add(c);
  }

  // runs of >= 3 neighbours with identical extent and no wick are a label box split by its text
  bool boxy(DetectedCandle c) =>
      math.min(c.yOpen, c.yClose) - c.yHigh <= 1 && c.yLow - math.max(c.yOpen, c.yClose) <= 1;
  final keep = List<bool>.filled(dedup.length, true);
  var i = 0;
  while (i < dedup.length) {
    var j = i;
    while (j + 1 < dedup.length &&
        (dedup[j + 1].yHigh - dedup[i].yHigh).abs() <= 1 &&
        (dedup[j + 1].yLow - dedup[i].yLow).abs() <= 1 &&
        boxy(dedup[j + 1]) &&
        boxy(dedup[i])) {
      j++;
    }
    if (j - i + 1 >= 3) {
      for (var k = i; k <= j; k++) {
        keep[k] = false;
      }
      diag['dropped_label_runs'] = (diag['dropped_label_runs'] as int) + j - i + 1;
    }
    i = j + 1;
  }
  dedup = [for (var k = 0; k < dedup.length; k++) if (keep[k]) dedup[k]];

  // label fragments right after the last candle (the current-price tag cut by its text into 1-2 pieces, typical
  // after downscaling) must not become the "forming" candle: no wicks, and closer than the candle spacing or
  // clearly narrower than the candles. A real candle — even a forming one without wicks yet — sits on its own
  // grid slot with the full body width.
  if (dedup.length >= 5) {
    final sp = medianOf([for (var k = 1; k < dedup.length; k++) dedup[k].x - dedup[k - 1].x]);
    bool fragment(DetectedCandle c, DetectedCandle prev) =>
        boxy(c) && (c.x - prev.x < 0.9 * sp || c.right - c.left + 1 < 0.8 * medW);
    while (dedup.length >= 5 && fragment(dedup.last, dedup[dedup.length - 2])) {
      dedup = dedup.sublist(0, dedup.length - 1);
      diag['dropped_label_runs'] = (diag['dropped_label_runs'] as int) + 1;
    }
  }

  diag['median_body_width'] = medW;
  if (dedup.length >= 3) {
    final gaps = [for (var k = 1; k < dedup.length; k++) (dedup[k].x - dedup[k - 1].x).toDouble()];
    final mean = gaps.reduce((a, b) => a + b) / gaps.length;
    final sd = math.sqrt(gaps.map((g) => (g - mean) * (g - mean)).reduce((a, b) => a + b) / gaps.length);
    diag['median_spacing'] = medianOf(gaps);
    diag['spacing_cv'] = sd / math.max(1.0, mean);
  }
  return (dedup, diag);
}
