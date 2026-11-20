@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:uata_app/engine/vision/axis.dart';
import 'package:uata_app/engine/vision/reader.dart';

import 'parity.dart';
import 'vision_parity_test.dart' show loadRgb;

final _tesseract = () {
  try {
    return Process.runSync('tesseract', ['--version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}();

/// The phone's OCR, as the Android plugin runs it: automatic page segmentation, no character whitelist.
Future<String> cliOcr(Uint8List png, {required bool digits}) async {
  final dir = Directory.systemTemp.createTempSync('uata_ocr');
  try {
    File('${dir.path}/l.png').writeAsBytesSync(png);
    final r = await Process.run('tesseract', ['${dir.path}/l.png', 'stdout', '--psm', '3', '-l', 'eng']);
    return r.stdout as String;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  test('labels → price scale: outliers dropped, look-alike letters fixed, nonsense refused', () {
    // y → price 1.10 at y=100 falling 0.001 per 50 px
    final labels = [for (var i = 0; i < 8; i++) (100.0 + 50 * i, (1.1 - 0.001 * i).toStringAsFixed(5))];
    final s = scaleFromLabels([...labels, (230.0, '9.99999'), (300.0, 'EURUSD')], 'right')!;
    expect(s.labelsUsed, 8);
    expect(s.slope, closeTo(-0.001 / 50, 1e-12));
    expect(s.price(100), closeTo(1.1, 1e-9));
    expect(s.decimals, 5);
    expect(normaliseLabel(' 1.O9l52 '), '1.09152');
    expect(normaliseLabel('3,568.000'), '3568.000');
    expect(normaliseLabel('1,0915'), '1.0915');
    expect(normaliseLabel('12,500,000'), '12500000');
    expect(normaliseLabel('Sell'), 'Sell'); // no digit: left alone (and refused)
    expect(scaleFromLabels([(10.0, '1.1'), (12.0, '1.2'), (14.0, '1.3')], 'right'), isNull); // < 20 px spread
    expect(scaleFromLabels([for (var i = 0; i < 5; i++) (100.0 * i, '${1 + i}')], 'right'), isNull); // rising downwards
    expect(timeframeFromText('EURUSD  30s'), (30, '30s'));
    expect(timeframeFromText('Gold OTC M5'), (300, 'M5'));
    expect(timeframeFromText('nothing here'), (null, null));
  });

  test('real OCR (Tesseract as the phone runs it) reads the axis of synthetic charts: prices match the truth',
      () async {
    final dir = Directory.systemTemp.createTempSync('uata_axis');
    final cases = <Map<String, dynamic>>[
      for (final (i, style) in ['dark_classic', 'dark_tv', 'light_classic', 'light_tv'].indexed)
        {'seed': i, 'render': {'style': style}},
      {'seed': 7, 'render': {'style': 'dark_tv', 'width': 1400, 'height': 720, 'decimals': 3}},
      {'seed': 8, 'render': {'style': 'light_tv', 'supertrend': true, 'signal_labels': true, 'width': 1400, 'height': 720}},
    ];
    for (var i = 0; i < cases.length; i++) {
      cases[i]['path'] = '${dir.path}/c$i.png';
    }
    final truth = await python({'op': 'render_axis', 'cases': cases}) as List;
    var read = 0;
    for (var i = 0; i < cases.length; i++) {
      final t = truth[i] as Map;
      final r = await ChartReader(ocr: LineOcrChartOcr(cliOcr)).read(loadRgb(cases[i]['path'] as String));
      final scale = r['price_scale'] as Map?;
      if (scale == null) continue;
      read++;
      // the slope may differ by a label's rounding; prices over the whole plot must agree within half a label step
      // labels are rounded (e.g. 3 decimals): the read line may be off by up to half a label digit
      final tol = math.max(((t['slope'] as num) * 3).abs(), 0.5 * math.pow(10, -(scale['decimals'] as int)));
      for (final y in [60, 200, 400]) {
        final mine = (scale['slope'] as num) * y + (scale['intercept'] as num);
        final real = (t['slope'] as num) * y + (t['intercept'] as num);
        expect((mine - real).abs(), lessThan(tol), reason: 'case $i y=$y');
      }
      expect(r['warnings'], isNot(contains('price_axis_not_read_relative_units_only')));
      expect((r['summary'] as Map)['prices_read'], isTrue);
      final last = ((r['candles'] as List).first as Map);
      final o = ((t['ohlc'] as List).first as List);
      expect(((last['high'] as num) - (o[1] as num)).abs(), lessThan(tol + ((t['slope'] as num) * 2).abs()));
    }
    expect(read, greaterThanOrEqualTo(cases.length - 1), reason: 'the axis should be read on (almost) every chart');
    dir.deleteSync(recursive: true);
  }, skip: paritySkip != false ? paritySkip : (_tesseract ? false : 'tesseract not installed'), timeout: const Timeout(Duration(minutes: 3)));
}
