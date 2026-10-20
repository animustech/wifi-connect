# An explicitly set ACTIVITY_TIMEOUT wins over the shipped default.
describe "an explicit ACTIVITY_TIMEOUT overrides the default"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
run_start_sh --passes 1 --default-activity-timeout ACTIVITY_TIMEOUT=45
assert_launched
assert_activity_timeout 45
