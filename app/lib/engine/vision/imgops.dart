/// Pure-Dart image operations that reproduce the OpenCV calls used by the Python chart reader
/// bit-for-bit (verified by parity tests on the same PNG files):
/// BGR→HSV (8-bit, fixed-point tables — verified on all 16.7M colours), BGR→GRAY, INTER_NEAREST resize, morphological opening
/// with a vertical rectangle, 8-connected components with stats, 3×3 Laplacian (REFLECT_101).
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 8-bit RGB image, row-major, 3 bytes per pixel (R, G, B).
class RgbImage {
  RgbImage(this.width, this.height, this.rgb) : assert(rgb.length == width * height * 3);
  final int width, height;
  final Uint8List rgb;

  int r(int x, int y) => rgb[(y * width + x) * 3];
  int g(int x, int y) => rgb[(y * width + x) * 3 + 1];
  int b(int x, int y) => rgb[(y * width + x) * 3 + 2];
}

/// Binary mask (0 / 1), row-major.
class Mask {
  Mask(this.width, this.height) : data = Uint8List(width * height);
  Mask.from(this.width, this.height, this.data);
  final int width, height;
  final Uint8List data;
  bool at(int x, int y) => data[y * width + x] != 0;
  int count() {
    var n = 0;
    for (final v in data) {
      n += v;
    }
    return n;
  }
}

/// cvRound: round half to even.
int cvRound(double v) {
  final f = v.floorToDouble();
  final diff = v - f;
  if (diff > 0.5) return f.toInt() + 1;
  if (diff < 0.5) return f.toInt();
  return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
}

const _hsvShift = 12;
final Int32List _sdiv = () {
  final t = Int32List(256);
  for (var i = 1; i < 256; i++) {
    t[i] = cvRound((255 << _hsvShift) / i);
  }
  return t;
}();
final Int32List _hdiv180 = () {
  final t = Int32List(256);
  for (var i = 1; i < 256; i++) {
    t[i] = cvRound((180 << _hsvShift) / (6.0 * i));
  }
  return t;
}();

/// OpenCV COLOR_BGR2HSV for 8-bit images (H in 0..179). Returns (h, s, v) planes.
(Uint8List, Uint8List, Uint8List) toHsv(RgbImage img) {
  final n = img.width * img.height;
  final hh = Uint8List(n), ss = Uint8List(n), vv = Uint8List(n);
  final p = img.rgb;
  for (var i = 0; i < n; i++) {
    final r = p[i * 3], g = p[i * 3 + 1], b = p[i * 3 + 2];
    var v = b, vmin = b;
    if (g > v) v = g;
    if (r > v) v = r;
    if (g < vmin) vmin = g;
    if (r < vmin) vmin = r;
    final diff = v - vmin;
    final vr = v == r ? -1 : 0;
    final vg = v == g ? -1 : 0;
    final s = (diff * _sdiv[v] + (1 << (_hsvShift - 1))) >> _hsvShift;
    var h = (vr & (g - b)) + (~vr & ((vg & (b - r + 2 * diff)) + ((~vg) & (r - g + 4 * diff))));
    h = (h * _hdiv180[diff] + (1 << (_hsvShift - 1))) >> _hsvShift;
    if (h < 0) h += 180;
    hh[i] = h;
    ss[i] = s;
    vv[i] = v;
  }
  return (hh, ss, vv);
}

/// OpenCV COLOR_BGR2GRAY for 8-bit images (fixed point, 15-bit shift — verified on all 16.7M colours).
Uint8List toGrey(RgbImage img) {
  final n = img.width * img.height;
  final out = Uint8List(n);
  final p = img.rgb;
  for (var i = 0; i < n; i++) {
    out[i] = (p[i * 3 + 2] * 3735 + p[i * 3 + 1] * 19235 + p[i * 3] * 9798 + (1 << 14)) >> 15;
  }
  return out;
}

/// OpenCV INTER_NEAREST resize.
RgbImage resizeNearest(RgbImage img, int w, int h) {
  final out = Uint8List(w * h * 3);
  final fx = img.width / w, fy = img.height / h;
  for (var y = 0; y < h; y++) {
    final sy = math.min((y * fy).floor(), img.height - 1);
    for (var x = 0; x < w; x++) {
      final sx = math.min((x * fx).floor(), img.width - 1);
      final s = (sy * img.width + sx) * 3, d = (y * w + x) * 3;
      out[d] = img.rgb[s];
      out[d + 1] = img.rgb[s + 1];
      out[d + 2] = img.rgb[s + 2];
    }
  }
  return RgbImage(w, h, out);
}

/// Morphological opening with a (1 × kh) rectangle, anchor at kh ~/ 2 (OpenCV defaults:
/// pixels outside the image do not erode / do not dilate).
Mask openVertical(Mask m, int kh) {
  final w = m.width, h = m.height, a = kh ~/ 2;
  final er = Uint8List(w * h);
  for (var x = 0; x < w; x++) {
    for (var y = 0; y < h; y++) {
      var v = 1;
      for (var q = y - a; q < y - a + kh; q++) {
        if (q < 0 || q >= h) continue;
        if (m.data[q * w + x] == 0) {
          v = 0;
          break;
        }
      }
      er[y * w + x] = v;
    }
  }
  final out = Uint8List(w * h);
  for (var x = 0; x < w; x++) {
    for (var y = 0; y < h; y++) {
      for (var q = y - a; q < y - a + kh; q++) {
        if (q < 0 || q >= h) continue;
        if (er[q * w + x] != 0) {
          out[y * w + x] = 1;
          break;
        }
      }
    }
  }
  return Mask.from(w, h, out);
}

/// Morphological opening with a (kw × kh) rectangle, anchor (kw ~/ 2, kh ~/ 2), same border rules as
/// [openVertical]. Separable (rows then columns) — identical to the 2-D operation for binary masks.
Mask openRect(Mask m, int kw, int kh) {
  final w = m.width, h = m.height, ax = kw ~/ 2, ay = kh ~/ 2;
  Uint8List pass(Uint8List src, bool erode, bool horizontal) {
    final out = Uint8List(w * h);
    final k = horizontal ? kw : kh, a = horizontal ? ax : ay, n = horizontal ? w : h;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final pos = horizontal ? x : y;
        var v = erode ? 1 : 0;
        for (var q = pos - a; q < pos - a + k; q++) {
          if (q < 0 || q >= n) continue;
          final s = horizontal ? src[y * w + q] : src[q * w + x];
          if (erode && s == 0) {
            v = 0;
            break;
          }
          if (!erode && s != 0) {
            v = 1;
            break;
          }
        }
        out[y * w + x] = v;
      }
    }
    return out;
  }

  final er = pass(pass(m.data, true, true), true, false);
  return Mask.from(w, h, pass(pass(er, false, true), false, false));
}

class Component {
  Component(this.label, this.x, this.y, this.w, this.h, this.area);
  final int label;
  int x, y, w, h, area;
}

class Labeling {
  Labeling(this.labels, this.width, this.components);
  final Int32List labels; // 0 = background, components numbered 1.. in raster order of their first pixel
  final int width;
  final List<Component> components;

  /// The component's own pixels inside its bounding box (rows × cols).
  List<List<bool>> crop(Component c) => [
        for (var yy = c.y; yy < c.y + c.h; yy++) [for (var xx = c.x; xx < c.x + c.w; xx++) labels[yy * width + xx] == c.label]
      ];
}

/// 8-connected components with bounding boxes and areas (cv2.connectedComponentsWithStats).
Labeling components8(Mask m) {
  final w = m.width, h = m.height;
  final labels = Int32List(w * h);
  final comps = <Component>[];
  final stack = <int>[];
  for (var start = 0; start < w * h; start++) {
    if (m.data[start] == 0 || labels[start] != 0) continue;
    final id = comps.length + 1;
    var minX = w, minY = h, maxX = -1, maxY = -1, area = 0;
    labels[start] = id;
    stack.add(start);
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      final px = p % w, py = p ~/ w;
      area++;
      if (px < minX) minX = px;
      if (px > maxX) maxX = px;
      if (py < minY) minY = py;
      if (py > maxY) maxY = py;
      for (var dy = -1; dy <= 1; dy++) {
        final ny = py + dy;
        if (ny < 0 || ny >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final nx = px + dx;
          if (nx < 0 || nx >= w || (dx == 0 && dy == 0)) continue;
          final q = ny * w + nx;
          if (m.data[q] != 0 && labels[q] == 0) {
            labels[q] = id;
            stack.add(q);
          }
        }
      }
    }
    comps.add(Component(id, minX, minY, maxX - minX + 1, maxY - minY + 1, area));
  }
  return Labeling(labels, w, comps);
}

/// numpy's pairwise summation (blocks of 8 accumulators, recursion above 128 elements), so sums,
/// means and variances agree with numpy to the last bit.
double pairwiseSum(Float64List a, [int start = 0, int? count]) {
  final n = count ?? a.length - start;
  if (n < 8) {
    var res = 0.0; // numpy starts from -0.0; identical for our sums
    for (var i = 0; i < n; i++) {
      res += a[start + i];
    }
    return res;
  }
  if (n <= 128) {
    final r = Float64List(8);
    for (var j = 0; j < 8; j++) {
      r[j] = a[start + j];
    }
    var i = 8;
    for (; i < n - (n % 8); i += 8) {
      for (var j = 0; j < 8; j++) {
        r[j] += a[start + i + j];
      }
    }
    var res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]));
    for (; i < n; i++) {
      res += a[start + i];
    }
    return res;
  }
  var n2 = n ~/ 2;
  n2 -= n2 % 8;
  return pairwiseSum(a, start, n2) + pairwiseSum(a, start + n2, n - n2);
}

/// numpy `.var()` of a float64 array: mean by pairwise sum, then pairwise sum of squared deviations.
double npVar(Float64List a) {
  final m = pairwiseSum(a) / a.length;
  final d = Float64List(a.length);
  for (var i = 0; i < a.length; i++) {
    final x = a[i] - m;
    d[i] = x * x;
  }
  return pairwiseSum(d) / a.length;
}

/// numpy `.std()` of a uint8 array: the mean is summed through numpy's 8192-element cast buffer.
double npStdU8(Uint8List v) {
  final f = Float64List.fromList([for (final x in v) x.toDouble()]);
  var s = 0.0;
  for (var i = 0; i < f.length; i += 8192) {
    s = s + pairwiseSum(f, i, math.min(8192, f.length - i));
  }
  final m = s / f.length;
  for (var i = 0; i < f.length; i++) {
    final x = f[i] - m;
    f[i] = x * x;
  }
  return math.sqrt(pairwiseSum(f) / f.length);
}

/// Variance of the 3×3 Laplacian (ksize 1: [[0,1,0],[1,-4,1],[0,1,0]], BORDER_REFLECT_101).
double laplacianVariance(Uint8List grey, int w, int h) {
  int rf(int i, int n) => n == 1 ? 0 : (i < 0 ? -i : (i >= n ? 2 * n - 2 - i : i));
  final vals = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    final yu = rf(y - 1, h), yd = rf(y + 1, h);
    for (var x = 0; x < w; x++) {
      final xl = rf(x - 1, w), xr = rf(x + 1, w);
      vals[y * w + x] =
          (grey[yu * w + x] + grey[yd * w + x] + grey[y * w + xl] + grey[y * w + xr] - 4 * grey[y * w + x]).toDouble();
    }
  }
  return npVar(vals);
}

double stdOf(Uint8List v) => npStdU8(v);

double medianOf(List<num> xs) {
  final s = [for (final x in xs) x.toDouble()]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}
