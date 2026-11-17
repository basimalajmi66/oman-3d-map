# قاعدة البيانات المحلية

* المحرك: SQLite بوضع WAL و`synchronous=NORMAL` — البيانات المؤكدة لا تضيع عند إغلاق البرنامج أو انقطاعه.
* المخطط: `backend/uata/db/schema_v1.sql` و`schema_v2.sql` (المرحلة 2) و`schema_v3.sql` (المرحلة 3: حفظ قراءة الشارت مع كل صورة) و`schema_v4.sql` (المرحلة 5: `location` و`rule_json` لعناصر المعرفة). الترحيلات مرقمة في `MIGRATIONS` وتُسجَّل في `schema_migrations`، وتُطبَّق تلقائياً عند التشغيل وبعد استعادة نسخة أقدم.
* كل اتصال قصير العمر داخل معاملة `BEGIN IMMEDIATE` (آمن مع خيوط FastAPI).
* الأعمدة المنتهية بـ `_json` تُفك تلقائياً (`tags_json` ← `tags`).

## الجداول

| الجدول | الغرض | أهم القيود |
|---|---|---|
| `settings` | إعدادات المستخدم (JSON مُتحقق منه بـ pydantic) | — |
| `knowledge_sources` | كل ما أضافه المستخدم: ملاحظة، PDF، DOCX، XLSX، TXT، صورة، فيديو، رابط | `sha256` فريد (منع التكرار)؛ `extraction_status ∈ pending/done/unsupported_yet/failed` |
| `knowledge_items` | وحدة معرفة واحدة مستخرجة من مصدر | `status ∈ pending_review/approved/rejected/archived`؛ `video_timestamp_ms` لربط المعلومة بتوقيت الفيديو؛ `clarity ∈ [0,1]` |
| `knowledge_items_fts` | فهرس بحث نصي FTS5 (unicode61 يدعم العربية) | متزامن بمشغلات insert/update/delete |
| `knowledge_links` | ربط المعلومات: related/supports/contradicts/refines/example_of | يمنع ربط العنصر بنفسه |
| `knowledge_embeddings` | متجهات البحث المحلي (تضمين `hashing-v1`، 2048 بُعداً) لكل عنصر، تُعاد عند تعديل المحتوى أو تغيير النموذج | float32 BLOB |
| `learning_reports` | تقرير "ما تعلمه النظام" + التعارضات، ينتظر الموافقة | `status` |
| `strategies` | بطاقة الاستراتيجية: شروط الدخول/الخروج/الامتناع، الأطر، ظروف السوق، المؤشرات، الإصدار | اسم فريد؛ `status ∈ draft/testing/approved/retired` |
| `strategy_examples` | أمثلة ناجحة/فاشلة | `outcome ∈ success/failure` |
| `backtest_runs` | نتائج اختبار مرتبطة باستراتيجية **واحدة** وإصدارها | فترات in-sample و out-of-sample منفصلة؛ التكاليف |
| `analysis_sessions` | جلسات التحليل | جلسة واحدة `running` فقط |
| `signals` | سجل الإشارات | `signal ∈ BUY/SELL/WAIT`؛ BUY/SELL تتطلب `duration_sec`؛ `confidence_calibrated`؛ `data_basis ∈ image_only/price_feed/image_and_feed` |
| `trade_results` | نتائج الصفقات التي يدخلها المستخدم | `account_type ∈ simulation/demo/real` — لا تُخلط في الإحصاءات |
| `analysis_inputs` (v2) | صور الشارت المرسلة للتحليل (رفع/مشاركة/لقطة شاشة) — منفصلة عن المكتبة | `input_mode ∈ upload/share/screenshot/screen_region`؛ أبعاد حقيقية مقروءة بـ OpenCV؛ آخر 500 فقط؛ v3: `reading_json` (القراءة الكاملة) و`data_quality` و`usable` |
| `audit_log` | سجل التعلم والتدقيق: كل إضافة/اعتماد/رفض/تعديل إعداد/نسخ/استعادة | `actor ∈ user/system` |

## مخزن الملفات
`files/<أول حرفين من sha256>/<sha256><الامتداد>` — عنونة بالمحتوى، فلا يتكرر الملف ولا يمكن لاسم ملف خبيث (`../../x`) الخروج من المجلد.

## النسخ الاحتياطي
ملف `.uatabak` مشفر يحتوي نسخة متسقة من قاعدة البيانات (SQLite backup API) + كل الملفات + `manifest.json`. يشمل: الاستراتيجيات، المستندات، المعرفة المستخرجة، الإعدادات، سجل التعلم، نتائج الاختبارات، الإشارات والنتائج. يُنقل بين الكمبيوتر والهاتف ويُستعاد بكلمة المرور.
