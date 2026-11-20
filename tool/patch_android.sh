#!/usr/bin/env bash
# Донастройка сгенерированного android-проекта (запускается в GitHub Actions после `flutter create`).
set -euo pipefail

M=android/app/src/main/AndroidManifest.xml
if ! grep -q 'android.permission.CAMERA' "$M"; then
  sed -i 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <uses-permission android:name="android.permission.CAMERA"/>\n    <application#' "$M"
fi
sed -i 's#android:label="srokomer"#android:label="Срокомер"#' "$M"

# Корейская модель распознавания текста ML Kit
if [ -f android/app/build.gradle ]; then
  G=android/app/build.gradle
  grep -q text-recognition-korean "$G" || printf "\ndependencies {\n    implementation 'com.google.mlkit:text-recognition-korean:16.0.1'\n}\n" >> "$G"
else
  G=android/app/build.gradle.kts
  grep -q text-recognition-korean "$G" || printf "\ndependencies {\n    implementation(\"com.google.mlkit:text-recognition-korean:16.0.1\")\n}\n" >> "$G"
fi

# Плагины (mobile_scanner и др.) требуют Kotlin 2.x
for S in android/settings.gradle android/settings.gradle.kts; do
  if [ -f "$S" ]; then sed -i -E 's/(org\.jetbrains\.kotlin\.android"\)? version ")1\.[0-9.]+"/\12.1.0"/' "$S"; fi
done

echo "----- $M"; cat "$M"
echo "----- $G"; cat "$G"
echo "----- settings"; cat android/settings.gradle* || true
