#!/usr/bin/env bash
# Test harness for scripts/start.sh.
#
# start.sh reaches the outside world through exactly four things, and all four are
# replaceable from here:
#
#   iwgetid          stubbed on PATH
#   ip               stubbed on PATH
#   /sys/class/net   fixture tree, injected via SYSFS_ROOT
#   ./wifi-connect   stubbed via WIFI_CONNECT_BIN
#
# So every decision start.sh makes is testable without a radio, a container or a
# device. That matters because every defect found on 2026-09-15 was a decision
# bug, not a radio bug. See docs/testing-connectivity.md.
#
# Deliberately bash 3.2 compatible: this runs on the macOS the work is done on,
# with no container and no dependencies.

set -u

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../../.." && pwd)"
START_SH="$REPO_ROOT/scripts/start.sh"

CASE_NAME=""
TMP=""
FAILURES=0

# ---------------------------------------------------------------- lifecycle

harness_init() {
    CASE_NAME="${1:-unnamed}"
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/wcstart.XXXXXX")"
    mkdir -p "$TMP/bin" "$TMP/sys"
    date +%s > "$TMP/started_at"
    : > "$TMP/wifi_connect.argv"
    : > "$TMP/iwgetid.ssid"
    : > "$TMP/ip.ifaces"
    FAILURES=0
    _write_stubs
}

harness_cleanup() {
    [ -n "$TMP" ] && rm -rf "$TMP"
}

# --------------------------------------------------------------- fixtures

# fixture_sysfs <iface:kind> ...
#   kind: physical  - has a `device` symlink (real NIC: eth0, wwan0)
#         wireless  - has `device` AND `phy80211` (wlan0)
#         virtual   - has neither (balena0, docker0, br-*, lo, resin-vpn)
#
# The distinction is the whole point of the wired check: under network_mode:host
# the container sees bridges carrying global IPs whether or not anything is
# plugged in, so filtering by NAME reports "wired" on a device with no Ethernet
# at all and wifi-connect then never starts.
fixture_sysfs() {
    local spec iface kind
    rm -rf "$TMP/sys"; mkdir -p "$TMP/sys"
    for spec in "$@"; do
        iface="${spec%%:*}"
        kind="${spec#*:}"
        mkdir -p "$TMP/sys/$iface"
        case "$kind" in
            physical) : > "$TMP/sys/$iface/device" ;;
            wireless) : > "$TMP/sys/$iface/device"; : > "$TMP/sys/$iface/phy80211" ;;
            virtual)  : ;;
            *) echo "fixture_sysfs: unknown kind '$kind'" >&2; exit 2 ;;
        esac
    done
}

# fixture_ip <iface> ...   interfaces that currently carry a global IPv4 address
fixture_ip() {
    printf '%s\n' "$@" > "$TMP/ip.ifaces"
}

# fixture_iwgetid <ssid|""> [--drop-after N] [--return-after N]
#   Empty ssid means "not associated".
#   --drop-after N    association is lost N seconds into the run
#   --return-after N  and comes back N seconds into the run
fixture_iwgetid() {
    printf '%s' "${1:-}" > "$TMP/iwgetid.ssid"
    shift || true
    : > "$TMP/iwgetid.drop_after"
    : > "$TMP/iwgetid.return_after"
    while [ $# -gt 0 ]; do
        case "$1" in
            --drop-after)   printf '%s' "$2" > "$TMP/iwgetid.drop_after"; shift 2 ;;
            --return-after) printf '%s' "$2" > "$TMP/iwgetid.return_after"; shift 2 ;;
            *) echo "fixture_iwgetid: unknown option '$1'" >&2; exit 2 ;;
        esac
    done
}

# fixture_wifi_connect_joins <ssid>
#   The stub binary "succeeds": it joins <ssid> and exits, as the real one does.
fixture_wifi_connect_joins() {
    printf '%s' "$1" > "$TMP/wifi_connect.joins"
}

_write_stubs() {
    cat > "$TMP/bin/iwgetid" <<'STUB'
#!/usr/bin/env bash
T="$WCSTART_TMP"
[ -f "$T/iwgetid.override" ] && { cat "$T/iwgetid.override"; exit 0; }
ssid="$(cat "$T/iwgetid.ssid" 2>/dev/null)"
[ -n "$ssid" ] || exit 1
elapsed=$(( $(date +%s) - $(cat "$T/started_at") ))
drop="$(cat "$T/iwgetid.drop_after" 2>/dev/null)"
back="$(cat "$T/iwgetid.return_after" 2>/dev/null)"
if [ -n "$drop" ] && [ "$elapsed" -ge "$drop" ]; then
    if [ -n "$back" ] && [ "$elapsed" -ge "$back" ]; then echo "$ssid"; exit 0; fi
    exit 1
fi
echo "$ssid"
STUB

    # Only the `ip -4 -o addr show dev <iface> scope global up` form is used.
    cat > "$TMP/bin/ip" <<'STUB'
#!/usr/bin/env bash
T="$WCSTART_TMP"
dev=""
while [ $# -gt 0 ]; do
    case "$1" in dev) dev="$2"; shift 2 ;; *) shift ;; esac
done
grep -qx "$dev" "$T/ip.ifaces" 2>/dev/null || exit 0   # no output = no address
echo "1: $dev    inet 192.0.2.10/24 scope global $dev"
STUB

    cat > "$TMP/bin/wifi-connect" <<'STUB'
#!/usr/bin/env bash
T="$WCSTART_TMP"
printf '%s\n' "$*" >> "$T/wifi_connect.argv"
if [ -f "$T/wifi_connect.joins" ]; then
    cp "$T/wifi_connect.joins" "$T/iwgetid.override"
fi
exit 0
STUB

    chmod +x "$TMP/bin/iwgetid" "$TMP/bin/ip" "$TMP/bin/wifi-connect"
}

# --------------------------------------------------------------- execution

# run_start_sh [--passes N] [VAR=VALUE ...]
run_start_sh() {
    local passes=1
    local -a extra_env
    extra_env=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --passes) passes="$2"; shift 2 ;;
            *) extra_env[${#extra_env[@]}]="$1"; shift ;;
        esac
    done

    date +%s > "$TMP/started_at"

    env -i \
        PATH="$TMP/bin:/usr/bin:/bin" \
        HOME="$HOME" \
        WCSTART_TMP="$TMP" \
        SYSFS_ROOT="$TMP/sys" \
        WIFI_CONNECT_BIN="$TMP/bin/wifi-connect" \
        MAX_PASSES="$passes" \
        BALENA_DEVICE_UUID="${BALENA_DEVICE_UUID:-e3042ef0668f92664ba56878036ff528}" \
        WIRED_CHECK_TIMEOUT="${WIRED_CHECK_TIMEOUT:-0}" \
        WIFI_CHECK_TIMEOUT="${WIFI_CHECK_TIMEOUT:-2}" \
        WIFI_CHECK_INTERVAL="${WIFI_CHECK_INTERVAL:-1}" \
        SUPERVISE_INTERVAL="${SUPERVISE_INTERVAL:-1}" \
        PORTAL_RETRY_GAP="${PORTAL_RETRY_GAP:-1}" \
        ACTIVITY_TIMEOUT="${ACTIVITY_TIMEOUT:-0}" \
        "${extra_env[@]}" \
        bash "$START_SH" > "$TMP/out.log" 2>&1
}

# --------------------------------------------------------------- assertions

_fail() {
    printf '    FAIL: %s\n' "$1"
    FAILURES=$((FAILURES + 1))
}

assert_launched() {
    if [ ! -s "$TMP/wifi_connect.argv" ]; then
        _fail "expected wifi-connect to be launched, it was not"
        _dump
    fi
}

refute_launched() {
    if [ -s "$TMP/wifi_connect.argv" ]; then
        _fail "expected wifi-connect NOT to be launched, it was $(wc -l < "$TMP/wifi_connect.argv" | tr -d ' ')x"
        _dump
    fi
}

assert_launch_count() {
    local want="$1" got
    got="$(grep -c . "$TMP/wifi_connect.argv" 2>/dev/null || echo 0)"
    [ "$got" = "$want" ] || { _fail "expected $want launch(es), got $got"; _dump; }
}

assert_log() {
    grep -q -- "$1" "$TMP/out.log" || { _fail "expected log to contain: $1"; _dump; }
}

refute_log() {
    grep -q -- "$1" "$TMP/out.log" && { _fail "expected log NOT to contain: $1"; _dump; }
    return 0
}

assert_portal_ssid() {
    grep -q -- "-s $1" "$TMP/wifi_connect.argv" \
        || { _fail "expected portal SSID $1"; _dump; }
}

_dump() {
    printf '      --- start.sh output ---\n'
    sed 's/^/      /' "$TMP/out.log"
    printf '      --- wifi-connect invocations ---\n'
    if [ -s "$TMP/wifi_connect.argv" ]; then
        sed 's/^/      /' "$TMP/wifi_connect.argv"
    else
        printf '      (none)\n'
    fi
}

harness_result() {
    return "$FAILURES"
}
