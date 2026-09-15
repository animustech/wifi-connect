# S5 - a portal profile survived an ungraceful exit, NetworkManager auto-
# activated it, and iwgetid now reports OUR OWN hotspot. Treating that as a
# healthy connection skips wifi-connect entirely: no portal, no reconnect,
# dark until someone physically attends the device.
describe "S5  our own stale portal AP is not a connection"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid "Loci-AP-e3042ef"
run_start_sh --passes 1
assert_launched
assert_log "Stale portal AP"
refute_log "WiFi connected to Loci-AP"
