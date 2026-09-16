# S4 - a device stranded with its portal up recovers on its own when the vessel
# AP returns, with nobody touching the portal. This is the scenario that keeps a
# vessel from going dark, and it runs at PRODUCTION ORDERING: the portal's
# activity timeout is shorter than the periodic-reconnect tick, so the portal
# always gives up first and M4 never fires.
#
# That ordering is the whole point. Shipped defaults are ACTIVITY_TIMEOUT=300
# against RECONNECT_INTERVAL_MINUTES=15 (900 s), so recovery comes from handing
# wlan0 back to NetworkManager, not from M4. Measured in the field on f5bffbf,
# 2026-09-16: 13.1 s from give-up to associated. See docs/connectivity-scenarios.md
# S4. M4's legacy path is covered separately in s4b-m4-legacy-reconnect.sh.
describe "S4  stranded device recovers unattended when the AP returns"
reset_rig
"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null
learn_network "Deep Runner-IOT" testpass123 || { sfail "setup: could not learn the AP"; return 0; }
"$AP" down 1 >/dev/null; sleep 3

# ACTIVITY_TIMEOUT (20 s) < the M4 tick (RECONNECT_INTERVAL_MINUTES=1, i.e. 60 s),
# mirroring the shipped 300 s < 900 s. Raise the timeout above the tick and this
# scenario stops testing the production path.
device_up ACTIVITY_TIMEOUT=20 PORTAL_RETRY_GAP=30
wait_for 90 portal_is_up || { sfail "portal never came up"; return 0; }

# The AP returns while the portal still holds the radio. Nothing can happen until
# the portal gives the interface back - that wait is the cost of the portal, and
# it is bounded by ACTIVITY_TIMEOUT.
"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null
wait_for 150 joined_a_network || { sfail "still stranded"; return 0; }

assert_log "Timeout reached. Exiting..."
assert_log "gave up - leaving the radio to NetworkManager"

# The regression guard. If either of these appears, ACTIVITY_TIMEOUT has been
# raised above the M4 tick and this scenario is silently testing the legacy path
# instead of the shipped one.
refute_log "Periodic reconnect: attempting"
refute_log "Forced periodic rescan"

# S10, asserted here: the device's own AP must never appear in its own scan.
device_log | grep 'Access points:' | grep -q "$PORTAL" \
    && sfail "own portal SSID leaked into the scan (S10)"
