# S15 - a saved network that is not in the scan is not worth activating.
describe "S15 nothing is activated when no saved network is in range"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_profile u1 A A yes
fixture_nmcli_visible Other1 Other2
run_start_sh --passes 1
assert_log "Recovery: no saved network to activate (2 SSIDs visible)"
assert_log "Recovery: nothing activated - waiting 1s"
