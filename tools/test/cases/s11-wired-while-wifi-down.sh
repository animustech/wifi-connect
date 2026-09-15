# S11 - WiFi is gone but a cable is in. Wired is connectivity; no portal.
describe "S11 wired present while WiFi is down"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip    eth0
fixture_iwgetid ""
run_start_sh --passes 2
refute_launched
