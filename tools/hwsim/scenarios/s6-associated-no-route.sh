# S6 - the AP answers, WPA completes, DHCP grants a lease, and there is no route
# to anywhere. On a vessel with a spotty satellite uplink this is probably the
# most common failure, and wifi-connect must NOT react to it: the WiFi link is
# genuinely fine and a captive portal would not fix a dead modem. The remedy is
# loci-nmea-relay's SQLite backlog, upstream of here.
#
# A characterisation test. It pins current behaviour so that adding a
# connectivity check later is a deliberate decision, not an accident.
describe "S6  associated with no upstream route - must not raise the portal"
reset_rig
"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null   # netns AP: no route out by construction
learn_network "Deep Runner-IOT" testpass123
joined_a_network || { sfail "setup: device never joined"; return 0; }
ping -I wlan0 -c1 -W2 1.1.1.1 >/dev/null 2>&1 && sfail "setup: the AP namespace unexpectedly routes to the internet"
device_up
sleep 40
portal_is_up && sfail "portal was raised despite a healthy association"
joined_a_network || sfail "device lost its association"
assert_log "WiFi connected to Deep Runner-IOT"
