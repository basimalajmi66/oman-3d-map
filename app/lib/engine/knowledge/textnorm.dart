/// Arabic/English normalisation and the bilingual trading glossary (port of knowledge/textnorm.py).
///
/// Python's `\w`, `\b` and `\d` are Unicode-aware (Arabic letters and digits count); Dart's are ASCII-only,
/// so the equivalents below spell out `[\p{L}\p{N}_]` explicitly.
library;

final _diacritics = RegExp('[ؐ-ًؚ-ٰٟۖ-ۭـ]');

String normalize(String text) {
  var t = text.toLowerCase();
  t = t.replaceAll(_diacritics, '');
  t = t.replaceAll(RegExp('[إأآٱ]'), 'ا');
  return t.replaceAll('ى', 'ي').replaceAll('ة', 'ه').replaceAll('ؤ', 'و').replaceAll('ئ', 'ي');
}

const _glossarySource = <String, List<String>>{
  'rsi': ['rsi', 'مؤشر القوة النسبية', 'القوه النسبيه', 'ار اس اي'],
  'macd': ['macd', 'ماكد', 'الماكد'],
  'bollinger': ['bollinger', 'بولينجر', 'بولنجر', 'بولينغر'],
  'atr': ['atr', 'متوسط المدى الحقيقي'],
  'moving_average': ['moving average', 'ema', 'sma', 'المتوسط المتحرك', 'المتوسطات المتحركه', 'موفنج', 'متوسط متحرك'],
  'support': ['support', 'دعم', 'الدعم'],
  'resistance': ['resistance', 'مقاومه', 'المقاومه'],
  'trend': ['trend', 'اتجاه', 'الاتجاه', 'ترند'],
  'uptrend': ['uptrend', 'up trend', 'اتجاه صاعد', 'ترند صاعد'],
  'downtrend': ['downtrend', 'down trend', 'اتجاه هابط', 'ترند هابط'],
  'engulfing': ['engulfing', 'ابتلاع', 'الابتلاعيه', 'ابتلاعيه'],
  'hammer': ['hammer', 'مطرقه', 'المطرقه'],
  'shooting_star': ['shooting star', 'شهاب', 'الشهاب', 'نجمه ساقطه'],
  'doji': ['doji', 'دوجي', 'الدوجي'],
  'pin_bar': ['pin bar', 'pinbar', 'بن بار'],
  'morning_star': ['morning star', 'نجمه الصباح'],
  'evening_star': ['evening star', 'نجمه المساء'],
  'overbought': ['overbought', 'تشبع شرائي', 'التشبع الشرائي'],
  'oversold': ['oversold', 'تشبع بيعي', 'التشبع البيعي'],
  'breakout': ['breakout', 'break out', 'breaks out', 'breaks', 'breaks above', 'breaks below', 'neckline', //
    'اختراق', 'كسر', 'خط العنق'],
  'candle_close': ['candle close', 'close of the candle', 'اغلاق الشمعه', 'اغلاق شمعه', 'تغلق الشمعه'],
  'supply_demand': ['supply', 'demand', 'العرض', 'الطلب', 'منطقه عرض', 'منطقه طلب'],
  'liquidity': ['liquidity', 'سيوله', 'السيوله'],
  'volume': ['volume', 'حجم التداول', 'الفوليوم'],
  'momentum': ['momentum', 'زخم', 'الزخم'],
  'volatility': ['volatility', 'تذبذب', 'التذبذب', 'تقلب'],
  'double_top': ['double top', 'قمه مزدوجه', 'القمه المزدوجه'],
  'double_bottom': ['double bottom', 'قاع مزدوج', 'القاع المزدوج'],
  'head_shoulders': ['head and shoulders', 'head & shoulders', 'راس وكتفين', 'الراس والكتفين', 'راس و كتفين'],
  'bull_flag': ['bull flag', 'bullish flag', 'علم صاعد', 'العلم الصاعد'],
  'ascending_triangle': ['ascending triangle', 'مثلث صاعد', 'المثلث الصاعد'],
  'gap_retest': ['imbalance', 'fair value gap', 'fvg', 'the gap', 'فجوه', 'الفجوه', 'فجوه سعريه'],
  'news': ['news', 'الاخبار', 'خبر'],
  // actions
  'act_buy': ['buy', 'call', 'long', 'buyers are back', 'buyers take over', 'buyers keep pushing', //
    'شراء', 'اشتر', 'اشتري', 'صفقه شراء', 'صعود'],
  'act_sell': ['sell', 'put', 'short', 'sellers take over', 'sellers are back', 'بيع', 'بع', 'صفقه بيع', 'هبوط'],
  'act_avoid': ['avoid', 'do not enter', "don't enter", 'dont enter', 'never enter', 'no trade', 'stay out', 'wait', //
    'لا تدخل', 'لا تتداول', 'تجنب', 'امتنع', 'انتظر', 'لا تفتح'],
  'act_enter': ['enter', 'ادخل', 'الدخول', 'افتح صفقه'],
  'act_exit': ['exit', 'close the trade', 'take profit', 'اخرج', 'الخروج', 'اغلق الصفقه'],
};

/// concept → normalised surface forms, longest first (ties: Python's stable sort of a set — sorted for determinism).
final Map<String, List<String>> glossary = {
  for (final e in _glossarySource.entries)
    e.key: ({for (final s in e.value) normalize(s)}.toList()
      ..sort()
      ..sort((a, b) => b.length.compareTo(a.length)))
};

/// Factor / pattern codes of the analysis engine → concepts (to query the library).
const factorConcepts = <String, List<String>>{
  'rsi': ['rsi'], 'macd': ['macd'], 'bollinger_bands': ['bollinger'], 'atr': ['atr', 'volatility'],
  'moving_averages': ['moving_average'], 'support_resistance': ['support', 'resistance'],
  'trend': ['trend'], 'supply_demand': ['supply_demand'], 'liquidity_zones': ['liquidity'],
  'volume': ['volume'], 'momentum': ['momentum'], 'volatility': ['volatility'],
  'chart_patterns': ['double_top', 'double_bottom', 'head_shoulders', 'bull_flag', 'ascending_triangle'], 'candlesticks': [], 'price_action': ['candle_close'],
  'pattern_hammer': ['hammer'], 'pattern_bullish_engulfing': ['engulfing'], 'pattern_bearish_engulfing': ['engulfing'],
  'pattern_shooting_star': ['shooting_star'], 'pattern_doji': ['doji'], 'pattern_morning_star': ['morning_star'],
  'pattern_evening_star': ['evening_star'], 'rsi_overbought': ['rsi', 'overbought'], 'rsi_oversold': ['rsi', 'oversold'],
  'trend_up': ['uptrend'], 'trend_down': ['downtrend'], 'sr_breakout_up': ['breakout', 'resistance'],
  'sr_breakdown': ['breakout', 'support'], 'sr_near_support': ['support'], 'sr_near_resistance': ['resistance'],
};

final _arabic = RegExp('[؀-ۿ]');

RegExp _wordPattern(String form) {
  final f = RegExp.escape(form);
  // whole words / phrases; Arabic forms may carry proclitics (و، ف، ب، ل، ك، ال)
  if (_arabic.hasMatch(form)) return RegExp('(?<![؀-ۿ])(?:[وفبلك]?(?:ال)?)$f(?![؀-ۿ])');
  return RegExp('(?<![a-z0-9])$f(?![a-z0-9])');
}

final Map<String, List<RegExp>> _patterns = {
  for (final e in glossary.entries) e.key: [for (final f in e.value) _wordPattern(f)]
};

/// Canonical concepts mentioned in `text`.
Set<String> concepts(String text) {
  final t = normalize(text);
  return {for (final e in _patterns.entries) if (e.value.any((p) => p.hasMatch(t))) e.key};
}

List<String> surfaceForms(String concept) => glossary[concept] ?? const [];

/// Python's `re.findall(r"\w+", text, re.UNICODE)`.
final wordRe = RegExp(r'[\p{L}\p{N}_]+', unicode: true);
List<String> words(String text) => [for (final m in wordRe.allMatches(text)) m[0]!];
