#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Mutation-tests the fail-closed guards in scripts/dependency-change.sh.
# Each guard is the 'if' statement on the line after a '# guard: <name>'
# comment. For every guard in turn, this disables it by rewriting
# 'if <test>' as 'if false && <test>' in a scratch copy, runs
# tests/dependency-change-test.sh against the copy, and requires the
# suite to fail. A guard whose removal no test notices is reported as a
# survivor, so a fail-closed test cannot pass vacuously.
#
# Usage: bash tests/mutate.sh

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
script="$here/../scripts/dependency-change.sh"
suite="$here/dependency-change-test.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/dependency-change-mutate.XXXXXX")"
trap 'rm -rf "$work"' EXIT

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

survivors=0
total=0
for guard in $guards; do
    total=$((total + 1))
    mutant="$work/$guard.sh"
    awk -v name="$guard" '
        armed && /^[[:space:]]*if / {
            sub(/if /, "if false \\&\\& ")
            armed = 0
            done = 1
        }
        $0 ~ ("^[[:space:]]*# guard: " name "$") { armed = 1 }
        { print }
        END { if (!done) exit 3 }
    ' "$script" > "$mutant" || {
        echo "FAIL: guard '$guard' is not followed by an 'if' line"
        survivors=$((survivors + 1))
        continue
    }
    if cmp -s "$script" "$mutant"; then
        echo "FAIL: guard '$guard' could not be disabled"
        survivors=$((survivors + 1))
    elif DETECT_SCRIPT="$mutant" bash "$suite" > "$work/$guard.log" 2>&1
    then
        echo "SURVIVED: disabling guard '$guard' left the suite green"
        survivors=$((survivors + 1))
    else
        echo "killed: $guard ($(grep -c '^FAIL' "$work/$guard.log") failing)"
    fi
done

echo
if [ "$survivors" -gt 0 ]; then
    echo "$survivors of $total guards survived mutation ❌"
    exit 1
fi
echo "All $total guards are covered by a failing test ✅"
