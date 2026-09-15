# S11 - a cable is plugged in while the device is sitting in its portal. Wired is
# connectivity, so the next supervision pass must stop relaunching wifi-connect.
#
# The portal is NOT torn down mid-session - the binary is only re-evaluated once
# it exits - which is a deliberate simplification, so the assertion is about what
# happens after that, not during.
describe "S11 wired arriving is noticed on the next pass"
reset_rig
"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null
learn_network "Deep Runner-IOT" testpass123 || { sfail "setup: could not learn the AP"; return 0; }
"$AP" down 1 >/dev/null; sleep 3
device_up ACTIVITY_TIMEOUT=20 PORTAL_RETRY_GAP=15
wait_for 90 portal_is_up || { sfail "portal never came up"; return 0; }

# The cable goes in: eth0 appears in the view the container has of the world, and
# it really does carry a global IP (it is the VM's own uplink).
mkdir -p /tmp/hwsim/sys-nowired/eth0
touch /tmp/hwsim/sys-nowired/eth0/device

wait_for 120 sh -c 'docker logs wc 2>&1 | grep -q "Wired connection detected"' \
    || sfail "wired arrival was never noticed"
