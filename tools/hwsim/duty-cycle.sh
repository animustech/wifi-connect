#!/usr/bin/env bash
# How much of a long outage does wifi-connect spend holding the radio?
# Runs INSIDE the VM as root.
#
#   duty-cycle.sh <seconds> [ACTIVITY_TIMEOUT] [PORTAL_RETRY_GAP]
#
# The AP stays down throughout. Every 2 s we record whether wlan0 is in AP mode
# (we are holding it, NetworkManager cannot reacquire anything) or not (NM has
# it). NM reacquires a returning AP in 5-10 s; our own reconnect tick is minutes,
# so time spent in AP mode is time recovery is slower than doing nothing.
#
# Timings are compressed so a run takes minutes. The ratio is what transfers, not
# the absolute numbers.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DURATION="${1:-180}"
AT="${2:-120}"
GAP="${3:-60}"
UUID="${BALENA_DEVICE_UUID:-e3042ef0668f92664ba56878036ff528}"

rm -rf /tmp/hwsim/sys-nowired
mkdir -p /tmp/hwsim/sys-nowired/wlan0 /tmp/hwsim/sys-nowired/lo
touch /tmp/hwsim/sys-nowired/wlan0/device /tmp/hwsim/sys-nowired/wlan0/phy80211

"$HERE/ap.sh" down >/dev/null
docker rm -f wc >/dev/null 2>&1 || true
sleep 2

docker run -d --name wc --network host --privileged --cap-add NET_ADMIN \
    -v /run/dbus/system_bus_socket:/host/run/dbus/system_bus_socket \
    -v /tmp/hwsim/sys-nowired:/fake-sys:ro -v wc-data:/data \
    -e SYSFS_ROOT=/fake-sys -e BALENA_DEVICE_UUID="$UUID" \
    -e WIFI_CHECK_TIMEOUT=10 -e WIFI_CHECK_INTERVAL=5 -e SUPERVISE_INTERVAL=10 \
    -e RECONNECT_INTERVAL_MINUTES=1 -e RECONNECT_RESCAN_EVERY=2 \
    -e ACTIVITY_TIMEOUT="$AT" -e PORTAL_RETRY_GAP="$GAP" \
    wifi-connect:test >/dev/null

held=0; free=0; samples=0
end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$end" ]; do
    if [ "$(iw dev wlan0 info 2>/dev/null | awk '/type/{print $2}')" = "AP" ]; then
        held=$((held + 1))
    else
        free=$((free + 1))
    fi
    samples=$((samples + 1))
    sleep 2
done

docker rm -f wc >/dev/null 2>&1 || true
pct=$(( held * 100 / samples ))
echo "ACTIVITY_TIMEOUT=$AT PORTAL_RETRY_GAP=$GAP over ${DURATION}s:"
echo "  radio held by wifi-connect : ${pct}%  (${held}/${samples} samples)"
echo "  available to NetworkManager: $((100 - pct))%"
