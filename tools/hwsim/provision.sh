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
lsmod | grep -q mac80211_hwsim || modprobe mac80211_hwsim radios=2
ip netns list | grep -qx ap || ip netns add ap
# phy1 becomes the AP; moving it into the netns also hides it from NM.
if [ -d /sys/class/ieee80211/phy1 ]; then
    iw phy phy1 set netns name ap
fi

echo "==> done"
ip netns exec ap ip -br link | grep wlan || true
nmcli -t -f DEVICE,TYPE,STATE device status
