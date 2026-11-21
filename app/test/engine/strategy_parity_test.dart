@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:uata_app/engine/analysis/analyzer.dart';
import 'package:uata_app/engine/signal/decision.dart';
import 'package:uata_app/engine/strategy/backtest.dart';
import 'package:uata_app/engine/strategy/conditions.dart' as cd;
import 'package:uata_app/engine/strategy/features.dart';
import 'package:uata_app/engine/strategy/translate.dart';

import 'parity.dart';

FeatureSet fsOf(List<Map<String, double>> s) => FeatureSet([for (final c in s) c['open']!], [for (final c in s) c['high']!],
    [for (final c in s) c['low']!], [for (final c in s) c['close']!]);

final params = <String, List<Map<String, dynamic>>>{
  'rsi_below': [{}, {'value': 40}],
  'rsi_above': [{}, {'value': 60}],
  'price_above_ema': [{}, {'period': 9}, {'period': 50}, {'period': 5}, {'period': 13}, {'period': 200}],
  'price_below_ema': [{}, {'period': 9}, {'period': 200}],
  'stoch_below': [{}, {'value': 30}, {'value': 50}],
  'stoch_above': [{}, {'value': 70}, {'value': 50}],
  'adx_above': [{}, {'value': 15}, {'value': 35}],
  'adx_below': [{}, {'value': 30}],
  'ema_cross_up': [{}, {'fast': 9, 'slow': 21}, {'fast': 21, 'slow': 50}],
  'ema_cross_down': [{}, {'fast': 9, 'slow': 21}],
  'candle_streak_up': [{}, {'n': 2}, {'n': 5}],
  'candle_streak_down': [{}, {'n': 2}],
  'near_support': [{}, {'atr': 1.5}],
  'near_resistance': [{}, {'atr': 1.5}],
  'pattern': [
    for (final p in cd.patternNames) {'name': p}
  ],
  'market': [{'condition': 'trending'}, {'condition': 'ranging'}, {'condition': 'volatile'}],
  'momentum_up': [{}, {'atr': 0.5}],
  'momentum_down': [{}, {'atr': 0.5}],
};

final defn = {
  'long': {
    'all': [{'id': 'trend_up'}, {'id': 'bullish_candle'}]
  },
  'short': {
    'all': [{'id': 'trend_down'}, {'id': 'bearish_candle'}]
  },
  'veto': [{'id': 'market', 'condition': 'volatile'}],
  'duration_sec': 60,
};

void main() {
  test('every condition on every bar, trend, market condition and S/R levels match Python', () async {
    for (final seed in [1, 2, 3]) {
      final s = series(seed, n: 400, drift: (seed - 2) * 0.0003, vol: seed == 3 ? 0.002 : 0.0008);
      final py = await python({'op': 'conditions', 'series': s, 'params': params, 'definition': defn}) as Map;
      final fs = fsOf(s);
      final def = cd.validateDefinition(defn);
      for (final cid in cd.catalog.keys) {
        for (final p in (params[cid] ?? const [<String, dynamic>{}])) {
          final c = cd.validate({'id': cid, ...p});
          final key = "$cid:${_pyJson(p)}";
          expect([for (var i = 0; i < fs.n; i++) cd.holds(fs, i, c)], py[key], reason: 'seed $seed $key');
        }
      }
      expect([for (var i = 0; i < fs.n; i++) cd.signalAt(fs, i, def)], py['_signal'], reason: 'signals seed $seed');
      expect([for (var i = 0; i < fs.n; i++) fs.trend(i)], py['_trend']);
      expect([for (var i = 0; i < fs.n; i++) fs.marketCondition(i)], py['_market']);
      expectSame([for (var i = 0; i < fs.n; i++) [for (final lv in fs.levels(i)) [lv.$1, lv.$2, lv.$3]]], py['_levels']);
    }
  }, skip: paritySkip);

  test('backtests match Python (trades, metrics, OOS split, gate)', () async {
    final cases = [
      {'series': series(11, n: 1500, drift: 0.0002), 'definition': defn, 'timeframe_sec': 30},
      {'series': series(12, n: 1500), 'definition': defn, 'timeframe_sec': 30, 'payout': 0.8, 'in_sample': 0.5},
      {
        'series': series(13, n: 1200, vol: 0.002),
        'definition': {
          'long': {
            'all': [{'id': 'rsi_below', 'value': 35}, {'id': 'near_support', 'atr': 1.0}]
          },
          'short': {
            'all': [{'id': 'rsi_above', 'value': 65}, {'id': 'near_resistance', 'atr': 1.0}]
          },
          'duration_sec': 180,
        },
        'timeframe_sec': 60,
        'synthetic': true,
      },
      {
        'series': series(14, n: 1000, drift: -0.0002),
        'definition': {
          'long': {
            'all': [{'id': 'breakout_up'}]
          },
          'short': {
            'all': [{'id': 'breakdown'}, {'id': 'macd_negative'}]
          },
          'duration_sec': 90,
        },
        'timeframe_sec': 30,
      },
    ];
    final py = await python({'op': 'backtest', 'cases': cases}) as List;
    for (var k = 0; k < cases.length; k++) {
      final c = cases[k];
      final r = runBacktest(fsOf(c['series'] as List<Map<String, double>>), cd.validateDefinition(c['definition'] as Map),
          c['timeframe_sec'] as int,
          payout: (c['payout'] as num? ?? 0.85).toDouble(), inSample: (c['in_sample'] as num? ?? 0.7).toDouble());
      r['gate'] = gate(r, synthetic: c['synthetic'] == true);
      expect((py[k] as Map)['all']['trades'], greaterThan(0), reason: 'case $k should trade');
      expectSame(r, py[k], path: 'case$k');
    }
  }, skip: paritySkip);

  test('14-step decisions match Python (WAIT reasons and BUY/SELL)', () async {
    final settings = {
      'candle_timeframe_sec': 30, 'min_data_quality_to_signal': 0.6, 'min_confluence_factors': 3,
      'min_confidence_to_signal': 0.65, 'trade_duration_min_sec': 60, 'trade_duration_max_sec': 180,
    };
    Map<String, dynamic> reading(List<Map<String, double>> s, {double quality = 0.9, bool usable = true, int? tf}) => {
          'usable': usable, 'data_quality': quality, 'timeframe_sec': tf, 'abstain_reasons': usable ? [] : ['blurry'],
          'candles': [
            for (var i = 0; i < s.length; i++)
              {
                'status': i == s.length - 1 ? 'possibly_forming' : 'closed',
                for (final k in ['open', 'high', 'low', 'close']) 'rel_$k': s[i][k],
                'y_open': i, 'y_close': i, 'y_high': i, 'y_low': i,
              }
          ],
        };
    Map<String, dynamic> strat(int id, Map def, {int tf = 30, double exp = 0.1, String status = 'approved'}) => {
          'id': id, 'name': 'S$id', 'version': 1, 'status': status, 'definition': cd.validateDefinition(def),
          'latest_backtest': {
            'qualifies': true, 'params': {'timeframe_sec': tf},
            'out_of_sample': {
              'trades': 40, 'win_rate': 0.6, 'win_rate_ci95': [0.45, 0.73], 'expectancy_per_trade': exp,
              'significant_edge': false, 'by_condition': {}
            },
          },
        };
    final buyDef = {
      'long': {
        'all': [{'id': 'bullish_candle'}]
      },
      'duration_sec': 60
    };
    final sellDef = {
      'short': {
        'all': [{'id': 'bearish_candle'}]
      },
      'duration_sec': 60
    };
    final up = series(21, n: 120, drift: 0.0006), down = series(22, n: 120, drift: -0.0006);
    final cases = [
      {'reading': reading(up, usable: false), 'settings': settings, 'strategies': []},
      {'reading': reading(up, quality: 0.4), 'settings': settings, 'strategies': []},
      {'reading': reading(up, tf: 60), 'settings': settings, 'strategies': []},
      {'reading': reading(up.sublist(0, 20)), 'settings': settings, 'strategies': []},
      {'reading': reading(up), 'settings': settings, 'strategies': []},
      {'reading': reading(up), 'settings': settings, 'strategies': [strat(1, buyDef, tf: 60)]},
      {'reading': reading(up.sublist(0, 40)), 'settings': settings, 'strategies': [strat(1, buyDef)]},
      for (final s in [up, down, series(23, n: 120), series(24, n: 120, drift: 0.0004), series(25, n: 120, drift: -0.0004)])
        {
          'reading': reading(s),
          'settings': settings,
          'strategies': [strat(1, buyDef), strat(2, sellDef, exp: 0.2)],
          'knowledge': [{'title': 'Trend rule'}],
        },
      {'reading': reading(up), 'settings': {...settings, 'min_confluence_factors': 9}, 'strategies': [strat(1, buyDef)]},
      {'reading': reading(up), 'settings': {...settings, 'trade_duration_min_sec': 120}, 'strategies': [strat(1, buyDef)]},
      {'reading': reading(up), 'settings': {...settings, 'min_confidence_to_signal': 0.99}, 'strategies': [strat(1, buyDef)]},
    ];
    final py = await python({'op': 'decide', 'cases': cases}) as List;
    var signals = 0;
    for (var k = 0; k < cases.length; k++) {
      final c = cases[k];
      final tech = analyzeReading(c['reading'] as Map<String, dynamic>);
      final dec = decide(c['reading'] as Map, tech, c['settings'] as Map, [for (final s in c['strategies'] as List) s as Map],
          knowledge: (c['knowledge'] as List?)?.cast<Map>());
      expectSame(tech, (py[k] as Map)['technical'], path: 'case$k.technical');
      expectSame(dec.toJson(), (py[k] as Map)['decision'], path: 'case$k.decision');
      if (dec.signal != 'WAIT') signals++;
    }
    expect(signals, greaterThan(0), reason: 'at least one case must reach BUY/SELL');
  }, skip: paritySkip);

  test('rule translation matches Python', () async {
    final cases = [
      [
        [
          {'text': 'buy oversold at support', 'actions': ['act_buy'], 'conditions': ['oversold', 'support']},
          {'text': 'sell engulfing with the trend', 'actions': ['act_sell'], 'conditions': ['engulfing', 'trend']},
          {'text': 'do not enter on news', 'actions': ['act_avoid'], 'conditions': ['news']},
          {'text': 'avoid volatility', 'actions': ['act_avoid'], 'conditions': ['volatility']},
          {'text': 'exit at resistance', 'actions': ['act_exit'], 'conditions': ['resistance']},
          {'text': 'buy oversold at support again', 'actions': ['act_buy'], 'conditions': ['support', 'oversold']},
        ],
        90
      ],
    ];
    final py = await python({'op': 'translate', 'cases': cases}) as List;
    for (var k = 0; k < cases.length; k++) {
      final c = cases[k];
      expectSame(translateRules([for (final r in c[0] as List) r as Map<String, dynamic>], durationSec: c[1] as int), py[k]);
    }
  }, skip: paritySkip);
}

/// json.dumps(params, sort_keys=True) as Python writes it.
String _pyJson(Map p) {
  final keys = p.keys.map((k) => '$k').toList()..sort();
  return '{${keys.map((k) => '"$k": ${p[k] is String ? '"${p[k]}"' : p[k]}').join(', ')}}';
}
