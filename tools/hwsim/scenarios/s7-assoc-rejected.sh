# S7 - the saved AP is in range and beaconing but refuses to associate us. This
# is what actually stranded be8bdb2 three times: CTRL-EVENT-ASSOC-REJECT with an
# all-zero BSSID, which is the AP not answering, not a credential failure.
#
# The portal must come up (there is nothing else to do), and critically the
# device must not be left believing it is connected.
describe "S7  AP present but rejecting - portal comes up"
reset_rig
"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null
learn_network "Deep Runner-IOT" testpass123
joined_a_network || { sfail "setup: device never joined"; return 0; }
"$AP" down 1 >/dev/null; sleep 2
"$AP" up 1 "Deep Runner-IOT" testpass123 --reject >/dev/null   # same AP, now refusing us
device_up
wait_for 90 portal_is_up || sfail "portal never came up against a rejecting AP"
assert_log "starting WiFi Connect"
