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
# start a new log line and forge a workflow command. The runner's
# legacy parser finds '##[' anywhere on a line, so that marker becomes
# '#\#[', which a backslash in the value, doubled, cannot spell.
printable() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//\#\#\[/#\\#[}"
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

# Escapes every character of a pattern segment but '*'. From Bash 4.1,
# '[[ == ]]' reads extended globs such as '+(...)' whatever the extglob
# option says, so an unescaped 'deps+(x).lock' would miss the file of
# that name and match others.
glob_segment() {
    local value="$1" escaped="" char
    while [ -n "$value" ]; do
        char="${value:0:1}"
        value="${value:1}"
        if [ "$char" = '*' ]; then
            escaped="$escaped*"
        else
            escaped="$escaped\\$char"
        fi
    done
    printf '%s' "$escaped"
}

# Patterns are split into segments once. Bash 3.2 has no nested arrays,
# so pattern i owns pattern_parts[pattern_offset[i]] onward, for
# pattern_size[i] segments, each escaped by glob_segment; pattern_dir[i]
# is 1 for a directory pattern.
patterns=()
pattern_parts=()
pattern_offset=()
pattern_size=()
pattern_dir=()

add_pattern() {
    local pattern="$1" source="$2" directory=0 segment
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
    for segment in "${segments[@]}"; do
        pattern_parts+=("$(glob_segment "$segment")")
    done
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

# Whether segments[start] onward match the first n segments of pattern
# i, all of them when n is omitted, anchored at the directory holding
# segments[start]. Callers check the segment counts.
match_anchored() {
    local start="$1" i="$2" offset size j
    offset="${pattern_offset[i]}"
    size="${3:-${pattern_size[i]}}"
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

# Whether a pattern could match a path beneath the directory 'path', as
# a symbolic link there can point at any directory. Inside the prefix,
# or at an ancestor of it, a pattern may be anchored beneath the link,
# so any pattern could. Elsewhere the pattern must be anchored at an
# ancestor of the prefix and reach past the link: 'buildSrc/' or
# 'gradle/*.versions.toml' for a link named buildSrc or gradle.
matches_below() {
    local path="$1" count common=0 i size start depth
    if in_prefix "$path" || [[ "$prefix_rel" == "$path"/* ]]; then
        return 0
    fi
    split_path "$path"
    count="${#segments[@]}"
    while [ "$common" -lt "$prefix_depth" ] &&
        [ "$common" -lt "$count" ] &&
        [ "${segments[common]}" = "${prefix_parts[common]}" ]; do
        common=$(( common + 1 ))
    done
    for (( i = 0; i < ${#patterns[@]}; i++ )); do
        size="${pattern_size[i]}"
        for (( start = 0; start <= common; start++ )); do
            depth=$(( count - start ))
            if { [ "$size" -gt "$depth" ] ||
                { [ "${pattern_dir[i]}" -eq 1 ] &&
                    [ "$size" -eq "$depth" ]; }; } &&
                match_anchored "$start" "$i" "$depth"; then
                return 0
            fi
        done
    done
    return 1
}

reason=""
base_sha=""
top_logical=""
top_physical=""

# --- symbolic link aliases ----------------------------------------------
#
# An unchanged link such as package.json -> manifests/node.json makes a
# change to its target a change to a dependency file, though only the
# target shows in the diff. For each revision compared, every link a
# pattern could reach is resolved inside the tree, the way the file
# system would follow it, into an alias: a logical name (where the link
# is reached), the path it resolves to, and the links followed on the
# way. A directory alias exposes the links beneath its target under new
# logical names, which are resolved in turn.
#
# A target outside the repository is not part of the change, but the
# links followed to reach it are. Whatever cannot be resolved leaves
# the result unresolved.

# The revision's links and submodules, from git ls-tree
tree_path=()
tree_mode=()
tree_sha=()
tree_target=()
tree_loaded=()

# The submodules nested in the revision's submodules, as their owners'
# recorded commits hold them: nested_path[k], a repository path, is
# recorded at nested_sha[k] by the submodule nested_owner[k]. Each
# submodule found checked out at its pointer appends its own to these,
# once, and nested_loaded lists those that have.
nested_path=()
nested_sha=()
nested_owner=()
nested_loaded=()

# The aliases of both revisions. Alias i followed the links
# alias_followed[alias_offset[i]] onward, alias_count[i] of them;
# alias_outside[i] is 1 when its target lies outside the repository.
alias_name=()
alias_target=()
alias_outside=()
alias_offset=()
alias_count=()
alias_followed=()

# Caps the logical names a pattern could reach, per revision, which
# also bounds the work: directory links that reach their own ancestors,
# or each other, multiply them without end
max_aliases=1000
# As the kernel's SYMLOOP_MAX caps the links followed in one lookup
max_hops=40

# Sets 'found' to the index of path in the revision's tree lists, or -1
found=-1
tree_index() {
    local path="$1" i
    found=-1
    for (( i = 0; i < ${#tree_path[@]}; i++ )); do
        if [ "${tree_path[i]}" = "$path" ]; then
            found="$i"
            return 0
        fi
    done
    return 0
}

# The paths spelling_unique has passed in the revision
spelt=()

# Whether the path $1, which the walk reached in the revision's tree as
# spelt, is the only spelling of it that the tree holds; fails, too,
# when that cannot be checked. A file system that folds case, as macOS
# and Windows do by default, reads manifests/NODE.json from a tracked
# manifests/node.json, or follows a tracked 'manifests' link for
# 'MANIFESTS', so a target that git spells otherwise cannot be matched
# against the diff. Git folds ASCII letters only, while such file
# systems also fold other letters and normalise Unicode, so a name with
# any other byte passes only when the tree holds it exactly as spelt.
spelling_unique() {
    local path="$1" k exact=0 folded=0 high lower name name_folded
    for (( k = 0; k < ${#spelt[@]}; k++ )); do
        if [ "${spelt[k]}" = "$path" ]; then
            return 0
        fi
    done
    lower="$(printf '%s' "$path" | LC_ALL=C tr '[:upper:]' '[:lower:]' &&
        printf x)" || return 1
    lower="${lower%x}"
    if [[ "$path" == *$'\n'* ]]; then
        # grep would need a NUL in its pattern, which not every grep
        # reads, so a name holding a newline is compared here
        while IFS= read -r -d '' name <&3 &&
            IFS= read -r -d '' name_folded <&4; do
            if [ "$name" = "$path" ]; then
                exact=$(( exact + 1 ))
            fi
            if [ "$name_folded" = "$lower" ]; then
                folded=$(( folded + 1 ))
            fi
        done 3< "$work_dir/names0" 4< "$work_dir/names0.folded" ||
            return 1
    else
        printf '%s\n' "$path" > "$work_dir/spelling" &&
            printf '%s\n' "$lower" > "$work_dir/spelling.folded" ||
            return 1
        exact="$(LC_ALL=C grep -a -c -F -x -f "$work_dir/spelling" \
            "$work_dir/names" || [ "$?" -eq 1 ])" || return 1
        folded="$(LC_ALL=C grep -a -c -F -x -f \
            "$work_dir/spelling.folded" "$work_dir/names.folded" ||
            [ "$?" -eq 1 ])" || return 1
    fi
    high="$(printf '%s' "$path" | LC_ALL=C tr -d '\000-\177' &&
        printf x)" || return 1
    if [ "$exact" != "$folded" ] ||
        { [ "$high" != x ] && [ "$exact" -eq 0 ]; }; then
        return 1
    fi
    spelt+=("$path")
    return 0
}

# Sets 'canonical' to the physical directory $1, or, where it is the
# checkout or a submodule's checkout under another spelling, such as
# /work/REPO for /work/repo on a file system that folds case, to that
# directory as the walk spells it. Identity decides, not spelling.
canonical=""
canonical_dir() {
    local path="$1" j
    canonical="$path"
    if [ -L "$path" ] || [ ! -d "$path" ]; then
        return 0
    fi
    if [ "$path" != "$top_physical" ] && [ "$path" -ef "$top_physical" ]
    then
        canonical="$top_physical"
        return 0
    fi
    if [[ "$path" != "$top_physical"/* ]]; then
        return 0
    fi
    for (( j = 0; j < ${#tree_path[@]}; j++ )); do
        if [ "${tree_mode[j]}" = 160000 ] &&
            [ "$path" != "$top_physical/${tree_path[j]}" ] &&
            [ "$path" -ef "$top_physical/${tree_path[j]}" ]; then
            canonical="$top_physical/${tree_path[j]}"
            return 0
        fi
    done
    for (( j = 0; j < ${#nested_path[@]}; j++ )); do
        if [ "$path" != "$top_physical/${nested_path[j]}" ] &&
            [ "$path" -ef "$top_physical/${nested_path[j]}" ]; then
            canonical="$top_physical/${nested_path[j]}"
            return 0
        fi
    done
    return 0
}

# Lists the links and submodules of a revision into the tree arrays,
# and every path in it, directories included, into the name lists that
# spelling_unique reads. Swapping NUL and newline lets grep filter
# whole records whatever the path holds, on GNU and BSD tools alike.
load_tree() {
    local rev="$1" listing="$work_dir/tree" record meta
    tree_path=()
    tree_mode=()
    tree_sha=()
    tree_target=()
    tree_loaded=()
    nested_path=()
    nested_sha=()
    nested_owner=()
    nested_loaded=()
    spelt=()
    # guard: alias-tree
    if ! { git ls-tree -r -z --full-tree "$rev" > "$listing" 2> /dev/null &&
        tr '\n\000' '\000\n' < "$listing" |
        { grep -a -e '^120000 ' -e '^160000 ' || [ "$?" -eq 1 ]; } |
        tr '\n\000' '\000\n' > "$listing.links" &&
        git ls-tree -r -t -z --name-only --full-tree "$rev" \
            > "$work_dir/names0" 2> /dev/null &&
        LC_ALL=C tr '[:upper:]' '[:lower:]' < "$work_dir/names0" \
            > "$work_dir/names0.folded" &&
        tr '\n\000' '\000\n' < "$work_dir/names0" > "$work_dir/names" &&
        tr '\n\000' '\000\n' < "$work_dir/names0.folded" \
            > "$work_dir/names.folded"; }; then
        unresolve "git ls-tree ${rev:0:12} failed"
        return 0
    fi
    while IFS= read -r -d '' record; do
        meta="${record%%$'\t'*}"
        tree_path+=("${record#*$'\t'}")
        tree_mode+=("${meta%% *}")
        tree_sha+=("${meta##* }")
        tree_target+=("")
        tree_loaded+=(0)
    done < "$listing.links"
    return 0
}

# Sets 'found' to the index of path among the nested submodules, or -1
nested_index() {
    local path="$1" k
    found=-1
    for (( k = 0; k < ${#nested_path[@]}; k++ )); do
        if [ "${nested_path[k]}" = "$path" ]; then
            found="$k"
            return 0
        fi
    done
    return 0
}

# Records the submodules nested in submodule $1, checked out at $2 at
# its pointer $3, from that recorded commit's tree, once per revision
load_nested() {
    local sub="$1" root="$2" pointer="$3" k record meta
    local listing="$work_dir/nested"
    for (( k = 0; k < ${#nested_loaded[@]}; k++ )); do
        if [ "${nested_loaded[k]}" = "$sub" ]; then
            return 0
        fi
    done
    nested_loaded+=("$sub")
    # guard: submodule-nested
    if ! { git -C "$root" ls-tree -r -z --full-tree "$pointer" \
        > "$listing" 2> /dev/null &&
        tr '\n\000' '\000\n' < "$listing" |
        { grep -a -e '^160000 ' || [ "$?" -eq 1 ]; } |
        tr '\n\000' '\000\n' > "$listing.links"; }; then
        unresolve "the submodules nested in '$(printable "$sub")' cannot\
 be listed"
        return 0
    fi
    while IFS= read -r -d '' record; do
        meta="${record%%$'\t'*}"
        nested_path+=("$sub/${record#*$'\t'}")
        nested_sha+=("${meta##* }")
        nested_owner+=("$sub")
    done < "$listing.links"
    return 0
}

# Sets 'link_target' to what link i of the revision points at
link_target=""
read_link() {
    local i="$1" value
    if [ "${tree_loaded[i]}" -eq 0 ]; then
        # guard: alias-target
        if ! value="$(git cat-file blob "${tree_sha[i]}" 2> /dev/null &&
            printf x)"; then
            unresolve "the target of symbolic link\
 '$(printable "${tree_path[i]}")' is not in the checkout"
            return 0
        fi
        tree_target[i]="${value%x}"
        tree_loaded[i]=1
    fi
    link_target="${tree_target[i]}"
}

# Sets 'rel' to the repository path of the physical path $1, and
# 'submodule' to the deepest submodule known to hold it, or empty, when
# the path lies in the checkout; returns 1 when it does not. A nested
# submodule is known once its owner has been found at its pointer.
rel=""
submodule=""
checkout_path() {
    local path="$1" j
    rel=""
    submodule=""
    if [ "$path" = "$top_physical" ]; then
        rel=""
    elif [[ "$path" == "$top_physical"/* ]]; then
        rel="${path#"$top_physical"/}"
    else
        return 1
    fi
    for (( j = 0; j < ${#tree_path[@]}; j++ )); do
        if [ "${tree_mode[j]}" = 160000 ] &&
            { [ "$rel" = "${tree_path[j]}" ] ||
                [[ "$rel" == "${tree_path[j]}"/* ]]; }; then
            submodule="${tree_path[j]}"
            break
        fi
    done
    if [ -z "$submodule" ]; then
        return 0
    fi
    for (( j = 0; j < ${#nested_path[@]}; j++ )); do
        if [ "${#nested_path[j]}" -gt "${#submodule}" ] &&
            { [ "$rel" = "${nested_path[j]}" ] ||
                [[ "$rel" == "${nested_path[j]}"/* ]]; }; then
            submodule="${nested_path[j]}"
        fi
    done
    return 0
}

# Resolves link i of the revision as the file system would, from the
# directory holding it; or, when i is empty, the link at the physical
# path $2 among the checked-out files of submodule $3. Sets 'resolved'
# to the repository path reached, empty for the root, or
# 'resolved_outside' to 1 when the target lies outside the repository,
# and then 'resolved_dir' to 1 when it is a directory; 'followed' lists
# every link in the tree followed, the first included, and every
# submodule entered, whether or not the target lies outside. A target
# inside a submodule resolves to the submodule, whose pointer stands
# for all beneath, with 'resolved_abs' the physical path reached.
#
# Inside the repository the walk reads the revision's tree. Once a '..'
# or an absolute target leaves it, or it enters a submodule, the walk
# follows the runner's file system physically, one segment at a time,
# so that a spelling such as '/work/./repo', '//work/repo' or
# '../repo', a link outside the checkout, or a '..' out of a submodule
# cannot hide a path that re-enters the repository. Reaching the
# checkout outside any submodule resumes the walk in the tree, from its
# root; anything else lies outside. Each submodule the walk enters must
# be checked out at its pointer before its files are read, as
# submodule_trusted decides.
resolved=""
resolved_outside=0
resolved_dir=0
resolved_abs=""
followed=()
resolve_link() {
    local i="$1" current rest segment hops=0 looped=0 outside=0 abs=""
    local candidate target stuck=0 label entered="" probed is_link
    resolved=""
    resolved_outside=0
    resolved_dir=0
    resolved_abs=""
    followed=()
    current=""
    if [ -n "$i" ]; then
        label="${tree_path[i]}"
        if [[ "${tree_path[i]}" == */* ]]; then
            current="${tree_path[i]%/*}"
        fi
        rest="${tree_path[i]##*/}"
    else
        label="${2#"$top_physical"/}"
        followed=("$3")
        entered="$3"
        # A nested submodule's owners stand for it in the superproject
        nested_index "$3"
        while [ "$found" -ge 0 ]; do
            followed+=("${nested_owner[found]}")
            nested_index "${nested_owner[found]}"
        done
        outside=1
        abs="${2%/*}"
        rest="${2##*/}"
    fi
    while [ -n "$rest" ]; do
        segment="${rest%%/*}"
        if [[ "$rest" == */* ]]; then
            rest="${rest#*/}"
        else
            rest=""
        fi
        case "$segment" in
            "" | .)
                continue
                ;;
        esac
        if [ "$outside" -eq 1 ]; then
            if [ "$segment" = .. ]; then
                candidate="${abs%/*}"
            else
                candidate="$abs/$segment"
            fi
            canonical_dir "$candidate"
            candidate="$canonical"
            if checkout_path "$candidate"; then
                if [ -z "$submodule" ]; then
                    outside=0
                    current=""
                    entered=""
                    if [ -n "$rel" ]; then
                        rest="$rel${rest:+/$rest}"
                    fi
                    continue
                fi
                if [ "$submodule" != "$entered" ]; then
                    entered="$submodule"
                    followed+=("$submodule")
                    submodule_trusted "$submodule" || :
                    if [ -n "$reason" ]; then
                        return 0
                    fi
                fi
            fi
            if [ "$segment" = .. ]; then
                abs="$candidate"
                continue
            fi
            # A name that is not a link proves so only where its
            # directory can be searched, and a link only once read: a
            # failed probe is never taken for absence
            probed=1
            is_link=0
            if [ -L "$candidate" ]; then
                is_link=1
                target="$(readlink "$candidate" 2> /dev/null &&
                    printf x)" || probed=0
            elif [ ! -e "$candidate" ] &&
                ! { [ -d "${abs:-/}" ] && [ -x "${abs:-/}" ]; }; then
                probed=0
            fi
            # guard: alias-probe
            if [ "$probed" -eq 0 ]; then
                unresolve "symbolic link '$(printable "$label")' passes\
 through a directory that cannot be searched or a link that cannot be\
 read"
                return 0
            fi
            if [ "$is_link" -eq 1 ]; then
                if [ "$hops" -ge "$max_hops" ]; then
                    looped=1
                    break
                fi
                hops=$(( hops + 1 ))
                target="${target%x}"
                target="${target%$'\n'}"
                if [[ "$target" == /* ]]; then
                    abs=""
                fi
                rest="$target${rest:+/$rest}"
                continue
            fi
            abs="$candidate"
            if [ -d "$candidate" ] && [ ! -L "$candidate" ]; then
                continue
            fi
            stuck=1
            break
        fi
        if [ "$segment" = .. ]; then
            if [ -z "$current" ]; then
                outside=1
                abs="${top_physical%/*}"
            elif [[ "$current" == */* ]]; then
                current="${current%/*}"
            else
                current=""
            fi
            continue
        fi
        current="${current:+$current/}$segment"
        # guard: alias-spelling
        if ! spelling_unique "$current"; then
            unresolve "symbolic link '$(printable "$label")' reaches\
 '$(printable "$current")', which the tree spells otherwise or which\
 could not be checked"
            return 0
        fi
        tree_index "$current"
        if [ "$found" -lt 0 ]; then
            continue
        fi
        # A submodule's files are not in the tree, but its directory is
        # checked out: a '..' straight out of it lands back in the tree,
        # and its files are trusted only where they speak for the
        # revision
        if [ "${tree_mode[found]}" = 160000 ]; then
            followed+=("$current")
            entered="$current"
            submodule_trusted "$current" || :
            if [ -n "$reason" ]; then
                return 0
            fi
            outside=1
            abs="$top_physical/$current"
            continue
        fi
        if [ "$hops" -ge "$max_hops" ]; then
            looped=1
            break
        fi
        hops=$(( hops + 1 ))
        followed+=("$current")
        read_link "$found"
        if [ -n "$reason" ]; then
            return 0
        fi
        if [[ "$current" == */* ]]; then
            current="${current%/*}"
        else
            current=""
        fi
        if [[ "$link_target" == /* ]]; then
            outside=1
            abs=""
            current=""
        fi
        rest="$link_target${rest:+/$rest}"
    done
    # guard: alias-loop
    if [ "$looped" -eq 1 ]; then
        unresolve "symbolic link '$(printable "$label")' does\
 not resolve within $max_hops links"
        return 0
    fi
    if [ "$outside" -eq 0 ]; then
        resolved="$current"
        return 0
    fi
    if checkout_path "$abs" && [ -n "$submodule" ]; then
        resolved="$submodule"
        resolved_abs="$abs"
        return 0
    fi
    resolved_outside=1
    if [ "$stuck" -eq 0 ]; then
        resolved_dir=1
    fi
}

# Whether a pattern could reach a link of this logical name, so that
# it needs resolving. Links no pattern reaches cost nothing and count
# towards no cap.
reachable() {
    matches_path "$1" || matches_below "$1"
}

# Set while collecting the aliases of HEAD
checking_head=0
head_sha=""

# Whether the checked-out files of submodule $1 speak for the revision
# and so must be read; leaves the result unresolved when they would
# have to but cannot. Every path that enters a submodule asks, whether
# it reaches it directly, beneath a directory alias, or on the way to a
# file link's target. A submodule that is not initialised has no files
# for the build to read, so its pointer stands for everything beneath
# it. The base shares HEAD's checked-out files: where its pointer is
# the same they speak for it too, and where it differs the pointer's
# change counts already. A nested submodule's pointer is the one its
# owner's recorded commit holds, known only once the owner has passed
# this check, so the rule recurses.
submodule_trusted() {
    local sub="$1" root pointer="" head_pointer entries commit nested=0
    root="$top_physical/$sub"
    tree_index "$sub"
    if [ "$found" -ge 0 ]; then
        pointer="${tree_sha[found]}"
    else
        nested_index "$sub"
        if [ "$found" -ge 0 ]; then
            pointer="${nested_sha[found]}"
            nested=1
        fi
    fi
    if [ "$checking_head" -eq 0 ] && [ "$nested" -eq 0 ]; then
        head_pointer="$(git rev-parse --verify --quiet "$head_sha:$sub" \
            2> /dev/null)" || head_pointer=""
        if [ "$head_pointer" != "$pointer" ]; then
            return 1
        fi
    fi
    if [ ! -e "$root/.git" ]; then
        # A sentinel keeps the listing whole: a command substitution
        # strips trailing newlines, so a root holding only an entry
        # named by newlines would otherwise pass for an empty one
        # guard: submodule-root
        if ! entries="$(ls -A "$root" 2> /dev/null && printf x)"; then
            unresolve "submodule '$(printable "$sub")' cannot be read"
            return 1
        fi
        if [ "$entries" = x ]; then
            return 1
        fi
    fi
    commit="$(git -C "$root" rev-parse --verify --quiet HEAD \
        2> /dev/null)" || commit=""
    # guard: submodule-commit
    if { [ -z "$pointer" ] || [ "$commit" != "$pointer" ]; }; then
        unresolve "submodule '$(printable "$sub")' is not checked out\
 at its pointer"
        return 1
    fi
    load_nested "$sub" "$root" "$pointer"
    if [ -n "$reason" ]; then
        return 1
    fi
    return 0
}

# Queues the links among a submodule's checked-out files beneath the
# physical directory $2, reached under the logical name $1, for the
# submodule at $3. Its files are not in the superproject's tree, but
# the build reads them, and a link among them can lead back into the
# repository. Links inside a submodule nested in it are left to that
# submodule, which is queued in turn once it passes its own check.
# Appends to the queue and sets 'overflow' of the calling
# collect_aliases, which Bash's dynamic scoping makes visible here.
queue_submodule() {
    local name="$1" dir="$2" sub="$3" path suffix k nested_dir
    local listing="$work_dir/submodule"
    if ! submodule_trusted "$sub"; then
        return 0
    fi
    # guard: submodule-files
    if ! find "$dir" -name .git -prune -o -type l -print0 \
        > "$listing" 2> /dev/null; then
        unresolve "the files of submodule '$(printable "$sub")' cannot\
 be listed"
        return 0
    fi
    while IFS= read -r -d '' path; do
        checkout_path "$path" || :
        if [ "$submodule" != "$sub" ]; then
            continue
        fi
        suffix="${path#"$dir"/}"
        if ! reachable "$name/$suffix"; then
            continue
        fi
        if [ "${#queue_names[@]}" -ge "$max_aliases" ]; then
            overflow=1
            return 0
        fi
        queue_names+=("$name/$suffix")
        queue_links+=("")
        queue_files+=("$path")
        queue_subs+=("$sub")
    done < "$listing"
    for (( k = 0; k < ${#nested_path[@]} && overflow == 0; k++ )); do
        nested_dir="$top_physical/${nested_path[k]}"
        if [ "${nested_owner[k]}" != "$sub" ] ||
            [[ "$nested_dir" != "$dir"/* ]]; then
            continue
        fi
        suffix="${nested_dir#"$dir"/}"
        if ! reachable "$name/$suffix"; then
            continue
        fi
        queue_submodule "$name/$suffix" "$nested_dir" "${nested_path[k]}"
        if [ -n "$reason" ]; then
            return 0
        fi
    done
}

# Queues entry j of the revision's tree, a link or a submodule, reached
# under the logical name $2
queue_entry() {
    local j="$1" name="$2"
    if ! reachable "$name"; then
        return 0
    fi
    if [ "${tree_mode[j]}" = 160000 ]; then
        queue_submodule "$name" "$top_physical/${tree_path[j]}" \
            "${tree_path[j]}"
        return 0
    fi
    if [ "${#queue_names[@]}" -ge "$max_aliases" ]; then
        overflow=1
        return 0
    fi
    queue_names+=("$name")
    queue_links+=("$j")
    queue_files+=("")
    queue_subs+=("")
}

# Records the aliases of one revision. The queue holds the links a
# pattern could reach: queue_links[k] indexes the revision's tree, or
# is empty for a link at the physical path queue_files[k] among the
# checked-out files of submodule queue_subs[k].
collect_aliases() {
    local rev="$1" k=0 i j name overflow=0 suffix
    local -a queue_names=() queue_links=() queue_files=() queue_subs=()
    load_tree "$rev"
    if [ -n "$reason" ]; then
        return 0
    fi
    for (( i = 0; i < ${#tree_path[@]} && overflow == 0; i++ )); do
        queue_entry "$i" "${tree_path[i]}"
        if [ -n "$reason" ]; then
            return 0
        fi
    done
    while [ "$overflow" -eq 0 ] && [ "$k" -lt "${#queue_names[@]}" ]; do
        name="${queue_names[k]}"
        resolve_link "${queue_links[k]}" "${queue_files[k]}" \
            "${queue_subs[k]}"
        k=$(( k + 1 ))
        if [ -n "$reason" ]; then
            return 0
        fi
        # An outside target is not part of the change, but the links
        # followed to reach it are: retargeting one swaps the file
        alias_name+=("$name")
        alias_target+=("$resolved")
        alias_outside+=("$resolved_outside")
        alias_offset+=("${#alias_followed[@]}")
        alias_count+=("${#followed[@]}")
        if [ "${#followed[@]}" -gt 0 ]; then
            alias_followed+=("${followed[@]}")
        fi
        # Files beneath a directory outside the repository are not in
        # the tree, yet any of them could link back into it, so where a
        # pattern could match beneath the link nothing can be proved
        # guard: alias-outside-dir
        if [ "$resolved_dir" -eq 1 ] && matches_below "$name"; then
            unresolve "symbolic link '$(printable "$name")' reaches a\
 directory outside the repository"
            return 0
        fi
        if [ "$resolved_outside" -eq 1 ]; then
            continue
        fi
        # The links beneath a directory inside a submodule, and beneath
        # a directory in the tree, links and submodules alike, as
        # reached through the alias
        if [ -n "$resolved_abs" ]; then
            if [ -d "$resolved_abs" ]; then
                queue_submodule "$name" "$resolved_abs" "$resolved"
            fi
            if [ -n "$reason" ]; then
                return 0
            fi
            continue
        fi
        for (( j = 0; j < ${#tree_path[@]} && overflow == 0; j++ )); do
            if [ -z "$resolved" ]; then
                suffix="${tree_path[j]}"
            elif [[ "${tree_path[j]}" == "$resolved"/* ]]; then
                suffix="${tree_path[j]#"$resolved"/}"
            else
                continue
            fi
            queue_entry "$j" "$name/$suffix"
            if [ -n "$reason" ]; then
                return 0
            fi
        done
    done
    # guard: alias-count
    if [ "$overflow" -eq 1 ]; then
        unresolve "symbolic links reach more than $max_aliases paths"
        return 0
    fi
}

# Whether a changed path is a dependency file, or a directory a pattern
# could match beneath, under the logical name of an alias that reaches
# it; or a link an alias followed, or a path above an alias's target.
matches_alias() {
    local path="$1" old_mode="$2" new_mode="$3" i j target candidate
    local is_link=0
    if [ "$old_mode" = 120000 ] || [ "$new_mode" = 120000 ] ||
        [ "$old_mode" = 160000 ] || [ "$new_mode" = 160000 ]; then
        is_link=1
    fi
    for (( i = 0; i < ${#alias_name[@]}; i++ )); do
        target="${alias_target[i]}"
        candidate=""
        if [ "${alias_outside[i]}" -eq 1 ]; then
            :
        elif [ -z "$target" ]; then
            candidate="${alias_name[i]}/$path"
        elif [ "$path" = "$target" ]; then
            candidate="${alias_name[i]}"
        elif [[ "$path" == "$target"/* ]]; then
            candidate="${alias_name[i]}/${path#"$target"/}"
        elif [[ "$target" == "$path"/* ]]; then
            return 0
        fi
        if [ -n "$candidate" ]; then
            if matches_path "$candidate"; then
                return 0
            fi
            if [ "$is_link" -eq 1 ] && matches_below "$candidate"; then
                return 0
            fi
        fi
        for (( j = alias_offset[i]; j < alias_offset[i] + alias_count[i];
            j++ )); do
            if [ "${alias_followed[j]}" = "$path" ]; then
                return 0
            fi
        done
    done
    return 1
}

unresolve() {
    reason="unresolved: $1"
}

# Sets 'cwd' to the physical working directory. A command substitution
# strips trailing newlines, so a sentinel keeps a name such as
# $'/work/repo\n' intact, and only the newline pwd ends with goes.
cwd=""
physical_cwd() {
    cwd="$(pwd -P && printf x)"
    cwd="${cwd%x}"
    cwd="${cwd%$'\n'}"
}

# Canonicalises path-prefix against the repository root, walking it one
# segment at a time so that no component, the last included, may be a
# symbolic link: a change could retarget one and swap the project
# without touching any matched file.
resolve_prefix() {
    local top="$1" prefix current segment rel tracked inside=0
    local -a walk=()
    prefix="${path_prefix:-.}"
    physical_cwd
    current="$cwd"
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
            2> /dev/null | tr -d '\0' && printf x)" || tracked=""
        tracked="${tracked%x}"
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
links=()
aliased=()

detect() {
    local top="" head diff_file meta path old_mode new_mode
    top="$(git rev-parse --show-toplevel 2> /dev/null && printf x)" ||
        top=""
    top="${top%x}"
    top="${top%$'\n'}"
    # guard: not-a-checkout
    if [ -z "$top" ]; then
        unresolve "the working directory is not a git checkout"
        return 0
    fi
    top_logical="$top"
    top="$(cd -P "$top" && pwd -P && printf x)"
    top="${top%x}"
    top="${top%$'\n'}"
    top_physical="$top"
    head="$(commit_of HEAD)"
    head_sha="$head"
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
    collect_aliases "$base_sha"
    if [ -n "$reason" ]; then
        return 0
    fi
    checking_head=1
    collect_aliases "$head"
    if [ -n "$reason" ]; then
        return 0
    fi
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
        old_mode="${meta:1:6}"
        new_mode="${meta:8:6}"
        if matches_path "$path"; then
            matched+=("$path")
        # A submodule pointer is a whole directory that can bring in any
        # dependency, so it counts wherever a pattern could match
        # beneath it, as a root-level buildSrc submodule does for a
        # sub-project: over-matching is safe.
        elif { [ "$old_mode" = 160000 ] || [ "$new_mode" = 160000 ]; } &&
            matches_below "$path"; then
            submodules+=("$path")
        # A symbolic link may name a directory: retargeting buildSrc
        # swaps the build without touching a path beneath it.
        elif { [ "$old_mode" = 120000 ] || [ "$new_mode" = 120000 ]; } &&
            matches_below "$path"; then
            links+=("$path")
        elif matches_alias "$path" "$old_mode" "$new_mode"; then
            aliased+=("$path")
        fi
    done < "$diff_file"
    return 0
}

# Sets 'parent' to the directory holding path $1, as dirname would,
# without a command substitution, which would strip a trailing newline
# from a name such as $'out\n' and so check or create another path
parent=""
parent_of() {
    local path="$1"
    while [[ "$path" == */ ]] && [ "$path" != / ]; do
        path="${path%/}"
    done
    if [[ "$path" != */* ]]; then
        parent=.
        return 0
    fi
    path="${path%/*}"
    while [[ "$path" == */ ]]; do
        path="${path%/}"
    done
    parent="${path:-/}"
}

# Rejects an output whose directory passes through a symbolic link
# inside the working directory: the checkout could plant one, so that
# removing and writing the sidecar reach a file outside it, or a planted
# sidecar is read through it. The directory is walked one segment at a
# time from '/' or the working directory, tracking the physical path,
# so that no spelling ('/work/./repo', '/work/x/../repo', a link above
# the checkout) can hide where a segment lies. A link outside the
# working directory is the caller's choice and is followed, but one
# segment of its target at a time, never by 'cd -P', so that a link
# inside the checkout on the way to that target is still caught.
check_output_dir() {
    local dir rest segment current inside target hops=0
    parent_of "$output"
    dir="$parent"
    physical_cwd
    inside="$cwd"
    if [[ "$dir" == /* ]]; then
        current=""
        rest="${dir#/}"
    else
        current="$inside"
        rest="$dir"
    fi
    while [ -n "$rest" ]; do
        segment="${rest%%/*}"
        if [[ "$rest" == */* ]]; then
            rest="${rest#*/}"
        else
            rest=""
        fi
        case "$segment" in
            "" | .)
                continue
                ;;
            ..)
                current="${current%/*}"
                continue
                ;;
        esac
        if [ ! -L "$current/$segment" ]; then
            current="$current/$segment"
            # A directory that cannot be searched hides whether what
            # lies in it is a link: a failed probe is never an answer
            if [ -d "$current" ] && [ ! -x "$current" ]; then
                die "output '$(printable "$output")' passes through a\
 directory that cannot be searched"
            fi
            # Identity, not spelling, decides whether the walk has
            # reached the working directory: a file system that folds
            # case takes /work/REPO for /work/repo
            if [ "$current" != "$inside" ] && [ -d "$current" ] &&
                [ "$current" -ef "$inside" ]; then
                current="$inside"
            fi
            continue
        fi
        # guard: output-symlink
        if [ "$current" = "$inside" ] || [[ "$current" == "$inside"/* ]]
        then
            die "output '$(printable "$output")' passes through a\
 symbolic link"
        fi
        if [ "$hops" -ge "$max_hops" ]; then
            die "output '$(printable "$output")' passes through more\
 than $max_hops symbolic links"
        fi
        hops=$(( hops + 1 ))
        target="$(readlink "$current/$segment" 2> /dev/null && printf x)" ||
            die "output '$(printable "$output")' passes through a\
 symbolic link that cannot be read"
        target="${target%x}"
        target="${target%$'\n'}"
        if [[ "$target" == /* ]]; then
            current=""
        fi
        rest="$target${rest:+/$rest}"
    done
}

# The change under review must never vouch for itself, so any sidecar
# already in the checkout goes before detection starts.
remove_sidecar() {
    if [ -z "$output" ]; then
        die "output must name the sidecar path"
    fi
    check_output_dir
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
    parent_of "$output"
    dir="$parent"
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
    if [ "${#links[@]}" -gt 0 ]; then
        for item in "${links[@]}"; do
            printf 'Symbolic link changed: %s\n' "$(printable "$item")"
        done
    fi
    if [ "${#aliased[@]}" -gt 0 ]; then
        for item in "${aliased[@]}"; do
            printf 'Dependency file changed through a symbolic link: %s\n' \
                "$(printable "$item")"
        done
    fi
    count=$(( ${#matched[@]} + ${#submodules[@]} + ${#links[@]} +
        ${#aliased[@]} ))
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
