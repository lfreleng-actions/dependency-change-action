#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Mutation-tests the fail-closed guards in scripts/dependency-change.sh.
# Each guard is the 'if' statement on the line after a '# guard: <name>'
# comment. For every guard in turn, this disables it in a scratch copy
# by appending 'false' to its condition list, 'if <test>; false; then',
# runs tests/dependency-change-test.sh against the copy, and requires
# the suite to fail. The condition still runs with all its side effects,
# the files it writes and the variables it sets, so only the decision
# changes: a mutant cannot be killed by an unrelated breakage, only by a
# test that reaches the guarded failure. A guard whose removal no test
# notices is reported as a survivor, so a fail-closed test cannot pass
# vacuously.
#
# One failing case is all a kill needs, so each mutant's suite stops at
# its first failure, and the mutants run in parallel.
#
# Usage: bash tests/mutate.sh
#   MUTATE_JOBS  mutants run at once; defaults to the number of CPUs

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
script="$here/../scripts/dependency-change.sh"
suite="$here/dependency-change-test.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/dependency-change-mutate.XXXXXX")"
trap 'rm -rf "$work"' EXIT

jobs="${MUTATE_JOBS:-$(getconf _NPROCESSORS_ONLN 2> /dev/null || echo 2)}"
if ! [[ "$jobs" =~ ^[1-9][0-9]*$ ]]; then
    echo "MUTATE_JOBS must be a positive integer ❌"
    exit 1
fi

guard_re='^[[:space:]]*# guard: [a-z0-9-]+$'
guards="$(grep -E "$guard_re" "$script" | sed 's/.*# guard: //')"
if [ -z "$guards" ]; then
    echo "No guards found in $script ❌"
    exit 1
fi

if ! bash "$suite" > "$work/baseline.log" 2>&1; then
    cat "$work/baseline.log"
    echo "The unmutated suite fails; fix it before mutating ❌"
    exit 1
fi

# mutate <guard>: writes the verdict on one guard to $work/<guard>.verdict
mutate() {
    local guard="$1" mutant="$work/$1.sh" verdict
    # The condition ends at the first 'then', at the end of a line
    # ('...; then') or alone on one; 'false' goes just before it
    if ! awk -v name="$guard" '
        armed == 1 {
            if ($0 !~ /^[[:space:]]*if /) {
                exit 3
            }
            armed = 2
        }
        armed == 2 && /; then$/ {
            sub(/; then$/, "; false; then")
            armed = 0
            done = 1
        }
        armed == 2 && /^[[:space:]]*then$/ {
            sub(/then$/, "false; then")
            armed = 0
            done = 1
        }
        $0 ~ ("^[[:space:]]*# guard: " name "$") { armed = 1 }
        { print }
        END { if (!done) exit 3 }
    ' "$script" > "$mutant"; then
        verdict="FAIL: guard '$guard' is not followed by an 'if' line\
 ending its condition with 'then'"
    elif cmp -s "$script" "$mutant"; then
        verdict="FAIL: guard '$guard' could not be disabled"
    elif DETECT_SCRIPT="$mutant" FAIL_FAST=1 bash "$suite" \
        > "$work/$guard.log" 2>&1; then
        verdict="SURVIVED: disabling guard '$guard' left the suite green"
    else
        verdict="killed: $guard"
    fi
    printf '%s\n' "$verdict" > "$work/$guard.verdict"
}

# Bash 3.2 has no 'wait -n', so the mutants run in batches of $jobs
running=0
for guard in $guards; do
    mutate "$guard" &
    running=$((running + 1))
    if [ "$running" -ge "$jobs" ]; then
        wait
        running=0
    fi
done
wait

survivors=0
total=0
for guard in $guards; do
    total=$((total + 1))
    if [ -f "$work/$guard.verdict" ]; then
        verdict="$(cat "$work/$guard.verdict")"
    else
        verdict="FAIL: guard '$guard' recorded no verdict"
    fi
    echo "$verdict"
    case "$verdict" in
        killed:*) ;;
        *) survivors=$((survivors + 1)) ;;
    esac
done

echo
if [ "$survivors" -gt 0 ]; then
    echo "$survivors of $total guards survived mutation ❌"
    exit 1
fi
echo "All $total guards are covered by a failing test ✅"
