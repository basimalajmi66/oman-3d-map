/// Translate extracted rules into testable conditions (port of strategy/translate.py).
/// Deterministic, no guessing: anything without a testable equivalent stays *untestable* text.
library;

import 'dart:convert';

const conceptMap = <String, Map<String, List<Map<String, dynamic>>>>{
  'rsi': {'long': [], 'short': []}, // needs overbought/oversold to be meaningful
  'oversold': {
    'long': [{'id': 'rsi_below', 'value': 30}],
    'short': [{'id': 'rsi_below', 'value': 30}]
  },
  'overbought': {
    'long': [{'id': 'rsi_above', 'value': 70}],
    'short': [{'id': 'rsi_above', 'value': 70}]
  },
  'support': {
    'long': [{'id': 'near_support'}],
    'short': [{'id': 'near_support'}]
  },
  'resistance': {
    'long': [{'id': 'near_resistance'}],
    'short': [{'id': 'near_resistance'}]
  },
  'uptrend': {
    'long': [{'id': 'trend_up'}],
    'short': [{'id': 'trend_up'}]
  },
  'downtrend': {
    'long': [{'id': 'trend_down'}],
    'short': [{'id': 'trend_down'}]
  },
  'trend': {
    'long': [{'id': 'trend_up'}],
    'short': [{'id': 'trend_down'}]
  },
  'engulfing': {
    'long': [{'id': 'pattern', 'name': 'bullish_engulfing'}],
    'short': [{'id': 'pattern', 'name': 'bearish_engulfing'}]
  },
  'hammer': {
    'long': [{'id': 'pattern', 'name': 'hammer'}],
    'short': [{'id': 'pattern', 'name': 'hanging_man'}]
  },
  'shooting_star': {
    'long': [{'id': 'pattern', 'name': 'inverted_hammer'}],
    'short': [{'id': 'pattern', 'name': 'shooting_star'}]
  },
  'doji': {
    'long': [{'id': 'pattern', 'name': 'doji'}],
    'short': [{'id': 'pattern', 'name': 'doji'}]
  },
  'morning_star': {
    'long': [{'id': 'pattern', 'name': 'morning_star'}],
    'short': []
  },
  'evening_star': {
    'long': [],
    'short': [{'id': 'pattern', 'name': 'evening_star'}]
  },
  'macd': {
    'long': [{'id': 'macd_cross_up'}],
    'short': [{'id': 'macd_cross_down'}]
  },
  'bollinger': {
    'long': [{'id': 'bb_below_lower'}],
    'short': [{'id': 'bb_above_upper'}]
  },
  'moving_average': {
    'long': [{'id': 'price_above_ema', 'period': 21}],
    'short': [{'id': 'price_below_ema', 'period': 21}]
  },
  'breakout': {
    'long': [{'id': 'breakout_up'}],
    'short': [{'id': 'breakdown'}]
  },
  'momentum': {
    'long': [{'id': 'momentum_up'}],
    'short': [{'id': 'momentum_down'}]
  },
  'volatility': {
    'long': [{'id': 'market', 'condition': 'volatile'}],
    'short': [{'id': 'market', 'condition': 'volatile'}]
  },
  'candle_close': {'long': [], 'short': []}, // every condition is already evaluated on a closed candle
  'double_top': {
    'long': [],
    'short': [{'id': 'chart_pattern', 'name': 'double_top'}]
  },
  'double_bottom': {
    'long': [{'id': 'chart_pattern', 'name': 'double_bottom'}],
    'short': []
  },
  'head_shoulders': {
    'long': [],
    'short': [{'id': 'chart_pattern', 'name': 'head_shoulders'}]
  },
  'bull_flag': {
    'long': [{'id': 'chart_pattern', 'name': 'bull_flag'}],
    'short': []
  },
  'ascending_triangle': {
    'long': [{'id': 'chart_pattern', 'name': 'ascending_triangle'}],
    'short': []
  },
  'gap_retest': {
    'long': [{'id': 'chart_pattern', 'name': 'gap_retest_bull'}],
    'short': [{'id': 'chart_pattern', 'name': 'gap_retest_bear'}]
  },
};

const untestableConcepts = {'news', 'liquidity', 'supply_demand', 'volume', 'atr', 'pin_bar'};

/// A chart pattern's own break replaces the generic "breakout above/below a level".
const patternConcepts = {'double_top', 'double_bottom', 'head_shoulders', 'bull_flag', 'ascending_triangle', 'gap_retest'};

List<Map<String, dynamic>> _dedup(List<Map<String, dynamic>> conds) {
  final seen = <String>{};
  final out = <Map<String, dynamic>>[];
  for (final c in conds) {
    final key = jsonEncode((c.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => [e.key, e.value]).toList());
    if (seen.add(key)) out.add({...c});
  }
  return out;
}

/// `rules`: [{'text', 'actions', 'conditions'}] (approved rule items). Returns a strategy definition.
Map<String, dynamic> translateRules(List<Map<String, dynamic>> rules, {int durationSec = 120}) {
  final longC = <Map<String, dynamic>>[], shortC = <Map<String, dynamic>>[], veto = <Map<String, dynamic>>[];
  final untestable = <String>[], used = <String>[];
  for (final r in rules) {
    final acts = {...(r['actions'] as List? ?? const [])};
    var concepts = {...(r['conditions'] as List? ?? const []).cast<String>()}.toList()..sort();
    if (concepts.any(patternConcepts.contains)) concepts = [for (final c in concepts) if (c != 'breakout' && c != 'trend') c];
    final bad = concepts.where((c) => untestableConcepts.contains(c) || !conceptMap.containsKey(c));
    if (bad.isNotEmpty || concepts.isEmpty) {
      untestable.add(r['text'] as String);
      continue;
    }
    if (acts.contains('act_avoid')) {
      veto.addAll([for (final k in concepts) ...conceptMap[k]!['long']!]);
    } else if (acts.contains('act_buy') && !acts.contains('act_sell')) {
      longC.addAll([for (final k in concepts) ...conceptMap[k]!['long']!]);
    } else if (acts.contains('act_sell') && !acts.contains('act_buy')) {
      shortC.addAll([for (final k in concepts) ...conceptMap[k]!['short']!]);
    } else if (acts.length == 1 &&
        acts.contains('act_enter') &&
        concepts.every((k) =>
            conceptMap[k]!['long']!.isNotEmpty &&
            conceptMap[k]!['short']!.isNotEmpty &&
            jsonEncode(conceptMap[k]!['long']) != jsonEncode(conceptMap[k]!['short']))) {
      // "enter" without a side, on a setup that has a side of its own (gap retest: with the move)
      longC.addAll([for (final k in concepts) ...conceptMap[k]!['long']!]);
      shortC.addAll([for (final k in concepts) ...conceptMap[k]!['short']!]);
    } else {
      untestable.add(r['text'] as String); // exit-only or ambiguous direction
      continue;
    }
    used.add(r['text'] as String);
  }
  return {
    'long': {'all': _dedup(longC)},
    'short': {'all': _dedup(shortC)},
    'veto': _dedup(veto),
    'duration_sec': durationSec,
    'untestable': untestable,
    'translated_rules': used,
  };
}
