# S4b - M4, the binary's own periodic reconnect, recovering a stranded device.
#
# THIS PATH IS UNREACHABLE IN PRODUCTION. M4 only ever ticks when
#
#     ACTIVITY_TIMEOUT > RECONNECT_INTERVAL_MINUTES * 60      (or ACTIVITY_TIMEOUT = 0)
#
# because spawn_activity_timeout is a one-shot sleep and spawn_periodic_reconnect
# sleeps before its first tick. Shipped defaults are 300 s against 900 s, so the
# portal always exits first. The ACTIVITY_TIMEOUT=0 override below is what makes
# this scenario reachable at all, and is therefore the proof of that claim - if
# this file ever passes without the override, the ordering has changed.
#
# Kept because M4 is still live code and the knobs are environment variables: a
# fleet can re-enable it by setting RECONNECT_INTERVAL_MINUTES below the timeout.
# The production path is s4-stranded-recovers.sh; see docs/connectivity-scenarios.md S4.
describe "S4b M4 recovers a stranded device (legacy path, needs ACTIVITY_TIMEOUT=0)"
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
