# A disconnected pass records what NetworkManager thinks, to stdout and to the
# capped file on /data. The journal rotated away the only evidence of why a saved
# profile stayed blocked for 21 days; this line is what would have survived.
describe "NM state line is logged on a down pass, to stdout and the file"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_device "GENERAL.STATE=30 (disconnected)" \
    "GENERAL.REASON=39 (Device disconnected by user or client)" \
    "GENERAL.AUTOCONNECT=no" "GENERAL.CONNECTION="
fixture_nmcli_profile u1 "Prospect WiFi" "Prospect WiFi" yes
fixture_nmcli_visible "Prospect WiFi"
run_start_sh --passes 1
line="NM state: wlan0=disconnected (reason=39 (Device disconnected by user or client)) dev-autoconnect=no active=- profiles=[Prospect WiFi auto=yes visible=yes]"
# Fixed-string match: the line holds brackets, which assert_log would read as regex.
grep -qF -- "$line" "$TMP/out.log" \
    || { _fail "expected log to contain: $line"; _dump; }
# -F for the line itself (it holds brackets); the timestamp is checked separately.
grep -qF -- " $line" "$TMP/nm-state.log" 2>/dev/null \
    && grep -q -- "^20..-..-..T..:..:..Z NM state:" "$TMP/nm-state.log" \
    || { _fail "expected timestamped state line in the state file"; _dump; }
