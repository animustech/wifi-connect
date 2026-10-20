# S15 - a busy radio refuses a fresh scan; the cached list is still good enough.
describe "S15 a refused rescan falls back to the cached scan list"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_profile u1 Vessel Vessel yes
fixture_nmcli_visible Vessel
fixture_nmcli_rescan_fails
fixture_nmcli_up u1 ok
run_start_sh --passes 1
assert_nmcli_called "connection up uuid u1"
