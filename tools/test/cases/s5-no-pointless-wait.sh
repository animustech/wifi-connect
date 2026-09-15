# S5 - a radio serving our own AP is not about to associate to anything, so the
# check window must be skipped rather than burned.
describe "S5  stale portal AP skips the wait"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid "Loci-AP-e3042ef"
started=$(date +%s)
run_start_sh --passes 1 WIFI_CHECK_TIMEOUT=20 WIFI_CHECK_INTERVAL=1
elapsed=$(( $(date +%s) - started ))
if [ "$elapsed" -ge 15 ]; then
    _fail "waited ${elapsed}s before relaunching; should not wait at all"
fi
assert_launched
