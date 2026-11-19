/// Shrink chart images before analysis: big screenshots and photos are slow to read and use a lot of memory
/// on phones and tablets. The longest side is limited to `maxSide` (Settings.chart_max_side) with area
/// averaging, and the result is stored as PNG: JPEG compression was measured to create false candles
/// (75% quality: +4 candles on one chart), while averaging + PNG kept the last candle right on every test chart.
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as im;

import 'engine_api.dart';


Future<Uint8List> _readAll(UploadFile f) async {
  final b = BytesBuilder(copy: false);
  await for (final c in f.openRead()) {
    b.add(c);
  }
  return b.takeBytes();
}

/// Returns (bytes, width, height, shrunk) — runs in a background isolate.
(Uint8List, int, int, bool)? _shrink(Uint8List data, int maxSide) {
  final img = im.decodeImage(data);
  if (img == null) return null; // not an image: let the engine answer with its own error
  final longest = math.max(img.width, img.height);
  final needsResize = maxSide > 0 && longest > maxSide;
  if (!needsResize) return (data, img.width, img.height, false); // already small enough: sent unchanged
  final out = im.copyResize(img,
      width: img.width >= img.height ? maxSide : null,
      height: img.height > img.width ? maxSide : null,
      interpolation: im.Interpolation.average);
  return (im.encodePng(out, level: 6), out.width, out.height, true);
}

/// The image to send for analysis. `maxSide` 0 = keep the original.
Future<UploadFile> prepareChartImage(UploadFile f, int maxSide) async {
  if (maxSide <= 0) return f;
  final data = await _readAll(f);
  // read only the header (size) first: small or unknown files are sent as they are, without decoding
  final decoder = im.findDecoderForData(data);
  final info = decoder?.startDecode(data);
  if (info == null || math.max(info.width, info.height) <= maxSide) {
    return UploadFile(name: f.name, length: data.length, openRead: () => Stream.value(data));
  }
  final r = await Isolate.run(() => _shrink(data, maxSide));
  if (r == null || !r.$4) return UploadFile(name: f.name, length: data.length, openRead: () => Stream.value(data));
  final bytes = r.$1;
  final name = '${f.name.replaceFirst(RegExp(r'\.[^.]*$'), '')}.png';
  return UploadFile(name: name, length: bytes.length, openRead: () => Stream.value(bytes));
}
