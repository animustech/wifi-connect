# S8 - the vessel changed its WiFi password. The device holds a profile that can
# never succeed, M4 will retry it forever, and the portal is the only remedy -
# with nobody aboard to use it.
#
# Not a bug to fix, a limit to prove. The test asserts the device ends up in the
# portal and stays there, so the claim "not solvable from here" is measured
# rather than assumed.
describe "S8  stale credentials - device cannot recover unaided"
reset_rig
"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null
learn_network "Deep Runner-IOT" testpass123
joined_a_network || { sfail "setup: device never joined"; return 0; }
"$AP" psk 1 "Deep Runner-IOT" changedpass999 >/dev/null 2>&1   # vessel rotates the key
device_up
wait_for 120 portal_is_up || sfail "portal never came up after the key changed"
sleep 90                                    # two reconnect ticks
joined_a_network && sfail "unexpectedly recovered - the key really did change?"
assert_log "Periodic reconnect: attempting"
