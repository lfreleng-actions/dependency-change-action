#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Decides whether the change under review touched the files that declare
# or lock its dependencies, and records the answer as a sidecar that
# grype-scan-action reads through its dependency-change-manifest input.
#
# Runs in the checkout's working directory and reads its inputs from
# the environment, as action.yaml passes them:
#   INPUT_ECOSYSTEMS      comma-separated preset names
#   INPUT_PATTERNS        extra patterns, one per line
#   INPUT_PATH_PREFIX     project directory, relative to the working dir
#   INPUT_GERRIT_REFSPEC  non-empty on Gerrit-triggered runs
#   INPUT_BASE            explicit base commit
#   INPUT_OUTPUT          sidecar path
#   EVENT_BEFORE          github.event.before, for push events
#   GITHUB_EVENT_NAME, GITHUB_SHA, GITHUB_OUTPUT  from the runner
#
# Fails closed: when it cannot prove what the change touched, it writes
# no sidecar and leaves the 'changed' output empty. It exits non-zero
# only for invalid inputs, never because of what it found.
#
# Every check that leaves the result unresolved is an 'if' statement on
# the line after a '# guard: <name>' comment. tests/mutate.sh disables
# each one in turn and requires tests/dependency-change-test.sh to fail,
# so no guard can be dropped without a test noticing.
#
# Written for Bash 3.2, the version macOS ships: no associative arrays,
# no mapfile, and no expansion of an empty array under 'set -u'.

set -euo pipefail

# Detection is read-only and offline: never fetch a missing object from
# a promisor remote, and never prompt for credentials. Paths given to
# git are literal, never pathspec magic.
export GIT_NO_LAZY_FETCH=1
export GIT_LITERAL_PATHSPECS=1
export GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS=0

ecosystems="${INPUT_ECOSYSTEMS:-}"
extra_patterns="${INPUT_PATTERNS:-}"
path_prefix="${INPUT_PATH_PREFIX:-}"
gerrit_refspec="${INPUT_GERRIT_REFSPEC:-}"
explicit_base="${INPUT_BASE:-}"
output="${INPUT_OUTPUT:-}"
event_name="${GITHUB_EVENT_NAME:-}"
event_sha="${GITHUB_SHA:-}"
event_before="${EVENT_BEFORE:-}"

zero_sha_re='^0+$'
sha_re='^([0-9a-f]{40}|[0-9a-f]{64})$'

work_dir=""
cleanup() {
    if [ -n "$work_dir" ]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT

die() {
    printf 'Error: %s ❌\n' "$1" >&2
    exit 1
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# Renders a value on one line, so a file name carrying a newline cannot
# start a new log line and forge a workflow command.
printable() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    printf '%s' "$value"
}

# Writes one step output with a random heredoc delimiter, regenerated
# until it is absent from the value, so no value can inject a key.
set_output() {
    local name="$1" value="$2" delimiter
    if [ -z "${GITHUB_OUTPUT:-}" ]; then
        return 0
    fi
    delimiter="ghadelim_${RANDOM}${RANDOM}${RANDOM}${RANDOM}"
    while [[ "$value" == *"$delimiter"* ]]; do
        delimiter="ghadelim_${RANDOM}${RANDOM}${RANDOM}${RANDOM}"
    done
    {
        printf '%s<<%s\n' "$name" "$delimiter"
        printf '%s\n' "$value"
        printf '%s\n' "$delimiter"
    } >> "$GITHUB_OUTPUT"
}

preset_patterns() {
    case "$1" in
        node)
            printf '%s\n' package.json package-lock.json \
                npm-shrinkwrap.json yarn.lock .yarnrc.yml pnpm-lock.yaml \
                pnpm-workspace.yaml bun.lock bun.lockb
            ;;
        python)
            printf '%s\n' pyproject.toml uv.lock poetry.lock pdm.lock \
                Pipfile Pipfile.lock setup.py setup.cfg 'requirements*.txt' \
                'requirements/*.txt' 'constraints*.txt' tox.ini
            ;;
        go)
            printf '%s\n' go.mod go.sum go.work go.work.sum \
                vendor/modules.txt
            ;;
        maven)
            printf '%s\n' pom.xml .mvn/extensions.xml .mvn/maven.config
            ;;
        gradle)
            printf '%s\n' build.gradle build.gradle.kts settings.gradle \
                settings.gradle.kts gradle.properties \
                'gradle/*.versions.toml' gradle.lockfile \
                settings-gradle.lockfile gradle/dependency-locks/ \
                buildSrc/ build-logic/
            ;;
        rust)
            printf '%s\n' Cargo.toml Cargo.lock .cargo/config.toml \
                .cargo/config
            ;;
        docker)
            printf '%s\n' Dockerfile 'Dockerfile.*' '*.Dockerfile' \
                '*.dockerfile' Containerfile 'Containerfile.*'
            ;;
        *)
            return 1
            ;;
    esac
}

# Splits a slash-separated path into the global array 'segments'. A
# loop rather than 'read -a', which would stop at a newline in a name.
segments=()
split_path() {
    local rest="$1"
    segments=()
    while [[ "$rest" == */* ]]; do
        segments+=("${rest%%/*}")
        rest="${rest#*/}"
    done
    segments+=("$rest")
}

# The pattern dialect is deliberately small: literal characters, '*'
# within one path segment, '/' between segments and a trailing '/' for
# a directory. Anything else is rejected rather than half-supported.
validate_pattern() {
    local pattern="$1" body
    case "$pattern" in
        /* | *//* | *'**'* | *'?'* | *'['* | *']'* | *\\*)
            return 1
            ;;
    esac
    if [[ "$pattern" == *[[:cntrl:]]* ]]; then
        return 1
    fi
    body="/${pattern%/}/"
    case "$body" in
        */./* | */../*)
            return 1
            ;;
    esac
    return 0
}

# Patterns are split into segments once. Bash 3.2 has no nested arrays,
# so pattern i owns pattern_parts[pattern_offset[i]] onward, for
# pattern_size[i] segments; pattern_dir[i] is 1 for a directory pattern.
patterns=()
pattern_parts=()
pattern_offset=()
pattern_size=()
pattern_dir=()

add_pattern() {
    local pattern="$1" source="$2" directory=0
    if ! validate_pattern "$pattern"; then
        die "invalid pattern '$(printable "$pattern")' in $source"
    fi
    patterns+=("$pattern")
    if [[ "$pattern" == */ ]]; then
        directory=1
        pattern="${pattern%/}"
    fi
    split_path "$pattern"
    pattern_offset+=("${#pattern_parts[@]}")
    pattern_size+=("${#segments[@]}")
    pattern_dir+=("$directory")
    pattern_parts+=("${segments[@]}")
}

load_patterns() {
    local list name line
    list="${ecosystems//$'\n'/,}"
    while [ -n "$list" ]; do
        name="$(trim "${list%%,*}")"
        if [[ "$list" == *,* ]]; then
            list="${list#*,}"
        else
            list=""
        fi
        if [ -z "$name" ]; then
            continue
        fi
        if ! preset_patterns "$name" > /dev/null; then
            die "unknown ecosystem '$(printable "$name")'; expected one of:\
 node, python, go, maven, gradle, rust, docker"
        fi
        while IFS= read -r line; do
            add_pattern "$line" "ecosystem $name"
        done <<< "$(preset_patterns "$name")"
    done
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim "$line")"
        if [ -n "$line" ]; then
            add_pattern "$line" "patterns"
        fi
    done <<< "$extra_patterns"
    if [ "${#patterns[@]}" -eq 0 ]; then
        die "set ecosystems, patterns, or both"
    fi
}

# Whether segments[start] onward match pattern i, anchored at the
# directory holding segments[start]. A name or path pattern needs
# exactly as many segments as it has; a directory pattern needs its
# segments followed by at least one more.
match_anchored() {
    local start="$1" i="$2" offset size j
    offset="${pattern_offset[i]}"
    size="${pattern_size[i]}"
    for (( j = 0; j < size; j++ )); do
        # shellcheck disable=SC2053  # the right-hand side is a glob
        [[ "${segments[start + j]}" == ${pattern_parts[offset + j]} ]] ||
            return 1
    done
    return 0
}

# prefix_rel is the project directory relative to the repository root,
# empty for the root itself, and prefix_parts its segments. A path
# inside it matches a pattern anchored at any directory at or below the
# prefix; any path matches a pattern anchored at a strict ancestor of
# the prefix, which keeps sibling projects out.
prefix_rel=""
prefix_parts=()
prefix_depth=0

matches_path() {
    local path="$1" count common=0 last i size start
    split_path "$path"
    count="${#segments[@]}"
    # The deepest permitted anchor: any directory holding the path when
    # it lies inside the prefix, otherwise the deepest ancestor of the
    # prefix that also holds the path.
    if [ -z "$prefix_rel" ] || [[ "$path" == "$prefix_rel"/* ]]; then
        last=$(( count - 1 ))
    else
        while [ "$common" -lt "$prefix_depth" ] &&
            [ "$common" -lt "$count" ] &&
            [ "${segments[common]}" = "${prefix_parts[common]}" ]; do
            common=$(( common + 1 ))
        done
        last="$common"
    fi
    for (( i = 0; i < ${#patterns[@]}; i++ )); do
        size="${pattern_size[i]}"
        if [ "${pattern_dir[i]}" -eq 1 ]; then
            for (( start = 0; start <= last && start + size < count; \
                start++ )); do
                if match_anchored "$start" "$i"; then
                    return 0
                fi
            done
        else
            start=$(( count - size ))
            if [ "$start" -ge 0 ] && [ "$start" -le "$last" ] &&
                match_anchored "$start" "$i"; then
                return 0
            fi
        fi
    done
    return 1
}

in_prefix() {
    [ -z "$prefix_rel" ] || [ "$1" = "$prefix_rel" ] ||
        [[ "$1" == "$prefix_rel"/* ]]
}

reason=""
base_sha=""
top_logical=""

unresolve() {
    reason="unresolved: $1"
}

# Canonicalises path-prefix against the repository root, walking it one
# segment at a time so that no component, the last included, may be a
# symbolic link: a change could retarget one and swap the project
# without touching any matched file.
resolve_prefix() {
    local top="$1" prefix current segment rel tracked inside=0
    local -a walk=()
    prefix="${path_prefix:-.}"
    current="$(pwd -P)"
    if [[ "$prefix" == /* ]]; then
        if [ "$prefix" = "$top_logical" ] ||
            [[ "$prefix" == "$top_logical"/* ]]; then
            prefix="${prefix#"$top_logical"}"
            inside=1
        elif [ "$prefix" = "$top" ] || [[ "$prefix" == "$top"/* ]]; then
            prefix="${prefix#"$top"}"
            inside=1
        fi
        # guard: prefix-absolute-outside
        if [ "$inside" -eq 0 ]; then
            unresolve "path-prefix leaves the checkout"
            return 0
        fi
        current="$top"
        prefix="${prefix#/}"
    fi
    split_path "$prefix"
    walk=("${segments[@]}")
    for segment in "${walk[@]}"; do
        case "$segment" in
            "" | .)
                ;;
            ..)
                current="${current%/*}"
                ;;
            *)
                # guard: prefix-symlink
                if [ -L "$current/$segment" ]; then
                    unresolve "path-prefix passes through a symbolic link"
                    return 0
                fi
                current="$current/$segment"
                ;;
        esac
    done
    # guard: prefix-outside
    if [ "$current" != "$top" ] && [[ "$current" != "$top"/* ]]; then
        unresolve "path-prefix leaves the checkout"
        return 0
    fi
    # guard: prefix-missing
    if [ ! -d "$current" ]; then
        unresolve "path-prefix is not an existing directory"
        return 0
    fi
    rel="${current#"$top"}"
    rel="${rel#/}"
    # The prefix must be a directory git tracks at HEAD, spelt as git
    # spells it: on a case-insensitive file system a mis-cased prefix
    # passes the checks above and would then match nothing.
    tracked="$rel"
    if [ -n "$rel" ]; then
        tracked="$(git -C "$top" ls-tree -d --name-only -z HEAD -- "$rel" \
            2> /dev/null | tr -d '\0')" || tracked=""
    fi
    # guard: prefix-untracked
    if [ "$tracked" != "$rel" ]; then
        unresolve "path-prefix is not a directory tracked at HEAD"
        return 0
    fi
    prefix_rel="$rel"
    return 0
}

commit_of() {
    git rev-parse --verify --quiet "$1^{commit}" 2> /dev/null || true
}

resolve_base() {
    local head="$1" candidate=""
    if [ -n "$explicit_base" ]; then
        # guard: base-option
        if [[ "$explicit_base" == -* ]]; then
            unresolve "base '$(printable "$explicit_base")' is not a commit"
            return 0
        fi
        candidate="$(commit_of "$explicit_base")"
        # guard: base-explicit
        if [ -z "$candidate" ]; then
            unresolve "base '$(printable "$explicit_base")' is not a\
 commit in the checkout"
            return 0
        fi
    elif [ -n "$gerrit_refspec" ]; then
        candidate="$(commit_of 'HEAD^1')"
        # guard: gerrit-parent
        if [ -z "$candidate" ]; then
            unresolve "HEAD^1 is not in the checkout"
            return 0
        fi
    else
        # guard: event
        if [ "$event_name" != pull_request ] && [ "$event_name" != push ]
        then
            unresolve "no base for '$(printable "${event_name:-unknown}")'\
 events"
            return 0
        fi
        # guard: head-sha
        if [ "$head" != "$event_sha" ]; then
            unresolve "HEAD is not GITHUB_SHA, so the checkout is not the\
 change"
            return 0
        fi
        if [ "$event_name" = pull_request ]; then
            candidate="$(commit_of 'HEAD^1')"
            # guard: pr-parent
            if [ -z "$candidate" ]; then
                unresolve "HEAD^1 is not in the checkout"
                return 0
            fi
        else
            # guard: push-before-format
            if ! [[ "$event_before" =~ $sha_re ]]; then
                unresolve "the push carries no 'before' commit"
                return 0
            fi
            # guard: push-created
            if [[ "$event_before" =~ $zero_sha_re ]]; then
                unresolve "the push created the branch"
                return 0
            fi
            candidate="$(commit_of "$event_before")"
            # guard: push-before-missing
            if [ -z "$candidate" ]; then
                unresolve "${event_before:0:12} is not in the checkout"
                return 0
            fi
        fi
    fi
    # A shallow or partial clone can hold the commit but not its tree
    # guard: base-tree
    if ! git cat-file -e "${candidate}^{tree}" 2> /dev/null; then
        unresolve "${candidate:0:12} has no tree in the checkout"
        return 0
    fi
    base_sha="$candidate"
    return 0
}

matched=()
submodules=()

detect() {
    local top="" head diff_file meta path old_mode new_mode
    top="$(git rev-parse --show-toplevel 2> /dev/null)" || top=""
    # guard: not-a-checkout
    if [ -z "$top" ]; then
        unresolve "the working directory is not a git checkout"
        return 0
    fi
    top_logical="$top"
    top="$(cd -P "$top" && pwd -P)"
    head="$(commit_of HEAD)"
    # guard: head
    if [ -z "$head" ]; then
        unresolve "HEAD is not a commit"
        return 0
    fi
    resolve_prefix "$top"
    if [ -n "$reason" ]; then
        return 0
    fi
    if [ -n "$prefix_rel" ]; then
        split_path "$prefix_rel"
        prefix_parts=("${segments[@]}")
        prefix_depth="${#prefix_parts[@]}"
    fi
    resolve_base "$head"
    if [ -n "$reason" ]; then
        return 0
    fi

    work_dir="$(mktemp -d \
        "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dependency-change.XXXXXX")"
    diff_file="$work_dir/diff"
    # --raw rather than --name-only so a submodule pointer shows its
    # mode; --no-renames counts both sides of a rename; -z keeps every
    # path byte for byte, newlines included.
    # guard: diff
    if ! git -C "$top" diff --raw -z --no-renames --no-ext-diff \
        --ignore-submodules=none "$base_sha" "$head" -- \
        > "$diff_file" 2> /dev/null; then
        unresolve "git diff ${base_sha:0:12} HEAD failed"
        return 0
    fi
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
        old_mode="${meta:1:6}"
        new_mode="${meta:8:6}"
        if matches_path "$path"; then
            matched+=("$path")
        # A submodule pointer inside the prefix can bring in any
        # dependency, so it counts: over-matching is safe.
        elif { [ "$old_mode" = 160000 ] || [ "$new_mode" = 160000 ]; } &&
            in_prefix "$path"; then
            submodules+=("$path")
        fi
    done < "$diff_file"
    return 0
}

# The change under review must never vouch for itself, so any sidecar
# already in the checkout goes before detection starts.
remove_sidecar() {
    if [ -z "$output" ]; then
        die "output must name the sidecar path"
    fi
    if [ -d "$output" ] && [ ! -L "$output" ]; then
        die "output '$(printable "$output")' is a directory"
    fi
    # guard: planted-sidecar
    if [ -e "$output" ] || [ -L "$output" ]; then
        rm -f -- "$output"
    fi
    if [ -e "$output" ] || [ -L "$output" ]; then
        die "could not remove the existing '$(printable "$output")'"
    fi
}

write_sidecar() {
    local value="$1" dir tmp
    dir="$(dirname -- "$output")"
    mkdir -p -- "$dir"
    tmp="$(mktemp "$dir/.dependency-change.XXXXXX")"
    printf '{"changed": %s}\n' "$value" > "$tmp"
    mv -f -- "$tmp" "$output"
}

main() {
    local changed="" item count
    remove_sidecar
    load_patterns
    detect
    if [ -n "$reason" ]; then
        printf 'Dependencies changed: unknown (%s)\n' "$reason"
        set_output changed ""
        set_output reason "$reason"
        set_output base ""
        set_output manifest ""
        return 0
    fi
    if [ "${#matched[@]}" -gt 0 ]; then
        for item in "${matched[@]}"; do
            printf 'Dependency file changed: %s\n' "$(printable "$item")"
        done
    fi
    if [ "${#submodules[@]}" -gt 0 ]; then
        for item in "${submodules[@]}"; do
            printf 'Submodule changed: %s\n' "$(printable "$item")"
        done
    fi
    count=$(( ${#matched[@]} + ${#submodules[@]} ))
    changed=false
    if [ "$count" -gt 0 ]; then
        changed=true
    fi
    reason="since ${base_sha:0:12}"
    write_sidecar "$changed"
    printf 'Dependencies changed: %s (%s)\n' "$changed" "$reason"
    set_output changed "$changed"
    set_output reason "$reason"
    set_output base "$base_sha"
    set_output manifest "$output"
}

main "$@"
