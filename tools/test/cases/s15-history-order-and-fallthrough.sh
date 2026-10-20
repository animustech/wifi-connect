# S15 - the most recently connected network is tried first, and a failure falls
# through to the next candidate.
describe "S15 candidates are tried most recent first and fall through on failure"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_profile u1 Old Old yes
fixture_nmcli_profile u2 Recent Recent yes
fixture_nmcli_visible Old Recent
printf '{"last_connected":{"Old":100,"Recent":200}}' > "$TMP/reconnect-history.json"
fixture_nmcli_up u2 "fail Secrets were required, but not provided"
fixture_nmcli_up u1 ok
run_start_sh --passes 1
u2_line="$(grep -n 'connection up uuid u2' "$TMP/nmcli.argv" | head -n 1 | cut -d: -f1)"
u1_line="$(grep -n 'connection up uuid u1' "$TMP/nmcli.argv" | head -n 1 | cut -d: -f1)"
if [ -z "$u2_line" ] || [ -z "$u1_line" ] || [ "$u2_line" -ge "$u1_line" ]; then
    _fail "expected u2 to be activated before u1"; _dump_nmcli
fi
assert_log "'Recent' -> failed: Connection activation failed: Secrets were required, but not provided"
assert_log "'Old' -> activated"
