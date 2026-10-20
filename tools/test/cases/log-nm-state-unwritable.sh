# A broken /data must cost the log, never the supervision.
describe "NM state still goes to stdout when the file cannot be written"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
run_start_sh --passes 1 NM_STATE_LOG="$TMP/missing-dir/x.log"
assert_log "NM state:"
assert_launched
assert_log "gave up - leaving the radio to NetworkManager"
