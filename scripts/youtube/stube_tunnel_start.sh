#!/system/bin/sh
# Start StarTube's TLS-PSK tunnel (Sber's SOCKS5 proxy) outside the app.
#
# ru.sberdevices.startube has a built-in DPI bypass: an stunnel client on
# 127.0.0.1:<localPort> that speaks TLS-PSK to Sber's proxy and lets the far
# side resolve and dial YouTube. The app starts that stunnel itself and kills
# it right away (race in ProxyUpdater), so the proxy is never there and the
# app reports "нет доступа к сервису YouTube".
#
# Here the same stunnel is started once, from the app's own cached config
# (PSK, target, local port), and kept alive by youtube_watchdog.sh.
#
# Safe to run repeatedly: exits when a tunnel is already up.

PKG=ru.sberdevices.startube
DIR=/data/local/openstation/yt
CONF=$DIR/stunnel.conf
LOG=$DIR/stunnel.log
DEFAULT_PORT=11086

i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $i -lt 60 ]; do
    sleep 2; i=$((i + 1))
done
i=0
while ! ip route 2>/dev/null | grep -q 'dev wlan0' && [ $i -lt 30 ]; do
    sleep 2; i=$((i + 1))
done

pidof stube_tunnel >/dev/null 2>&1 && exit 0
pidof libstunnel.so >/dev/null 2>&1 && exit 0

BASE=$(pm path $PKG 2>/dev/null | sed 's/^package://; s#/base.apk$##')
[ -n "$BASE" ] || exit 0
[ -x "$BASE/lib/arm/libstunnel.so" ] || exit 0

mkdir -p "$DIR"

if [ ! -x "$DIR/stube_tunnel" ] || [ "$BASE/lib/arm/libstunnel.so" -nt "$DIR/stube_tunnel" ]; then
    cp "$BASE/lib/arm/libstunnel.so" "$DIR/stube_tunnel" 2>/dev/null || exit 0
fi
chmod 755 "$DIR/stube_tunnel"

PREFS=/data/data/$PKG/shared_prefs/APP_PREFS.xml
[ -f "$PREFS" ] || exit 0

# The cached config is JSON stored inside XML, so quotes are &quot;.
CFG=$(sed 's/&quot;/"/g' "$PREFS" 2>/dev/null)
PSK=$(printf '%s' "$CFG" | grep -o '"pskKey":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')
TARGET=$(printf '%s' "$CFG" | grep -o '"target":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')
PORT=$(printf '%s' "$CFG" | grep -o '"localPort":"[0-9]*"' | head -1 | sed 's/.*:"//; s/"$//')
[ -n "$PSK" ] || exit 0
[ -n "$TARGET" ] || TARGET=st-ru1.sbrdvc.ru:4433
[ -n "$PORT" ] || PORT=$DEFAULT_PORT
# Optional pin of a working address; the service is multi-homed.
[ -f "$DIR/target" ] && TARGET=$(cat "$DIR/target" 2>/dev/null)

printf '%s' "$PORT" > "$DIR/port"
printf '%s' "$PSK" > "$DIR/psk.txt" || exit 0
chmod 600 "$DIR/psk.txt"
{
    echo "debug = 4"
    echo "syslog = no"
    echo "foreground = yes"
    echo "[auto-proxy-0]"
    echo "client = yes"
    echo "accept = $PORT"
    echo "connect = $TARGET"
    echo "PSKsecrets = $DIR/psk.txt"
} > "$CONF" || exit 0
chmod 600 "$CONF"

cd "$DIR" || exit 0
nohup ./stube_tunnel "$CONF" >>"$LOG" 2>&1 </dev/null &
