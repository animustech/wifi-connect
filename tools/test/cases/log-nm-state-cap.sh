# The file lives on /data, which has no one to clean it. It is bounded at 1 MiB and
# trims whole lines from the front so what remains still parses.
describe "NM state file is trimmed to its newest 512 KiB and keeps whole lines"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid ""
yes 'old line' | head -n 122223 > "$TMP/nm-state.log"
run_start_sh --passes 1
size="$(wc -c < "$TMP/nm-state.log" | tr -d ' ')"
# Newest 524288 bytes kept, plus the few lines one pass appends (well under 4 KiB),
# and the partial line at the cut is dropped so it is at least a little under 524288.
{ [ "$size" -le $((524288 + 4096)) ] && [ "$size" -ge $((524288 - 9)) ]; } \
    || { _fail "expected about 524288 bytes in the state file, got $size"; _dump; }
[ "$(head -n 1 "$TMP/nm-state.log")" = "old line" ] \
    || { _fail "expected the first line to be a whole old line"; _dump; }
tail -n 5 "$TMP/nm-state.log" | grep -q "NM state:" \
    || { _fail "expected the new state lines at the end"; _dump; }
