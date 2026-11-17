# تقرير: مثبّت Windows

## ما تم تنفيذه
* مثبّت **Inno Setup** (`installer/uata.iss`) للمستخدم الحالي في `%LOCALAPPDATA%\Programs\UATA` دون صلاحيات مسؤول، مع اختصار في قائمة ابدأ واختياري على سطح المكتب.
* **Tesseract مضمّن** (`<install>\tesseract`) مع بيانات **العربية والإنجليزية**؛ المحرك يجده تلقائياً (الترتيب: `UATA_TESSERACT` ← النسخة المضمّنة ← PATH ← مجلدات Program Files).
* **FFmpeg مضمّن** داخل المحرك (imageio-ffmpeg) لتحليل الفيديو.
* إلغاء التثبيت يوقف المحرك ثم يحذف البرنامج **ويُبقي بيانات المستخدم** (حذفها متاح من الإعدادات ← حذف كل البيانات).
* المحرك يعلن قدراته في `/health → capabilities` (OCR ولغاته، تحويل الكلام، FFmpeg، التقاط الشاشة)، وتظهر في الإعدادات ← «هذه النسخة المثبتة»، مع حقل لمسار نموذج تحويل الكلام المحلي.

## الملفات
`installer/uata.iss`، `scripts/build_windows.ps1` (`-BundleTesseract -Installer -Version`)، `backend/uata/vision/axis.py`، `backend/uata/api/app.py`، `app/lib/ui/screens/settings_screen.dart`، `.github/workflows/ci.yml`.

## نتائج الاختبار
* pytest: 202 ناجحة (منها اختبار القدرات)، bandit: 0 مشاكل.
* Flutter: 71 ناجحة (59 واجهة + 12 عقد مع المحرك الحقيقي).
* **CI على Windows حقيقي (التشغيل 12):** بناء المثبّت `UATA-Setup-0.1.0.exe` (~170MB) ← تثبيت صامت ← تشغيل المحرك من مجلد التثبيت ← النتيجة:
  ```json
  {"ocr": true, "ocr_languages": ["ara", "eng"], "speech_to_text": false, "ffmpeg": true, "screen_capture": true}
  ```
  ← إيقاف المحرك ← إلغاء تثبيت صامت ← التحقق من حذف البرنامج. ✔
* المثبّت متاح كـ artifact باسم `uata-windows-installer` في كل تشغيل CI.

## أخطاء أُصلحت
* ملف لغة Inno العربية غير مرفق مع Inno Setup ← المثبّت بالإنجليزية (التطبيق نفسه عربي).

## المتبقي
* المثبّت غير موقّع رقمياً (يظهر تحذير SmartScreen) — يتطلب شهادة توقيع كود.
* تحويل الكلام إلى نص يحتاج نموذجاً محلياً يضعه المستخدم ويحدد مساره.
* قرار Android ما زال مطلوباً.
