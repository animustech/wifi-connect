# With no ACTIVITY_TIMEOUT set, the portal waits 10 minutes for an installer to
# open it before handing the radio back.
describe "ACTIVITY_TIMEOUT defaults to 600 s"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
run_start_sh --passes 1 --default-activity-timeout
assert_launched
assert_activity_timeout 600
