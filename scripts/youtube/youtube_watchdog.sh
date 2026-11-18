#!/system/bin/sh
# Keep the YouTube route on SberPortal alive:
#   1. StarTube's TLS-PSK tunnel to Sber's SOCKS5 proxy (port from the app);
#   2. ytproxy, the local HTTP proxy that sends YouTube through that tunnel;
#   3. the system proxy setting that points every app at ytproxy.
#
# Used at boot by sber_guard.sh and safe to run several times: a pid file bound
# to boot_id keeps a single instance.

DIR=/data/local/openstation/yt
BIN=/data/local/openstation
PIDFILE=$DIR/watchdog.pid
PROXY_ADDR=127.0.0.1:11088
mkdir -p "$DIR"
BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
if [ -f "$PIDFILE" ]; then
    read OLD OLD_BOOT < "$PIDFILE" 2>/dev/null
    [ "$OLD_BOOT" = "$BOOT" ] && [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null && exit 0
fi
echo "$$ $BOOT" > "$PIDFILE"

while true; do
    if [ "$(getprop sys.boot_completed)" = "1" ]; then
        if ! pidof stube_tunnel >/dev/null 2>&1 && ! pidof libstunnel.so >/dev/null 2>&1; then
            sh "$DIR/stube_tunnel_start.sh"
        fi
        # ytproxy forks one child per connection, so pidof is useless here:
        # check that the listening socket exists instead (11088 = 0x2B50).
        if ! grep -q ':2B50' /proc/net/tcp 2>/dev/null; then
            ( cd "$BIN" && nohup setsid ./ytproxy 11088 11086 1 >>"$DIR/ytproxy.log" 2>&1 </dev/null & )
        fi
        if [ "$(settings get global http_proxy 2>/dev/null)" != "$PROXY_ADDR" ]; then
            settings put global http_proxy "$PROXY_ADDR"
        fi
    fi
    sleep 5
done
