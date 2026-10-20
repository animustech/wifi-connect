#!/usr/bin/env bash
# NetworkManager helpers for start.sh. Sourced, never run.
#
# NM can keep a saved profile blocked from autoconnect (a device-level flag, or a
# profile that exhausted its retries) and say nothing about it. The journal rotates,
# so by the time anyone looks the reason is gone. nm_log_state writes what NM thinks
# to stdout and to a capped file on /data, which outlives both.

NM_STATE_LOG="${NM_STATE_LOG:-/data/nm-state.log}"
# Cap on the state file. Past it the oldest whole lines are dropped, down to
# NM_STATE_LOG_KEEP bytes, so trimming is not repeated on every write.
NM_STATE_LOG_MAX="${NM_STATE_LOG_MAX:-1048576}"
NM_STATE_LOG_KEEP="${NM_STATE_LOG_KEEP:-524288}"

# The WiFi interface every query and activation is scoped to.
NM_IFACE="${NM_IFACE:-wlan0}"

nm_warned_unavailable=""

# True (exit 0) if nmcli is installed. Says so once per process when it is not.
nm_available() {
    command -v nmcli >/dev/null 2>&1 && return 0
    if [ -z "$nm_warned_unavailable" ]; then
        nm_warned_unavailable=1
        nm_log "NetworkManager tools not available - state log and recovery disabled"
    fi
    return 1
}

# nm_log <text>: timestamped line to stdout and the state file. A file that cannot
# be written costs the file, never the supervision loop.
nm_log() {
    local line size
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $1"
    printf '%s\n' "$line"
    {
        printf '%s\n' "$line" >> "$NM_STATE_LOG"
        # wc -c, not stat -c: this also runs on the BSD userland the tests use.
        size="$(wc -c < "$NM_STATE_LOG" | tr -d ' ')"
        if [ "${size:-0}" -gt "$NM_STATE_LOG_MAX" ]; then
            # The first line of the tail is usually cut mid-line, so drop it.
            tail -c "$NM_STATE_LOG_KEEP" "$NM_STATE_LOG" | sed 1d > "$NM_STATE_LOG.tmp" \
                && mv "$NM_STATE_LOG.tmp" "$NM_STATE_LOG"
        fi
    } 2>/dev/null || true
    return 0
}

# nm_dev_field <FIELD>: one $NM_IFACE device property, or "-" if empty or unavailable.
nm_dev_field() {
    local v
    v="$(nmcli --escape no -g "$1" device show "$NM_IFACE" 2>/dev/null)" || v=""
    printf '%s' "${v:--}"
}

# nm_visible_ssids <yes|no>: SSIDs in the scan list, one per line. The argument is
# nmcli's --rescan: "no" reads the cached list, "yes" triggers a fresh scan.
nm_visible_ssids() {
    nmcli --escape no -t -f SSID device wifi list ifname "$NM_IFACE" --rescan "$1" 2>/dev/null \
        | grep .
}

# nm_wifi_profiles: uuid<TAB>autoconnect<TAB>name for every saved WiFi profile.
# In terse mode ':' and '\' inside a value arrive backslash-escaped, and NAME is the
# last field, so it keeps any ':' it contains and is unescaped here.
nm_wifi_profiles() {
    local uuid type auto name
    nmcli -t -f UUID,TYPE,AUTOCONNECT,NAME connection show 2>/dev/null \
        | while IFS=: read -r uuid type auto name; do
            [ "$type" = "802-11-wireless" ] || continue
            name="$(printf '%s' "$name" | sed 's/\\\(.\)/\1/g')"
            printf '%s\t%s\t%s\n' "$uuid" "$auto" "$name"
        done
}

# nm_profile_field <uuid> <field>: one property of a saved profile.
nm_profile_field() {
    nmcli --escape no -g "$2" connection show uuid "$1" 2>/dev/null
}

# The one-line summary nm_log_state writes. Any field NM cannot give prints "-".
nm_state_line() {
    local state reason visible profiles uuid auto name ssid vis tab
    tab="$(printf '\t')"
    state="$(nm_dev_field GENERAL.STATE)"
    case "$state" in
        *\(*\)*) state="${state#*\(}"; state="${state%\)*}" ;;
    esac
    reason="$(nm_dev_field GENERAL.REASON)"
    visible="$(nm_visible_ssids no)"
    profiles=""
    while IFS="$tab" read -r uuid auto name; do
        [ -n "$uuid" ] || continue
        # Visibility is by SSID: a profile's name need not match what it joins.
        ssid="$(nm_profile_field "$uuid" 802-11-wireless.ssid)"
        if [ -n "$ssid" ] && printf '%s\n' "$visible" | grep -qxF -- "$ssid"; then vis=yes; else vis=no; fi
        profiles="${profiles:+$profiles, }$name auto=$auto visible=$vis"
    done <<EOP
$(nm_wifi_profiles)
EOP
    printf 'NM state: %s=%s (reason=%s) dev-autoconnect=%s active=%s profiles=[%s]' \
        "$NM_IFACE" "$state" "$reason" "$(nm_dev_field GENERAL.AUTOCONNECT)" \
        "$(nm_dev_field GENERAL.CONNECTION)" "$profiles"
}

nm_log_state() {
    nm_available && nm_log "$(nm_state_line)"
}

RECONNECT_HISTORY="${RECONNECT_HISTORY:-/data/reconnect-history.json}"

# nm_recovery_candidates: uuid<TAB>ssid<TAB>name for each saved profile worth
# activating, most recently connected first. Runs in the caller's shell (redirect
# its output, never $(...) it) because it sets NM_VISIBLE_COUNT for the log line.
#
# A candidate autoconnects, is not an access-point profile (ours included) and is in
# range. A busy radio refuses a fresh scan; the cached list then has to do. History
# that is missing or unreadable counts as 0 for every SSID, so the order stays
# NetworkManager's own (the sort is stable).
nm_recovery_candidates() {
    local visible uuid auto name ssid mode last tab
    tab="$(printf '\t')"
    visible="$(nm_visible_ssids yes)" || visible="$(nm_visible_ssids no)"
    # One row per access point, so count distinct SSIDs.
    NM_VISIBLE_COUNT="$(printf '%s\n' "$visible" | grep . | sort -u | grep -c .)"
    while IFS="$tab" read -r uuid auto name; do
        [ -n "$uuid" ] || continue
        [ "$auto" = "yes" ] || continue
        mode="$(nm_profile_field "$uuid" 802-11-wireless.mode)"
        [ "$mode" != "ap" ] || continue
        ssid="$(nm_profile_field "$uuid" 802-11-wireless.ssid)"
        [ -n "$ssid" ] && [ "$ssid" != "$PORTAL_SSID" ] || continue
        printf '%s\n' "$visible" | grep -qxF -- "$ssid" || continue
        last="$(jq -r --arg s "$ssid" '.last_connected[$s] // 0' "$RECONNECT_HISTORY" 2>/dev/null)"
        case "$last" in ''|*[!0-9]*) last=0 ;; esac
        printf '%s\t%s\t%s\t%s\n' "$last" "$uuid" "$ssid" "$name"
    done <<EOP | sort -s -t "$tab" -k1,1nr | cut -f2-
$(nm_wifi_profiles)
EOP
}

# nm_recover_saved_networks: activate visible saved profiles, each once, until one
# takes. Returns 0 on the first success. An explicit activation overrides the
# autoconnect blocks NM sets on its own, which is the point.
nm_recover_saved_networks() {
    local list uuid ssid name out msg waited tab
    tab="$(printf '\t')"
    list="$(mktemp "${TMPDIR:-/tmp}/nm-candidates.XXXXXX")" || return 1
    nm_recovery_candidates > "$list"
    if [ ! -s "$list" ]; then
        rm -f "$list"
        nm_log "Recovery: no saved network to activate ($NM_VISIBLE_COUNT SSIDs visible)"
        return 1
    fi
    while IFS="$tab" read -r uuid ssid name; do
        # The rescan above can take a while; if the link came up meanwhile, leave it.
        if connected; then
            rm -f "$list"
            return 0
        fi
        if out="$(nmcli --wait 45 connection up uuid "$uuid" ifname "$NM_IFACE" 2>&1)"; then
            nm_log "Recovery: activating saved profile '$name' -> activated"
            rm -f "$list"
            # The association can trail the activation by a moment.
            waited=0
            while ! connected && [ "$waited" -lt $((3 * ${WIFI_CHECK_INTERVAL:-5})) ]; do
                sleep "${WIFI_CHECK_INTERVAL:-5}"
                waited=$((waited + ${WIFI_CHECK_INTERVAL:-5}))
            done
            return 0
        fi
        # nmcli may print warnings (client/daemon version skew, a missing password
        # prompt) ahead of the error, so pick the error rather than the first line.
        msg="$(printf '%s\n' "$out" | grep -m1 '^Error: ')" \
            || msg="$(printf '%s\n' "$out" | grep -v '^Warning: ' | head -n 1)"
        nm_log "Recovery: activating saved profile '$name' -> failed: ${msg#Error: }"
    done < "$list"
    rm -f "$list"
    return 1
}
