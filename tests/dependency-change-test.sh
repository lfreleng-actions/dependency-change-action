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

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
script="${DETECT_SCRIPT:-$here/../scripts/dependency-change.sh}"
work="$(mktemp -d "${TMPDIR:-/tmp}/dependency-change-test.XXXXXX")"
work="$(cd "$work" && pwd -P)"
trap 'rm -rf "$work"' EXIT
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
dir="$(pr_repo -- "$forged/package.json" "::warning::y/package.json")"
expect true "names with newlines and workflow commands" "$dir" \
    GITHUB_EVENT_NAME=pull_request GITHUB_SHA="$(sha "$dir")" \
    INPUT_ECOSYSTEMS=node
cases=$((cases + 1))
if grep -q '^::' "$work/stdout" "$work/stderr"; then
    fail "a log line starts a workflow command"
elif [ "$out_keys" != " changed reason base manifest" ]; then
    fail "outputs were '$out_keys'"
elif [ "$(grep -c 'Dependency file changed:' "$work/stdout")" -ne 2 ]
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

# --- not a checkout ----------------------------------------------------

mkdir "$work/plain"
unresolved "not a git checkout" "plain directory" "$work/plain" \
    GITHUB_EVENT_NAME=pull_request INPUT_ECOSYSTEMS=node
git init -q "$work/unborn"
unresolved "HEAD is not a commit" "repository with no commits" \
    "$work/unborn" GITHUB_EVENT_NAME=pull_request INPUT_ECOSYSTEMS=node

echo
if [ "$failures" -gt 0 ]; then
    echo "$failures of $cases cases failed ❌"
    exit 1
fi
echo "All $cases cases passed ✅"
