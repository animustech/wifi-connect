# S14 - repeated resets. The trigger (poor vessel power, a flapping VSAT link) is
# out of scope; what matters is that a reset costs minutes, not days, and that
# nothing accumulates across them.
#
# A container restart, not a true power cut - kernel and NetworkManager state
# survive - so this proves the service-level behaviour only.
describe "S14 repeated restarts leave no residue"
reset_rig
"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null
learn_network "Deep Runner-IOT" testpass123
"$AP" down 1 >/dev/null; sleep 2
for round in 1 2 3; do
    device_up
    wait_for 60 portal_is_up || { sfail "round $round: portal never came up"; return 0; }
    device_down
    sleep 3
done
# Each run must clean up after itself: exactly one portal profile, never a pile.
n="$(nmcli -t -f NAME connection show 2>/dev/null | grep -c "^$PORTAL" || true)"
[ "$n" -le 1 ] || sfail "stale portal profiles accumulated across restarts: $n"
"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null
device_up
wait_for 180 joined_a_network || sfail "did not recover after three restarts"
