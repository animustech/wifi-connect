# S15 - a damaged history file costs the ordering, nothing else: no jq noise, and
# the candidates keep the order NM lists them in.
describe "S15 a corrupt reconnect history leaves the order alone and the log clean"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_profile u1 First First yes
fixture_nmcli_profile u2 Second Second yes
fixture_nmcli_visible First Second
printf 'not json' > "$TMP/reconnect-history.json"
fixture_nmcli_up u1 ok
fixture_nmcli_up u2 ok
run_start_sh --passes 1
assert_nmcli_called "connection up uuid u1"
refute_nmcli_called "connection up uuid u2"
refute_log "parse error"
