@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as im;
import 'package:test/test.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/core/image_prep.dart';
import 'package:uata_app/engine/local/chart_inputs.dart';
import 'package:uata_app/engine/vision/reader.dart';

import 'parity.dart';

UploadFile mem(String name, List<int> b) => UploadFile(name: name, length: b.length, openRead: () => Stream.value(b));
Future<Uint8List> bytesOf(UploadFile f) async => Uint8List.fromList((await f.openRead().toList()).expand((x) => x).toList());

void main() {
  test('a big screenshot is shrunk to the longest side (lossless PNG)', () async {
    final big = im.encodeJpg(im.Image(width: 2400, height: 1500)..clear(im.ColorRgb8(20, 30, 40)));
    final out = await prepareChartImage(mem('shot.jpg', big), 1280);
    expect(out.name, 'shot.png');
    final d = im.decodeImage(await bytesOf(out))!;
    expect([d.width, d.height], [1280, 800]);
    final tall = im.encodePng(im.Image(width: 1080, height: 2400));
    expect(im.decodeImage(await bytesOf(await prepareChartImage(mem('p.png', tall), 1280)))!.height, 1280);
  });

  test('crop: the chosen area only (exact pixels), then the usual shrinking', () async {
    final src = im.Image(width: 400, height: 200)..clear(im.ColorRgb8(0, 0, 0));
    im.fillRect(src, x1: 100, y1: 50, x2: 299, y2: 149, color: im.ColorRgb8(200, 10, 10)); // the "chart"
    final out = await prepareChartImage(mem('c.jpg', im.encodePng(src)), 0, crop: (0.25, 0.25, 0.75, 0.75));
    expect(out.name, 'c.png');
    final d = im.decodeImage(await bytesOf(out))!;
    expect([d.width, d.height], [200, 100]);
    expect([d.getPixel(0, 0).r, d.getPixel(199, 99).r], [200, 200]); // nothing of the black border left
    final big = im.Image(width: 3000, height: 1000);
    final both = im.decodeImage(await bytesOf(await prepareChartImage(mem('b.png', im.encodePng(big)), 1280, crop: (0.0, 0.0, 0.5, 1.0))))!;
    expect([both.width, both.height], [1280, 853]); // 1500×1000 cropped, then shrunk
    expect(cropRect((0.0, 0.0, 1.0, 1.0), 10, 10), (0, 0, 10, 10));
    expect(cropRect((0.99, 0.99, 0.99, 0.99), 10, 10), (9, 9, 1, 1)); // never empty
  });

  test('small images, "original size" and non-images are left alone', () async {
    final small = im.encodePng(im.Image(width: 800, height: 450));
    final kept = await prepareChartImage(mem('s.png', small), 1280);
    expect(kept.name, 's.png');
    expect(await bytesOf(kept), small);
    final big = im.encodePng(im.Image(width: 3000, height: 2000));
    expect((await prepareChartImage(mem('b.png', big), 0)).name, 'b.png');
    final junk = 'not an image'.codeUnits;
    expect(await bytesOf(await prepareChartImage(mem('x.png', junk), 1280)), junk); // the engine reports it
  });

  test('a large real chart shrunk to 1280 px is still read correctly (same candles)', () async {
    final dir = Directory.systemTemp.createTempSync('uata_shrink');
    final path = '${dir.path}/big.png';
    final py = await python({
      'op': 'render_read',
      'cases': [
        {'seed': 21, 'n': 80, 'path': path, 'render': {'style': 'dark_tv', 'width': 2560, 'height': 1440}}
      ],
    }) as List;
    final original = py.single as Map;
    final shrunk = await prepareChartImage(mem('big.png', File(path).readAsBytesSync()), 1280);
    final reading = await ChartReader().read(rgbOf(im.decodeImage(await bytesOf(shrunk))!));
    expect(original['usable'], true);
    expect(reading['usable'], true, reason: '${reading['abstain_reasons']}');
    expect((reading['candles'] as List).length, (original['candles'] as List).length);
    final dirs = [for (final c in reading['candles'] as List) c['bullish']];
    expect(dirs, [for (final c in original['candles'] as List) c['bullish']]); // every candle's direction kept
    expect(shrunk.length, lessThan(File(path).lengthSync()));
    dir.deleteSync(recursive: true);
  }, skip: paritySkip);

  test('shrinking keeps charts readable: last (forming) candle always right, almost every candle found', () async {
    final dir = Directory.systemTemp.createTempSync('uata_shrink_many');
    final cases = <Map<String, dynamic>>[];
    var k = 0;
    for (final style in ['dark_classic', 'dark_tv', 'light_classic', 'light_tv']) {
      for (final size in [[2560, 1440], [2000, 1250]]) {
        cases.add({'seed': 30 + k, 'n': 60 + (k * 13) % 60, 'path': '${dir.path}/s$k.png',
          'render': {'style': style, 'width': size[0], 'height': size[1], 'ma_overlay': k.isOdd}});
        k++;
      }
    }
    final py = await python({'op': 'render_read', 'cases': cases}) as List;
    var total = 0, errors = 0;
    for (var i = 0; i < cases.length; i++) {
      final file = File(cases[i]['path'] as String);
      final shrunk = await prepareChartImage(mem('c.png', file.readAsBytesSync()), 1280);
      final img = im.decodeImage(await bytesOf(shrunk))!;
      expect(img.width, 1280);
      final r = await ChartReader().read(rgbOf(img));
      final o = (py[i] as Map)['candles'] as List;
      final scale = 1280 / (cases[i]['render'] as Map)['width'];
      expect(r['usable'], true, reason: 'case $i');
      final last = (r['candles'] as List).last;
      expect(((last['x'] as int) - (o.last['x'] as int) * scale).abs(), lessThanOrEqualTo(3), reason: 'case $i: forming candle');
      expect(last['status'], 'possibly_forming');
      total += o.length;
      errors += ((r['candles'] as List).length - o.length).abs();
    }
    expect(errors / total, lessThan(0.02), reason: '$errors of $total candles differ');
    dir.deleteSync(recursive: true);
  }, skip: paritySkip, timeout: const Timeout(Duration(minutes: 3)));
}
