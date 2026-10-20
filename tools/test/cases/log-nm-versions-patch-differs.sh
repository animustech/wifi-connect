# A patch-level difference between nmcli and the host's NetworkManager is routine
# (the image and balenaOS ship different builds), so it logs the versions and no skew.
describe "versions are logged once, a patch difference is not skew"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_versions 1.52.1 1.52.0
run_start_sh --passes 2
assert_log_count 1 "NetworkManager versions: nmcli 1.52.1 host 1.52.0"
refute_log "version skew"
