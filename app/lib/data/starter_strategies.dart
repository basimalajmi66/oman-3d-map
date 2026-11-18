/// Classic, publicly known technical-analysis setups, expressed with the engine's testable conditions.
///
/// They are added as DRAFTS: nothing is approved automatically, and nothing here claims they work. The
/// historical test on real data decides, and the user approves (or not) each one.
library;

class StarterStrategy {
  const StarterStrategy(this.name, this.ar, this.en, this.definition);
  final String name;
  final String ar, en; // the idea, in plain words
  final Map<String, dynamic> definition;
}

const starterSource = 'Classic setup from common technical-analysis literature — not proven; the historical test decides.';

const starterStrategies = <StarterStrategy>[
  StarterStrategy(
    'ارتداد RSI عند الدعم والمقاومة',
    'شراء عند تشبع البيع قرب دعم، وبيع عند تشبع الشراء قرب مقاومة. لا دخول في السوق المتقلب.',
    'Buy when RSI is oversold near support, sell when overbought near resistance; no entry in volatile markets.',
    {
      'long': {'all': [{'id': 'rsi_below', 'value': 30}, {'id': 'near_support'}]},
      'short': {'all': [{'id': 'rsi_above', 'value': 70}, {'id': 'near_resistance'}]},
      'veto': [{'id': 'market', 'condition': 'volatile'}],
      'duration_sec': 120,
    },
  ),
  StarterStrategy(
    'الارتداد مع الاتجاه (EMA)',
    'في اتجاه صاعد مرتب (EMA 9 > 21 > 50) شراء بعد تصحيح (RSI أقل من 45) وشمعة صاعدة، والعكس للبيع.',
    'In an aligned uptrend (EMA 9 > 21 > 50) buy a pullback (RSI < 45) on a bullish candle; the reverse for sells.',
    {
      'long': {'all': [{'id': 'ema_bull_alignment'}, {'id': 'rsi_below', 'value': 45}, {'id': 'bullish_candle'}]},
      'short': {'all': [{'id': 'ema_bear_alignment'}, {'id': 'rsi_above', 'value': 55}, {'id': 'bearish_candle'}]},
      'duration_sec': 60,
    },
  ),
  StarterStrategy(
    'تقاطع MACD مع الاتجاه',
    'تقاطع MACD صاعد في اتجاه صاعد للشراء، وتقاطع هابط في اتجاه هابط للبيع.',
    'Bullish MACD cross in an uptrend to buy, bearish cross in a downtrend to sell.',
    {
      'long': {'all': [{'id': 'macd_cross_up'}, {'id': 'trend_up'}]},
      'short': {'all': [{'id': 'macd_cross_down'}, {'id': 'trend_down'}]},
      'duration_sec': 120,
    },
  ),
  StarterStrategy(
    'العودة إلى المتوسط (بولينجر) في السوق العرضي',
    'في السوق العرضي: شراء عند الإغلاق تحت الحد السفلي لبولينجر، وبيع فوق الحد العلوي.',
    'In ranging markets: buy a close below the lower Bollinger band, sell a close above the upper band.',
    {
      'long': {'all': [{'id': 'bb_below_lower'}, {'id': 'market', 'condition': 'ranging'}]},
      'short': {'all': [{'id': 'bb_above_upper'}, {'id': 'market', 'condition': 'ranging'}]},
      'duration_sec': 60,
    },
  ),
  StarterStrategy(
    'الابتلاع عند الدعم والمقاومة',
    'نمط ابتلاعي صاعد قرب دعم للشراء، وابتلاعي هابط قرب مقاومة للبيع.',
    'Bullish engulfing near support to buy, bearish engulfing near resistance to sell.',
    {
      'long': {'all': [{'id': 'pattern', 'name': 'bullish_engulfing'}, {'id': 'near_support'}]},
      'short': {'all': [{'id': 'pattern', 'name': 'bearish_engulfing'}, {'id': 'near_resistance'}]},
      'duration_sec': 120,
    },
  ),
  StarterStrategy(
    'الاختراق مع الزخم',
    'اختراق مستوى مقاومة مع زخم صاعد للشراء، وكسر دعم مع زخم هابط للبيع.',
    'Break above a level with upward momentum to buy, below a level with downward momentum to sell.',
    {
      'long': {'all': [{'id': 'breakout_up'}, {'id': 'momentum_up'}]},
      'short': {'all': [{'id': 'breakdown'}, {'id': 'momentum_down'}]},
      'duration_sec': 120,
    },
  ),
  StarterStrategy(
    'المطرقة والشهاب',
    'مطرقة قرب دعم بعد هبوط للشراء، وشهاب قرب مقاومة بعد صعود للبيع.',
    'Hammer near support after a decline to buy, shooting star near resistance after a rise to sell.',
    {
      'long': {'all': [{'id': 'pattern', 'name': 'hammer'}, {'id': 'near_support'}]},
      'short': {'all': [{'id': 'pattern', 'name': 'shooting_star'}, {'id': 'near_resistance'}]},
      'duration_sec': 120,
    },
  ),
  StarterStrategy(
    'استمرار الاتجاه القوي',
    'اتجاه صاعد مع زخم وهيستوجرام MACD موجب للشراء، والعكس للبيع. لا دخول في السوق المتقلب.',
    'Uptrend with momentum and a positive MACD histogram to buy, the reverse to sell; no entry in volatile markets.',
    {
      'long': {'all': [{'id': 'trend_up'}, {'id': 'momentum_up'}, {'id': 'macd_positive'}]},
      'short': {'all': [{'id': 'trend_down'}, {'id': 'momentum_down'}, {'id': 'macd_negative'}]},
      'veto': [{'id': 'market', 'condition': 'volatile'}],
      'duration_sec': 60,
    },
  ),
];
