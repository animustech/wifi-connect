#!/usr/bin/env bash

export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/host/run/dbus/system_bus_socket

# True (exit 0) if any non-loopback, non-wireless, physical-device-backed interface
# currently has a global IPv4 address, i.e. a wired connection is genuinely up (not
# just cabled but still negotiating DHCP). Restricted to interfaces with a real
# physical-device backing (a `device` symlink under /sys/class/net/<iface>/) so that
# bridges/veth/tun (e.g. balena0, supervisor0, docker0, br-*, resin-vpn), which always
# carry a global IP under network_mode: host regardless of whether a cable is
# plugged in, are not mistaken for a wired connection.
wired_connected() {
    local iface_path iface
    for iface_path in /sys/class/net/*/; do
        iface="$(basename "$iface_path")"
        # Physical NICs only. Bridges (balena0/supervisor0/docker0/br-*), veth,
        # tun (resin-vpn) and lo have no backing device symlink.
        [ -e "${iface_path}device" ] || continue
        # Skip wireless NICs (belt-and-braces alongside the name match below).
        [ -e "${iface_path}wireless" ] && continue
        [ -e "${iface_path}phy80211" ] && continue
        case "$iface" in
            lo|wlan*|wl*) continue ;;
        esac
        if ip -4 -o addr show dev "$iface" scope global up 2>/dev/null | grep -q .; then
            return 0
        fi
    done
    return 1
}

PORTAL_SSID="Loci-AP-${BALENA_DEVICE_UUID:0:7}"

# True (exit 0) only for an association to a network that is not our own
# captive-portal hotspot.
#
# `iwgetid -r` reports the hotspot's SSID when wlan0 is in AP mode, so a portal
# profile left behind by an ungraceful exit is auto-activated by NetworkManager
# at boot and reads here as a perfectly healthy connection. Treating that as
# connected would skip wifi-connect entirely: no portal, no supervision, and a
# device that is dark until someone physically attends it.
wifi_connected() {
    local ssid
    ssid="$(iwgetid -r 2>/dev/null)" || return 1
    [ -n "$ssid" ] || return 1
    [ "$ssid" != "$PORTAL_SSID" ] || return 1
    return 0
}

connected() {
    wired_connected || wifi_connected
}

# Wired interfaces typically finish link negotiation and DHCP faster than WiFi, so a
# short bounded wait here is enough to avoid a boot-time race against a plugged-in
# cable that just hasn't finished getting an address yet.
WIRED_CHECK_TIMEOUT=10
elapsed=0
while ! wired_connected && [ "$elapsed" -lt "$WIRED_CHECK_TIMEOUT" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
done

# How long to let an association complete before surrendering wlan0 to the portal.
# Doubles as a debounce: a link that drops briefly and comes back is not worth
# raising a captive portal for.
WIFI_CHECK_TIMEOUT="${WIFI_CHECK_TIMEOUT:-300}"
WIFI_CHECK_INTERVAL="${WIFI_CHECK_INTERVAL:-5}"
# How often to re-examine the link while it is healthy.
SUPERVISE_INTERVAL="${SUPERVISE_INTERVAL:-60}"

# Supervision loop, not a one-shot boot gate.
#
# wifi-connect exits as soon as it successfully joins a network - that is
# upstream's design. Previously start.sh then fell through to `sleep infinity`,
# so for the rest of the boot there was no portal process and no periodic
# reconnect: a device that came up fine and lost its link hours later had
# nothing left to recover it. Measured on e3042ef, 2026-09-15 - the link died at
# 13:32 and wlan0 saw no activity at all for the next 37 minutes.
#
# Re-deciding on an interval closes that. Both directions are covered: wired
# arriving later is noticed, and WiFi lost later is noticed.
last_state=""
while true; do
    if connected; then
        if [ "$last_state" != "connected" ]; then
            if wired_connected; then
                printf 'Wired connection detected - WiFi Connect not needed\n'
            else
                printf 'WiFi connected to %s\n' "$(iwgetid -r)"
            fi
            last_state="connected"
        fi
        sleep "$SUPERVISE_INTERVAL"
        continue
    fi

    if [ "$last_state" = "connected" ]; then
        printf 'Connection lost - waiting up to %ss for it to return\n' \
            "$WIFI_CHECK_TIMEOUT"
    fi
    last_state="disconnected"

    elapsed=0
    if [ "$(iwgetid -r 2>/dev/null)" = "$PORTAL_SSID" ]; then
        # Nothing to wait for: the radio is serving our own stale portal, so it
        # cannot be associating to anything. Relaunching deletes the leftover
        # profile when wifi-connect creates its own.
        printf 'Stale portal AP %s is up from a previous run - not waiting\n' \
            "$PORTAL_SSID"
    else
        while ! connected && [ "$elapsed" -lt "$WIFI_CHECK_TIMEOUT" ]; do
            sleep "$WIFI_CHECK_INTERVAL"
            elapsed=$((elapsed + WIFI_CHECK_INTERVAL))
        done
    fi

    if connected; then
        continue
    fi

    printf 'No connection after %ss - starting WiFi Connect\n' "$elapsed"
    # Blocks until a network is joined through the portal, then exits. The loop
    # picks supervision back up from there.
    ./wifi-connect -s "$PORTAL_SSID" -p "!${BALENA_DEVICE_UUID:0:7}#"
    printf 'WiFi Connect exited - resuming supervision\n'
    last_state=""
    sleep "$SUPERVISE_INTERVAL"
done
