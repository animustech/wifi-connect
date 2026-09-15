# S0 - boots wired: wifi-connect must never be launched.
describe "S0  wired connection present"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip    eth0
fixture_iwgetid ""
run_start_sh --passes 2
refute_launched
assert_log "Wired connection detected"
