import 'package:test/test.dart';
import 'package:uata_app/engine/analysis/analyzer.dart';
import 'package:uata_app/engine/signal/chart_read.dart';
import 'package:uata_app/l10n/strings.dart';

import 'parity.dart';

Map<String, dynamic> reading(List<Map<String, double>> s, {bool usable = true}) => {
      'usable': usable, 'data_quality': 0.9,
      'candles': [
        for (var i = 0; i < s.length; i++)
          {
            'status': i == s.length - 1 ? 'possibly_forming' : 'closed',
            for (final k in ['open', 'high', 'low', 'close']) 'rel_$k': s[i][k],
          }
      ],
    };

void main() {
  test('a rising chart reads "up" with a buy as the next step; a falling one "down" with a sell', () {
    final up = reading(series(21, n: 120, drift: 0.0008));
    final down = reading(series(22, n: 120, drift: -0.0008));
    final ru = chartRead(up, analyzeReading(up), durationSec: 60);
    final rd = chartRead(down, analyzeReading(down), durationSec: 60);
    expect(ru['bias'], 'up', reason: '$ru');
    expect((ru['next'] as Map)['action'], 'buy');
    expect((ru['next'] as Map)['duration_sec'], 60);
    expect(ru['bullish'], isNotEmpty);
    expect(rd['bias'], 'down', reason: '$rd');
    expect((rd['next'] as Map)['action'], 'sell');
    // the text the user sees
    final (head, step, _) = readText('ar', ru);
    expect(head, contains('صعود'));
    expect(step, contains('شراء'));
  });

  test('a flat chart is "unclear": the next step is a plan — wait for a break', () {
    final flat = reading(series(23, n: 120, vol: 0.0004));
    final r = chartRead(flat, analyzeReading(flat));
    if (r['bias'] == 'unclear') {
      expect((r['next'] as Map)['action'], 'wait_break');
      final (_, step, lines) = readText('ar', r);
      expect(step, contains('انتظر'));
      expect(lines, isNotEmpty);
    } else {
      expect(['buy', 'sell'], contains((r['next'] as Map)['action']));
    }
  });

  test('no usable picture → no reading, said plainly', () {
    final bad = reading(series(24, n: 120), usable: false);
    final r = chartRead(bad, analyzeReading(bad));
    expect(r['strength'], 'none');
    expect(readText('ar', r).$1, tr('ar', 'read_none'));
  });

  test('every direction over many charts: the reading follows the drift far more often than not', () {
    var right = 0, wrong = 0;
    for (var seed = 1; seed <= 30; seed++) {
      final drift = seed.isEven ? 0.0006 : -0.0006;
      final r = reading(series(100 + seed, n: 150, drift: drift));
      final bias = chartRead(r, analyzeReading(r))['bias'];
      if (bias == (drift > 0 ? 'up' : 'down')) right++;
      if (bias == (drift > 0 ? 'down' : 'up')) wrong++;
    }
    expect(right, greaterThan(wrong * 3), reason: 'right $right wrong $wrong');
  });
}
