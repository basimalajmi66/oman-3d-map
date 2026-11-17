/// Arabic / English UI strings. Add a language by adding a column.
const Map<String, Map<String, String>> _strings = {
  'app_title': {'ar': 'مساعد التداول الذكي', 'en': 'AI Trading Assistant'},
  'buy': {'ar': 'شراء BUY', 'en': 'BUY'},
  'sell': {'ar': 'بيع SELL', 'en': 'SELL'},
  'wait': {'ar': 'انتظار WAIT', 'en': 'WAIT'},
  'confidence': {'ar': 'الثقة التقديرية', 'en': 'Est. confidence'},
  'uncalibrated': {'ar': 'غير معايرة', 'en': 'uncalibrated'},
  'duration': {'ar': 'مدة الصفقة', 'en': 'Duration'},
  'timeframe': {'ar': 'الإطار الزمني', 'en': 'Timeframe'},
  'start': {'ar': 'بدء التحليل', 'en': 'Start'},
  'stop': {'ar': 'إيقاف', 'en': 'Stop'},
  'emergency_stop': {'ar': 'إيقاف فوري', 'en': 'Emergency stop'},
  'library': {'ar': 'المكتبة', 'en': 'Library'},
  'training': {'ar': 'التدريب', 'en': 'Training'},
  'log': {'ar': 'السجل', 'en': 'Log'},
  'settings': {'ar': 'الإعدادات', 'en': 'Settings'},
  'manual_only': {
    'ar': 'التنفيذ يدوي بالكامل — الأداة لا تنفذ أي صفقة',
    'en': 'Manual only — this tool never executes trades'
  },
  // states
  'state_idle': {'ar': 'التحليل متوقف', 'en': 'Analysis stopped'},
  'state_running_no_engine': {
    'ar': 'الجلسة تعمل — محرك التحليل لم يُثبت بعد (المراحل 3-8)',
    'en': 'Session running — analysis engine not installed yet (phases 3-8)'
  },
  'state_analyzing': {'ar': 'جارٍ تحليل السوق', 'en': 'Analyzing market'},
  'state_halted': {'ar': 'تم الإيقاف الفوري', 'en': 'Emergency stop active'},
  'state_offline': {'ar': 'المحرك المحلي غير متصل', 'en': 'Local engine offline'},
  'reason_analysis_not_running': {'ar': 'لا يوجد تحليل نشط', 'en': 'No active analysis'},
  'reason_analysis_engine_not_installed': {
    'ar': 'لا توجد إشارة: محرك التحليل غير متوفر بعد، لذلك تبقى التوصية انتظار.',
    'en': 'No signal: the analysis engine is not available yet, so the recommendation stays WAIT.'
  },
  'reason_emergency_stop_active': {'ar': 'الإيقاف الفوري مفعّل', 'en': 'Emergency stop is active'},
  'retry': {'ar': 'إعادة المحاولة', 'en': 'Retry'},
  'offline_help': {
    'ar': 'شغّل المحرك المحلي: python -m uata (من مجلد backend)',
    'en': 'Start the local engine: python -m uata (from the backend folder)'
  },
  // signal details
  'signal_details': {'ar': 'تفاصيل الإشارة', 'en': 'Signal details'},
  'reasons': {'ar': 'الأسباب', 'en': 'Reasons'},
  'supporting': {'ar': 'العوامل المؤيدة', 'en': 'Supporting factors'},
  'opposing': {'ar': 'العوامل المعارضة', 'en': 'Opposing factors'},
  'data_quality': {'ar': 'جودة البيانات', 'en': 'Data quality'},
  'strategy': {'ar': 'الاستراتيجية', 'en': 'Strategy'},
  'data_basis': {'ar': 'أساس التحليل', 'en': 'Data basis'},
  'none': {'ar': 'لا يوجد', 'en': 'None'},
  'close': {'ar': 'إغلاق', 'en': 'Close'},
  'confidence_note': {
    'ar': 'نسبة الثقة تقدير داخلي وليست احتمال ربح حقيقي ما لم تُعاير إحصائياً.',
    'en': 'Confidence is an internal estimate, not a probability of profit, unless statistically calibrated.'
  },
  // library
  'search': {'ar': 'بحث في المكتبة…', 'en': 'Search the library…'},
  'add_note': {'ar': 'إضافة معلومة', 'en': 'Add note'},
  'add_file': {'ar': 'إضافة ملف', 'en': 'Add file'},
  'add_url': {'ar': 'إضافة رابط', 'en': 'Add link'},
  'title': {'ar': 'العنوان', 'en': 'Title'},
  'content': {'ar': 'المحتوى', 'en': 'Content'},
  'category': {'ar': 'التصنيف', 'en': 'Category'},
  'tags': {'ar': 'وسوم (مفصولة بفواصل)', 'en': 'Tags (comma separated)'},
  'type': {'ar': 'النوع', 'en': 'Type'},
  'save': {'ar': 'حفظ', 'en': 'Save'},
  'cancel': {'ar': 'إلغاء', 'en': 'Cancel'},
  'delete': {'ar': 'حذف', 'en': 'Delete'},
  'approve': {'ar': 'اعتماد', 'en': 'Approve'},
  'reject': {'ar': 'رفض', 'en': 'Reject'},
  'pending_review': {'ar': 'بانتظار موافقتك', 'en': 'Awaiting your approval'},
  'approved': {'ar': 'معتمد', 'en': 'Approved'},
  'rejected': {'ar': 'مرفوض', 'en': 'Rejected'},
  'archived': {'ar': 'مؤرشف', 'en': 'Archived'},
  'empty_library': {
    'ar': 'المكتبة فارغة. أضف معلومات أو ملفات لتعليم المساعد.',
    'en': 'The library is empty. Add notes or files to teach the assistant.'
  },
  'no_results': {'ar': 'لا توجد نتائج', 'en': 'No results'},
  'source': {'ar': 'المصدر', 'en': 'Source'},
  'added_at': {'ar': 'تاريخ الإضافة', 'en': 'Added'},
  'extraction': {'ar': 'استخراج المحتوى', 'en': 'Extraction'},
  'extraction_done': {'ar': 'تم', 'en': 'Done'},
  'extraction_unsupported_yet': {
    'ar': 'محفوظ — استخراج هذا النوع يأتي في مرحلة لاحقة',
    'en': 'Stored — extraction for this type comes in a later phase'
  },
  'extraction_pending': {'ar': 'قيد الانتظار', 'en': 'Pending'},
  'extraction_failed': {'ar': 'فشل', 'en': 'Failed'},
  'items': {'ar': 'المعارف المستخرجة', 'en': 'Extracted knowledge'},
  'confirm_delete': {'ar': 'حذف هذا المصدر وكل ما استخرج منه؟', 'en': 'Delete this source and everything extracted from it?'},
  'duplicate_file': {'ar': 'الملف موجود مسبقاً في المكتبة', 'en': 'This file is already in the library'},
  'select_source': {'ar': 'اختر مصدراً لعرض تفاصيله', 'en': 'Select a source to see details'},
  'approval_note': {
    'ar': 'لا يستخدم المحرك أي معرفة قبل اعتمادك لها.',
    'en': 'The engine uses no knowledge until you approve it.'
  },
  // log / results
  'signals_tab': {'ar': 'الإشارات', 'en': 'Signals'},
  'results_tab': {'ar': 'نتائج الصفقات', 'en': 'Trade results'},
  'no_signals': {'ar': 'لا توجد إشارات مسجلة بعد', 'en': 'No signals recorded yet'},
  'no_trades': {'ar': 'لا توجد نتائج مسجلة', 'en': 'No results recorded'},
  'total': {'ar': 'الإجمالي', 'en': 'Total'},
  'add_result': {'ar': 'تسجيل نتيجة', 'en': 'Record result'},
  'account_type': {'ar': 'نوع الحساب', 'en': 'Account'},
  'simulation': {'ar': 'محاكاة', 'en': 'Simulation'},
  'demo': {'ar': 'تجريبي', 'en': 'Demo'},
  'real': {'ar': 'حقيقي', 'en': 'Real'},
  'asset': {'ar': 'الأصل المالي', 'en': 'Asset'},
  'direction': {'ar': 'الاتجاه', 'en': 'Direction'},
  'outcome': {'ar': 'النتيجة', 'en': 'Outcome'},
  'win': {'ar': 'ربح', 'en': 'Win'},
  'loss': {'ar': 'خسارة', 'en': 'Loss'},
  'draw': {'ar': 'تعادل', 'en': 'Draw'},
  'cancelled': {'ar': 'ملغاة', 'en': 'Cancelled'},
  'notes': {'ar': 'ملاحظات', 'en': 'Notes'},
  'win_rate': {'ar': 'نسبة النجاح', 'en': 'Win rate'},
  'sample': {'ar': 'العينة', 'en': 'sample'},
  'small_sample': {
    'ar': 'العينة صغيرة — لا يمكن الاعتماد على النسبة',
    'en': 'Small sample — the rate is not reliable'
  },
  'seconds': {'ar': 'ث', 'en': 's'},
  // training
  'training_title': {'ar': 'وضع التدريب والاختبار', 'en': 'Training & backtesting'},
  'training_unavailable': {
    'ar': 'محرك الاستراتيجيات والاختبار التاريخي يُبنى في المرحلة 7. هذه حالة المكونات الفعلية في هذا الإصدار:',
    'en': 'The strategy and backtesting engine is built in Phase 7. Actual component status in this build:'
  },
  'available': {'ar': 'متوفر', 'en': 'Available'},
  'not_available': {'ar': 'غير متوفر بعد', 'en': 'Not available yet'},
  'comp_chart_vision': {'ar': 'قراءة الشارت (المرحلة 3)', 'en': 'Chart vision (Phase 3)'},
  'comp_technical_analysis': {'ar': 'التحليل الفني (المرحلة 4)', 'en': 'Technical analysis (Phase 4)'},
  'comp_knowledge_rag': {'ar': 'الاسترجاع المعزز RAG (المرحلة 5)', 'en': 'Knowledge RAG (Phase 5)'},
  'comp_video_learning': {'ar': 'تحليل الفيديو (المرحلة 6)', 'en': 'Video learning (Phase 6)'},
  'comp_strategy_engine': {'ar': 'محرك الاستراتيجيات (المرحلة 7)', 'en': 'Strategy engine (Phase 7)'},
  'comp_signal_engine': {'ar': 'محرك الإشارات (المرحلة 8)', 'en': 'Signal engine (Phase 8)'},
  // settings
  'trading_section': {'ar': 'إعدادات التداول', 'en': 'Trading'},
  'candle_tf': {'ar': 'إطار الشمعة', 'en': 'Candle timeframe'},
  'min_duration': {'ar': 'أقل مدة مقترحة', 'en': 'Min suggested duration'},
  'max_duration': {'ar': 'أعلى مدة مقترحة', 'en': 'Max suggested duration'},
  'min_conf': {'ar': 'أدنى ثقة لإصدار إشارة', 'en': 'Min confidence to signal'},
  'min_quality': {'ar': 'أدنى جودة بيانات', 'en': 'Min data quality'},
  'min_factors': {'ar': 'أقل عدد عوامل متوافقة', 'en': 'Min confluence factors'},
  'cooldown': {'ar': 'فترة منع التكرار', 'en': 'Repeat cooldown'},
  'continuous': {'ar': 'تحليل مستمر', 'en': 'Continuous analysis'},
  'tf_warning': {
    'ar': 'شموع 30 ثانية تحتاج مصدر بيانات يدعمها؛ لا تتوفر في كل المنصات.',
    'en': '30-second candles need a data source that provides them; not every platform does.'
  },
  'indicators_section': {'ar': 'المؤشرات وعوامل التحليل', 'en': 'Indicators & factors'},
  'ui_section': {'ar': 'الواجهة', 'en': 'Interface'},
  'language': {'ar': 'اللغة', 'en': 'Language'},
  'theme': {'ar': 'المظهر', 'en': 'Theme'},
  'theme_system': {'ar': 'حسب النظام', 'en': 'System'},
  'theme_dark': {'ar': 'داكن', 'en': 'Dark'},
  'theme_light': {'ar': 'فاتح', 'en': 'Light'},
  'always_on_top': {'ar': 'النافذة فوق التطبيقات', 'en': 'Always on top'},
  'opacity': {'ar': 'الشفافية', 'en': 'Opacity'},
  'privacy_section': {'ar': 'الخصوصية والأذونات', 'en': 'Privacy & permissions'},
  'screen_permission': {'ar': 'السماح بقراءة الشاشة', 'en': 'Allow screen reading'},
  'screen_permission_desc': {
    'ar': 'لن تُقرأ الشاشة إلا بعد تفعيل هذا الإذن، ويُلغى عند الإيقاف الفوري.',
    'en': 'The screen is never read unless enabled. Revoked by emergency stop.'
  },
  'external_sources': {'ar': 'السماح بمصادر بيانات خارجية', 'en': 'Allow external data sources'},
  'backup_section': {'ar': 'النسخ الاحتياطي المشفر', 'en': 'Encrypted backup'},
  'create_backup': {'ar': 'إنشاء نسخة احتياطية', 'en': 'Create backup'},
  'restore_backup': {'ar': 'استعادة نسخة', 'en': 'Restore backup'},
  'passphrase': {'ar': 'كلمة مرور النسخة (10 أحرف على الأقل)', 'en': 'Backup passphrase (min 10 chars)'},
  'passphrase_warning': {
    'ar': 'لا يمكن استعادة النسخة بدون كلمة المرور. لا تُحفظ في أي مكان.',
    'en': 'The backup cannot be restored without this passphrase. It is not stored anywhere.'
  },
  'restore_warning': {
    'ar': 'ستستبدل الاستعادة جميع البيانات الحالية.',
    'en': 'Restoring replaces all current data.'
  },
  'backup_created': {'ar': 'تم إنشاء النسخة', 'en': 'Backup created'},
  'restored': {'ar': 'تمت الاستعادة', 'en': 'Restored'},
  'danger_section': {'ar': 'حذف البيانات', 'en': 'Delete data'},
  'wipe': {'ar': 'حذف جميع بياناتي', 'en': 'Delete all my data'},
  'wipe_confirm': {
    'ar': 'سيتم حذف المكتبة والاستراتيجيات والسجلات والإعدادات نهائياً. اكتب: DELETE ALL MY DATA',
    'en': 'Library, strategies, logs and settings will be permanently deleted. Type: DELETE ALL MY DATA'
  },
  'include_backups': {'ar': 'احذف النسخ الاحتياطية أيضاً', 'en': 'Also delete backups'},
  'wiped': {'ar': 'تم حذف جميع البيانات', 'en': 'All data deleted'},
  'reset_settings': {'ar': 'استعادة الإعدادات الافتراضية', 'en': 'Reset settings to defaults'},
  'saved': {'ar': 'تم الحفظ', 'en': 'Saved'},
  'error': {'ar': 'خطأ', 'en': 'Error'},
  'trading_mode': {'ar': 'أسلوب التداول: يدوي (ثابت)', 'en': 'Trading mode: manual (fixed)'},
  // indicator names
  'ind_price_action': {'ar': 'حركة السعر', 'en': 'Price action'},
  'ind_candlesticks': {'ar': 'الشموع اليابانية', 'en': 'Japanese candlesticks'},
  'ind_support_resistance': {'ar': 'الدعم والمقاومة', 'en': 'Support & resistance'},
  'ind_trend': {'ar': 'تحليل الاتجاه', 'en': 'Trend analysis'},
  'ind_supply_demand': {'ar': 'العرض والطلب', 'en': 'Supply & demand'},
  'ind_liquidity_zones': {'ar': 'مناطق السيولة', 'en': 'Liquidity zones'},
  'ind_moving_averages': {'ar': 'المتوسطات المتحركة', 'en': 'Moving averages'},
  'ind_rsi': {'ar': 'RSI', 'en': 'RSI'},
  'ind_macd': {'ar': 'MACD', 'en': 'MACD'},
  'ind_bollinger_bands': {'ar': 'بولينجر باند', 'en': 'Bollinger Bands'},
  'ind_atr': {'ar': 'ATR', 'en': 'ATR'},
  'ind_volume': {'ar': 'الحجم (عند توفره)', 'en': 'Volume (when available)'},
  'ind_momentum': {'ar': 'الزخم', 'en': 'Momentum'},
  'ind_volatility': {'ar': 'التذبذب', 'en': 'Volatility'},
  'ind_chart_patterns': {'ar': 'النماذج السعرية', 'en': 'Chart patterns'},
  // knowledge item types / kinds
  'it_note': {'ar': 'ملاحظة', 'en': 'Note'},
  'it_rule': {'ar': 'قاعدة', 'en': 'Rule'},
  'it_strategy_fragment': {'ar': 'جزء من استراتيجية', 'en': 'Strategy fragment'},
  'it_example': {'ar': 'مثال صفقة', 'en': 'Trade example'},
  'it_definition': {'ar': 'تعريف', 'en': 'Definition'},
};

String tr(String lang, String key) => _strings[key]?[lang] ?? _strings[key]?['en'] ?? key;

bool hasString(String key) => _strings.containsKey(key);
