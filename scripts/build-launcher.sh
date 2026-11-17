#!/usr/bin/env bash
# Сборка форкнутого лаунчера и подпись debug-ключом.
# Требования: JDK 17, Android SDK (build-tools 34+), Gradle 8.6.
set -euo pipefail

cd "$(dirname "$0")/../launcher"

: "${JAVA_HOME:?export JAVA_HOME=<JDK 17>}"
: "${ANDROID_HOME:?export ANDROID_HOME=<Android SDK>}"
GRADLE="${GRADLE:-gradle}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

"$GRADLE" :app:assembleRelease --no-daemon --console=plain

BUILD_TOOLS="${BUILD_TOOLS:-$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -1)}"
APKSIGNER="$ANDROID_HOME/build-tools/$BUILD_TOOLS/apksigner"
KEYSTORE="${DEBUG_KEYSTORE:-$HOME/.android/debug.keystore}"

if [ ! -f "$KEYSTORE" ]; then
  echo "Нет debug-keystore: $KEYSTORE" >&2
  echo "Создайте его: keytool -genkey -v -keystore \"$KEYSTORE\" -storepass android \\" >&2
  echo "  -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 -validity 10000 -dname CN=Android" >&2
  exit 1
fi

"$APKSIGNER" sign \
  --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
  --ks-key-alias androiddebugkey \
  --out ../OpenStation-SberPortal.apk \
  app/build/outputs/apk/release/app-release-unsigned.apk

"$APKSIGNER" verify --print-certs ../OpenStation-SberPortal.apk | head -3
echo "Готово: $(cd .. && pwd)/OpenStation-SberPortal.apk"
