# S1 - an operator used the portal and the device joined. No gap: supervision
# resumes at the normal interval.
describe "S1  portal joined a network, no retry gap"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_wifi_connect_joins "Deep Runner-IOT"
run_start_sh --passes 2
assert_launched
assert_launch_count 1
assert_log "joined a network - resuming supervision"
refute_log "leaving the radio to NetworkManager"
