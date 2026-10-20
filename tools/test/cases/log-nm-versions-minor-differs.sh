# A different major.minor means the recovery code was never exercised against this
# host, so the log says so.
describe "a minor version difference logs a skew warning"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_versions 1.52.1 1.54.0
run_start_sh --passes 2
assert_log_count 1 "NetworkManager versions: nmcli 1.52.1 host 1.54.0"
assert_log_count 1 "NetworkManager version skew: nmcli 1.52 vs host 1.54 - re-test recovery against this host version"
