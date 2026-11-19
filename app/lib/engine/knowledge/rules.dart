/// Heuristic extraction of trading rules and conflict detection (port of knowledge/rules.py).
/// Candidate rules are proposals in the learning report — never used until the user approves them.
library;

import 'textnorm.dart';

const _w = r'\p{L}\p{N}_';
final conditionMarkers = RegExp(
    '(?<![؀-ۿ])(اذا|إذا|عندما|عند|حين|لما|متي|بشرط)(?![؀-ۿ])|(?<![$_w])(if|when|whenever|only when|once|after)(?![$_w])',
    caseSensitive: false,
    unicode: true);
final sentenceSplit = RegExp(r'(?<=[.!?؟؛;\n])\s+|\n+');
final tfRe = RegExp(
    '(\\p{Nd}{1,3})\\s*(ثانيه|ثواني|دقيقه|دقائق|ساعه|ساعات|sec|secs|s|min|mins|m|h)(?![$_w؀-ۿ])'
    '|(?<![؀-ۿ])(دقيقتين|دقيقتان|ساعتين|دقيقه واحده)(?![؀-ۿ])',
    caseSensitive: false,
    unicode: true);
const actions = ['act_buy', 'act_sell', 'act_enter', 'act_avoid', 'act_exit'];
const _incompatible = [
  {'act_buy', 'act_sell'}, {'act_enter', 'act_avoid'}, {'act_buy', 'act_avoid'}, {'act_sell', 'act_avoid'},
];

class CandidateRule {
  CandidateRule(this.text, this.actions, this.conditions, this.timeframes, this.location);
  final String text;
  final List<String> actions, conditions, timeframes;
  final String location;
  Map<String, dynamic> toJson() =>
      {'text': text, 'actions': actions, 'conditions': conditions, 'timeframes': timeframes, 'location': location};
}

String _strip(String s, String chars) {
  var a = 0, b = s.length;
  while (a < b && chars.contains(s[a])) {
    a++;
  }
  while (b > a && chars.contains(s[b - 1])) {
    b--;
  }
  return s.substring(a, b);
}

List<CandidateRule> extractRules(String text, [String location = '']) {
  final out = <CandidateRule>[];
  for (final sent in text.split(sentenceSplit)) {
    final s = _strip(sent, ' -•*\t');
    if (s.length < 12 || s.length > 400) continue;
    if (!conditionMarkers.hasMatch(normalize(s)) && !conditionMarkers.hasMatch(s)) continue;
    final cs = concepts(s);
    final acts = cs.where(actions.contains).toList()..sort();
    if (acts.contains('act_avoid') && acts.contains('act_enter')) acts.remove('act_enter'); // "do not enter"
    if (acts.isEmpty) continue;
    final conds = cs.where((c) => !actions.contains(c)).toList()..sort();
    final tfs = [for (final m in tfRe.allMatches(normalize(s))) m[0]!];
    out.add(CandidateRule(s, acts, conds, tfs, location));
  }
  return out;
}

Set<String> _mainAction(List actions) {
  final a = {...actions.cast<String>()};
  if (a.contains('act_buy') || a.contains('act_sell')) a.remove('act_enter');
  return a;
}

/// `existing`: approved rules [{'item_id', 'text', 'actions', 'conditions'}].
List<Map<String, dynamic>> conflicts(CandidateRule r, List<Map<String, dynamic>> existing) {
  final found = <Map<String, dynamic>>[];
  final na = _mainAction(r.actions);
  final nc = {...r.conditions};
  for (final ex in existing) {
    final ea = _mainAction(ex['actions'] as List);
    final ec = {...(ex['conditions'] as List).cast<String>()};
    final shared = nc.intersection(ec);
    if (shared.length < 2 && !(shared.isNotEmpty && nc.length == shared.length && shared.length == ec.length)) continue;
    final clash = na.any((x) => ea.any((y) => _incompatible.any((p) => p.length == {x, y}.length && p.containsAll({x, y}))));
    if (clash) {
      found.add({
        'item_id': ex['item_id'], 'existing_text': ex['text'], 'new_text': r.text,
        'shared_conditions': shared.toList()..sort(), 'new_actions': na.toList()..sort(), 'existing_actions': ea.toList()..sort(),
      });
    }
  }
  return found;
}
