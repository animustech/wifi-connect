# A profile's name is a label; what it joins is its SSID, and that is what has to
# be in the scan for the profile to be reachable.
describe "NM state visibility follows the profile SSID, not its name"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_profile u1 "Ship wifi" "Prospect_WiFi" yes
fixture_nmcli_profile u2 "Prospect_WiFi" "Elsewhere" yes
fixture_nmcli_visible "Prospect_WiFi"
run_start_sh --passes 1
assert_log "profiles=\[Ship wifi auto=yes visible=yes, Prospect_WiFi auto=yes visible=no\]"
