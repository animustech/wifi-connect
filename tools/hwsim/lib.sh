#!/usr/bin/env bash
# Shared helpers for the hwsim scenarios. Sourced by run-scenarios.sh.
set -u
HWSIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP="$HWSIM_DIR/ap.sh"
IMAGE="${IMAGE:-wifi-connect:test}"
UUID="${BALENA_DEVICE_UUID:-e3042ef0668f92664ba56878036ff528}"
PORTAL="Loci-AP-${UUID:0:7}"
SFAIL=0

sfail() { printf '    FAIL: %s\n' "$1"; SFAIL=$((SFAIL + 1)); }

# A vessel Pi has no cable. The VM cannot drop its own uplink without killing the
# shell driving it, and start.sh correctly reads that uplink as wired and
# suppresses wifi-connect - so the container gets a sysfs view with only the
# radio in it. Everything else is real: NetworkManager, D-Bus, wpa_supplicant.
fake_sys() {
    rm -rf /tmp/hwsim/sys-nowired
    mkdir -p /tmp/hwsim/sys-nowired/wlan0 /tmp/hwsim/sys-nowired/lo
    touch /tmp/hwsim/sys-nowired/wlan0/device /tmp/hwsim/sys-nowired/wlan0/phy80211
}

# device_up [EXTRA_ENV...]  - start the real container against the real radio
device_up() {
    fake_sys
    docker rm -f wc >/dev/null 2>&1
    local -a e=()
    for kv in "$@"; do e+=(-e "$kv"); done
    docker run -d --name wc --network host --privileged --cap-add NET_ADMIN \
        -v /run/dbus/system_bus_socket:/host/run/dbus/system_bus_socket \
        -v /tmp/hwsim/sys-nowired:/fake-sys:ro -v wc-data:/data \
        -e SYSFS_ROOT=/fake-sys -e BALENA_DEVICE_UUID="$UUID" \
        -e WIFI_CHECK_TIMEOUT=10 -e WIFI_CHECK_INTERVAL=5 -e SUPERVISE_INTERVAL=10 \
        -e RECONNECT_INTERVAL_MINUTES=1 -e RECONNECT_RESCAN_EVERY=2 \
        -e ACTIVITY_TIMEOUT=0 -e PORTAL_RETRY_GAP=30 \
        "${e[@]}" "$IMAGE" >/dev/null
}

device_down() { docker rm -f wc >/dev/null 2>&1 || true; }
device_log()  { docker logs wc 2>&1; }

wlan_mode() { iw dev wlan0 info 2>/dev/null | awk '/type/{print $2}'; }
wlan_ssid() { iwgetid -r 2>/dev/null || true; }

# wait_for <seconds> <predicate-command...>
wait_for() {
    local limit="$1"; shift
    local i=0
    while [ "$i" -lt "$limit" ]; do
        if "$@"; then return 0; fi
        sleep 2; i=$((i + 2))
    done
    return 1
}

portal_is_up()      { [ "$(wlan_mode)" = "AP" ]; }
joined_a_network()  { local s; s="$(wlan_ssid)"; [ -n "$s" ] && [ "$s" != "$PORTAL" ]; }
not_joined()        { ! joined_a_network; }

assert_log()   { device_log | grep -q -- "$1" || sfail "expected log: $1"; }
refute_log()   { device_log | grep -q -- "$1" && sfail "unexpected log: $1"; return 0; }

# Every scenario must leave the rig in a known state or the next one inherits it.
reset_rig() {
    device_down
    forget_all_wifi
    for s in 1 2 peer; do "$AP" down "$s" >/dev/null 2>&1; done
    nmcli -t -f NAME connection show 2>/dev/null | grep -E "^Loci-AP-" | \
        while read -r c; do nmcli connection delete "$c" >/dev/null 2>&1; done
    sleep 2
}

forget_all_wifi() {
    nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}' | \
        while read -r c; do nmcli connection delete "$c" >/dev/null 2>&1; done
}

# Wait until an SSID is actually visible in a scan. NetworkManager's scan cache
# lags a freshly started AP by several seconds, and `nmcli device wifi connect`
# fails outright with "No network with SSID found" rather than waiting - which
# looks like a broken AP when it is only a stale cache.
wait_ssid_visible() {
    local ssid="$1" i=0
    while [ "$i" -lt 40 ]; do
        nmcli device wifi rescan ifname wlan0 >/dev/null 2>&1
        sleep 3; i=$((i + 3))
        nmcli -t -f SSID device wifi list ifname wlan0 2>/dev/null | grep -qx "$ssid" && return 0
    done
    return 1
}

# Teach the device a network the way an operator would.
learn_network() {
    local ssid="$1" psk="$2" i=0
    # A half-written profile from an earlier failed attempt makes every later
    # attempt fail with "key-mgmt: property is missing".
    nmcli connection delete "$ssid" >/dev/null 2>&1
    wait_ssid_visible "$ssid" || return 1
    while [ "$i" -lt 3 ]; do
        nmcli device wifi connect "$ssid" password "$psk" ifname wlan0 >/dev/null 2>&1
        sleep 3
        [ "$(wlan_ssid)" = "$ssid" ] && return 0
        i=$((i + 1))
    done
    return 1
}
