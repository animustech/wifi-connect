# S9 - two saved networks in range. M4 orders candidates most-recently-successful
# first, from its own cache at /data/reconnect-history.json.
#
# MEASURED LIMIT, found while writing this test: the cache only records
# connections wifi-connect made ITSELF - through the portal, or through a
# reconnect tick. A connection NetworkManager makes on its own never appears,
# and NM autoconnect is the normal case on a healthy device. So on a unit that
# has simply been online for months the cache is empty and the ordering is
# arbitrary. It still tries every candidate, so this costs time, not recovery.
#
# The test therefore asserts the property that genuinely holds: once M4 has
# connected to a network, that network is recorded and tried first next time.
describe "S9  a network M4 connected to is recorded and tried first"
reset_rig
docker volume rm wc-data >/dev/null 2>&1      # start from an empty history

"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null
"$AP" up 2 "Gekko-Guest"    guestpass456 >/dev/null
learn_network "Deep Runner-IOT" testpass123 || { sfail "setup: could not learn AP1"; return 0; }
learn_network "Gekko-Guest"    guestpass456 || { sfail "setup: could not learn AP2"; return 0; }
"$AP" down 1 >/dev/null; "$AP" down 2 >/dev/null; sleep 3

# Round one: only Gekko-Guest returns, so M4 connects to it and records it.
device_up
wait_for 90 portal_is_up || { sfail "portal never came up (round 1)"; return 0; }
"$AP" up 2 "Gekko-Guest" guestpass456 >/dev/null
wait_for 180 joined_a_network || { sfail "M4 never reconnected (round 1)"; return 0; }
hist="$(cat /var/lib/docker/volumes/wc-data/_data/reconnect-history.json 2>/dev/null)"
case "$hist" in
    *Gekko-Guest*) : ;;
    *) sfail "history did not record the network M4 connected to: $hist" ;;
esac

# Round two: both are away, then both return together. Gekko-Guest is the most
# recently successful, so it must be attempted first.
device_down
"$AP" down 2 >/dev/null; sleep 3
device_up
wait_for 90 portal_is_up || { sfail "portal never came up (round 2)"; return 0; }
"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null
"$AP" up 2 "Gekko-Guest"    guestpass456 >/dev/null
wait_for 180 joined_a_network || { sfail "never reconnected (round 2)"; return 0; }
first="$(device_log | grep "Reconnecting to saved network" | tail -1)"
case "$first" in
    *Gekko-Guest*) : ;;
    "")            sfail "M4 never logged a reconnect attempt in round 2" ;;
    *)             sfail "tried the wrong network first: $first" ;;
esac
