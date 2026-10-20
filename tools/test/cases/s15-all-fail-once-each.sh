# S15 - every candidate gets one attempt per give-up, no more.
describe "S15 each failing candidate is tried exactly once"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_profile u1 Old Old yes
fixture_nmcli_profile u2 Recent Recent yes
fixture_nmcli_visible Old Recent
fixture_nmcli_up u1 "fail no"
fixture_nmcli_up u2 "fail no"
run_start_sh --passes 1
for u in u1 u2; do
    n="$(grep -c "connection up uuid $u" "$TMP/nmcli.argv")"
    [ "$n" = 1 ] || { _fail "expected one activation of $u, got $n"; _dump_nmcli; }
done
assert_log "Recovery: nothing activated - waiting 1s"
