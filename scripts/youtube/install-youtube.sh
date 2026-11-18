#!/usr/bin/env bash
# Поднимает YouTube на SberPortal и цепляет его к автозагрузке.
#
# Что делает:
#   * кладёт ytproxy и скрипты в /data/local/openstation/yt;
#   * ставит системный прокси 127.0.0.1:11088 (только YouTube идёт через
#     туннель, остальной трафик — напрямую);
#   * запускает watchdog и прописывает его в sber_guard.sh (стартует при
#     загрузке от bootstarter).
#
# Требуется: собранный ytproxy (см. build.sh), adb с root на портале,
# установленный StarTube (ru.sberdevices.startube) и SmartTube.
#
# Использование:
#   D=127.0.0.1:15555 ./install-youtube.sh [путь-к-ytproxy]
set -euo pipefail

D=${D:?укажи adb serial, например D=127.0.0.1:15555}
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=${1:-$HERE/ytproxy}
[ -f "$BIN" ] || { echo "нет ytproxy: $BIN" >&2; exit 1; }

echo "[1/4] push"
adb -s "$D" shell 'mkdir -p /data/local/openstation/yt'
adb -s "$D" push "$BIN" /data/local/openstation/ytproxy >/dev/null
adb -s "$D" push "$HERE/stube_tunnel_start.sh" /data/local/openstation/yt/stube_tunnel_start.sh >/dev/null
adb -s "$D" push "$HERE/youtube_watchdog.sh" /data/local/openstation/yt/youtube_watchdog.sh >/dev/null
adb -s "$D" shell 'chmod 755 /data/local/openstation/ytproxy /data/local/openstation/yt/*.sh'

echo "[2/4] системный прокси + разрешение приложению StarTube"
adb -s "$D" shell 'settings put global http_proxy 127.0.0.1:11088'
adb -s "$D" shell 'pm enable ru.sberdevices.startube >/dev/null 2>&1 || true'

echo "[3/4] hook watchdog into sber_guard.sh"
adb -s "$D" shell '
  G=/data/local/tmp/sber_guard.sh
  [ -f "$G" ] || exit 0
  sed -i "/stube_stunnel_watchdog/d" "$G" 2>/dev/null || true
  grep -q openstation/yt/youtube_watchdog "$G" && exit 0
  sed -i "2i [ -x /data/local/openstation/yt/youtube_watchdog.sh ] && (nohup sh /data/local/openstation/yt/youtube_watchdog.sh >/dev/null 2>\&1 \&)" "$G"
'

echo "[4/4] start and verify"
adb -s "$D" shell 'nohup sh /data/local/openstation/yt/youtube_watchdog.sh >/dev/null 2>&1 &'
sleep 8
adb -s "$D" shell 'echo "tunnel=$(pidof stube_tunnel) proxy=$(settings get global http_proxy) listen11088=$(grep -c ":2B50" /proc/net/tcp)"'
adb -s "$D" shell 'tail -3 /data/local/openstation/yt/ytproxy.log 2>/dev/null || true'
echo "Готово: YouTube идёт через туннель StarTube, остальное — напрямую."
