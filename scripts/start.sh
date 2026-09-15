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

# Wired interfaces typically finish link negotiation and DHCP faster than WiFi, so a
# short bounded wait here is enough to avoid a boot-time race against a plugged-in
# cable that just hasn't finished getting an address yet.
WIRED_CHECK_TIMEOUT=10
elapsed=0
while ! wired_connected && [ "$elapsed" -lt "$WIRED_CHECK_TIMEOUT" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
done

if wired_connected; then
    printf 'Wired connection detected - skipping WiFi Connect\n'
else
    # Optional step - it takes couple of seconds (or longer) to establish a WiFi connection
    # sometimes. In this case, following checks will fail and wifi-connect
    # will be launched even if the device will be able to connect to a WiFi network.
    # If this is your case, you can wait for a while and then check for the connection.
    sleep 15

    # Choose a condition for running WiFi Connect according to your use case:

    # 1. Is there a default gateway?
    # ip route | grep default

    # 2. Is there Internet connectivity?
    # nmcli -t g | grep full

    # 3. Is there Internet connectivity via a google ping?
    # wget --spider http://google.com 2>&1

    # 4. Is there an active WiFi connection?
    iwgetid -r

    if [ $? -eq 0 ]; then
        printf 'Skipping WiFi Connect\n'
    else
        printf 'Starting WiFi Connect\n'
        ./wifi-connect -s "Loci-AP-${BALENA_DEVICE_UUID:0:7}" -p "!${BALENA_DEVICE_UUID:0:7}#"
    fi
fi

# Start your application here.
sleep infinity
