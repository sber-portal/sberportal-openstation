#!/usr/bin/env bash
# Сборка ytproxy под портал (armeabi-v7a).
set -euo pipefail
cd "$(dirname "$0")"

: "${ANDROID_NDK:?export ANDROID_NDK=<path to NDK>}"
CC="$ANDROID_NDK/toolchains/llvm/prebuilt/$(uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/mac/')-x86_64/bin/armv7a-linux-androideabi28-clang"
STRIP="${STRIP:-$(dirname "$CC")/llvm-strip}"

[ -x "$CC" ] || { echo "нет компилятора: $CC" >&2; exit 1; }

"$CC" -O2 -Wall -Wextra -o ytproxy ytproxy.c
"$STRIP" --strip-unneeded ytproxy
ls -l ytproxy
