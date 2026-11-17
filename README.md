# Universal AI Trading Assistant — مساعد التداول الذكي

مساعد تداول مستقل عن أي منصة، يعمل محلياً، يتعلم مما تعلّمه إياه بعد موافقتك، ويعرض توصيات **BUY / SELL / WAIT** مع أسبابها.
**لا ينفذ أي صفقة إطلاقاً — القرار والتنفيذ بيدك.**

> الحالة: المراحل **1 و3 و4 و5 و7 و8 مكتملة**، و**6** عدا تحويل الكلام إلى نص (ملفات الترجمة مدعومة)، و**2** في الواجهة — **تضمين المحرك في Android متعذر حالياً (قرار مطلوب)**. نسخة Windows تُبنى وتُفحص في CI. **الإشارات BUY/SELL تصدر فقط من استراتيجية اعتمدتها بعد اختبار خارج العينة على بيانات حقيقية؛ وإلا WAIT مع السبب.**
> محرك التحليل (قراءة الشارت، المؤشرات، الإشارات) يُبنى في المراحل 3–8؛ حتى ذلك الحين تعرض الأداة **WAIT** وتوضح السبب بدل أي إشارة مختلقة.
> راجع [تقرير المرحلة 1](docs/reports/PHASE_1_REPORT.md) و[تقرير المرحلة 2](docs/reports/PHASE_2_REPORT.md) و[تقرير المرحلة 3](docs/reports/PHASE_3_REPORT.md) و[تقرير المرحلة 4](docs/reports/PHASE_4_REPORT.md) و[تقرير المرحلة 5](docs/reports/PHASE_5_REPORT.md) و[تقرير المرحلة 6](docs/reports/PHASE_6_REPORT.md) و[تقرير المرحلة 7](docs/reports/PHASE_7_REPORT.md) و[تقرير المرحلة 8](docs/reports/PHASE_8_REPORT.md) و[خارطة الطريق](docs/ROADMAP.md).

## الهيكل
```
backend/            المحرك المحلي (Python + FastAPI + SQLite)
  uata/api/         واجهة HTTP على 127.0.0.1 بتوكن
  uata/services/    الإعدادات، التحكم، المعرفة، السجلات، النسخ الاحتياطي
  uata/db/          الاتصال والترحيلات + schema_v1.sql
  uata/vision/       قارئ الشارت (OpenCV + Tesseract)
  uata/analysis/     التحليل الفني (مؤشرات، أنماط، هيكل السوق)
  uata/knowledge/    استخراج المستندات، القواعد، التعارضات، الاسترجاع الهجين
  uata/video/        تحليل الفيديو التعليمي
  uata/strategy/     الاستراتيجيات والاختبار التاريخي
  uata/signal/       محرك القرار
  tests/            182 اختبار pytest
app/                تطبيق Flutter (Windows / Android / iOS)
  lib/core/         عقد المحرك، عميل HTTP، تشغيل المحرك، التحكم بالنافذة
  lib/state/        حالة التطبيق
  lib/ui/           اللوحة العائمة والشاشات
  lib/l10n/         العربية والإنجليزية
  test/             اختبارات الواجهة + اختبارات العقد مع المحرك الحقيقي
docs/               المعمارية، قاعدة البيانات، تصميم الواجهة، خطة الاختبار، التقارير
scripts/            بناء Windows وتشغيل المحرك للتطوير
```

## متطلب اختياري: OCR
لقراءة الأسعار من محور الشارت ثبّت [Tesseract](https://github.com/UB-Mannheim/tesseract/wiki) (Windows) أو `apt install tesseract-ocr`. بدونه يعمل القارئ بقيم نسبية ويوضح ذلك.

## التشغيل للتطوير
```bash
# 1) المحرك
cd backend
pip install -r requirements-dev.txt
python -m uata                 # يستمع على 127.0.0.1:8765 ، البيانات في %LOCALAPPDATA%\UniversalAITradingAssistant
python -m pytest               # الاختبارات

# 2) الواجهة (Windows)
cd app
flutter pub get
flutter run -d windows         # أو اضبط UATA_BACKEND_DIR ليشغّل التطبيق المحرك بنفسه
flutter test
```

## بناء نسخة Android
```bash
cd app && flutter build apk --debug --target-platform android-arm64,android-x64
# يضمّن المحرك عبر Chaquopy. Python 3.12 متاح لمعماريتي arm64 و x86_64 فقط (أجهزة 32-بت غير مدعومة)
```

## بناء نسخة Windows كاملة
```powershell
./scripts/build_windows.ps1
# الناتج: app\build\windows\x64\runner\Release\uata_app.exe + engine\uata-engine.exe
```
يبني CI (GitHub Actions) نفس النسخة على `windows-latest` ويرفعها كـ artifact باسم `uata-windows`.

## كيف تحصل على إشارات
1. استورد بياناتك التاريخية الحقيقية (CSV) من شاشة التدريب.
2. أنشئ استراتيجية (أو حوّل القواعد التي اعتمدتها من كتبك وفيديوهاتك).
3. شغّل الاختبار التاريخي؛ إذا اجتاز البوابة (خارج العينة)، اعتمدها بنفسك.
4. ابدأ التحليل وارفع/التقط الشارت — BUY/SELL تظهر فقط عند تحقق شروطها وتوافق العوامل.

## الخصوصية
كل البيانات على جهازك فقط. لا حسابات، لا سحابة، لا كلمات مرور منصات. النسخ الاحتياطية مشفرة (AES-256-GCM) بكلمة مرور لا تُحفظ. يمكنك حذف كل شيء من الإعدادات.

## تنبيه
التداول ينطوي على مخاطر عالية. الأداة مساعد تحليلي ولا تضمن أي ربح، ونسب الثقة المعروضة تقديرية ما لم تُوسم بأنها معايرة إحصائياً.
