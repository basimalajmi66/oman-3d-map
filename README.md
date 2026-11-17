# Universal AI Trading Assistant — مساعد التداول الذكي

مساعد تداول مستقل عن أي منصة، يعمل محلياً، يتعلم مما تعلّمه إياه بعد موافقتك، ويعرض توصيات **BUY / SELL / WAIT** مع أسبابها.
**لا ينفذ أي صفقة إطلاقاً — القرار والتنفيذ بيدك.**

> الحالة: **المرحلة 1 مكتملة**، و**المرحلة 2** (Android/التابلت/استقبال صور الشارت) مكتملة في الجزء القابل للاختبار؛ بناء APK يتم في CI.
> محرك التحليل (قراءة الشارت، المؤشرات، الإشارات) يُبنى في المراحل 3–8؛ حتى ذلك الحين تعرض الأداة **WAIT** وتوضح السبب بدل أي إشارة مختلقة.
> راجع [تقرير المرحلة 1](docs/reports/PHASE_1_REPORT.md) و[تقرير المرحلة 2](docs/reports/PHASE_2_REPORT.md) و[خارطة الطريق](docs/ROADMAP.md).

## الهيكل
```
backend/            المحرك المحلي (Python + FastAPI + SQLite)
  uata/api/         واجهة HTTP على 127.0.0.1 بتوكن
  uata/services/    الإعدادات، التحكم، المعرفة، السجلات، النسخ الاحتياطي
  uata/db/          الاتصال والترحيلات + schema_v1.sql
  tests/            68 اختبار pytest
app/                تطبيق Flutter (Windows / Android / iOS)
  lib/core/         عقد المحرك، عميل HTTP، تشغيل المحرك، التحكم بالنافذة
  lib/state/        حالة التطبيق
  lib/ui/           اللوحة العائمة والشاشات
  lib/l10n/         العربية والإنجليزية
  test/             اختبارات الواجهة + اختبارات العقد مع المحرك الحقيقي
docs/               المعمارية، قاعدة البيانات، تصميم الواجهة، خطة الاختبار، التقارير
scripts/            بناء Windows وتشغيل المحرك للتطوير
```

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
cd app && flutter build apk --debug    # يضمّن المحرك عبر Chaquopy (يحتاج Android SDK والوصول إلى chaquo.com)
```

## بناء نسخة Windows كاملة
```powershell
./scripts/build_windows.ps1
# الناتج: app\build\windows\x64\runner\Release\uata_app.exe + engine\uata-engine.exe
```
يبني CI (GitHub Actions) نفس النسخة على `windows-latest` ويرفعها كـ artifact باسم `uata-windows`.

## الخصوصية
كل البيانات على جهازك فقط. لا حسابات، لا سحابة، لا كلمات مرور منصات. النسخ الاحتياطية مشفرة (AES-256-GCM) بكلمة مرور لا تُحفظ. يمكنك حذف كل شيء من الإعدادات.

## تنبيه
التداول ينطوي على مخاطر عالية. الأداة مساعد تحليلي ولا تضمن أي ربح، ونسب الثقة المعروضة تقديرية ما لم تُوسم بأنها معايرة إحصائياً.
