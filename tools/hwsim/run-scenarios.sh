#!/usr/bin/env bash
# Runs the hwsim scenarios against the real container on virtual radios.
# Runs INSIDE the VM as root.
#
#   run-scenarios.sh            all
#   run-scenarios.sh s7         matching a substring
#
# Slow by nature - each case waits on real association, DHCP and reconnect ticks.
# Ticks are compressed (1 min, not 15) so a full run is minutes, not hours.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

FILTER="${1:-}"
TOTAL=0; FAILED=0; DESCRIPTION=""
describe() { DESCRIPTION="$1"; }

for f in "$HERE"/scenarios/*.sh; do
    name="$(basename "$f" .sh)"
    [ -z "$FILTER" ] || case "$name" in *"$FILTER"*) ;; *) continue ;; esac
    TOTAL=$((TOTAL + 1)); SFAIL=0; DESCRIPTION="$name"
    # A syntax error makes `.` abort partway through, leaving SFAIL at 0 - which
    # the loop below would report as a pass. Check before sourcing; a scenario
    # that never ran its assertions must never read as green.
    if ! bash -n "$f" 2>/dev/null; then
        printf '  FAIL  %s (syntax error)\n' "$name"
        bash -n "$f" 2>&1 | sed 's/^/          /'
        FAILED=$((FAILED + 1)); continue
    fi
    # shellcheck disable=SC1090
    . "$f"
    if [ "$SFAIL" -eq 0 ]; then printf '  ok    %s\n' "$DESCRIPTION"
    else printf '  FAIL  %s\n' "$DESCRIPTION"; FAILED=$((FAILED + 1)); fi
done

reset_rig
printf '\n%s scenario(s), %s failed\n' "$TOTAL" "$FAILED"
[ "$FAILED" -eq 0 ]
