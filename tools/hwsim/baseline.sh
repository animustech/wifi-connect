#!/usr/bin/env bash
# Measures how fast NetworkManager recovers ON ITS OWN when the AP returns,
# with wifi-connect not running at all. Runs INSIDE the VM as root.
#
# This is the number every design decision here has to respect: if the
# supervision loop holds the radio, recovery is whatever M4's tick is (15 min)
# instead of this.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWN_FOR="${1:-20}"

"$HERE/ap.sh" down
echo "AP down at $(date +%T), leaving it down ${DOWN_FOR}s"
sleep "$DOWN_FOR"
echo -n "  still down, associated? "; iwgetid -r || echo "(no)"

"$HERE/ap.sh" up >/dev/null
echo "AP back at $(date +%T)"
for i in $(seq 1 24); do
    sleep 5
    ssid="$(iwgetid -r 2>/dev/null || true)"
    if [ -n "$ssid" ]; then
        echo "  RECOVERED after ~$((i * 5))s -> $ssid"
        ip -4 -br addr show wlan0
        exit 0
    fi
done
echo "  NOT recovered within 120s"
exit 1
