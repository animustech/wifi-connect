# S0 regression - the field-bricking one.
#
# Under network_mode:host the container sees balena0/supervisor0/docker0/br-*,
# all carrying a global IP whether or not a cable exists. A name-based wired
# check calls that "wired" on a device with no Ethernet at all and wifi-connect
# never starts. Only the physical-backing test tells them apart.
describe "S0  bridges carry IPs but there is no real NIC"
fixture_sysfs balena0:virtual supervisor0:virtual docker0:virtual br-abc123:virtual wlan0:wireless lo:virtual
fixture_ip    balena0 supervisor0 docker0 br-abc123
fixture_iwgetid ""
run_start_sh --passes 1
assert_launched
refute_log "Wired connection detected"
