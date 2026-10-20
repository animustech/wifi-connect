# S15 - nmcli warns on every call when its version differs from the daemon's. The
# logged failure reason is NetworkManager's error, never that warning.
describe "S15 a version-skew warning does not displace the failure reason"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_version_warning
fixture_nmcli_profile u1 Vessel Vessel yes
fixture_nmcli_visible Vessel
fixture_nmcli_up u1 "fail no suitable device"
run_start_sh --passes 1
assert_log "Recovery: activating saved profile 'Vessel' -> failed: Connection activation failed: no suitable device"
refute_log "failed: Warning"
refute_log "versions don't match"
assert_log "NM state: wlan0="
