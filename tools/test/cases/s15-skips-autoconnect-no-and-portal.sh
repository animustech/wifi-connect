# S15 - a profile the owner turned autoconnect off for, and our own portal profile,
# are never activated.
describe "S15 autoconnect=no and portal profiles are not candidates"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_profile u1 Vessel Vessel no
fixture_nmcli_profile u2 Loci-AP-e3042ef Loci-AP-e3042ef yes ap
fixture_nmcli_visible Vessel Loci-AP-e3042ef
run_start_sh --passes 1
refute_nmcli_called "connection up"
assert_log "Recovery: no saved network to activate (2 SSIDs visible)"
