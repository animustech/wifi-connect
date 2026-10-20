# S15 - if the link comes up while the candidates are being gathered, a fresh
# link is left alone.
describe "S15 no activation once the link is already up"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
fixture_nmcli_profile u1 Vessel Vessel yes
fixture_nmcli_visible Vessel
fixture_nmcli_up u1 ok
# Reads as down for the start.sh checks, then up from the first rescan onwards.
cat > "$TMP/bin/iwgetid" <<'STUB'
#!/usr/bin/env bash
T="$WCSTART_TMP"
grep -q -- "--rescan yes" "$T/nmcli.argv" 2>/dev/null && { echo Other; exit 0; }
exit 1
STUB
run_start_sh --passes 1
refute_nmcli_called "connection up"
refute_log "Recovery: nothing activated"
