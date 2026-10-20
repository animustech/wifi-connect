# A host version that cannot be read prints '-' and cannot be compared, so no skew line.
describe "an unreadable host version logs a dash and no skew"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_versions 1.52.1
run_start_sh --passes 2
assert_log_count 1 "NetworkManager versions: nmcli 1.52.1 host -"
refute_log "version skew"
