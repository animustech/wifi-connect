# S2 - boots, joins a saved network, stays up. No portal, no delay.
describe "S2  already associated at boot"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid "Deep Runner-IOT"
run_start_sh --passes 3
refute_launched
assert_log "WiFi connected to Deep Runner-IOT"
