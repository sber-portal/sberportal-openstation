#!/usr/bin/env bash
# Сборка демона под armeabi-v7a и (опционально) установка на портал.
#
#   ANDROID_NDK=/path/to/ndk ./scripts/build-daemon.sh
#   ANDROID_NDK=... ADB_SERIAL=127.0.0.1:15555 ./scripts/build-daemon.sh --install
set -euo pipefail

cd "$(dirname "$0")/.."
: "${ANDROID_NDK:?export ANDROID_NDK=<Android NDK 27.x>}"

# Ожидается upstream-репозиторий рядом с этим форком.
UPSTREAM="${UPSTREAM:-../OPENSTATION}"
if [ ! -d "$UPSTREAM/daemon" ]; then
  echo "Нет исходников демона в $UPSTREAM" >&2
  echo "Склонируйте https://github.com/Olegu621/OPENSTATION и примените daemon/patches/*.patch" >&2
  exit 1
fi

BUILD_DIR="${BUILD_DIR:-build-v7}"

cmake -S "$UPSTREAM/daemon" -B "$BUILD_DIR" \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=armeabi-v7a \
  -DANDROID_PLATFORM=android-28 \
  -DCMAKE_BUILD_TYPE=Release

cmake --build "$BUILD_DIR" -j"$(getconf _NPROCESSORS_ONLN)"
STRIP="$(echo "$ANDROID_NDK"/toolchains/llvm/prebuilt/*/bin/llvm-strip)"
"$STRIP" --strip-unneeded "$BUILD_DIR/openstationd"

echo "Готово: $BUILD_DIR/openstationd ($(du -h "$BUILD_DIR/openstationd" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
  : "${ADB_SERIAL:?export ADB_SERIAL=<adb serial>}"
  adb -s "$ADB_SERIAL" push "$BUILD_DIR/openstationd" /data/local/openstation/openstationd.new
  adb -s "$ADB_SERIAL" shell 'cd /data/local/openstation && \
    cp -f openstationd openstationd.bak 2>/dev/null || true; \
    cp -f openstationd.new openstationd && chmod 755 openstationd && \
    kill $(pidof openstationd) 2>/dev/null || true'
  sleep 2
  adb -s "$ADB_SERIAL" shell 'nohup setsid sh -c "exec env \
    LD_LIBRARY_PATH=/data/local/openstation/lib:/vendor/lib:/system/lib \
    /data/local/openstation/openstationd >>/data/local/openstation/boot.log 2>&1" >/dev/null 2>&1 &'
  sleep 3
  adb -s "$ADB_SERIAL" shell 'pidof openstationd' || true
fi
