#!/usr/bin/env bash
# The simulated vessel access point. Runs INSIDE the VM as root.
#
#   ap.sh up [ssid] [passphrase]
#   ap.sh down
#   ap.sh status
#
# `down` is how every outage scenario is staged - it is the equivalent of the
# vessel's router losing power.
set -euo pipefail

SSID="${2:-Deep Runner-IOT}"
PSK="${3:-testpass123}"
CONF=/tmp/hwsim-hostapd.conf

case "${1:-status}" in
up)
    cat > "$CONF" <<EOF
interface=wlan1
driver=nl80211
ssid=$SSID
hw_mode=g
channel=6
wpa=2
wpa_passphrase=$PSK
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
    ip netns exec ap ip link set wlan1 up
    ip netns exec ap ip addr replace 10.42.0.1/24 dev wlan1
    ip netns exec ap hostapd -B "$CONF"
    # A vessel AP hands out addresses; without this, association succeeds and
    # IP configuration then times out, which looks like an auth failure.
    pgrep -x dnsmasq >/dev/null || \
        ip netns exec ap dnsmasq --interface=wlan1 --bind-interfaces \
            --dhcp-range=10.42.0.50,10.42.0.150,12h --except-interface=lo
    echo "AP '$SSID' up"
    ;;
down)
    # -x, never -f: a -f pattern containing "hostapd" also matches the shell
    # running this script, which then kills itself.
    pkill -x hostapd || true
    echo "AP down"
    ;;
status)
    if pgrep -x hostapd >/dev/null; then
        ip netns exec ap iw dev wlan1 info | grep -E 'ssid|type|channel' || true
    else
        echo "AP down"
    fi
    echo -n "device radio: "; iwgetid -r || echo "(not associated)"
    ip -4 -br addr show wlan0 2>/dev/null || true
    ;;
*) echo "usage: ap.sh up|down|status" >&2; exit 2 ;;
esac
