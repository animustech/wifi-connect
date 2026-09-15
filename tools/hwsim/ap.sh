#!/usr/bin/env bash
# The simulated radio environment. Runs INSIDE the VM as root.
#
#   ap.sh setup                                 create namespaces, place radios
#   ap.sh up   <slot> [ssid] [psk] [--reject]   bring an AP up
#   ap.sh down <slot>                           take it down (stages every outage)
#   ap.sh psk  <slot> <ssid> <new-psk>          restart it with a different key (S8)
#   ap.sh status
#
# Slots:
#   1     the vessel AP                       wlan1 in netns ap1
#   2     a second vessel AP                  wlan2 in netns ap2   (S9 ordering)
#   peer  another Loci unit's captive portal  wlan3 in netns peer  (S13)
#
# wlan0 stays in the host namespace under NetworkManager - it is the device.
#
# Never hardcode phy numbers: reloading mac80211_hwsim renumbers them (phy0..phy3
# became phy2..phy5 after one reload), so resolve netdev -> phy at runtime.
set -euo pipefail

slot_iface() { case "$1" in 1) echo wlan1 ;; 2) echo wlan2 ;; peer) echo wlan3 ;;
                            *) echo "unknown slot '$1'" >&2; exit 2 ;; esac; }
slot_ns()    { case "$1" in 1) echo ap1 ;; 2) echo ap2 ;; peer) echo peer ;; esac; }
slot_net()   { case "$1" in 1) echo 10.42.0 ;; 2) echo 10.43.0 ;; peer) echo 10.44.0 ;; esac; }

cmd_setup() {
    local ns iface phy
    for slot in 1 2 peer; do
        ns="$(slot_ns "$slot")"; iface="$(slot_iface "$slot")"
        ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$ns" || ip netns add "$ns"
        if [ -e "/sys/class/net/$iface/phy80211/name" ]; then
            phy="$(cat "/sys/class/net/$iface/phy80211/name")"
            iw phy "$phy" set netns name "$ns"
        fi
        ip netns exec "$ns" ip link set lo up 2>/dev/null || true
    done
    echo "namespaces ready: ap1 ap2 peer (wlan0 stays with NetworkManager)"
}

cmd_up() {
    local slot="$1"; shift
    local ssid="${1:-Deep Runner-IOT}"; local psk="${2:-testpass123}"
    shift 2 2>/dev/null || true
    local reject=0 a
    for a in "$@"; do [ "$a" = "--reject" ] && reject=1; done

    local ns iface net conf
    ns="$(slot_ns "$slot")"; iface="$(slot_iface "$slot")"; net="$(slot_net "$slot")"
    conf="/tmp/hwsim-hostapd-$slot.conf"

    cat > "$conf" <<EOF
interface=$iface
driver=nl80211
ssid=$ssid
hw_mode=g
channel=6
wpa=2
wpa_passphrase=$psk
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
    if [ "$reject" = 1 ]; then
        # An AP that is present and beaconing but refuses to associate us - the
        # be8bdb2 failure (CTRL-EVENT-ASSOC-REJECT), not a credential problem.
        # A MAC deny list is the closest faithful reproduction hostapd offers.
        cat /sys/class/net/wlan0/address > "/tmp/hwsim-deny-$slot"
        printf 'macaddr_acl=0\ndeny_mac_file=/tmp/hwsim-deny-%s\n' "$slot" >> "$conf"
    fi

    ip netns exec "$ns" ip link set "$iface" up
    ip netns exec "$ns" ip addr replace "$net.1/24" dev "$iface"
    ip netns exec "$ns" hostapd -B -P "/tmp/hwsim-hostapd-$slot.pid" "$conf"
    # Without DHCP, association succeeds and IP configuration then times out,
    # which reads like an auth failure and sends you hunting in the wrong place.
    # pgrep is NOT namespace-aware - the process table is shared - so a pgrep here
    # would find another slot's dnsmasq. Track pids per slot instead.
    if ! [ -s "/tmp/hwsim-dnsmasq-$slot.pid" ] || \
       ! kill -0 "$(cat "/tmp/hwsim-dnsmasq-$slot.pid")" 2>/dev/null; then
        ip netns exec "$ns" dnsmasq --interface="$iface" --bind-interfaces \
            --dhcp-range="$net.50,$net.150,12h" --except-interface=lo \
            --pid-file="/tmp/hwsim-dnsmasq-$slot.pid"
    fi
    echo "slot $slot: '$ssid' up$([ "$reject" = 1 ] && echo ' (rejecting us)')"
}

cmd_down() {
    local slot="$1" pidfile
    pidfile="/tmp/hwsim-hostapd-$slot.pid"
    # Kill BY PID, not by name. `pkill -x hostapd` inside a netns kills every
    # hostapd on the box, because the process table is shared across network
    # namespaces - taking slot 1 down would silently take slot 2 with it. And
    # never `pkill -f hostapd`: that pattern also matches the shell running this
    # script, which then kills itself.
    if [ -s "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        kill "$(cat "$pidfile")"
        rm -f "$pidfile"
    fi
    echo "slot $slot: down"
}

cmd_status() {
    local ns iface
    for slot in 1 2 peer; do
        ns="$(slot_ns "$slot")"; iface="$(slot_iface "$slot")"
        # Liveness by interface mode, not by pgrep: the process table is shared
        # across namespaces, so pgrep reports another slot's AP as this one's.
        if [ "$(ip netns exec "$ns" iw dev "$iface" info 2>/dev/null | awk '/type/{print $2}')" = "AP" ]; then
            printf 'slot %-4s up   %s\n' "$slot" \
                "$(ip netns exec "$ns" iw dev "$iface" info 2>/dev/null | awk '/ssid/{$1="";print}')"
        else
            printf 'slot %-4s down\n' "$slot"
        fi
    done
    printf 'device wlan0: %s\n' "$(iwgetid -r 2>/dev/null || echo '(not associated)')"
    ip -4 -br addr show wlan0 2>/dev/null || true
}

case "${1:-status}" in
    setup)  cmd_setup ;;
    up)     shift; cmd_up "$@" ;;
    down)   shift; cmd_down "$@" ;;
    psk)    cmd_down "$2" >/dev/null; sleep 1; cmd_up "$2" "$3" "$4" ;;
    status) cmd_status ;;
    *) echo "usage: ap.sh setup|up|down|psk|status" >&2; exit 2 ;;
esac
