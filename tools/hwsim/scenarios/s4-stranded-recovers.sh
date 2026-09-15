# S4 - the scenario the reconnect feature exists for, and the one that could
# never be observed on hardware: a device stranded with its portal up recovers on
# its own when the vessel AP returns, with nobody touching the portal.
describe "S4  stranded device recovers unattended when the AP returns"
reset_rig
"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null
learn_network "Deep Runner-IOT" testpass123 || { sfail "setup: could not learn the AP"; return 0; }
"$AP" down 1 >/dev/null; sleep 3
device_up ACTIVITY_TIMEOUT=0
wait_for 90 portal_is_up || { sfail "portal never came up"; return 0; }

"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null
wait_for 240 joined_a_network || { sfail "still stranded"; return 0; }

assert_log "Forced periodic rescan"
assert_log "Periodic reconnect: attempting"
assert_log "joined a network - resuming supervision"
# S10, asserted here: the device's own AP must never appear in its own scan, or
# every reconnect tick becomes a silent no-op.
device_log | grep 'Access points:' | grep -q "$PORTAL" \
    && sfail "own portal SSID leaked into the scan (S10)"
