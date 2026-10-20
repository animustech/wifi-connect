# S15 - NetworkManager refuses to autoconnect a saved network, and the supervisor
# must notice and activate it explicitly once the portal gives up. In the field a
# saved profile stayed blocked for 21 days with its AP in range; handing the radio
# back to NetworkManager recovered nothing because NM itself would not try.
#
# The block is induced BEFORE the container starts, so the whole portal cycle runs
# against a NetworkManager that already refuses to autoconnect.
describe "S15 blocked autoconnect: saved network activated explicitly after give-up"
reset_rig
"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null
learn_network "Deep Runner-IOT" testpass123 || { sfail "setup: could not learn the AP"; return 0; }

nmcli device disconnect wlan0 >/dev/null 2>&1
sleep 20
not_joined || { sfail "setup: block did not hold"; return 0; }

device_up ACTIVITY_TIMEOUT=20 PORTAL_RETRY_GAP=600
wait_for 90 portal_is_up || { sfail "portal never came up"; return 0; }

i=0
while [ "$i" -lt 60 ]; do
    device_log | grep -q "Timeout reached. Exiting..." && break
    sleep 2; i=$((i + 2))
done

device_log | grep -q "gave up - leaving the radio to NetworkManager" || { sfail "portal never gave up"; return 0; }

wait_for 90 joined_a_network || { sfail "still stranded 90s after give-up"; return 0; }

assert_log "Recovery: activating saved profile 'Deep Runner-IOT' -> activated"
