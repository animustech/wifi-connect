#!/usr/bin/env bash
# S4 - a device stranded with its portal up recovers on its own when the vessel
# AP returns, with nobody touching the portal. Runs INSIDE the VM as root.
#
# This is the scenario the whole reconnect feature exists for and the one that
# could never be observed on hardware: every field recovery so far came from a
# human opening the portal before the first tick fired.
#
# Ticks are compressed (1 min instead of 15) so the run takes minutes, not hours.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-wifi-connect:test}"
UUID="${BALENA_DEVICE_UUID:-e3042ef0668f92664ba56878036ff528}"
PORTAL="Loci-AP-${UUID:0:7}"
SSID="${SSID:-Deep Runner-IOT}"
fail=0

# A vessel Pi has no cable. The VM cannot drop its own uplink without killing the
# shell it is being driven through, so the container is given a sysfs view that
# contains only the radio. Everything else - NetworkManager, D-Bus, the radio
# itself - is real.
rm -rf /tmp/hwsim/sys-nowired
mkdir -p /tmp/hwsim/sys-nowired/wlan0 /tmp/hwsim/sys-nowired/lo
touch /tmp/hwsim/sys-nowired/wlan0/device /tmp/hwsim/sys-nowired/wlan0/phy80211

echo "==> staging: AP down, device stranded"
"$HERE/ap.sh" down >/dev/null
docker rm -f wc >/dev/null 2>&1 || true
sleep 2

docker run -d --name wc --network host --privileged --cap-add NET_ADMIN \
    -v /run/dbus/system_bus_socket:/host/run/dbus/system_bus_socket \
    -v /tmp/hwsim/sys-nowired:/fake-sys:ro -v wc-data:/data \
    -e SYSFS_ROOT=/fake-sys -e BALENA_DEVICE_UUID="$UUID" \
    -e WIFI_CHECK_TIMEOUT=15 -e WIFI_CHECK_INTERVAL=5 -e SUPERVISE_INTERVAL=10 \
    -e RECONNECT_INTERVAL_MINUTES=1 -e RECONNECT_RESCAN_EVERY=2 \
    "$IMAGE" >/dev/null

for i in $(seq 1 12); do
    sleep 5
    [ "$(iw dev wlan0 info 2>/dev/null | awk '/ssid/{print $2}')" = "${PORTAL}" ] && break
done
if [ "$(iw dev wlan0 info 2>/dev/null | awk '/type/{print $2}')" != "AP" ]; then
    echo "  FAIL: portal never came up"; docker logs wc 2>&1 | tail; exit 1
fi
echo "  portal $PORTAL is up - device is stranded"

echo "==> the vessel AP returns; nobody touches the portal"
"$HERE/ap.sh" up >/dev/null 2>&1
start=$(date +%s)
recovered=""
for i in $(seq 1 30); do
    sleep 10
    s="$(iwgetid -r 2>/dev/null || true)"
    if [ -n "$s" ] && [ "$s" != "$PORTAL" ]; then recovered="$s"; break; fi
done
elapsed=$(( $(date +%s) - start ))

log="$(docker logs wc 2>&1)"
if [ -z "$recovered" ]; then
    echo "  FAIL: still stranded after ${elapsed}s"; printf '%s\n' "$log" | tail; exit 1
fi
echo "  RECOVERED after ${elapsed}s -> $recovered"

# The reconnect must be M4's doing, not a human's and not a fluke.
printf '%s\n' "$log" | grep -q 'Forced periodic rescan'        || { echo "  FAIL: no forced rescan"; fail=1; }
printf '%s\n' "$log" | grep -q 'Periodic reconnect: attempting' || { echo "  FAIL: M4 never attempted"; fail=1; }
printf '%s\n' "$log" | grep -q 'WiFi Connect exited'            || { echo "  FAIL: binary did not exit"; fail=1; }
# S10: the device's own AP must never appear in its own scan results.
if printf '%s\n' "$log" | grep 'Access points:' | grep -q "$PORTAL"; then
    echo "  FAIL: own portal SSID leaked into the scan (S10)"; fail=1
fi

[ "$fail" -eq 0 ] && echo "S4 PASS" || echo "S4 FAIL"
exit "$fail"
