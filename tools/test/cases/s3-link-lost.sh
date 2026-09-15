# S3 - joins at boot, loses the link later. The gap that left e3042ef with no
# portal process and no reconnect timer for 37 minutes.
#
# The link must be seen healthy for at least one pass before it drops, so the
# transition itself is what is under test - not a device that was never up.
describe "S3  link lost after a healthy start"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid "Deep Runner-IOT" --drop-after 3
run_start_sh --passes 6 SUPERVISE_INTERVAL=1 WIFI_CHECK_TIMEOUT=2 WIFI_CHECK_INTERVAL=1
assert_log "WiFi connected to Deep Runner-IOT"
assert_log "Connection lost"
assert_launched
