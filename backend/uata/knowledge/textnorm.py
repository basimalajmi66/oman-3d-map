"""Arabic/English normalisation and a bilingual trading glossary.

The glossary maps Arabic and English expressions of the same concept to one
canonical token (e.g. "مؤشر القوة النسبية" and "RSI" → ``c:rsi``). It is used
for retrieval (an English factor code finds Arabic notes and vice versa), rule
extraction and conflict detection.
"""

from __future__ import annotations

import re

_DIACRITICS = re.compile(r"[ؐ-ًؚ-ٰٟۖ-ۭـ]")  # harakat + tatweel


def normalize(text: str) -> str:
    t = text.lower()
    t = _DIACRITICS.sub("", t)
    t = re.sub("[إأآٱ]", "ا", t)
    t = t.replace("ى", "ي").replace("ة", "ه").replace("ؤ", "و").replace("ئ", "ي")
    return t


# canonical concept -> surface forms (already normalised by `normalize` at load time)
_GLOSSARY = {
    "rsi": ["rsi", "مؤشر القوة النسبية", "القوه النسبيه", "ار اس اي"],
    "macd": ["macd", "ماكد", "الماكد"],
    "bollinger": ["bollinger", "بولينجر", "بولنجر", "بولينغر"],
    "atr": ["atr", "متوسط المدى الحقيقي"],
    "moving_average": ["moving average", "ema", "sma", "المتوسط المتحرك", "المتوسطات المتحركه", "موفنج", "متوسط متحرك"],
    "support": ["support", "دعم", "الدعم"],
    "resistance": ["resistance", "مقاومه", "المقاومه"],
    "trend": ["trend", "اتجاه", "الاتجاه", "ترند"],
    "uptrend": ["uptrend", "up trend", "اتجاه صاعد", "ترند صاعد"],
    "downtrend": ["downtrend", "down trend", "اتجاه هابط", "ترند هابط"],
    "engulfing": ["engulfing", "ابتلاع", "الابتلاعيه", "ابتلاعيه"],
    "hammer": ["hammer", "مطرقه", "المطرقه"],
    "shooting_star": ["shooting star", "شهاب", "الشهاب", "نجمه ساقطه"],
    "doji": ["doji", "دوجي", "الدوجي"],
    "pin_bar": ["pin bar", "pinbar", "بن بار"],
    "morning_star": ["morning star", "نجمه الصباح"],
    "evening_star": ["evening star", "نجمه المساء"],
    "overbought": ["overbought", "تشبع شرائي", "التشبع الشرائي"],
    "oversold": ["oversold", "تشبع بيعي", "التشبع البيعي"],
    "breakout": ["breakout", "break out", "breaks out", "breaks", "breaks above", "breaks below", "neckline",
                 "اختراق", "كسر", "خط العنق"],
    "candle_close": ["candle close", "close of the candle", "اغلاق الشمعه", "اغلاق شمعه", "تغلق الشمعه"],
    "supply_demand": ["supply", "demand", "العرض", "الطلب", "منطقه عرض", "منطقه طلب"],
    "liquidity": ["liquidity", "سيوله", "السيوله"],
    "volume": ["volume", "حجم التداول", "الفوليوم"],
    "momentum": ["momentum", "زخم", "الزخم"],
    "volatility": ["volatility", "تذبذب", "التذبذب", "تقلب"],
    "double_top": ["double top", "قمه مزدوجه", "القمه المزدوجه"],
    "double_bottom": ["double bottom", "قاع مزدوج", "القاع المزدوج"],
    "head_shoulders": ["head and shoulders", "head & shoulders", "راس وكتفين", "الراس والكتفين", "راس و كتفين"],
    "bull_flag": ["bull flag", "bullish flag", "علم صاعد", "العلم الصاعد"],
    "ascending_triangle": ["ascending triangle", "مثلث صاعد", "المثلث الصاعد"],
    "gap_retest": ["imbalance", "fair value gap", "fvg", "the gap", "فجوه", "الفجوه", "فجوه سعريه"],
    "news": ["news", "الاخبار", "خبر"],
    # actions
    "act_buy": ["buy", "call", "long", "buyers are back", "buyers take over", "buyers keep pushing",
                "شراء", "اشتر", "اشتري", "صفقه شراء", "صعود"],
    "act_sell": ["sell", "put", "short", "sellers take over", "sellers are back", "بيع", "بع", "صفقه بيع", "هبوط"],
    "act_avoid": ["avoid", "do not enter", "don't enter", "dont enter", "never enter", "no trade", "stay out", "wait",
                  "لا تدخل", "لا تتداول", "تجنب", "امتنع", "انتظر", "لا تفتح"],
    "act_enter": ["enter", "ادخل", "الدخول", "افتح صفقه"],
    "act_exit": ["exit", "close the trade", "take profit", "اخرج", "الخروج", "اغلق الصفقه"],
}

# longest first; ties alphabetically — a set alone has a random order per process (hash seed), which made
# query expansion differ between runs
GLOSSARY: dict[str, list[str]] = {k: sorted({normalize(s) for s in v}, key=lambda f: (-len(f), f))
                                  for k, v in _GLOSSARY.items()}

# factor / pattern codes from the analysis engine -> concepts (to query the library)
FACTOR_CONCEPTS = {
    "rsi": ["rsi"], "macd": ["macd"], "bollinger_bands": ["bollinger"], "atr": ["atr", "volatility"],
    "moving_averages": ["moving_average"], "support_resistance": ["support", "resistance"],
    "trend": ["trend"], "supply_demand": ["supply_demand"], "liquidity_zones": ["liquidity"],
    "volume": ["volume"], "momentum": ["momentum"], "volatility": ["volatility"],
    "chart_patterns": ["double_top", "double_bottom", "head_shoulders", "bull_flag", "ascending_triangle"], "candlesticks": [], "price_action": ["candle_close"],
    "pattern_hammer": ["hammer"], "pattern_bullish_engulfing": ["engulfing"], "pattern_bearish_engulfing": ["engulfing"],
    "pattern_shooting_star": ["shooting_star"], "pattern_doji": ["doji"], "pattern_morning_star": ["morning_star"],
    "pattern_evening_star": ["evening_star"], "rsi_overbought": ["rsi", "overbought"], "rsi_oversold": ["rsi", "oversold"],
    "trend_up": ["uptrend"], "trend_down": ["downtrend"], "sr_breakout_up": ["breakout", "resistance"],
    "sr_breakdown": ["breakout", "support"], "sr_near_support": ["support"], "sr_near_resistance": ["resistance"],
}


def _word_pattern(form: str) -> re.Pattern:
    # match as whole words / phrases; allow Arabic proclitics (و، ف، ب، ل، ك، ال) before Arabic forms
    if re.search(r"[؀-ۿ]", form):
        return re.compile(r"(?<![؀-ۿ])(?:[وفبلك]?(?:ال)?)" + re.escape(form) + r"(?![؀-ۿ])")
    return re.compile(r"(?<![a-z0-9])" + re.escape(form) + r"(?![a-z0-9])")


_PATTERNS = {k: [_word_pattern(f) for f in forms] for k, forms in GLOSSARY.items()}


def concepts(text: str) -> set[str]:
    """Canonical concepts mentioned in ``text``."""
    t = normalize(text)
    return {k for k, pats in _PATTERNS.items() if any(p.search(t) for p in pats)}


def surface_forms(concept: str) -> list[str]:
    return GLOSSARY.get(concept, [])
