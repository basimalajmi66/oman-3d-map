/// A strategy written in the user's own words (Arabic or English) → a testable definition, with the same
/// deterministic rule reader and translator as the knowledge library. Nothing is guessed: sentences without a
/// testable equivalent are listed as untestable.
library;

import '../knowledge/rules.dart';
import 'translate.dart';

const _arDigits = '٠١٢٣٤٥٦٧٨٩';

/// Trade duration mentioned in a text, in seconds ("لمدة دقيقتين", "3 دقائق", "30 ثانية", "for 2 minutes"), or null.
int? durationFromText(String text) {
  var t = text;
  for (var i = 0; i < 10; i++) {
    t = t.replaceAll(_arDigits[i], '$i');
  }
  if (RegExp(r'دقيقتين|دقيقتان').hasMatch(t)) return 120;
  final m = RegExp(r'(\d{1,3})\s*(ثواني|ثوان|ثانية|ث(?!\p{L})|seconds?|secs?|s(?!\p{L})|دقائق|دقيقة|د(?!\p{L})|minutes?|mins?|m(?!\p{L}))',
          caseSensitive: false, unicode: true)
      .firstMatch(t);
  if (m != null) {
    final n = int.parse(m[1]!);
    final u = m[2]!.toLowerCase();
    final sec = RegExp(r'^(ثواني|ثوان|ثانية|ث|s|sec|secs|second|seconds)$').hasMatch(u);
    return sec ? n : n * 60;
  }
  if (RegExp(r'(?<!\p{L})دقيقة(?!\p{L})|one minute|a minute', caseSensitive: false, unicode: true).hasMatch(t)) return 60;
  return null;
}

/// (definition, sentences used, sentences that cannot be tested).
(Map<String, dynamic>, List<String>, List<String>) strategyFromText(String text, {int defaultDuration = 120}) {
  final rules = [for (final r in extractRules(text, 'text')) r.toJson()];
  final def = translateRules(rules, durationSec: durationFromText(text) ?? defaultDuration);
  final used = (def['translated_rules'] as List).cast<String>();
  final untestable = (def['untestable'] as List).cast<String>();
  // sentences with no rule at all (no buy / sell / avoid words) are untestable too
  for (final s in text.split(RegExp(r'[.!?؟\n]+'))) {
    final t = s.trim();
    if (t.length > 3 && !used.any((u) => u.contains(t) || t.contains(u.replaceAll(RegExp(r'[.!?؟]$'), ''))) &&
        !untestable.any((u) => u.contains(t) || t.contains(u))) {
      untestable.add(t);
    }
  }
  return (def, used, untestable);
}
