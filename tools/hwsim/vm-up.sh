#!/usr/bin/env bash
# Creates the Lima VM the hwsim rig runs in, then provisions it.
# Idempotent: safe to re-run.
#
#   tools/hwsim/vm-up.sh
#
# Debian 13 (trixie) deliberately - it is what the container image is built on,
# so NetworkManager, wpa_supplicant and D-Bus versions match what ships.
set -euo pipefail

VM="${HWSIM_VM:-wifitest}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v limactl >/dev/null || { echo "limactl not found: brew install lima" >&2; exit 1; }

if ! limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$VM"; then
    echo "==> creating VM '$VM'"
    limactl start --name="$VM" --cpus=4 --memory=4 --tty=false template://debian-13
else
    limactl start "$VM" 2>/dev/null || true
fi

echo "==> provisioning"
limactl shell "$VM" sudo bash -s < "$HERE/provision.sh"

echo
echo "VM '$VM' ready.  limactl shell $VM"
