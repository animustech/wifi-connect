# S13 - two Loci units within range of each other, routinely seen in the field:
# scans show Loci-AP-<other-uuid7> alongside real networks.
#
# The device must ignore a neighbour's portal - it has no credentials for it -
# while still filtering only its OWN SSID out of its scan results.
describe "S13 a neighbouring Loci portal is ignored, not joined"
reset_rig
"$AP" up peer "Loci-AP-f5bffbf" "!f5bffbf#" >/dev/null   # another unit's portal
"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null
learn_network "Deep Runner-IOT" testpass123
"$AP" down 1 >/dev/null; sleep 2
device_up
wait_for 90 portal_is_up || { sfail "portal never came up"; return 0; }
sleep 90                                     # let a forced rescan run
device_log | grep 'Access points:' | grep -q 'Loci-AP-f5bffbf' \
    || sfail "the neighbour's AP never appeared in a scan - test proves nothing"
device_log | grep 'Access points:' | grep -q "$PORTAL" \
    && sfail "our own portal SSID leaked into the scan"
[ "$(wlan_ssid)" = "Loci-AP-f5bffbf" ] && sfail "joined the neighbour's portal"
