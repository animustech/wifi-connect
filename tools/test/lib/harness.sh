#!/usr/bin/env bash
# Test harness for scripts/start.sh.
#
# start.sh reaches the outside world through exactly five things, and all five are
# replaceable from here:
#
#   iwgetid          stubbed on PATH
#   ip               stubbed on PATH
#   nmcli            stubbed on PATH, served from fixtures
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

# fixture_iwgetid <ssid|""> [--drop-after N] [--return-after N] [--return-after-portal N]
#   Empty ssid means "not associated".
#   --drop-after N    association is lost N seconds into the run
#   --return-after N  and comes back N seconds into the run
#   --return-after-portal N
#                     and comes back N seconds after wifi-connect was last
#                     launched, however long the run took to get there. Use it
#                     for a return that must land inside the post-portal grace
#                     period: a return timed from the start of the run races the
#                     portal launch, whose time varies by whole seconds.
fixture_iwgetid() {
    printf '%s' "${1:-}" > "$TMP/iwgetid.ssid"
    shift || true
    : > "$TMP/iwgetid.drop_after"
    : > "$TMP/iwgetid.return_after"
    : > "$TMP/iwgetid.return_after_portal"
    while [ $# -gt 0 ]; do
        case "$1" in
            --drop-after)   printf '%s' "$2" > "$TMP/iwgetid.drop_after"; shift 2 ;;
            --return-after) printf '%s' "$2" > "$TMP/iwgetid.return_after"; shift 2 ;;
            --return-after-portal) printf '%s' "$2" > "$TMP/iwgetid.return_after_portal"; shift 2 ;;
            *) echo "fixture_iwgetid: unknown option '$1'" >&2; exit 2 ;;
        esac
    done
}

# fixture_wifi_connect_joins <ssid>
#   The stub binary "succeeds": it joins <ssid> and exits, as the real one does.
fixture_wifi_connect_joins() {
    printf '%s' "$1" > "$TMP/wifi_connect.joins"
}

# fixture_nmcli_device FIELD=value ...
#   What `nmcli device show wlan0` reports, e.g. GENERAL.STATE="30 (disconnected)".
#   Without it the stub behaves like a missing device (exit 10).
fixture_nmcli_device() {
    printf '%s\n' "$@" > "$TMP/nmcli.device"
}

# fixture_nmcli_profile <uuid> <name> <ssid> <yes|no> [<mode>]
#   A saved WiFi profile; <yes|no> is its autoconnect flag. May be called repeatedly.
fixture_nmcli_profile() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-infrastructure}" \
        >> "$TMP/nmcli.profiles"
}

# fixture_nmcli_visible <ssid> ...   what the cached scan list holds
fixture_nmcli_visible() {
    printf '%s\n' "$@" > "$TMP/nmcli.visible"
}

# fixture_nmcli_rescan_fails   `--rescan yes` exits 1, as when the radio is busy.
#   Real nmcli 1.52 never does: on a refused or failed scan it prints the cached
#   list with exit 0. The code must cope with both, so the stricter shape is kept.
fixture_nmcli_rescan_fails() {
    : > "$TMP/nmcli.rescan_fails"
}

# fixture_nmcli_version_warning   every nmcli call prints, on stderr, the warning real
#   nmcli gives when its version differs from the NetworkManager daemon's.
fixture_nmcli_version_warning() {
    : > "$TMP/nmcli.version_warning"
}

# fixture_nmcli_versions <client> [<daemon>]
#   The version `nmcli --version` reports and the NetworkManager daemon version
#   `nmcli -t -f VERSION general` reports. Without a daemon version that query fails,
#   as when the host's NetworkManager cannot be reached. Unset, they read 1.52.1 and
#   1.52.0.
fixture_nmcli_versions() {
    printf '%s\n' "$1" > "$TMP/nmcli.client_version"
    printf '%s\n' "${2:-}" > "$TMP/nmcli.daemon_version"
}

# fixture_nmcli_up <uuid> ok|"ok-late <secs>"|"fail <msg>"
#   Outcome of `nmcli connection up uuid <uuid>`. Success also makes the link read
#   as associated to that profile's SSID, at once or <secs> later. No fixture
#   behaves like a failure.
fixture_nmcli_up() {
    printf '%s\n' "$2" > "$TMP/nmcli.up.$1"
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
backp="$(cat "$T/iwgetid.return_after_portal" 2>/dev/null)"
if [ -n "$drop" ] && [ "$elapsed" -ge "$drop" ]; then
    if [ -n "$backp" ] && [ -f "$T/wifi_connect.launched_at" ] \
        && [ $(( $(date +%s) - $(cat "$T/wifi_connect.launched_at") )) -ge "$backp" ]; then
        echo "$ssid"; exit 0
    fi
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
printf '%s\n' "${ACTIVITY_TIMEOUT-unset}" >> "$T/wifi_connect.activity_timeout"
date +%s > "$T/wifi_connect.launched_at"
if [ -f "$T/wifi_connect.joins" ]; then
    cp "$T/wifi_connect.joins" "$T/iwgetid.override"
fi
exit 0
STUB

    # Serves only the invocations start.sh and nm.sh make. In -t mode without
    # `--escape no` real nmcli backslash-escapes ':' and '\' inside values, and the
    # profile listing reproduces that so the parser's unescaping is exercised.
    cat > "$TMP/bin/nmcli" <<'STUB'
#!/usr/bin/env bash
T="$WCSTART_TMP"
printf '%s\n' "$*" >> "$T/nmcli.argv"
args=" $* "
[ -f "$T/nmcli.version_warning" ] \
    && echo "Warning: nmcli (1.52.1) and NetworkManager (1.52.0) versions don't match. Restarting NetworkManager is advised." >&2
esc() { sed -e 's/\\/\\\\/g' -e 's/:/\\:/g'; }
profile_ssid() { awk -F'\t' -v u="$1" '$1 == u { print $3 }' "$T/nmcli.profiles" 2>/dev/null; }
case "$args" in
    *" --version "*)
        echo "nmcli tool, version $(cat "$T/nmcli.client_version" 2>/dev/null || echo 1.52.1)"
        ;;
    *" -f VERSION general "*)
        if [ -f "$T/nmcli.daemon_version" ]; then
            v="$(cat "$T/nmcli.daemon_version")"
            [ -n "$v" ] || exit 8
            echo "$v"
        else
            echo 1.52.0
        fi
        ;;
    *" device show wlan0 "*)
        [ -f "$T/nmcli.device" ] || exit 10
        field="${args#* -g }"; field="${field%% *}"
        grep "^$field=" "$T/nmcli.device" | head -n 1 | cut -d= -f2-
        ;;
    *" connection show uuid "*)
        uuid="${args#* uuid }"; uuid="${uuid%% *}"
        field="${args#* -g }"; field="${field%% *}"
        case "$field" in
            802-11-wireless.ssid) awk -F'\t' -v u="$uuid" '$1 == u { print $3 }' "$T/nmcli.profiles" 2>/dev/null ;;
            802-11-wireless.mode) awk -F'\t' -v u="$uuid" '$1 == u { print $5 }' "$T/nmcli.profiles" 2>/dev/null ;;
        esac
        ;;
    *" connection show "*)
        [ -f "$T/nmcli.profiles" ] || exit 0
        while IFS=$'\t' read -r uuid name ssid auto mode; do
            printf '%s:802-11-wireless:%s:%s\n' "$uuid" "$auto" "$(printf '%s' "$name" | esc)"
        done < "$T/nmcli.profiles"
        ;;
    *" device wifi list "*)
        case "$args" in
            *"--rescan yes"*) [ -f "$T/nmcli.rescan_fails" ] && exit 1 ;;
        esac
        [ -f "$T/nmcli.visible" ] && cat "$T/nmcli.visible"
        ;;
    *" connection up "*)
        uuid="${args#* uuid }"; uuid="${uuid%% *}"
        outcome="$(cat "$T/nmcli.up.$uuid" 2>/dev/null)"
        case "$outcome" in
            ok)
                profile_ssid "$uuid" > "$T/iwgetid.override"
                echo "Connection successfully activated"
                ;;
            ok-late*)
                ( sleep "${outcome#ok-late }"; profile_ssid "$uuid" > "$T/iwgetid.override" ) >/dev/null 2>&1 &
                echo "Connection successfully activated"
                ;;
            *)
                echo "Error: Connection activation failed: ${outcome#fail }" >&2
                exit 4
                ;;
        esac
        ;;
esac
exit 0
STUB

    # The recovery order is read with jq, which the image carries.
    ln -s "$(command -v jq)" "$TMP/bin/jq" 2>/dev/null || true

    chmod +x "$TMP/bin/iwgetid" "$TMP/bin/ip" "$TMP/bin/wifi-connect" "$TMP/bin/nmcli"
}

# --------------------------------------------------------------- execution

# run_start_sh [--passes N] [--default-activity-timeout] [VAR=VALUE ...]
#   --default-activity-timeout  leave ACTIVITY_TIMEOUT unset for start.sh, so the
#                               shipped default applies (otherwise it is forced to 0)
run_start_sh() {
    local passes=1
    local -a extra_env
    extra_env=()
    local -a activity_env
    activity_env=("ACTIVITY_TIMEOUT=${ACTIVITY_TIMEOUT:-0}")
    while [ $# -gt 0 ]; do
        case "$1" in
            --passes) passes="$2"; shift 2 ;;
            --default-activity-timeout) activity_env=(); shift ;;
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
        ${activity_env[@]+"${activity_env[@]}"} \
        RECOVERY_GRACE="${RECOVERY_GRACE:-1}" \
        NM_STATE_LOG="${NM_STATE_LOG:-$TMP/nm-state.log}" \
        RECONNECT_HISTORY="${RECONNECT_HISTORY:-$TMP/reconnect-history.json}" \
        ${extra_env[@]+"${extra_env[@]}"} \
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

# assert_activity_timeout <seconds>: what the binary actually received, from its env.
assert_activity_timeout() {
    grep -qx -- "$1" "$TMP/wifi_connect.activity_timeout" 2>/dev/null \
        || _fail "expected wifi-connect to receive ACTIVITY_TIMEOUT=$1, got: $(tr '\n' ' ' < "$TMP/wifi_connect.activity_timeout" 2>/dev/null)"
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

# assert_log_count <n> <pattern>   the pattern appears on exactly n log lines
assert_log_count() {
    local want="$1" got
    got="$(grep -c -- "$2" "$TMP/out.log" 2>/dev/null)"
    [ "${got:-0}" = "$want" ] || { _fail "expected $want log line(s) with '$2', got ${got:-0}"; _dump; }
}

# assert_nmcli_called <substring>   some nmcli call's arguments contain it
assert_nmcli_called() {
    grep -qF -- "$1" "$TMP/nmcli.argv" 2>/dev/null \
        || { _fail "expected an nmcli call containing: $1"; _dump_nmcli; }
}

refute_nmcli_called() {
    grep -qF -- "$1" "$TMP/nmcli.argv" 2>/dev/null \
        && { _fail "expected no nmcli call containing: $1"; _dump_nmcli; }
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

_dump_nmcli() {
    printf '      --- nmcli invocations ---\n'
    if [ -s "$TMP/nmcli.argv" ]; then
        sed 's/^/      /' "$TMP/nmcli.argv"
    else
        printf '      (none)\n'
    fi
}

harness_result() {
    return "$FAILURES"
}
