# S4 - network absent at boot, nobody attends. Portal must come up.
describe "S4  no network at boot"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
run_start_sh --passes 1
assert_launched
assert_portal_ssid "Loci-AP-e3042ef"
assert_log "No connection after"
