# Outside the container, or on an image without NetworkManager's tools, the log and
# any recovery are off, said once, and supervision carries on.
describe "missing nmcli is reported once and does not stop supervision"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
rm -f "$TMP/bin/nmcli"
run_start_sh --passes 2
assert_log_count 1 "NetworkManager tools not available"
assert_log "gave up - leaving the radio to NetworkManager"
refute_log "NetworkManager versions"
