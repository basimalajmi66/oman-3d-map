@TestOn('vm')
library;

import 'dart:io';

import 'package:image/image.dart' as im;
import 'package:test/test.dart';
import 'package:uata_app/engine/vision/imgops.dart';
import 'package:uata_app/engine/vision/reader.dart';

import 'parity.dart';

RgbImage loadRgb(String path) {
  final d = im.decodeImage(File(path).readAsBytesSync())!.convert(numChannels: 3);
  return RgbImage(d.width, d.height, d.getBytes(order: im.ChannelOrder.rgb));
}

void main() {
  test('chart reader matches the Python reader pixel for pixel on the same images', () async {
    final dir = Directory.systemTemp.createTempSync('uata_vision');
    final cases = <Map<String, dynamic>>[
      for (final style in ['dark_classic', 'dark_tv', 'light_classic', 'light_tv'])
        {'seed': 1, 'render': {'style': style}},
      {'seed': 2, 'render': {'style': 'dark_tv', 'ma_overlay': true}},
      {'seed': 3, 'render': {'style': 'light_tv', 'ma_overlay': true, 'grid': false}},
      {'seed': 4, 'n': 120, 'render': {'style': 'dark_classic', 'width': 1400, 'height': 720}},
      {'seed': 5, 'n': 30, 'render': {'style': 'light_classic', 'width': 640, 'height': 400}},
      {'seed': 6, 'vol': 0.0002, 'render': {'style': 'dark_tv'}}, // tiny candles (second pass)
      {'seed': 7, 'render': {'style': 'dark_tv'}, 'degrade': {'jpeg_quality': 60}},
      {'seed': 8, 'render': {'style': 'light_tv'}, 'degrade': {'blur_ksize': 5}},
      {'seed': 9, 'render': {'style': 'dark_classic'}, 'degrade': {'blur_ksize': 11}}, // must abstain
      {'seed': 10, 'render': {'style': 'dark_classic'}, 'degrade': {'noise_sigma': 6, 'seed': 1}},
      {'seed': 11, 'render': {'style': 'light_classic'}, 'degrade': {'scale': 0.5}},
      {'seed': 12, 'n': 6, 'render': {'style': 'dark_tv'}}, // too few candles
      {'uptrend': true, 'render': {'style': 'dark_tv'}},
      {'seed': 13, 'render': {'style': 'dark_tv', 'price_tag': false, 'axis_labels': false}},
      {'seed': 14, 'n': 130, 'render': {'style': 'dark_tv', 'width': 1400}, 'limit': 60}, // newest 60 candles only
      {'seed': 15, 'n': 90, 'render': {'style': 'light_tv'}, 'limit': 100}, // fewer than the limit: unchanged
      // indicator lines and BUY/SELL labels in the candle colours (Pocket Option style): body-first reading
      for (final (seed, style) in [(0, 'dark_tv'), (4, 'light_tv'), (7, 'dark_classic'), (10, 'dark_tv')])
        {'seed': seed, 'n': 80, 'render': {'style': style, 'supertrend': true, 'signal_labels': true, 'width': 1400, 'height': 720}},
      {'seed': 2, 'n': 60, 'render': {'style': 'light_tv', 'supertrend': true}}, // the line only
    ];
    for (var i = 0; i < cases.length; i++) {
      cases[i]['path'] = '${dir.path}/chart_$i.png';
    }
    final py = await python({'op': 'render_read', 'cases': cases}) as List;
    var usable = 0, abstained = 0;
    for (var i = 0; i < cases.length; i++) {
      var dart = await ChartReader().read(loadRgb(cases[i]['path'] as String));
      if (cases[i]['limit'] != null) dart = limitCandles(dart, cases[i]['limit'] as int);
      final ref = Map<String, dynamic>.from(py[i] as Map);
      expectSame(dart, ref, path: 'case$i ${cases[i]['render']} ${cases[i]['degrade'] ?? ''}', tol: 1e-9);
      dart['usable'] == true ? usable++ : abstained++;
    }
    expect(usable, greaterThan(14));
    final modes = [for (final r in py) (r as Map)['detection']['mode']];
    expect(modes.where((m) => m == 'bodies_first').length, greaterThanOrEqualTo(4)); // the new path is exercised
    expect(abstained, greaterThan(0));
    dir.deleteSync(recursive: true);
  }, skip: paritySkip, timeout: const Timeout(Duration(minutes: 3)));
}
