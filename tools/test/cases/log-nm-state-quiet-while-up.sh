# While the link stays healthy nothing is logged beyond the transition, so the
# capped file is not spent on a device that is fine.
describe "NM state is logged once on connect, not on every healthy pass"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid "Vessel"
run_start_sh --passes 3
assert_log_count 1 "NM state:"
[ "$(grep -c "NM state:" "$TMP/nm-state.log")" = 1 ] \
    || { _fail "expected exactly 1 NM state line in the state file"; _dump; }
