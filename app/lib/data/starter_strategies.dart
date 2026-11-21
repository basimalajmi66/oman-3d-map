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
  StarterStrategy(
    'تشبع مزدوج: RSI مع بولينجر',
    'شراء عند تشبع بيع شديد (RSI أقل من 25) مع إغلاق تحت حد بولينجر السفلي، والعكس للبيع.',
    'Buy on deep oversold (RSI < 25) with a close below the lower Bollinger band; the reverse to sell.',
    {
      'long': {'all': [{'id': 'rsi_below', 'value': 25}, {'id': 'bb_below_lower'}]},
      'short': {'all': [{'id': 'rsi_above', 'value': 75}, {'id': 'bb_above_upper'}]},
      'duration_sec': 180,
    },
  ),
  StarterStrategy(
    'ارتداد RSI في السوق العرضي',
    'في السوق العرضي فقط: شراء عند RSI أقل من 30 وبيع عند RSI أعلى من 70.',
    'Ranging markets only: buy at RSI < 30, sell at RSI > 70.',
    {
      'long': {'all': [{'id': 'rsi_below', 'value': 30}, {'id': 'market', 'condition': 'ranging'}]},
      'short': {'all': [{'id': 'rsi_above', 'value': 70}, {'id': 'market', 'condition': 'ranging'}]},
      'duration_sec': 120,
    },
  ),
  StarterStrategy(
    'التصحيح تحت EMA 9 في اتجاه صاعد',
    'اتجاه صاعد والسعر فوق EMA 50، ثم تصحيح تحت EMA 9 تليه شمعة صاعدة للشراء؛ والعكس للبيع.',
    'Uptrend above EMA 50, a dip below EMA 9 and a bullish candle to buy; the reverse to sell.',
    {
      'long': {'all': [{'id': 'trend_up'}, {'id': 'price_above_ema', 'period': 50}, {'id': 'price_below_ema', 'period': 9}, {'id': 'bullish_candle'}]},
      'short': {'all': [{'id': 'trend_down'}, {'id': 'price_below_ema', 'period': 50}, {'id': 'price_above_ema', 'period': 9}, {'id': 'bearish_candle'}]},
      'duration_sec': 120,
    },
  ),
  StarterStrategy(
    'نجمة الصباح ونجمة المساء',
    'نمط نجمة الصباح بعد هبوط للشراء، ونجمة المساء بعد صعود للبيع.',
    'Morning star after a decline to buy, evening star after a rise to sell.',
    {
      'long': {'all': [{'id': 'pattern', 'name': 'morning_star'}]},
      'short': {'all': [{'id': 'pattern', 'name': 'evening_star'}]},
      'duration_sec': 180,
    },
  ),
  StarterStrategy(
    'الابتلاع مع الاتجاه',
    'ابتلاعي صاعد في اتجاه صاعد للشراء، وابتلاعي هابط في اتجاه هابط للبيع.',
    'Bullish engulfing in an uptrend to buy, bearish engulfing in a downtrend to sell.',
    {
      'long': {'all': [{'id': 'pattern', 'name': 'bullish_engulfing'}, {'id': 'trend_up'}]},
      'short': {'all': [{'id': 'pattern', 'name': 'bearish_engulfing'}, {'id': 'trend_down'}]},
      'duration_sec': 120,
    },
  ),
  StarterStrategy(
    'تقاطع MACD من منطقة الضعف',
    'تقاطع MACD صاعد و RSI أقل من 45 للشراء، وتقاطع هابط و RSI أعلى من 55 للبيع.',
    'Bullish MACD cross with RSI < 45 to buy, bearish cross with RSI > 55 to sell.',
    {
      'long': {'all': [{'id': 'macd_cross_up'}, {'id': 'rsi_below', 'value': 45}]},
      'short': {'all': [{'id': 'macd_cross_down'}, {'id': 'rsi_above', 'value': 55}]},
      'duration_sec': 180,
    },
  ),
  StarterStrategy(
    'الاختراق في سوق متجه',
    'اختراق مقاومة في سوق متجه صاعد للشراء، وكسر دعم في سوق متجه هابط للبيع.',
    'Breakout in a trending up-market to buy, breakdown in a trending down-market to sell.',
    {
      'long': {'all': [{'id': 'breakout_up'}, {'id': 'market', 'condition': 'trending'}, {'id': 'trend_up'}]},
      'short': {'all': [{'id': 'breakdown'}, {'id': 'market', 'condition': 'trending'}, {'id': 'trend_down'}]},
      'duration_sec': 300,
    },
  ),
  StarterStrategy(
    'الدوجي عند الدعم والمقاومة',
    'شمعة دوجي (تردد) قرب دعم للشراء، وقرب مقاومة للبيع.',
    'A doji (indecision) near support to buy, near resistance to sell.',
    {
      'long': {'all': [{'id': 'pattern', 'name': 'doji'}, {'id': 'near_support'}]},
      'short': {'all': [{'id': 'pattern', 'name': 'doji'}, {'id': 'near_resistance'}]},
      'duration_sec': 120,
    },
  ),
  StarterStrategy(
    'ركوب الزخم مع ترتيب المتوسطات',
    'EMA 9 > 21 > 50 مع هيستوجرام MACD موجب والسعر فوق EMA 9 للشراء؛ والعكس للبيع.',
    'EMA 9 > 21 > 50 with a positive MACD histogram and price above EMA 9 to buy; the reverse to sell.',
    {
      'long': {'all': [{'id': 'ema_bull_alignment'}, {'id': 'macd_positive'}, {'id': 'price_above_ema', 'period': 9}]},
      'short': {'all': [{'id': 'ema_bear_alignment'}, {'id': 'macd_negative'}, {'id': 'price_below_ema', 'period': 9}]},
      'duration_sec': 300,
    },
  ),
  StarterStrategy(
    'إنهاك الحركة (عكس الزخم)',
    'هبوط حاد (أكثر من 2 ATR) مع RSI أقل من 25 للشراء، وصعود حاد مع RSI أعلى من 75 للبيع.',
    'A sharp drop (over 2 ATR) with RSI < 25 to buy, a sharp rise with RSI > 75 to sell.',
    {
      'long': {'all': [{'id': 'momentum_down', 'atr': 2.0}, {'id': 'rsi_below', 'value': 25}]},
      'short': {'all': [{'id': 'momentum_up', 'atr': 2.0}, {'id': 'rsi_above', 'value': 75}]},
      'duration_sec': 120,
    },
  ),
  StarterStrategy(
    'المطرقة المقلوبة والرجل المشنوق',
    'مطرقة مقلوبة قرب دعم للشراء، ورجل مشنوق قرب مقاومة للبيع.',
    'Inverted hammer near support to buy, hanging man near resistance to sell.',
    {
      'long': {'all': [{'id': 'pattern', 'name': 'inverted_hammer'}, {'id': 'near_support'}]},
      'short': {'all': [{'id': 'pattern', 'name': 'hanging_man'}, {'id': 'near_resistance'}]},
      'duration_sec': 180,
    },
  ),
  StarterStrategy(
    'الارتداد في السوق المتقلب',
    'في السوق المتقلب: إغلاق تحت بولينجر السفلي مع شمعة صاعدة للشراء، وفوق العلوي مع شمعة هابطة للبيع.',
    'Volatile markets: a close below the lower band on a bullish candle to buy, above the upper band on a bearish candle to sell.',
    {
      'long': {'all': [{'id': 'bb_below_lower'}, {'id': 'market', 'condition': 'volatile'}, {'id': 'bullish_candle'}]},
      'short': {'all': [{'id': 'bb_above_upper'}, {'id': 'market', 'condition': 'volatile'}, {'id': 'bearish_candle'}]},
      'duration_sec': 60,
    },
  ),
  // ---- strategies widely circulated among Pocket Option / binary-options traders (forums, videos, free PDFs).
  // Written from their commonly shared rules; none is proven — the historical test and paper trading decide.
  StarterStrategy(
    'مجتمع: RSI مع بولينجر',
    'من أشهر استراتيجيات الدقيقة: الإغلاق خارج بولينجر السفلي مع RSI أقل من 30 للشراء، وخارج العلوي مع RSI أعلى من 70 للبيع.',
    'One of the most shared 1-minute setups: a close outside the lower Bollinger band with RSI < 30 to buy, outside the upper band with RSI > 70 to sell.',
    {
      'long': {'all': [{'id': 'bb_below_lower'}, {'id': 'rsi_below', 'value': 30}]},
      'short': {'all': [{'id': 'bb_above_upper'}, {'id': 'rsi_above', 'value': 70}]},
      'duration_sec': 60,
    },
  ),
  StarterStrategy(
    'مجتمع: تقاطع EMA 5 و13',
    'شراء عندما يقطع المتوسط الأسرع EMA 5 المتوسط EMA 13 للأعلى، وبيع عند التقاطع للأسفل.',
    'Buy when the fast EMA 5 crosses above EMA 13, sell when it crosses below.',
    {
      'long': {'all': [{'id': 'ema_cross_up', 'fast': 5, 'slow': 13}]},
      'short': {'all': [{'id': 'ema_cross_down', 'fast': 5, 'slow': 13}]},
      'duration_sec': 120,
    },
  ),
  StarterStrategy(
    'مجتمع: تقاطع EMA 5/13 مع EMA 200',
    'تقاطع EMA 5 و13 فقط في اتجاه EMA 200: شراء فوقه، وبيع تحته.',
    'The EMA 5/13 cross only in the direction of EMA 200: buys above it, sells below it.',
    {
      'long': {'all': [{'id': 'ema_cross_up', 'fast': 5, 'slow': 13}, {'id': 'price_above_ema', 'period': 200}]},
      'short': {'all': [{'id': 'ema_cross_down', 'fast': 5, 'slow': 13}, {'id': 'price_below_ema', 'period': 200}]},
      'duration_sec': 180,
    },
  ),
  StarterStrategy(
    'مجتمع: ستوكاستيك مع بولينجر',
    'ستوكاستيك أقل من 20 والإغلاق تحت بولينجر السفلي للشراء، وأعلى من 80 فوق العلوي للبيع.',
    'Stochastic below 20 with a close below the lower band to buy; above 80 with a close above the upper band to sell.',
    {
      'long': {'all': [{'id': 'stoch_below', 'value': 20}, {'id': 'bb_below_lower'}]},
      'short': {'all': [{'id': 'stoch_above', 'value': 80}, {'id': 'bb_above_upper'}]},
      'duration_sec': 60,
    },
  ),
  StarterStrategy(
    'مجتمع: تقاطع ستوكاستيك في منطقة التشبع',
    'تقاطع %K فوق %D وهو تحت 25 للشراء، وتحت %D وهو فوق 75 للبيع.',
    '%K crossing above %D while below 25 to buy; crossing below %D while above 75 to sell.',
    {
      'long': {'all': [{'id': 'stoch_cross_up'}, {'id': 'stoch_below', 'value': 25}]},
      'short': {'all': [{'id': 'stoch_cross_down'}, {'id': 'stoch_above', 'value': 75}]},
      'duration_sec': 120,
    },
  ),
  StarterStrategy(
    'مجتمع: MACD مع EMA 200',
    'تقاطع MACD صاعد والسعر فوق EMA 200 للشراء، وهابط والسعر تحته للبيع.',
    'A bullish MACD cross above EMA 200 to buy, a bearish cross below it to sell.',
    {
      'long': {'all': [{'id': 'macd_cross_up'}, {'id': 'price_above_ema', 'period': 200}]},
      'short': {'all': [{'id': 'macd_cross_down'}, {'id': 'price_below_ema', 'period': 200}]},
      'duration_sec': 180,
    },
  ),
  StarterStrategy(
    'مجتمع: Parabolic SAR مع ADX',
    'انقلاب SAR تحت السعر مع ADX أعلى من 25 و+DI فوق -DI للشراء، والعكس للبيع.',
    'SAR flips below price with ADX > 25 and +DI above -DI to buy; the reverse to sell.',
    {
      'long': {'all': [{'id': 'sar_flip_up'}, {'id': 'adx_above', 'value': 25}, {'id': 'di_bull'}]},
      'short': {'all': [{'id': 'sar_flip_down'}, {'id': 'adx_above', 'value': 25}, {'id': 'di_bear'}]},
      'duration_sec': 120,
    },
  ),
  StarterStrategy(
    'مجتمع: ثلاث شموع مع الزخم',
    'ثلاث شموع صاعدة متتالية مع اتجاه قوي (ADX أعلى من 20) للشراء، وثلاث هابطة للبيع.',
    'Three bullish candles in a row with a trend (ADX > 20) to buy, three bearish ones to sell.',
    {
      'long': {'all': [{'id': 'candle_streak_up', 'n': 3}, {'id': 'adx_above', 'value': 20}]},
      'short': {'all': [{'id': 'candle_streak_down', 'n': 3}, {'id': 'adx_above', 'value': 20}]},
      'duration_sec': 60,
    },
  ),
  StarterStrategy(
    'مجتمع: الانعكاس بعد ثلاث شموع',
    'بعد ثلاث شموع هابطة مع RSI أقل من 35 شراء (توقع ارتداد)، وبعد ثلاث صاعدة مع RSI أعلى من 65 بيع.',
    'After three bearish candles with RSI < 35 buy (expecting a bounce); after three bullish ones with RSI > 65 sell.',
    {
      'long': {'all': [{'id': 'candle_streak_down', 'n': 3}, {'id': 'rsi_below', 'value': 35}]},
      'short': {'all': [{'id': 'candle_streak_up', 'n': 3}, {'id': 'rsi_above', 'value': 65}]},
      'duration_sec': 60,
    },
  ),
  StarterStrategy(
    'مجتمع: Pin Bar مع RSI',
    'شمعة مطرقة مع RSI أقل من 40 للشراء، وشمعة شهاب مع RSI أعلى من 60 للبيع.',
    'A hammer with RSI < 40 to buy, a shooting star with RSI > 60 to sell.',
    {
      'long': {'all': [{'id': 'pattern', 'name': 'hammer'}, {'id': 'rsi_below', 'value': 40}]},
      'short': {'all': [{'id': 'pattern', 'name': 'shooting_star'}, {'id': 'rsi_above', 'value': 60}]},
      'duration_sec': 120,
    },
  ),
  StarterStrategy(
    'مجتمع: RSI في السوق بلا اتجاه (ADX)',
    'عندما يكون ADX أقل من 20 (لا اتجاه): RSI أقل من 30 للشراء وأعلى من 70 للبيع.',
    'When ADX is below 20 (no trend): RSI < 30 to buy, RSI > 70 to sell.',
    {
      'long': {'all': [{'id': 'rsi_below', 'value': 30}, {'id': 'adx_below', 'value': 20}]},
      'short': {'all': [{'id': 'rsi_above', 'value': 70}, {'id': 'adx_below', 'value': 20}]},
      'duration_sec': 60,
    },
  ),
];
