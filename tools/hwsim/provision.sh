#!/usr/bin/env bash
# Runs INSIDE the VM as root. Idempotent.
#
# Three things here are not obvious and cost real time to discover:
#
#  1. Debian's cloud kernel has no mac80211_hwsim. The generic kernel does, but
#     installing it is not enough - GRUB keeps booting the cloud one, so the
#     cloud kernel has to be purged outright and the VM rebooted.
#  2. NetworkManager must be told to leave the VM's uplink alone BEFORE it is
#     installed, or it takes over eth0 and the Lima shell dies with it.
#  3. The AP radio goes in its own netns, which also keeps NetworkManager away
#     from it - otherwise NM and hostapd fight over the same phy.
set -euo pipefail

need_reboot=0

if dpkg -l | grep -q '^ii  linux-image-cloud-arm64'; then
    echo "==> replacing the cloud kernel (no mac80211_hwsim in it)"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq linux-image-arm64
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
        linux-image-cloud-arm64 'linux-image-*-cloud-arm64'
    update-grub
    need_reboot=1
fi

if [ "$need_reboot" = 1 ]; then
    echo
    echo "REBOOT REQUIRED. Run:  limactl stop ${HWSIM_VM:-wifitest} && tools/hwsim/vm-up.sh"
    exit 10
fi

modinfo mac80211_hwsim >/dev/null 2>&1 || {
    echo "mac80211_hwsim still unavailable on $(uname -r)" >&2; exit 1; }

echo "==> NetworkManager guard (must exist before NM is installed)"
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/00-lima-unmanaged.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:eth0;interface-name:lima0;interface-name:docker0;type:ethernet
EOF

echo "==> packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    network-manager hostapd wpasupplicant dnsmasq-base iw wireless-tools docker.io

echo "==> virtual radios"
# Four radios, not two: wlan0 is the device, and ap.sh needs one each for slots
# 1 (vessel AP), 2 (second AP, S9 ordering) and peer (another Loci unit, S13).
# Provisioning two was enough for the original single-AP rig and silently starves
# every scenario added since - the failure surfaces as `Cannot find device wlan1`.
#
# Count the radios rather than just checking the module is loaded: a module left
# over from an earlier layout is loaded but wrong, and `lsmod | grep -q` calls that
# good. Reloading renumbers the phys, which is why nothing here may hardcode one.
HWSIM_RADIOS=4
if [ "$(ls -d /sys/class/ieee80211/phy* 2>/dev/null | wc -l)" -ne "$HWSIM_RADIOS" ]; then
    modprobe -r mac80211_hwsim 2>/dev/null || true
    modprobe mac80211_hwsim "radios=$HWSIM_RADIOS"
fi
# Radio placement and namespaces belong to `ap.sh setup` (ap1/ap2/peer). The old
# single `ap` netns here used to move phy1 out of the host namespace, which took
# the radio ap.sh was about to look for; drop it if an earlier run left it behind.
ip netns list 2>/dev/null | grep -qx ap && ip netns delete ap

echo "==> done"
ip netns exec ap ip -br link | grep wlan || true
nmcli -t -f DEVICE,TYPE,STATE device status
