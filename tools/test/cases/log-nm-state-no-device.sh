# nmcli failing for the device must still produce a line: the absence is itself the
# evidence.
describe "NM state line degrades to dashes when wlan0 is unknown"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
run_start_sh --passes 1
assert_log "wlan0=- (reason=-) dev-autoconnect=- active=- profiles=\[\]"
