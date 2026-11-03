#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Tests scripts/dependency-change.sh against scratch git repositories:
# pull request merge commits, multi-commit pushes, Gerrit changes,
# shallow and partial clones, planted sidecars, look-alike names,
# sibling and ancestor scoping, symbolic links, and hostile file names.
#
# Usage: bash tests/dependency-change-test.sh
#   DETECT_SCRIPT  script under test; tests/mutate.sh points it at a
#                  copy with one guard disabled
#   FAIL_FAST      when non-empty, stop at the first failing case

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
script="${DETECT_SCRIPT:-$here/../scripts/dependency-change.sh}"
work="$(mktemp -d "${TMPDIR:-/tmp}/dependency-change-test.XXXXXX")"
work="$(cd "$work" && pwd -P)"
# A case that fails early can leave a directory it locked unreadable
trap 'chmod -R u+rwx "$work" 2> /dev/null; rm -rf "$work"' EXIT
failures=0
cases=0

# Keep the scratch repositories independent of the caller's git setup
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$work/gitconfig"
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
git config --global init.defaultBranch main
git config --global commit.gpgSign false
git config --global protocol.file.allow always
git config --global core.autocrlf false

echo "bash: $BASH_VERSION, git: $(git --version)"

# --- scratch repository helpers ----------------------------------------

# new_repo: an empty repository holding one commit with a README
new_repo() {
    local dir
    dir="$(mktemp -d "$work/repo.XXXXXX")"
    git init -q "$dir"
    printf 'readme\n' > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m initial
    printf '%s\n' "$dir"
}

# put <repo> <path>...: create or update each file and stage it
put() {
    local dir="$1" path
    shift
    for path in "$@"; do
        mkdir -p "$dir/$(dirname "$path")"
        printf '%s\n' "$RANDOM$RANDOM" >> "$dir/$path"
        git -C "$dir" --literal-pathspecs add -- "$path"
    done
}

commit() {
    git -C "$1" commit -q --allow-empty -m "${2:-change}"
}

sha() {
    git -C "$1" rev-parse "${2:-HEAD}"
}

# pr_repo <base-side paths> -- <change paths>: a GitHub-style merge
# commit of a topic branch into main, which has moved on meanwhile.
# Leaves HEAD on the merge commit and prints the repository path.
pr_repo() {
    local dir base=() change=() side=base path
    dir="$(new_repo)"
    for path in "$@"; do
        if [ "$path" = "--" ]; then
            side=change
        elif [ "$side" = base ]; then
            base+=("$path")
        else
            change+=("$path")
        fi
    done
    git -C "$dir" checkout -q -b topic
    if [ "${#change[@]}" -gt 0 ]; then
        put "$dir" "${change[@]}"
    fi
    commit "$dir" topic
    git -C "$dir" checkout -q main
    if [ "${#base[@]}" -gt 0 ]; then
        put "$dir" "${base[@]}"
    fi
    commit "$dir" main-moves
    git -C "$dir" checkout -q --detach main
    git -C "$dir" merge -q --no-ff -m merge topic
    printf '%s\n' "$dir"
}

# --- running the script ------------------------------------------------

out_changed="" out_reason="" out_base="" out_manifest="" out_keys=""
status=0

# Parses the heredoc-style GITHUB_OUTPUT file the way the runner does
read_outputs() {
    local file="$1" line name="" delimiter="" value=""
    out_changed="" out_reason="" out_base="" out_manifest="" out_keys=""
    while IFS= read -r line; do
        if [ -z "$name" ]; then
            name="${line%%<<*}"
            delimiter="${line#*<<}"
            value=""
            out_keys="$out_keys $name"
            continue
        fi
        if [ "$line" = "$delimiter" ]; then
            case "$name" in
                changed) out_changed="$value" ;;
                reason) out_reason="$value" ;;
                base) out_base="$value" ;;
                manifest) out_manifest="$value" ;;
            esac
            name=""
            continue
        fi
        if [ -n "$value" ]; then
            value="$value"$'\n'"$line"
        else
            value="$line"
        fi
    done < "$file"
}

# run <repo> [NAME=value...]: run the script in <repo> with only the
# given inputs and context set
run() {
    local dir="$1"
    shift
    : > "$work/output"
    status=0
    (
        unset INPUT_ECOSYSTEMS INPUT_PATTERNS INPUT_PATH_PREFIX \
            INPUT_GERRIT_REFSPEC INPUT_BASE EVENT_BEFORE \
            GITHUB_EVENT_NAME GITHUB_SHA
        export INPUT_OUTPUT=dependency-change.json
        export GITHUB_OUTPUT="$work/output"
        if [ "$#" -gt 0 ]; then
            # shellcheck disable=SC2163  # NAME=value assignments
            export "$@"
        fi
        cd "$dir"
        bash "$script"
    ) > "$work/stdout" 2> "$work/stderr" || status=$?
    read_outputs "$work/output"
}

fail() {
    printf 'FAIL: %s\n' "$1"
    sed 's/^/  stdout: /' "$work/stdout"
    sed 's/^/  stderr: /' "$work/stderr"
    failures=$((failures + 1))
    if [ -n "${FAIL_FAST:-}" ]; then
        exit 1
    fi
}

# expect <true|false> <label> <repo> [NAME=value...]
expect() {
    local want="$1" label="$2" dir="$3" sidecar
    shift 3
    cases=$((cases + 1))
    run "$dir" "$@"
    sidecar="$dir/${INPUT_OUTPUT_OVERRIDE:-dependency-change.json}"
    if [ "$status" -ne 0 ]; then
        fail "$label: exit $status, expected 0"
    elif [ "$out_changed" != "$want" ]; then
        fail "$label: changed='$out_changed', expected '$want'\
 ($out_reason)"
    elif [ ! -f "$sidecar" ] ||
        [ "$(cat "$sidecar")" != "{\"changed\": $want}" ]; then
        fail "$label: sidecar does not record $want"
    elif ! [[ "$out_base" =~ ^[0-9a-f]{40}$ ]] ||
        [ "$out_reason" != "since ${out_base:0:12}" ]; then
        fail "$label: base='$out_base' reason='$out_reason'"
    elif [ -z "$out_manifest" ]; then
        fail "$label: manifest output is empty"
    else
        echo "ok: $label"
    fi
}

# unresolved <reason substring> <label> <repo> [NAME=value...]
unresolved() {
    local want="$1" label="$2" dir="$3"
    shift 3
    cases=$((cases + 1))
    run "$dir" "$@"
    if [ "$status" -ne 0 ]; then
        fail "$label: exit $status, expected 0"
    elif [ -n "$out_changed" ] || [ -n "$out_base" ] ||
        [ -n "$out_manifest" ]; then
        fail "$label: changed='$out_changed' base='$out_base'\
 manifest='$out_manifest', expected all empty"
    elif [ "$out_keys" != " changed reason base manifest" ]; then
        fail "$label: outputs were '$out_keys'"
    elif [ -e "$dir/dependency-change.json" ] ||
        [ -L "$dir/dependency-change.json" ]; then
        fail "$label: a sidecar exists"
    elif [[ "$out_reason" != "unresolved: "*"$want"* ]]; then
        fail "$label: reason '$out_reason' lacks '$want'"
    else
        echo "ok: $label"
    fi
}

# rejects <label> <repo> [NAME=value...]: invalid inputs fail the step
rejects() {
    local label="$1" dir="$2"
    shift 2
    cases=$((cases + 1))
    run "$dir" "$@"
    if [ "$status" -eq 0 ]; then
        fail "$label: exit 0, expected a failure"
    elif [ -f "$dir/dependency-change.json" ]; then
        fail "$label: a sidecar exists"
    elif [ -n "$out_changed" ]; then
        fail "$label: changed='$out_changed'"
    else
        echo "ok: $label"
    fi
}

# pr_case <want> <label> <ecosystems> <prefix> <base paths> -- <paths>
# The prefix "." is the repository root
pr_case() {
    local want="$1" label="$2" eco="$3" prefix="$4" dir
    shift 4
    # The project directory exists on the base branch
    if [ "$prefix" != . ]; then
        set -- "${prefix%/}/src.txt" "$@"
    fi
    dir="$(pr_repo "$@")"
    expect "$want" "$label" "$dir" GITHUB_EVENT_NAME=pull_request \
        GITHUB_SHA="$(sha "$dir")" INPUT_ECOSYSTEMS="$eco" \
        INPUT_PATH_PREFIX="$prefix"
}

# --- not a checkout ----------------------------------------------------

mkdir "$work/plain"
unresolved "not a git checkout" "plain directory" "$work/plain" \
    GITHUB_EVENT_NAME=pull_request INPUT_ECOSYSTEMS=node
git init -q "$work/unborn"
unresolved "HEAD is not a commit" "repository with no commits" \
    "$work/unborn" GITHUB_EVENT_NAME=pull_request INPUT_ECOSYSTEMS=node

# --- pull requests -----------------------------------------------------

pr_case true "pull request touching package.json" node . -- package.json
pr_case false "pull request touching only docs" node . -- docs/guide.md
pr_case false "base branch moved package.json; the change did not" \
    node . package.json -- docs/guide.md

dir="$(new_repo)"
put "$dir" package.json
commit "$dir"
git -C "$dir" mv package.json package.json.old
commit "$dir"
expect true "rename away from a dependency file counts" "$dir" \
    INPUT_ECOSYSTEMS=node INPUT_BASE=HEAD~1
git -C "$dir" rm -q package.json.old
put "$dir" Cargo.lock
commit "$dir"
git -C "$dir" rm -q Cargo.lock
commit "$dir"
expect true "deleted dependency file counts" "$dir" \
    INPUT_ECOSYSTEMS=rust INPUT_BASE=HEAD~1

dir="$(pr_repo -- package.json)"
unresolved "HEAD is not GITHUB_SHA" "checkout of another ref" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir" HEAD^1)" \
    INPUT_ECOSYSTEMS=node
unresolved "HEAD is not GITHUB_SHA" "GITHUB_SHA unset" "$dir" \
    GITHUB_EVENT_NAME=pull_request INPUT_ECOSYSTEMS=node

# Shallow clones: depth 2 holds the base, depth 1 does not
src="$(pr_repo -- package.json)"
git -C "$src" branch -q merged HEAD
shallow="$work/shallow1"
git clone -q --depth 1 --branch merged "file://$src" "$shallow"
unresolved "HEAD^1 is not in the checkout" "depth 1 pull request" \
    "$shallow" GITHUB_EVENT_NAME=pull_request \
    GITHUB_SHA="$(sha "$shallow")" INPUT_ECOSYSTEMS=node
shallow="$work/shallow2"
git clone -q --depth 2 --branch merged "file://$src" "$shallow"
expect true "depth 2 pull request" "$shallow" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$shallow")" \
    INPUT_ECOSYSTEMS=node

# A partial clone holds the base commit but not its tree. Dropping the
# promisor remote keeps the test offline on any git version.
git -C "$src" config uploadpack.allowFilter true
partial="$work/partial"
git clone -q --filter=tree:0 --branch merged "file://$src" "$partial"
git -C "$partial" remote remove origin
unresolved "has no tree" "partial clone without the base tree" \
    "$partial" GITHUB_EVENT_NAME=pull_request \
    GITHUB_SHA="$(sha "$partial")" INPUT_ECOSYSTEMS=node

# The base tree is present but a subtree the diff needs is not
dir="$(new_repo)"
put "$dir" app/lib/a.txt
commit "$dir"
put "$dir" app/lib/a.txt
commit "$dir"
tree="$(git -C "$dir" rev-parse HEAD~1:app/lib)"
rm -f "$dir/.git/objects/${tree:0:2}/${tree:2}"
unresolved "git diff" "diff fails on a missing object" "$dir" \
    INPUT_ECOSYSTEMS=node INPUT_BASE=HEAD~1

# --- pushes ------------------------------------------------------------

dir="$(new_repo)"
before="$(sha "$dir")"
put "$dir" package-lock.json
commit "$dir"
put "$dir" docs/guide.md
commit "$dir"
expect true "multi-commit push covers every pushed commit" "$dir" \
    GITHUB_EVENT_NAME=push GITHUB_SHA="$(sha "$dir")" \
    EVENT_BEFORE="$before" INPUT_ECOSYSTEMS=node
expect false "push of the last commit only" "$dir" \
    GITHUB_EVENT_NAME=push GITHUB_SHA="$(sha "$dir")" \
    EVENT_BEFORE="$(sha "$dir" HEAD^1)" INPUT_ECOSYSTEMS=node
unresolved "created the branch" "push creating a branch" "$dir" \
    GITHUB_EVENT_NAME=push GITHUB_SHA="$(sha "$dir")" \
    EVENT_BEFORE=0000000000000000000000000000000000000000 \
    INPUT_ECOSYSTEMS=node
unresolved "no 'before' commit" "push without before" "$dir" \
    GITHUB_EVENT_NAME=push GITHUB_SHA="$(sha "$dir")" \
    INPUT_ECOSYSTEMS=node
unresolved "no 'before' commit" "push with a symbolic before" "$dir" \
    GITHUB_EVENT_NAME=push GITHUB_SHA="$(sha "$dir")" \
    EVENT_BEFORE=HEAD~2 INPUT_ECOSYSTEMS=node
unresolved "is not in the checkout" "push before missing" "$dir" \
    GITHUB_EVENT_NAME=push GITHUB_SHA="$(sha "$dir")" \
    EVENT_BEFORE=1234567890abcdef1234567890abcdef12345678 \
    INPUT_ECOSYSTEMS=node
unresolved "HEAD is not GITHUB_SHA" "push of another ref" "$dir" \
    GITHUB_EVENT_NAME=push GITHUB_SHA="$before" \
    EVENT_BEFORE="$before" INPUT_ECOSYSTEMS=node

# --- other events ------------------------------------------------------

for event in schedule workflow_dispatch merge_group \
    pull_request_target ""; do
    unresolved "no base for" "event '${event:-none}'" "$dir" \
        GITHUB_EVENT_NAME="$event" GITHUB_SHA="$(sha "$dir")" \
        EVENT_BEFORE="$before" INPUT_ECOSYSTEMS=node
done

# --- Gerrit and explicit bases -----------------------------------------

expect false "Gerrit change compares with its parent" "$dir" \
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_SHA="$before" \
    INPUT_GERRIT_REFSPEC=refs/changes/01/1/1 INPUT_ECOSYSTEMS=node
git -C "$dir" branch -q gerrit HEAD~1
shallow="$work/gerrit1"
git clone -q --depth 1 --branch gerrit "file://$dir" "$shallow"
unresolved "HEAD^1 is not in the checkout" "depth 1 Gerrit change" \
    "$shallow" GITHUB_EVENT_NAME=workflow_dispatch \
    INPUT_GERRIT_REFSPEC=refs/changes/01/1/1 INPUT_ECOSYSTEMS=node
expect true "explicit base overrides event detection" "$dir" \
    GITHUB_EVENT_NAME=schedule INPUT_BASE="$before" \
    INPUT_GERRIT_REFSPEC=refs/changes/01/1/1 INPUT_ECOSYSTEMS=node
expect true "explicit base as a revision" "$dir" \
    INPUT_BASE=HEAD~2 INPUT_ECOSYSTEMS=node
unresolved "is not a commit in the checkout" "explicit base missing" \
    "$dir" GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
    INPUT_BASE=no-such-ref INPUT_ECOSYSTEMS=node
cases=$((cases + 1))
run "$dir" INPUT_BASE=--all INPUT_ECOSYSTEMS=node
if [ "$out_reason" = "unresolved: base '--all' is not a commit" ] &&
    [ -z "$out_changed" ]; then
    echo "ok: explicit base that looks like an option"
else
    fail "explicit base that looks like an option: '$out_reason'"
fi

# --- planted sidecars --------------------------------------------------

dir="$(new_repo)"
printf '{"changed": false}\n' > "$dir/dependency-change.json"
git -C "$dir" add -A
commit "$dir"
unresolved "no base for" "planted sidecar removed when unresolved" \
    "$dir" GITHUB_EVENT_NAME=schedule INPUT_ECOSYSTEMS=node
printf 'keep\n' > "$work/target"
ln -s "$work/target" "$dir/dependency-change.json"
unresolved "no base for" "planted symbolic link removed" "$dir" \
    GITHUB_EVENT_NAME=schedule INPUT_ECOSYSTEMS=node
cases=$((cases + 1))
if [ "$(cat "$work/target")" = keep ]; then
    echo "ok: symbolic link target left alone"
else
    fail "symbolic link target was written"
fi
mkdir "$dir/dependency-change.json"
rejects "sidecar path is a directory" "$dir" \
    GITHUB_EVENT_NAME=schedule INPUT_ECOSYSTEMS=node
rmdir "$dir/dependency-change.json"

dir="$(pr_repo -- package.json)"
INPUT_OUTPUT_OVERRIDE=out/nested/deps.json expect true \
    "sidecar written to a new directory" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
    INPUT_ECOSYSTEMS=node INPUT_OUTPUT=out/nested/deps.json

# A directory on the output's path may not be a symbolic link, at any
# depth: removing or writing the sidecar would follow it out of the
# checkout. The step fails, and the file beyond the link survives.
mkdir -p "$work/outside"
printf 'keep\n' > "$work/outside/deps.json"
dir="$(new_repo)"
ln -s "$work/outside" "$dir/out"
mkdir -p "$dir/real"
ln -s "$work/outside" "$dir/real/nested"
# Absolute spellings of the same path reach the checkout's 'out' link
# through '.', '..', '//' and a link above the checkout
mkdir -p "$work/dotdot"
ln -s "$dir" "$work/alias"
# ...and through links outside the checkout that target the 'out' link
# itself, absolutely, relatively, or by way of another outside link
ln -s "$dir/out" "$work/out-alias"
ln -s "${dir##*/}/out" "$work/out-relative"
ln -s out-alias "$work/out-chain"
for output in out/deps.json real/nested/deps.json ./out/deps.json \
    "$dir/out/deps.json" "${dir%/*}/./${dir##*/}/out/deps.json" \
    "${dir%/*}/dotdot/../${dir##*/}/out/deps.json" "/$dir//out/deps.json" \
    "$work/alias/out/deps.json" real/../out/deps.json \
    "$work/out-alias/deps.json" "$work/out-relative/deps.json" \
    "$work/out-chain/deps.json"; do
    rejects "output through a symbolic link: $output" "$dir" \
        GITHUB_EVENT_NAME=schedule INPUT_ECOSYSTEMS=node \
        INPUT_OUTPUT="$output"
    cases=$((cases + 1))
    if [ "$(cat "$work/outside/deps.json")" = keep ]; then
        echo "ok: file beyond the link left alone: $output"
    else
        fail "file beyond the link was changed: $output"
        printf 'keep\n' > "$work/outside/deps.json"
    fi
done
ln -s out-loop "$work/out-loop"
rejects "output through a symbolic link loop" "$dir" \
    GITHUB_EVENT_NAME=schedule INPUT_ECOSYSTEMS=node \
    INPUT_OUTPUT="$work/out-loop/deps.json"

# A directory name ending in a newline is checked, removed through and
# created as spelt, not as the same name with the newline stripped
mkdir -p "$work/outside-nl"
printf 'keep\n' > "$work/outside-nl/deps.json"
dir="$(pr_repo -- package.json)"
ln -s "$work/outside-nl" "$dir/out"$'\n'
rejects "output through a symbolic link whose name ends in a newline" \
    "$dir" GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
    INPUT_ECOSYSTEMS=node INPUT_OUTPUT="out"$'\n'"/deps.json"
cases=$((cases + 1))
if [ "$(cat "$work/outside-nl/deps.json")" = keep ]; then
    echo "ok: file beyond a link whose name ends in a newline left alone"
else
    fail "file beyond a link whose name ends in a newline was changed"
fi
INPUT_OUTPUT_OVERRIDE="new"$'\n'"/deps.json" expect true \
    "sidecar written to a new directory whose name ends in a newline" \
    "$dir" GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
    INPUT_ECOSYSTEMS=node INPUT_OUTPUT="new"$'\n'"/deps.json"

# A working directory, and a prefix, whose names end in a newline are
# used as spelt: capturing either without a sentinel strips the newline
# and checks another path than the one removed through
nl_dir="$work/checkout"$'\n'
git init -q "$nl_dir"
put "$nl_dir" README.md app/src.txt
mkdir "$nl_dir/app"$'\n'
put "$nl_dir" "app"$'\n'"/src.txt"
commit "$nl_dir"
put "$nl_dir" package.json app/package.json "app"$'\n'"/package.json"
commit "$nl_dir"
mkdir -p "$work/outside-wd"
printf 'keep\n' > "$work/outside-wd/deps.json"
ln -s "$work/outside-wd" "$nl_dir/out"
rejects "output through a link in a working directory ending in a newline" \
    "$nl_dir" INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node \
    INPUT_OUTPUT=out/deps.json
cases=$((cases + 1))
if [ "$(cat "$work/outside-wd/deps.json")" = keep ]; then
    echo "ok: file beyond a link in a working directory ending in a newline"
else
    fail "file beyond a link in a working directory ending in a newline\
 was changed"
fi
rm "$nl_dir/out"
expect true "working directory ending in a newline" "$nl_dir" \
    INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node
expect true "prefix in a working directory ending in a newline" \
    "$nl_dir" INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX=app
expect true "prefix ending in a newline" "$nl_dir" INPUT_BASE=HEAD~1 \
    INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX="app"$'\n'

# A directory on the output's path that cannot be searched could hide
# a symbolic link, so it fails the step
if [ "$(id -u)" -ne 0 ]; then
    dir="$(pr_repo -- package.json)"
    mkdir "$dir/locked"
    chmod a-x "$dir/locked"
    rejects "output in a directory that cannot be searched" "$dir" \
        GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
        INPUT_ECOSYSTEMS=node INPUT_OUTPUT=locked/deps.json
    cases=$((cases + 1))
    if grep -q 'cannot be searched' "$work/stderr"; then
        echo "ok: output check names the directory it cannot search"
    else
        fail "output check did not reject the directory it cannot search"
    fi
    chmod u+x "$dir/locked"
else
    echo "skip: output in a directory that cannot be searched (root)"
fi

# An absolute output outside the working directory is the caller's
dir="$(pr_repo -- package.json)"
cases=$((cases + 1))
run "$dir" GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
    INPUT_ECOSYSTEMS=node INPUT_OUTPUT="$work/elsewhere/deps.json"
if [ "$status" -eq 0 ] && [ "$out_changed" = true ] &&
    [ "$(cat "$work/elsewhere/deps.json")" = '{"changed": true}' ]; then
    echo "ok: absolute output outside the checkout"
else
    fail "absolute output outside the checkout: exit $status"
fi

# ...and so is a symbolic link outside it
mkdir -p "$work/elsewhere-target"
ln -s "$work/elsewhere-target" "$work/elsewhere-link"
cases=$((cases + 1))
run "$dir" GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
    INPUT_ECOSYSTEMS=node INPUT_OUTPUT="$work/elsewhere-link/deps.json"
if [ "$status" -eq 0 ] && [ "$out_changed" = true ] &&
    [ "$(cat "$work/elsewhere-target/deps.json")" = '{"changed": true}' ]
then
    echo "ok: output through a symbolic link outside the checkout"
else
    fail "output through a symbolic link outside the checkout:\
 exit $status"
fi

# --- look-alike names --------------------------------------------------

pr_case false "look-alike names do not match" node,python,go . -- \
    package.json.bak my-package.json package.jsonx docs/package.json.md \
    requirements.txt.orig go.mod.tmpl vendor/modules.txt.old \
    old-pyproject.toml
pr_case false "single-segment star" python . -- \
    requirements/extra/dev.txt
pr_case true "requirements directory" python . -- requirements/dev.txt

# --- scoping -----------------------------------------------------------

pr_case false "sibling project" node app -- other/package.json
pr_case false "prefix look-alike directory" node app -- apps/package.json
pr_case true "workspace root lock file" node app -- package-lock.json
pr_case true "inside the prefix at any depth" node app -- \
    app/sub/deep/package.json
pr_case true "intermediate ancestor" node services/api -- \
    services/package.json
pr_case false "sibling under a shared parent" node services/api -- \
    services/web/package.json
pr_case true "prefix with a trailing slash" node app/ -- app/package.json
pr_case true "prefix through dot segments" node ./app/../app -- \
    app/package.json

# Anchored paths and directories above the prefix
pr_case true "version catalogue above a sub-project" gradle app -- \
    gradle/libs.versions.toml
pr_case false "version catalogue in a sibling" gradle app -- \
    other/gradle/libs.versions.toml
pr_case true "version catalogue inside the prefix" gradle app -- \
    app/gradle/libs.versions.toml
pr_case true "version catalogue at an intermediate ancestor" gradle \
    services/api -- services/gradle/libs.versions.toml
pr_case true "buildSrc above a sub-project" gradle app -- \
    buildSrc/src/main/kotlin/Deps.kt
pr_case false "buildSrc in a sibling" gradle app -- \
    other/buildSrc/src/main/kotlin/Deps.kt
pr_case true "build-logic inside the prefix" gradle app -- \
    app/build-logic/settings.gradle.kts
pr_case false "directory pattern needs a directory" gradle . -- \
    mybuildSrc/Deps.kt buildSrc.md
pr_case true "dependency lock directory" gradle . -- \
    gradle/dependency-locks/compile.lockfile

# --- path-prefix canonicalisation --------------------------------------

dir="$(pr_repo -- app/package.json)"
ln -s app "$dir/link"
ln -s ../other "$dir/app/inner"
mkdir -p "$dir/other" "$dir/untracked"
merge="$(sha "$dir")"
for prefix in link app/inner link/; do
    unresolved "symbolic link" "symbolic link prefix '$prefix'" "$dir" \
        GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$merge" \
        INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX="$prefix"
done
unresolved "leaves the checkout" "prefix above the checkout" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$merge" \
    INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX=..
unresolved "leaves the checkout" "absolute prefix elsewhere" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$merge" \
    INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX="$work"
unresolved "not an existing directory" "missing prefix" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$merge" \
    INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX=nope
unresolved "tracked at HEAD" "untracked prefix" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$merge" \
    INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX=untracked
unresolved "" "mis-cased prefix" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$merge" \
    INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX=App
expect true "absolute prefix inside the checkout" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$merge" \
    INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX="$dir/app"
expect true "empty prefix is the root" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$merge" \
    INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX=

# --- hostile names -----------------------------------------------------

forged=$'x\n::error::forged\n::set-output name=changed::false'
dir="$(pr_repo -- "$forged/package.json" "::warning::y/package.json" \
    "##[error]forged/package.json" "z ##[stop-commands]tok/package.json")"
expect true "names with newlines and workflow commands" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
    INPUT_ECOSYSTEMS=node
cases=$((cases + 1))
# The runner reads '::' commands at the start of a line, and the legacy
# '##[' marker anywhere on it
if grep -q -e '^::' -e '##\[' "$work/stdout" "$work/stderr"; then
    fail "a log line carries a workflow command"
elif [ "$out_keys" != " changed reason base manifest" ]; then
    fail "outputs were '$out_keys'"
elif [ "$(grep -c 'Dependency file changed:' "$work/stdout")" -ne 4 ]
then
    fail "expected one log line per matched file"
else
    echo "ok: no workflow command forged"
fi

# --- presets and patterns ----------------------------------------------

# Every pattern of every preset, as the design table lists them,
# matches a file instantiated from it inside a sub-project
preset_table() {
    case "$1" in
        node) echo package.json package-lock.json npm-shrinkwrap.json \
            yarn.lock .yarnrc.yml pnpm-lock.yaml pnpm-workspace.yaml \
            bun.lock bun.lockb ;;
        python) echo pyproject.toml uv.lock poetry.lock pdm.lock Pipfile \
            Pipfile.lock setup.py setup.cfg 'requirements*.txt' \
            'requirements/*.txt' 'constraints*.txt' tox.ini ;;
        go) echo go.mod go.sum go.work go.work.sum vendor/modules.txt ;;
        maven) echo pom.xml .mvn/extensions.xml .mvn/maven.config ;;
        gradle) echo build.gradle build.gradle.kts settings.gradle \
            settings.gradle.kts gradle.properties 'gradle/*.versions.toml' \
            gradle.lockfile settings-gradle.lockfile \
            gradle/dependency-locks/ buildSrc/ build-logic/ ;;
        rust) echo Cargo.toml Cargo.lock .cargo/config.toml \
            .cargo/config ;;
        docker) echo Dockerfile 'Dockerfile.*' '*.Dockerfile' \
            '*.dockerfile' Containerfile 'Containerfile.*' ;;
    esac
}

set -f
for preset in node python go maven gradle rust docker; do
    for pattern in $(preset_table "$preset"); do
        path="${pattern//\*/x}"
        if [[ "$path" == */ ]]; then
            path="${path}file.txt"
        fi
        pr_case true "preset $preset matches $path" "$preset" sub -- \
            "sub/$path"
    done
    pr_case false "preset $preset ignores docs" "$preset" . -- \
        docs/guide.md
done
set +f

dir="$(pr_repo -- deps/a.lock)"
expect true "patterns alone" "$dir" GITHUB_EVENT_NAME=pull_request \
    GITHUB_SHA="$(sha "$dir")" INPUT_PATTERNS='deps/*.lock'
dir="$(pr_repo -- deps/x/a.lock extra.txtx)"
expect false "patterns alone, no match" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
    INPUT_PATTERNS=$'deps/*.lock\n\n  extra.txt  \r'
dir="$(pr_repo -- extra.txt)"
expect true "patterns trimmed, blank lines skipped" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
    INPUT_PATTERNS=$'deps/*.lock\n\n  extra.txt  \r'
expect true "patterns added to presets" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
    INPUT_ECOSYSTEMS=node INPUT_PATTERNS=extra.txt
dir="$(pr_repo -- go.sum)"
expect true "ecosystem list with spaces" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
    INPUT_ECOSYSTEMS=$' node , go,,\npython'

# Characters Bash reads as extended glob operators match literally
for name in 'deps+(internal).lock' '@(a|b).lock' '!(x).lock' \
    'lib*(x).lock'; do
    dir="$(pr_repo -- "$name")"
    expect true "pattern '$name' matches its literal name" "$dir" \
        GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
        INPUT_PATTERNS="$name"
done
dir="$(pr_repo -- depsinternal.lock a.lock y.lock libxx.lock)"
for name in 'deps+(internal).lock' '@(a|b).lock' '!(x).lock' \
    'lib*(x).lock'; do
    expect false "pattern '$name' is no extended glob" "$dir" \
        GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
        INPUT_PATTERNS="$name"
done
dir="$(pr_repo -- 'libv1(x).lock')"
expect true "star before a literal parenthesis" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
    INPUT_PATTERNS='lib*(x).lock'

# --- invalid inputs ----------------------------------------------------

dir="$(pr_repo -- package.json)"
merge="$(sha "$dir")"
rejects "unknown ecosystem" "$dir" GITHUB_EVENT_NAME=pull_request \
    GITHUB_SHA="$merge" INPUT_ECOSYSTEMS=node,cobol
rejects "neither ecosystems nor patterns" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$merge"
for pattern in '**/package.json' /package.json 'a/../b' 'a/./b' \
    'req[0-9].txt' 'file?.txt' 'a//b' 'back\slash'; do
    rejects "invalid pattern '$pattern'" "$dir" \
        GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$merge" \
        INPUT_PATTERNS="$pattern"
done
rejects "empty output path" "$dir" GITHUB_EVENT_NAME=pull_request \
    GITHUB_SHA="$merge" INPUT_ECOSYSTEMS=node INPUT_OUTPUT=

# --- submodules --------------------------------------------------------

lib="$(new_repo)"
dir="$(new_repo)"
git -C "$dir" submodule -q add "file://$lib" app/vendor/lib 2> /dev/null
git -C "$dir" submodule -q add "file://$lib" other/lib 2> /dev/null
commit "$dir"
sub_base="$(sha "$dir")"
put "$lib" more.txt
commit "$lib"
git -C "$dir/app/vendor/lib" pull -q origin main 2> /dev/null
git -C "$dir" add app/vendor/lib
commit "$dir"
expect true "submodule pointer inside the prefix" "$dir" \
    INPUT_BASE="$sub_base" INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX=app
git -C "$dir" config diff.ignoreSubmodules all
expect true "submodule pointer despite diff.ignoreSubmodules" "$dir" \
    INPUT_BASE="$sub_base" INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX=app
expect false "submodule pointer outside the prefix" "$dir" \
    INPUT_BASE="$sub_base" INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX=other

# A submodule above the prefix counts where an anchored pattern reaches
# it, as a root-level buildSrc does for a Gradle sub-project
# submodule_case <want> <label> <prefix> <submodule path>
submodule_case() {
    local want="$1" label="$2" prefix="$3" path="$4" dir
    dir="$(new_repo)"
    put "$dir" app/src.txt
    git -C "$dir" submodule -q add "file://$lib" "$path" 2> /dev/null
    git -C "$dir" -C "$path" checkout -q HEAD~1
    git -C "$dir" add -- "$path"
    commit "$dir"
    git -C "$dir" -C "$path" checkout -q main
    git -C "$dir" add -- "$path"
    commit "$dir"
    expect "$want" "$label" "$dir" INPUT_BASE=HEAD~1 \
        INPUT_ECOSYSTEMS=gradle INPUT_PATH_PREFIX="$prefix"
}
submodule_case true "buildSrc submodule above a sub-project" app buildSrc
submodule_case true "gradle submodule reaching a version catalogue" app \
    gradle
submodule_case false "buildSrc submodule in a sibling" app other/buildSrc
submodule_case false "unrelated submodule above a sub-project" app docs

# --- symbolic links ----------------------------------------------------

# link_case <want> <label> <prefix> <link>: retarget a symbolic link
# between two commits, with the gradle preset
link_case() {
    local want="$1" label="$2" prefix="$3" link="$4" dir
    dir="$(new_repo)"
    put "$dir" app/src.txt
    mkdir -p "$dir/$(dirname "$link")"
    ln -s "$work/one" "$dir/$link"
    git -C "$dir" --literal-pathspecs add -- "$link"
    commit "$dir"
    rm "$dir/$link"
    ln -s "$work/two" "$dir/$link"
    git -C "$dir" --literal-pathspecs add -- "$link"
    commit "$dir"
    expect "$want" "$label" "$dir" INPUT_BASE=HEAD~1 \
        INPUT_ECOSYSTEMS=gradle INPUT_PATH_PREFIX="$prefix"
}

link_case true "buildSrc link retargeted above a sub-project" app \
    buildSrc
link_case true "buildSrc link retargeted at the root" . buildSrc
link_case true "gradle link reaching a version catalogue" app gradle
link_case true "dependency-locks link" . gradle/dependency-locks
link_case true "any link inside the prefix" app app/lib
link_case false "buildSrc link in a sibling" app other/buildSrc
link_case false "unrelated link above a sub-project" app docs
link_case false "look-alike link name" app buildSrcx

# --- symbolic link aliases ---------------------------------------------

# mklink <repo> <target> <link>: create or retarget a link and stage it
mklink() {
    local dir="$1" target="$2" link="$3"
    mkdir -p "$dir/$(dirname "$link")"
    rm -f "$dir/$link"
    ln -s "$target" "$dir/$link"
    git -C "$dir" --literal-pathspecs add -- "$link"
}

# alias_repo <link target> <link> [<target>...]: a repository whose
# first commit holds an app directory, the link, and the given files;
# the caller commits the change under test
alias_repo() {
    local dir target="$1" link="$2"
    shift 2
    dir="$(new_repo)"
    put "$dir" app/src.txt "$@"
    mklink "$dir" "$target" "$link"
    commit "$dir"
    printf '%s\n' "$dir"
}

# alias_expect <want> <label> <repo> <ecosystems> <prefix>
alias_expect() {
    commit "$3"
    expect "$1" "$2" "$3" INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS="$4" \
        INPUT_PATH_PREFIX="$5"
}

# An unchanged link makes a change to its target a dependency change
dir="$(alias_repo manifests/node.json package.json manifests/node.json)"
put "$dir" manifests/node.json
alias_expect true "target of an unchanged package.json link" "$dir" \
    node .
dir="$(alias_repo ../manifests/node.json app/package.json \
    manifests/node.json)"
put "$dir" manifests/node.json
alias_expect true "link target above a sub-project" "$dir" node app
dir="$(alias_repo manifests/node.json notes.md manifests/node.json)"
put "$dir" manifests/node.json
alias_expect false "target of an unrelated link" "$dir" node .
dir="$(alias_repo manifests/node.json app/package.json \
    manifests/node.json)"
put "$dir" manifests/node.json
alias_expect false "link resolved from its own directory" "$dir" \
    node app
dir="$(alias_repo ../../outside/node.json package.json)"
put "$dir" README.md
alias_expect false "link leaving the repository" "$dir" node .

# Chains of links and links on the target's path
dir="$(alias_repo a.json package.json manifests/node.json)"
mklink "$dir" manifests/node.json a.json
commit "$dir"
put "$dir" manifests/node.json
alias_expect true "target at the end of a link chain" "$dir" node .
dir="$(alias_repo m/node.json package.json manifests/node.json)"
mklink "$dir" manifests m
commit "$dir"
put "$dir" manifests/node.json
alias_expect true "target through a directory link" "$dir" node .
dir="$(alias_repo ../cur/node.json app/package.json v1/node.json \
    v2/node.json)"
mklink "$dir" v1 cur
commit "$dir"
mklink "$dir" v2 cur
alias_expect true "link on the target's path retargeted" "$dir" node app
dir="$(alias_repo manifests/node.json package.json manifests/node.json)"
git -C "$dir" rm -q manifests/node.json
alias_expect true "link target deleted" "$dir" node .
dir="$(new_repo)"
put "$dir" app/src.txt manifests/node.json
mklink "$dir" "$dir/manifests/node.json" package.json
commit "$dir"
put "$dir" manifests/node.json
alias_expect true "absolute link into the checkout" "$dir" node .

# Directory links, and links beneath a directory link's target
dir="$(alias_repo shared/build-src buildSrc shared/build-src/Deps.kt \
    shared/other.txt)"
put "$dir" shared/build-src/Deps.kt
alias_expect true "file beneath a buildSrc link's target" "$dir" \
    gradle app
put "$dir" shared/other.txt
alias_expect false "file beside a buildSrc link's target" "$dir" \
    gradle app
dir="$(alias_repo shared buildSrc real/Deps.kt)"
mklink "$dir" ../real shared/deps
commit "$dir"
put "$dir" real/Deps.kt
alias_expect true "link beneath a buildSrc link's target" "$dir" \
    gradle app
dir="$(alias_repo ../vendor/lib/package.json app/package.json)"
git -C "$dir" submodule -q add "file://$lib" vendor/lib 2> /dev/null
git -C "$dir" -C vendor/lib checkout -q HEAD~1
git -C "$dir" add -- vendor/lib
commit "$dir"
git -C "$dir" -C vendor/lib checkout -q main
git -C "$dir" add -- vendor/lib
alias_expect true "link into a submodule whose pointer moved" "$dir" \
    node app

# A walk through a submodule continues in its checked-out files, and a
# '..' or a link there that leads back into the repository resumes in
# the tree. sub_walk_case <want> <label> <target> <changed path>, with
# the submodule at vendor/lib holding node.json -> ../manifests/node.json
linklib="$(new_repo)"
put "$linklib" sub/a.txt
ln -s ../manifests/node.json "$linklib/node.json"
git -C "$linklib" add -A
commit "$linklib"
sub_walk_case() {
    local want="$1" label="$2" target="$3" changed="$4" dir
    dir="$(alias_repo "$target" app/package.json \
        vendor/manifests/node.json vendor/other.txt)"
    git -C "$dir" submodule -q add "file://$linklib" vendor/lib \
        2> /dev/null
    commit "$dir"
    put "$dir" "$changed"
    alias_expect "$want" "$label" "$dir" node app
}
sub_walk_case true "target leaving a submodule by '..'" \
    ../vendor/lib/../manifests/node.json vendor/manifests/node.json
sub_walk_case true "target leaving a submodule's directory by '..'" \
    ../vendor/lib/sub/../../manifests/node.json vendor/manifests/node.json
sub_walk_case true "target through a link inside a submodule" \
    ../vendor/lib/node.json vendor/manifests/node.json
sub_walk_case false "file beside a target leaving a submodule" \
    ../vendor/lib/../manifests/node.json vendor/other.txt

# Links among an initialised submodule's files are resolved under the
# name a pattern sees, whether the submodule is reached directly or
# through a link. catalog_lib <link target>: a library holding
# libs.versions.toml -> <link target>, a locked/ directory, and a
# second commit
catalog_lib() {
    local lib
    lib="$(new_repo)"
    put "$lib" locked/a.txt
    ln -s "$1" "$lib/libs.versions.toml"
    git -C "$lib" add -A
    commit "$lib"
    put "$lib" more.txt
    commit "$lib"
    printf '%s\n' "$lib"
}
via_lib="$(catalog_lib ../../manifests/deps.toml)"
root_lib="$(catalog_lib ../manifests/deps.toml)"
# catalog_repo <library> <submodule path> [<link target> <link>]: a
# repository holding app/, manifests/deps.toml and the submodule, and
# the link when given; the caller commits the change under test
catalog_repo() {
    local dir
    dir="$(new_repo)"
    put "$dir" app/src.txt manifests/deps.toml manifests/other.toml
    git -C "$dir" submodule -q add "file://$1" "$2" 2> /dev/null
    if [ "$#" -gt 2 ]; then
        mklink "$dir" "$3" "$4"
    fi
    commit "$dir"
    printf '%s\n' "$dir"
}
dir="$(catalog_repo "$via_lib" vendor/lib vendor/lib gradle)"
put "$dir" manifests/deps.toml
alias_expect true "catalogue link in a submodule behind a gradle link" \
    "$dir" gradle app
put "$dir" manifests/other.toml
alias_expect false "file beside a catalogue in a linked submodule" \
    "$dir" gradle app
dir="$(catalog_repo "$root_lib" gradle)"
put "$dir" manifests/deps.toml
alias_expect true "catalogue link in a gradle submodule" "$dir" \
    gradle app
dir="$(catalog_repo "$via_lib" shared/lib shared buildSrc)"
put "$dir" manifests/deps.toml
alias_expect true "link in a submodule beneath a buildSrc link" "$dir" \
    gradle app
dir="$(catalog_repo "$root_lib" gradle)"
git -C "$dir" submodule -q deinit -f gradle 2> /dev/null
put "$dir" manifests/deps.toml
alias_expect false "catalogue in a submodule not initialised" "$dir" \
    gradle app

# Checked-out files that cannot speak for HEAD prove nothing
dir="$(catalog_repo "$via_lib" vendor/lib vendor/lib gradle)"
put "$dir" README.md
commit "$dir"
git -C "$dir" -C vendor/lib checkout -q HEAD~1
unresolved "is not checked out at its pointer" \
    "submodule checked out away from its pointer" "$dir" \
    INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=gradle INPUT_PATH_PREFIX=app
if [ "$(id -u)" -ne 0 ]; then
    dir="$(catalog_repo "$via_lib" vendor/lib vendor/lib gradle)"
    put "$dir" README.md
    commit "$dir"
    chmod 000 "$dir/vendor/lib/locked"
    unresolved "cannot be listed" "submodule files unreadable" "$dir" \
        INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=gradle INPUT_PATH_PREFIX=app
    chmod 755 "$dir/vendor/lib/locked"
    # A root that cannot be read is not an empty, uninitialised one
    dir="$(catalog_repo "$via_lib" vendor/lib vendor/lib gradle)"
    put "$dir" README.md
    commit "$dir"
    chmod 000 "$dir/vendor/lib"
    unresolved "cannot be read" "submodule root unreadable" "$dir" \
        INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=gradle INPUT_PATH_PREFIX=app
    chmod 755 "$dir/vendor/lib"
else
    echo "skip: submodule files unreadable (running as root)"
    echo "skip: submodule root unreadable (running as root)"
fi
# A root whose only entry is named by a newline is not an empty one
dir="$(new_repo)"
put "$dir" app/src.txt shared/package.json
git -C "$dir" submodule -q add "file://$lib" app/vendor/lib 2> /dev/null
commit "$dir"
rm -rf "$dir/app/vendor/lib"
mkdir "$dir/app/vendor/lib"
ln -s ../../../shared "$dir/app/vendor/lib/"$'\n'
put "$dir" shared/package.json
commit "$dir"
unresolved "is not checked out at its pointer" \
    "submodule root holding only a newline-named link" "$dir" \
    INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX=app

# A file link that passes through a submodule trusts its files only at
# the recorded pointer, as a directory link does. alias_lib holds
# node.json -> ../../manifests/other.json, then, at its tip, a link to
# ../../manifests/deps.json; app/package.json -> ../vendor/lib/node.json
alias_lib="$(new_repo)"
ln -s ../../manifests/other.json "$alias_lib/node.json"
git -C "$alias_lib" add -A
commit "$alias_lib"
rm "$alias_lib/node.json"
ln -s ../../manifests/deps.json "$alias_lib/node.json"
git -C "$alias_lib" add -A
commit "$alias_lib"
file_alias_repo() {
    local dir
    dir="$(alias_repo ../vendor/lib/node.json app/package.json \
        manifests/deps.json manifests/other.json)"
    git -C "$dir" submodule -q add "file://$alias_lib" vendor/lib \
        2> /dev/null
    commit "$dir"
    printf '%s\n' "$dir"
}
dir="$(file_alias_repo)"
put "$dir" manifests/deps.json
alias_expect true "file link through a submodule at its pointer" "$dir" \
    node app
dir="$(file_alias_repo)"
put "$dir" manifests/other.json
alias_expect false "file beside a file link through a submodule" "$dir" \
    node app
dir="$(file_alias_repo)"
put "$dir" manifests/deps.json
commit "$dir"
git -C "$dir" -C vendor/lib checkout -q HEAD~1
unresolved "is not checked out at its pointer" \
    "file link through a submodule away from its pointer" "$dir" \
    INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX=app

# A directory the walk passes through that cannot be searched hides
# whether its entries are links, so proves nothing. locked_lib holds
# locked/node.json -> ../../../manifests/deps.json, reached by
# app/package.json -> ../vendor/lib/locked/node.json
locked_lib="$(new_repo)"
mkdir "$locked_lib/locked"
ln -s ../../../manifests/deps.json "$locked_lib/locked/node.json"
git -C "$locked_lib" add -A
commit "$locked_lib"
locked_alias_repo() {
    local dir
    dir="$(alias_repo ../vendor/lib/locked/node.json app/package.json \
        manifests/deps.json manifests/other.json)"
    git -C "$dir" submodule -q add "file://$locked_lib" vendor/lib \
        2> /dev/null
    commit "$dir"
    printf '%s\n' "$dir"
}
dir="$(locked_alias_repo)"
put "$dir" manifests/deps.json
alias_expect true "file link through a directory in a submodule" "$dir" \
    node app
if [ "$(id -u)" -ne 0 ]; then
    dir="$(locked_alias_repo)"
    put "$dir" manifests/deps.json
    commit "$dir"
    chmod a-x "$dir/vendor/lib/locked"
    unresolved "cannot be searched" \
        "file link through a submodule directory that cannot be searched" \
        "$dir" INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node \
        INPUT_PATH_PREFIX=app
    chmod u+x "$dir/vendor/lib/locked"
else
    echo "skip: file link through a directory that cannot be searched\
 (root)"
fi

# A submodule nested in another is trusted only at the pointer its
# owner's recorded commit holds, on every path that enters it. outer_lib
# records inner_lib at its first commit, where node.json ->
# ../../../manifests/deps.json; inner_lib's tip links to other.json.
inner_lib="$(new_repo)"
ln -s ../../../manifests/deps.json "$inner_lib/node.json"
git -C "$inner_lib" add -A
commit "$inner_lib"
rm "$inner_lib/node.json"
ln -s ../../../manifests/other.json "$inner_lib/node.json"
git -C "$inner_lib" add -A
commit "$inner_lib"
outer_lib="$(new_repo)"
git -C "$outer_lib" submodule -q add "file://$inner_lib" nested \
    2> /dev/null
git -C "$outer_lib" -C nested checkout -q HEAD~1
git -C "$outer_lib" add -A
commit "$outer_lib"
# nested_repo <link target> <link> [<recursive>]: a repository holding
# app/, manifests/deps.json, manifests/other.json, outer_lib at
# vendor/lib, its nested submodule initialised when the third argument
# is given, and the link; the caller commits the change under test
nested_repo() {
    local dir
    dir="$(alias_repo "$1" "$2" manifests/deps.json manifests/other.json)"
    git -C "$dir" submodule -q add "file://$outer_lib" vendor/lib \
        2> /dev/null
    if [ "$#" -gt 2 ]; then
        git -C "$dir" submodule -q update --init --recursive 2> /dev/null
    fi
    commit "$dir"
    printf '%s\n' "$dir"
}
file_nested=../vendor/lib/nested/node.json
dir="$(nested_repo "$file_nested" app/package.json recursive)"
put "$dir" manifests/deps.json
alias_expect true "file link through a nested submodule at its pointer" \
    "$dir" node app
dir="$(nested_repo "$file_nested" app/package.json recursive)"
put "$dir" manifests/other.json
alias_expect false "file beside a link through a nested submodule" \
    "$dir" node app
dir="$(nested_repo "$file_nested" app/package.json)"
put "$dir" manifests/deps.json
alias_expect false "file link into a nested submodule not initialised" \
    "$dir" node app
dir="$(nested_repo "$file_nested" app/package.json recursive)"
put "$dir" manifests/deps.json
commit "$dir"
git -C "$dir" -C vendor/lib/nested checkout -q origin/main
unresolved "is not checked out at its pointer" \
    "file link through a nested submodule away from its pointer" "$dir" \
    INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX=app
dir="$(nested_repo vendor/lib buildSrc recursive)"
put "$dir" manifests/deps.json
alias_expect true "link in a nested submodule behind a buildSrc link" \
    "$dir" gradle app
dir="$(nested_repo vendor/lib buildSrc recursive)"
put "$dir" manifests/other.json
alias_expect false "file beside a link in a nested submodule" "$dir" \
    gradle app
dir="$(nested_repo vendor/lib buildSrc recursive)"
put "$dir" manifests/deps.json
commit "$dir"
git -C "$dir" -C vendor/lib/nested checkout -q origin/main
unresolved "is not checked out at its pointer" \
    "link in a nested submodule away from its pointer" "$dir" \
    INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=gradle INPUT_PATH_PREFIX=app
# An owner whose recorded tree cannot be read cannot vouch for what is
# nested in it
dir="$(nested_repo "$file_nested" app/package.json recursive)"
put "$dir" README.md
commit "$dir"
gitdir="$(git -C "$dir/vendor/lib" rev-parse --absolute-git-dir)"
mkdir "$work/packs.$$.$cases"
mv "$gitdir"/objects/pack/* "$work/packs.$$.$cases/" 2> /dev/null || :
for pack in "$work/packs.$$.$cases"/*.pack; do
    if [ -f "$pack" ]; then
        git -C "$dir/vendor/lib" unpack-objects -q < "$pack"
    fi
done
tree="$(git -C "$dir/vendor/lib" rev-parse 'HEAD^{tree}')"
rm -f "$gitdir/objects/${tree:0:2}/${tree:2}"
unresolved "submodules nested in" "nested submodules cannot be listed" \
    "$dir" INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node INPUT_PATH_PREFIX=app

# Files beneath a directory outside the repository could link back into
# it, so a link to one that a pattern could reach past proves nothing
mkdir -p "$work/ext-gradle"
dir="$(new_repo)"
put "$dir" app/src.txt manifests/deps.toml
ln -s "$dir/manifests/deps.toml" "$work/ext-gradle/libs.versions.toml"
mklink "$dir" "$work/ext-gradle" gradle
commit "$dir"
put "$dir" manifests/deps.toml
commit "$dir"
unresolved "reaches a directory outside" \
    "gradle link to a directory outside the repository" "$dir" \
    INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=gradle INPUT_PATH_PREFIX=app
dir="$(alias_repo "$work/ext-gradle" docs manifests/deps.toml)"
put "$dir" manifests/deps.toml
alias_expect false "unrelated link to a directory outside" "$dir" \
    gradle app

# A target that leaves the repository and re-enters it is inside it,
# however the path is spelt: '.', '..', '//', or a link outside the
# checkout. reentry_case <label> <link> <prefix> <target>, where the
# target's '@' stands for the name of the repository's directory
ln -s "$work" "$work/outside-alias"
reentry_case() {
    local label="$1" link="$2" prefix="$3" target="$4" dir
    dir="$(new_repo)"
    put "$dir" app/src.txt manifests/node.json
    mklink "$dir" "${target//@/${dir##*/}}" "$link"
    commit "$dir"
    put "$dir" manifests/node.json
    alias_expect true "$label" "$dir" node "$prefix"
}
reentry_case "absolute target with a dot segment" package.json . \
    "${work}/./@/manifests/node.json"
reentry_case "absolute target with repeated slashes" package.json . \
    "/$work//@//manifests//node.json"
reentry_case "absolute target through a link outside" package.json . \
    "$work/outside-alias/@/manifests/node.json"
reentry_case "relative target re-entering the checkout" package.json . \
    "../@/manifests/node.json"
reentry_case "relative target re-entering from a sub-project" \
    app/package.json app "../../@/manifests/node.json"
reentry_case "relative target with repeated slashes" package.json . \
    "manifests//node.json"
dir="$(new_repo)"
put "$dir" app/src.txt manifests/node.json
mklink "$dir" "../${dir##*/}/a.json" package.json
mklink "$dir" manifests/node.json a.json
commit "$dir"
put "$dir" manifests/node.json
alias_expect true "re-entering target continuing through a link" "$dir" \
    node .

# A target the tree spells otherwise is the tracked file on a file
# system that folds case, so a change to that file cannot be ruled out
dir="$(alias_repo manifests/NODE.json package.json manifests/node.json)"
put "$dir" manifests/node.json
commit "$dir"
unresolved "spells otherwise" "link target in another case" "$dir" \
    INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node
dir="$(alias_repo M/node.json package.json manifests/node.json)"
mklink "$dir" manifests m
commit "$dir"
put "$dir" manifests/node.json
commit "$dir"
unresolved "spells otherwise" "link on a target's path in another case" \
    "$dir" INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node
dir="$(alias_repo "manifests/NODE"$'\n'".json" package.json \
    "manifests/node"$'\n'".json")"
put "$dir" "manifests/node"$'\n'".json"
commit "$dir"
unresolved "spells otherwise" "link target with a newline in another case" \
    "$dir" INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node
# Git folds ASCII letters only, so another byte must match exactly
dir="$(alias_repo "manifests/nod"$'\xc3\xa9'".json" package.json \
    "manifests/nod"$'\xc3\xa9'".json")"
put "$dir" "manifests/nod"$'\xc3\xa9'".json"
alias_expect true "non-ASCII link target spelt as tracked" "$dir" node .
dir="$(alias_repo "manifests/node"$'\xcc\x81'".json" package.json \
    "manifests/nod"$'\xc3\xa9'".json")"
put "$dir" README.md
commit "$dir"
unresolved "spells otherwise" "non-ASCII link target not tracked" \
    "$dir" INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node
dir="$(alias_repo manifests/NODE.json package.json)"
put "$dir" README.md
alias_expect false "dangling link target tracked in no case" "$dir" \
    node .

# On a file system that folds case, another spelling of the checkout's
# own directory is the checkout, for link targets and the output alike
mkdir "$work/case-probe"
if [ -d "$work/CASE-PROBE" ]; then
    dir="$(new_repo)"
    put "$dir" app/src.txt manifests/node.json
    upper="$(printf '%s' "${dir##*/}" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
    mklink "$dir" "${dir%/*}/$upper/manifests/node.json" package.json
    commit "$dir"
    put "$dir" manifests/node.json
    alias_expect true "absolute target re-entering in another case" \
        "$dir" node .
    mkdir -p "$work/case-outside"
    ln -s "$work/case-outside" "$dir/out"
    for output in "${dir%/*}/$upper/out/deps.json" \
        "../$upper/out/deps.json"; do
        printf 'keep\n' > "$work/case-outside/deps.json"
        rejects "output through a link in another case: $output" "$dir" \
            GITHUB_EVENT_NAME=schedule INPUT_ECOSYSTEMS=node \
            INPUT_OUTPUT="$output"
        cases=$((cases + 1))
        if [ "$(cat "$work/case-outside/deps.json")" = keep ]; then
            echo "ok: file beyond a link in another case left alone"
        else
            fail "file beyond a link in another case was changed: $output"
        fi
    done
else
    echo "skip: checkout in another case (case-sensitive file system)"
fi

# A link on the way to a target outside the repository is part of the
# change: retargeting the root 'cur' swaps app/package.json
mkdir -p "$work/deps-v1" "$work/deps-v2"
printf '{}\n' > "$work/deps-v1/node.json"
printf '{}\n' > "$work/deps-v2/node.json"
dir="$(alias_repo ../cur/node.json app/package.json)"
mklink "$dir" "$work/deps-v1" cur
commit "$dir"
mklink "$dir" "$work/deps-v2" cur
alias_expect true "link to an outside target retargeted" "$dir" node app
put "$dir" README.md
alias_expect false "outside target behind unchanged links" "$dir" \
    node app

# Links no pattern reaches count towards no cap
dir="$(new_repo)"
put "$dir" app/src.txt
mkdir -p "$dir/other"
for (( n = 0; n <= 1000; n++ )); do
    ln -s ../README.md "$dir/other/l$n"
done
git -C "$dir" add -A
commit "$dir"
put "$dir" other/notes.md
alias_expect false "over 1000 links in a sibling project" "$dir" node app

# Links that cannot be resolved leave the result unresolved
dir="$(alias_repo a package.json)"
mklink "$dir" package.json a
commit "$dir"
put "$dir" README.md
commit "$dir"
unresolved "does not resolve within" "link loop" "$dir" \
    INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node
ln -s "$work/loop-b" "$work/loop-a"
ln -s "$work/loop-a" "$work/loop-b"
dir="$(alias_repo "$work/loop-a" package.json)"
put "$dir" README.md
commit "$dir"
unresolved "does not resolve within" "link loop outside the checkout" \
    "$dir" INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node
dir="$(alias_repo . x1)"
mklink "$dir" . x2
commit "$dir"
put "$dir" README.md
commit "$dir"
unresolved "reach more than" "two directory links to their parent" \
    "$dir" INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node
dir="$(alias_repo . loop)"
put "$dir" README.md
commit "$dir"
unresolved "reach more than" "directory link to its own parent" "$dir" \
    INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node
dir="$(alias_repo manifests/node.json package.json manifests/node.json)"
put "$dir" README.md
commit "$dir"
blob="$(git -C "$dir" rev-parse HEAD:package.json)"
rm -f "$dir/.git/objects/${blob:0:2}/${blob:2}"
unresolved "is not in the checkout" "link target object missing" \
    "$dir" INPUT_BASE=HEAD~1 INPUT_ECOSYSTEMS=node
dir="$(new_repo)"
put "$dir" app/lib/a.txt
commit "$dir"
put "$dir" README.md
commit "$dir"
tree="$(git -C "$dir" rev-parse HEAD:app/lib)"
rm -f "$dir/.git/objects/${tree:0:2}/${tree:2}"
unresolved "git ls-tree" "unchanged subtree object missing" "$dir" \
    INPUT_ECOSYSTEMS=node INPUT_BASE=HEAD~1

echo
if [ "$failures" -gt 0 ]; then
    echo "$failures of $cases cases failed ❌"
    exit 1
fi
echo "All $cases cases passed ✅"
