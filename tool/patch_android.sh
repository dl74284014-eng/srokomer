#!/usr/bin/env bash
# Донастройка сгенерированного android-проекта (запускается в GitHub Actions после `flutter create`).
set -euo pipefail

M=android/app/src/main/AndroidManifest.xml
# 식약처 API работает только по http — разрешаем
if ! grep -q usesCleartextTraffic "$M"; then
  sed -i 's#<application#<application android:usesCleartextTraffic="true"#' "$M"
fi
if ! grep -q 'android.permission.CAMERA' "$M"; then
  sed -i 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <uses-permission android:name="android.permission.CAMERA"/>\n    <application#' "$M"
fi
# Название под значком
sed -i 's#android:label="[^"]*"#android:label="@string/app_name"#' "$M"
mkdir -p android/app/src/main/res/values android/app/src/main/res/values-ko
cat > android/app/src/main/res/values/strings.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources><string name="app_name">L할인마트 유통기한</string></resources>
XML
cat > android/app/src/main/res/values-ko/strings.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources><string name="app_name">L할인마트 유통기한</string></resources>
XML

# Корейская модель распознавания текста ML Kit
if [ -f android/app/build.gradle ]; then
  G=android/app/build.gradle
  grep -q text-recognition-korean "$G" || printf "\ndependencies {\n    implementation 'com.google.mlkit:text-recognition-korean:16.0.1'\n}\n" >> "$G"
else
  G=android/app/build.gradle.kts
  grep -q text-recognition-korean "$G" || printf "\ndependencies {\n    implementation(\"com.google.mlkit:text-recognition-korean:16.0.1\")\n}\n" >> "$G"
fi

# R8: модели других языков ML Kit не подключаем — не ругаться на их отсутствие
cat > android/app/proguard-rules.pro <<'PRO'
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-keep class com.google.mlkit.vision.text.korean.** { *; }
PRO

# Плагины (mobile_scanner и др.) требуют Kotlin 2.x
for S in android/settings.gradle android/settings.gradle.kts; do
  if [ -f "$S" ]; then sed -i -E 's/(org\.jetbrains\.kotlin\.android"\)? version ")1\.[0-9.]+"/\12.1.0"/' "$S"; fi
done

echo "----- $M"; cat "$M"
echo "----- $G"; cat "$G"
echo "----- settings"; cat android/settings.gradle* || true
