# S15 - the grace period exists so NM gets the first go: if it reconnects by itself
# nothing is activated explicitly. The link returns 2s after the portal gave up,
# well inside RECOVERY_GRACE, whatever time the run took to reach the portal.
describe "S15 no explicit activation when NetworkManager reconnects by itself"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid "Vessel" --drop-after 0 --return-after-portal 2
fixture_nmcli_profile u1 Vessel Vessel yes
fixture_nmcli_visible Vessel
fixture_nmcli_up u1 ok
run_start_sh RECOVERY_GRACE=5
assert_log "Recovery: NetworkManager reconnected by itself"
refute_nmcli_called "connection up"
