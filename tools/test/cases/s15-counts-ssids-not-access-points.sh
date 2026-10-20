# S15 - one SSID heard from three access points is one network.
describe "S15 visible networks are counted by SSID"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_profile u1 A A yes
fixture_nmcli_visible Mesh Mesh Mesh
run_start_sh --passes 1
assert_log "Recovery: no saved network to activate (1 SSIDs visible)"
