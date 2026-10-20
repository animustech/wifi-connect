# S15 - NetworkManager has a saved profile blocked from autoconnect and says nothing
# (measured in the field: 21 days). After the portal gives up, an explicit
# activation overrides the block. The name has a ':' to prove the parse survives it.
describe "S15 a blocked saved profile is activated explicitly after give-up"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_profile u1 "Deep Runner:IOT" "Deep Runner:IOT" yes
fixture_nmcli_visible "Deep Runner:IOT"
fixture_nmcli_up u1 ok
run_start_sh --passes 2
assert_nmcli_called "connection up uuid u1 ifname wlan0"
assert_log "Recovery: activating saved profile 'Deep Runner:IOT' -> activated"
assert_log "WiFi connected to Deep Runner:IOT"
assert_log "gave up - leaving the radio to NetworkManager"
