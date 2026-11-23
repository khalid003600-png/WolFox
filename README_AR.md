# WolFox ليوتيوب على iOS

WolFox مشروع مفتوح المصدر يضيف ميزات وتحسينات إلى YouTube على iPhone وiPad، مثل تنزيل الفيديو والصوت وShorts، والتشغيل في الخلفية، وميزة صورة داخل صورة، وSponsorBlock، وتخصيص عناصر الواجهة.

> يحتوي هذا المستودع العام على الشيفرة والموارد وسكربتات البناء والاختبارات والإشعارات فقط؛ ولا يضم IPA أو تطبيقًا جاهزًا أو مكتبة مترجمة. يتطلب إنشاء IPA نسخة YouTube مفكوكة التشفير ومصرحًا بتعديلها.

## معاينة الواجهة

الصور التالية معاينات موجودة ضمن ملفات المشروع لعرض بعض الميزات. **ليست لقطات ملتقطة من تشغيل IPA المبنية في هذه الجلسة**؛ يلزم اختبار التثبيت والتشغيل على جهاز iPhone للتأكد من سلوك البناء الحالي.

<p align="center">
  <img src="screenshots/framed/video-player.png" width="230" alt="معاينة عناصر التحكم في مشغل الفيديو">
  <img src="screenshots/framed/player-settings.png" width="230" alt="معاينة إعدادات مشغل WolFox">
  <img src="screenshots/framed/download-progress.png" width="230" alt="معاينة تقدم تنزيل الفيديو">
</p>

## الاسم والتوافق

اسم التطبيق الظاهر وملف التنفيذ والعملية والمكتبة المحقونة وحزمة الموارد وملحق Safari الاختياري هي **WolFox**. يبقى معرّف تطبيق YouTube المضيف `com.google.ios.youtube` كما هو حتى تبقى وظائف الدمج والروابط متوافقة؛ لذلك تحل IPA محل YouTube ولا تثبّت بجانبه.

تُحفظ معرّفات وإعدادات داخلية تاريخية مثل `com.wolfox.ytkace` ومفاتيح `YTKACE.Preference.*` عند الحاجة للتوافق مع الترقية والبيانات. هذه قيم داخلية وليست أسماء ظاهرة للمستخدم. أُزيل قسم المطوّر القديم من إعدادات التطبيق، مع الإبقاء على نسب المصدر والتراخيص في ملفاتها.

## بناء مكتبة WolFox

يتطلب البناء Theos وiOS SDK ومكتبات FFmpeg الثابتة لمعمارية arm64. من مجلد المستودع:

```sh
export THEOS=/path/to/theos
bash Scripts/build.sh
```

يُنشأ الملف `dist/WolFox.dylib`. يمكن توفير مكتبات FFmpeg في `Vendor/FFmpeg/lib/` أو بناؤها من المصدر باستخدام `Scripts/build-ffmpeg.sh` مع الإبقاء على إشعارات LGPL المرفقة.

## إنشاء IPA محلية جاهزة لإعادة التوقيع

لإعادة تغليف IPA YouTube مفكوكة التشفير ومسموح بتعديلها:

```sh
bash Scripts/sideload-repack.sh /path/to/YouTube.ipa dist/WolFox.dylib /path/to/WolFox-YouTube-1.2.1.ipa
```

أو لتغليف مجلد تطبيق مفكوك:

```sh
bash Scripts/build-ipa.sh /path/to/YouTube.app dist/WolFox.dylib /path/to/WolFox-YouTube-1.2.1.ipa
```

يتحقق البرنامج من بقاء معرّف الحزمة `com.google.ios.youtube`، ويغيّر الاسم الظاهر واسم التنفيذ إلى WolFox، ويحقن `@rpath/WolFox.dylib` وموارد WolFox. التوقيع الناتج محلي/مؤقت؛ أعد توقيع IPA بشهادتك عبر ESign قبل تثبيتها. لا يتضمن المشروع شهادة Apple أو ملف provisioning، ولم يُجرَ اختبار تشغيل على جهاز فعلي ضمن هذا المستودع.

## المصدر والترخيص

يعتمد WolFox على مصدر YTKACE مع الإبقاء على ترخيص MIT ونسب المصدر وإشعارات المكونات التابعة. WolFox غير تابع لـGoogle أو YouTube.

المستودع: <https://github.com/khalid003600-png/WolFox>
