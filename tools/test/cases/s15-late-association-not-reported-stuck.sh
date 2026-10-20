# S15 - an activation that succeeds but associates a moment later is not followed by
# the "nothing activated" line.
describe "S15 a slow association after activation is waited for"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_profile u1 Vessel Vessel yes
fixture_nmcli_visible Vessel
fixture_nmcli_up u1 "ok-late 2"
run_start_sh --passes 2
assert_log "Recovery: activating saved profile 'Vessel' -> activated"
refute_log "Recovery: nothing activated"
