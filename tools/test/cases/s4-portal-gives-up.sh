# S4 - the portal gave up without joining anything (ACTIVITY_TIMEOUT expired with
# no visitor, or nothing joinable was in range). The radio must go back to
# NetworkManager for PORTAL_RETRY_GAP rather than the portal being re-raised
# immediately - NM reacquires a returning AP in 5-10s, measured on the hwsim rig,
# and it cannot do that while we hold the interface.
describe "S4  unattended portal hands the radio back"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
run_start_sh --passes 1
assert_launched
assert_log "gave up - leaving the radio to NetworkManager"
refute_log "joined a network"
