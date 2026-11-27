#!/usr/bin/env bash
# Донастройка сгенерированного android-проекта (запускается в GitHub Actions после `flutter create`).
set -euo pipefail

M=android/app/src/main/AndroidManifest.xml
# 식약처 API работает только по http — разрешаем
if ! grep -q usesCleartextTraffic "$M"; then
  sed -i 's#<application#<application android:usesCleartextTraffic="true"#' "$M"
fi
# Уведомления: разрешения и приёмники (перепланирование после перезагрузки)
if ! grep -q 'ScheduledNotificationReceiver' "$M"; then
  sed -i 's#</application>#<receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"/>\n        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver"><intent-filter><action android:name="android.intent.action.BOOT_COMPLETED"/><action android:name="android.intent.action.MY_PACKAGE_REPLACED"/><action android:name="android.intent.action.QUICKBOOT_POWERON"/><action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/></intent-filter></receiver>\n    </application>#' "$M"
  sed -i 's#<application#<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>\n    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>\n    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>\n    <application#' "$M"
fi

if ! grep -q 'android.permission.CAMERA' "$M"; then
  sed -i 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <uses-permission android:name="android.permission.CAMERA"/>\n    <application#' "$M"
fi
# Модель «убрать фон» скачивается заранее
if ! grep -q 'subject_segment' "$M"; then
  sed -i 's#</application>#<meta-data android:name="com.google.mlkit.vision.DEPENDENCIES" android:value="subject_segment,ocr"/>\n    </application>#' "$M"
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

# ПОСТОЯННАЯ подпись приложения: одна и та же для всех версий, иначе Android не даёт
# установить обновление поверх (и приходится удалять приложение вместе с данными).
GK=android/app/build.gradle.kts
GG=android/app/build.gradle
if [ -f "$GK" ] && ! grep -q 'create("fixed")' "$GK"; then
  sed -i 's#^    buildTypes {#    signingConfigs {\n        create("fixed") {\n            storeFile = file("../../tool/debug.keystore")\n            storePassword = "android"\n            keyAlias = "androiddebugkey"\n            keyPassword = "android"\n        }\n    }\n    buildTypes {#' "$GK"
  sed -i 's#signingConfigs.getByName("debug")#signingConfigs.getByName("fixed")#' "$GK"
  grep -q 'getByName("fixed")' "$GK" || { echo "signing patch failed"; exit 1; }
elif [ -f "$GG" ] && ! grep -q 'fixed {' "$GG"; then
  sed -i 's#^    buildTypes {#    signingConfigs {\n        fixed {\n            storeFile file("../../tool/debug.keystore")\n            storePassword "android"\n            keyAlias "androiddebugkey"\n            keyPassword "android"\n        }\n    }\n    buildTypes {#' "$GG"
  sed -i 's#signingConfig signingConfigs.debug#signingConfig signingConfigs.fixed#' "$GG"
  grep -q 'signingConfigs.fixed' "$GG" || { echo "signing patch failed"; exit 1; }
fi

# Корейская модель распознавания текста ML Kit
if [ -f android/app/build.gradle ]; then
  G=android/app/build.gradle
  grep -q text-recognition-korean "$G" || printf "\ndependencies {\n    implementation 'com.google.mlkit:text-recognition-korean:16.0.1'\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n" >> "$G"
  grep -q coreLibraryDesugaringEnabled "$G" || sed -i 's/compileOptions {/compileOptions {\n        coreLibraryDesugaringEnabled true/' "$G"
else
  G=android/app/build.gradle.kts
  grep -q text-recognition-korean "$G" || printf "\ndependencies {\n    implementation(\"com.google.mlkit:text-recognition-korean:16.0.1\")\n    coreLibraryDesugaring(\"com.android.tools:desugar_jdk_libs:2.1.4\")\n}\n" >> "$G"
  grep -q isCoreLibraryDesugaringEnabled "$G" || sed -i 's/compileOptions {/compileOptions {\n        isCoreLibraryDesugaringEnabled = true/' "$G"
fi

# R8: модели других языков ML Kit не подключаем — не ругаться на их отсутствие
cat > android/app/proguard-rules.pro <<'PRO'
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-keep class com.google.mlkit.vision.text.korean.** { *; }
-keep class com.dexterous.** { *; }
-keepattributes Signature
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
PRO

# Плагины (mobile_scanner и др.) требуют Kotlin 2.x
for S in android/settings.gradle android/settings.gradle.kts; do
  if [ -f "$S" ]; then sed -i -E 's/(org\.jetbrains\.kotlin\.android"\)? version ")1\.[0-9.]+"/\12.1.0"/' "$S"; fi
done

echo "----- $M"; cat "$M"
echo "----- $G"; cat "$G"
echo "----- settings"; cat android/settings.gradle* || true
