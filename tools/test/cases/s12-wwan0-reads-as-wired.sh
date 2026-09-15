# S12 - documents CURRENT behaviour, not a decision.
#
# wwan0 (SIM7600E-H over USB) has a `device` symlink, no phy80211, and does not
# match wlan*/wl*, so the wired check classifies an LTE modem as a wired
# connection and suppresses wifi-connect. Probably what we want - the device has
# connectivity - but it is accidental and has never been verified alongside
# loci-modem. If that behaviour is ever changed deliberately, this test should
# be updated, not deleted.
describe "S12 an LTE modem currently reads as a wired connection"
fixture_sysfs wwan0:physical wlan0:wireless lo:virtual
fixture_ip    wwan0
fixture_iwgetid ""
run_start_sh --passes 1
refute_launched
assert_log "Wired connection detected"
