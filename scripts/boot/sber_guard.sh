#!/system/bin/sh
# OpenStation boot helper for SberPortal.
#
# Started by RavnBootStarter (GuardThread) after boot; that thread restarts this
# script if its pid disappears. The script keeps the device reachable and the
# YouTube route alive, and blocks Sber firmware updates.
#
# Installed as /data/local/tmp/sber_guard.sh.
echo $$ > /data/local/tmp/sber_guard.pid

# ZeroTier is how remote units are reached - start it first.
[ -x /data/local/tmp/zt_start.sh ] && /data/local/tmp/zt_start.sh

# Firmware OTA block (idempotent one-shot).
[ -x /data/local/tmp/ota_guard.sh ] && sh /data/local/tmp/ota_guard.sh >/dev/null 2>&1

WATCHDOG=/data/local/openstation/yt/youtube_watchdog.sh

# Keep the watchdog itself alive: it owns the StarTube TLS-PSK tunnel and the
# local HTTP proxy, and the watchdog script is idempotent (it exits when a live
# instance is already there).
while true; do
    if [ -x "$WATCHDOG" ]; then
        wp=$(cat /data/local/openstation/yt/watchdog.pid 2>/dev/null | awk '{print $1}')
        if [ -z "$wp" ] || [ ! -d "/proc/$wp" ]; then
            nohup sh "$WATCHDOG" >/dev/null 2>&1 &
        fi
    fi
    sleep 30
done
