#!/usr/bin/env bash
# Установка лаунчера на портал.
#
# ADB обычно доступен только по сети, поэтому сначала поднимите туннель:
#   ssh -f -N -L 15555:<PORTAL_IP>:5555 <user>@<LAN_HOST>
#   ADB_SERIAL=127.0.0.1:15555 ./scripts/install-launcher.sh
set -euo pipefail

: "${ADB_SERIAL:?export ADB_SERIAL=<adb serial, напр. 127.0.0.1:15555>}"
APK="${1:-$(dirname "$0")/../OpenStation-SberPortal.apk}"

adb -s "$ADB_SERIAL" install -r "$APK"

# Android сбрасывает домашнее приложение после переустановки APK.
adb -s "$ADB_SERIAL" shell cmd package set-home-activity com.openstation.launcher/.MainActivity
adb -s "$ADB_SERIAL" shell appops set com.openstation.launcher WRITE_SETTINGS allow
adb -s "$ADB_SERIAL" shell appops set com.openstation.launcher SYSTEM_ALERT_WINDOW allow
adb -s "$ADB_SERIAL" shell pm grant com.openstation.launcher android.permission.RECORD_AUDIO 2>/dev/null || true

adb -s "$ADB_SERIAL" shell am force-stop com.openstation.launcher
adb -s "$ADB_SERIAL" shell am start -n com.openstation.launcher/.MainActivity
adb -s "$ADB_SERIAL" shell cmd package resolve-activity --brief \
  -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1

echo "Готово. Мастер настройки откроется один раз при первом запуске."
