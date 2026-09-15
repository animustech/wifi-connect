# S1 - the only scenario the captive portal genuinely exists for: a device with
# no credentials, provisioned by an operator through the portal.
#
# Exercises the real HTTP surface, not just the decision to launch: list the
# networks the device can see, POST a choice, and confirm it joins and the binary
# exits so start.sh resumes supervision.
describe "S1  operator provisions the device through the portal"
reset_rig
forget_all_wifi
"$AP" up 1 "Deep Runner-IOT" testpass123 >/dev/null
device_up ACTIVITY_TIMEOUT=0
wait_for 90 portal_is_up || { sfail "portal never came up"; return 0; }

nets="$(curl -s --max-time 10 http://192.168.42.1/networks || true)"
case "$nets" in
    *Deep\ Runner-IOT*) : ;;
    "") sfail "portal served nothing on /networks" ;;
    *)  sfail "vessel AP missing from the portal's network list: $nets" ;;
esac
case "$nets" in *"$PORTAL"*) sfail "portal offered its own AP as a choice" ;; esac

curl -s --max-time 20 -X POST http://192.168.42.1/connect \
     -H 'Content-Type: application/json' \
     -d "{\"ssid\":\"Deep Runner-IOT\",\"identity\":\"\",\"passphrase\":\"testpass123\"}" \
     >/dev/null || true

wait_for 90 joined_a_network || sfail "device never joined after the portal POST"
assert_log "joined a network - resuming supervision"
