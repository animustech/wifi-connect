#!/usr/bin/env bash
# Runs every start.sh decision-path test. No radio, no container, no device -
# these exercise scripts/start.sh against stubbed tools and a fixture sysfs tree.
#
#   tools/test/run.sh              # all cases
#   tools/test/run.sh s5           # cases matching a substring
#
# Scenario numbers map to docs/connectivity-scenarios.md.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/harness.sh"

FILTER="${1:-}"
TOTAL=0
FAILED=0
DESCRIPTION=""

describe() { DESCRIPTION="$1"; }

for case_file in "$HERE"/cases/*.sh; do
    case_name="$(basename "$case_file" .sh)"
    [ -z "$FILTER" ] || case "$case_name" in *"$FILTER"*) ;; *) continue ;; esac

    TOTAL=$((TOTAL + 1))
    DESCRIPTION="$case_name"
    harness_init "$case_name"

    # shellcheck disable=SC1090
    . "$case_file"

    if harness_result; then
        printf '  ok    %s\n' "$DESCRIPTION"
    else
        printf '  FAIL  %s\n' "$DESCRIPTION"
        FAILED=$((FAILED + 1))
    fi
    harness_cleanup
done

printf '\n%s case(s), %s failed\n' "$TOTAL" "$FAILED"
[ "$FAILED" -eq 0 ]
