<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 📦 Dependency Change Action

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/dependency-change-action) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/dependency-change-action/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/dependency-change-action)
<!-- prettier-ignore-end -->

Reports whether a change touched dependency files, so that
[`grype-scan-action`](https://github.com/lfreleng-actions/grype-scan-action)
applies its strict gate when the dependency set may have moved, and
relaxes it otherwise.

The action reads git objects and never the working tree: it compares a
base commit against `HEAD` with `git diff` and `git ls-tree`, and treats
every path as bytes. When it cannot prove what the change touched, it
reports an unresolved result, which the consumer gates as it does today.

It runs on `ubuntu-latest` and `macos-latest`. A commit-pinned
`actions/setup-python` step selects Python 3.13, from the runner's tool
cache where present, without touching the caller's `PATH`, so the
caller's environment never chooses the interpreter; `git` comes from
the runner or the `git` input.

## Usage Example

<!-- markdownlint-disable MD046 -->

```yaml
steps:
  - uses: actions/checkout@v4
    with:
      fetch-depth: 2

  - name: 'Detect dependency changes'
    id: dependencies
    uses: lfreleng-actions/dependency-change-action@main
    with:
      ecosystems: 'node'
      path-prefix: ${{ inputs.path_prefix }}
      gerrit-refspec: ${{ inputs.gerrit_refspec }}

  # Upload dependency-change.json in the same artefact as the SBOM, so
  # matrix jobs each carry their own signal.

  - name: 'Grype audit SBOM'
    uses: lfreleng-actions/grype-scan-action@main
    with:
      sbom: 'sbom-cyclonedx.json'
      gate-when: 'dependencies-changed'
      dependency-change-manifest: 'dependency-change.json'
```

<!-- markdownlint-enable MD046 -->

Callers need `fetch-depth: 2` for `pull_request` and Gerrit runs, so that
the parent of the checked-out commit is present.
`checkout-gerrit-change-action` fetches depth 2 by default.

## Inputs

<!-- markdownlint-disable MD013 -->

| Name             | Required | Default                  | Description                                                                                                          |
| ---------------- | -------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| `ecosystems`     | No\*     | `''`                     | Comma-separated presets: `node`, `python`, `go`, `maven`, `gradle`, `rust`, `docker`. An unknown name fails the step |
| `patterns`       | No\*     | `''`                     | Extra patterns, one per line, added to the presets                                                                   |
| `path-prefix`    | No       | `.`                      | Project directory within the repository                                                                              |
| `gerrit-refspec` | No       | `''`                     | Set on Gerrit-triggered runs; the checkout is then the change itself                                                 |
| `base`           | No       | `''`                     | Explicit base commit, overriding event detection; a commit the checkout lacks gives an unresolved result             |
| `output`         | No       | `dependency-change.json` | Sidecar path, relative to the working directory; a resolved result writes it, an unresolved one does not             |
| `git`            | No       | `''`                     | Absolute git executable path, untrimmed; empty finds `git` on `PATH`. Anything but an executable file fails the step |

<!-- markdownlint-enable MD013 -->

\* Set `ecosystems`, `patterns`, or both.

The action normalises `output` lexically (`.`, `..`, repeated `/`) and
reports that normalised path as `manifest`. It accepts an absolute
`output` when the path lies under the working directory, and fails the
step otherwise.

## Outputs

<!-- markdownlint-disable MD013 -->

| Name            | Description                                                                                                                 |
| --------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `changed`       | `true`, `false`, or **empty** when unresolved, so it can feed `grype-scan-action`'s `dependencies-changed` directly         |
| `reason`        | One line saying why, such as `2 dependency files changed since a1b2c3d4e5f6` or `unresolved: HEAD^1 is not in the checkout` |
| `base`          | The base commit compared against; empty when unresolved                                                                     |
| `manifest`      | Path to the sidecar; empty when unresolved                                                                                  |
| `changed-paths` | Every path the change touched, as a compact JSON array; `[]` when nothing changed, **empty** when unresolved                |

<!-- markdownlint-enable MD013 -->

`changed` is empty, never a word like `unresolved`, when the result is
unknown: `grype-scan-action` rejects any non-empty value other than
`true` or `false`.

`changed-paths` lists every path in the diff between the base and
`HEAD`, sorted, relative to the repository root with `/` separators. It
includes paths no pattern matched and paths outside `path-prefix`, in
the form `docker-build-matrix-action`'s `changed_files` input takes.
Like `changed`, it stays empty when the action cannot resolve the
result, so a consumer can tell "nothing changed" (`[]`) from "unknown"
(empty). JSON cannot carry a path that does not decode as UTF-8, so such
a path leaves `changed-paths` empty with a `::notice::`, while `changed`
and the sidecar report as usual.

The sidecar is a JSON document with `schema` (1), `changed`, `base`,
`reason`, the list of matched `files` and the list of every changed path
in `changed_paths`. Both lists decode a path that is not valid UTF-8
with `surrogateescape`. Adding `changed_paths` left `schema` at 1, since
a reader of the other keys sees no difference.

## Choosing the base

<!-- markdownlint-disable MD013 -->

| Context                                               | Base                                                    |
| ----------------------------------------------------- | ------------------------------------------------------- |
| `base` input set                                      | That commit                                             |
| `gerrit-refspec` set                                  | `HEAD^1`, the parent of the change                      |
| `pull_request`, with `HEAD` = `GITHUB_SHA`            | `HEAD^1`, the base-branch side of GitHub's merge commit |
| `push`, with `HEAD` = `GITHUB_SHA`                    | `github.event.before`, so every pushed commit counts    |
| `HEAD` ≠ `GITHUB_SHA` (another `repository` or `ref`) | unresolved                                              |
| `push` creating a branch (`before` is all zeros)      | unresolved                                              |
| `schedule`, `workflow_dispatch`, anything else        | unresolved                                              |
| `merge_group`, `pull_request_target`                  | unresolved                                              |
| Base, or its tree, not present in the checkout        | unresolved                                              |

<!-- markdownlint-enable MD013 -->

Unresolved on `schedule` and `workflow_dispatch` is deliberate: a
scheduled run of a verify workflow always applies the full gate.

A missing object is never fetched. Every git command runs with
`GIT_NO_LAZY_FETCH=1`, so a partial clone whose base tree is absent
reports unresolved instead of asking its promisor remote for it with
the checkout's credential. Git 2.46 introduced the variable and older
releases ignore it, so in a partial clone (one whose configuration
names a promisor remote, in `remote.<name>.promisor` or
`extensions.partialClone`) the action checks `git --version` once and
reports unresolved below 2.46, naming the version. A clone with no
promisor remote has nothing to fetch and runs on any git.

## The fail-closed contract

1. When the action cannot prove what the change touched, it writes **no**
   sidecar and leaves `changed` empty. It never writes `false` from an
   unproven position, and any unexpected exception is an unresolved
   result, not a crash and not `false`.
2. Over-matching is safe; under-matching is not. A file wrongly counted
   as a dependency file costs one strict run. When in doubt, a preset
   includes the file.
3. The change under review never vouches for itself: the action deletes
   any sidecar already at `output` before detection starts, and fails
   the step when it cannot, so a planted file never survives a run.
4. The action reports which files changed. It does not parse manifests,
   decide severities or gate; what it finds never fails the step. An
   invalid input, or a sidecar it cannot clear before detection or
   remove after a failed write, does.
5. It logs one line per matched file and a final verdict, with paths
   escaped so that a file name cannot forge a workflow command. Every
   output goes to `GITHUB_OUTPUT` with a random delimiter, so a path
   cannot add a further output.

## The trust boundary

The detector runs git with an environment of its own, so the job around
it cannot change what git reports:

- With the `git` input set, it runs that executable and never looks
  `git` up on `PATH`. The path must be absolute and, after resolving
  symbolic links, name an executable regular file; the resolved path is
  what runs. The value is never trimmed: leading or trailing
  whitespace, such as the newline a YAML block scalar leaves, is an
  input error, as is any other value that breaks these rules; either
  fails the step.
- It removes every `GIT_*` variable the caller set, such as `GIT_DIR`,
  `GIT_OBJECT_DIRECTORY` or `GIT_ALTERNATE_OBJECT_DIRECTORIES`, which
  would point git at another repository or other objects. The rest of
  the environment stays, `HOME` included, so system and global
  configuration such as `safe.directory` still apply.
- It sets `GIT_NO_REPLACE_OBJECTS=1`, so a replace ref planted in the
  clone cannot swap a dependency commit for one with an unchanged tree.
- It sets `GIT_GRAFT_FILE` to the null device, so a `.git/info/grafts`
  file cannot reparent `HEAD` and move the base.

It cannot defend against an earlier step in the same job that runs
untrusted code: such a step can replace git itself or rewrite the
clone. Run the detector before any step that executes code from the
change under review. When anything before the detector could change
`PATH`, such as a step that adds a directory from the checkout, pass
`git` as an absolute path, for example `/usr/bin/git`. Left empty, the
first `git` on `PATH` runs, as it did before the input existed.

## Patterns

The action diffs with `git diff --raw -z --no-renames
--ignore-submodules=none <base> HEAD`, so a rename or deletion counts on
both sides, a moved submodule pointer stays visible whatever
`diff.ignoreSubmodules` or a submodule's `ignore` setting in the
checkout's `.gitmodules` says, and each path matches as bytes.

- **Inside `path-prefix`**, a pattern matches at any depth.
- **Above `path-prefix`**, a pattern matches when anchored at an
  ancestor directory, where workspace roots keep shared lock files and
  parent build files, and nowhere else. A sibling project never matches.
- A pattern without `/` matches a file name; one with `/` matches a path
  relative to its anchor directory; one ending in `/` matches everything
  beneath that directory. `*` matches within one path segment, and no
  other character has a special meaning. A pattern using `**`, `?`, `[`,
  `]`, `\`, a leading `/`, or a `.` or `..` segment fails the step.

The action normalises `path-prefix` lexically; it must stay inside the
repository and must name a directory present in `HEAD`'s tree, with no
symbolic link or submodule among its components. Any other prefix gives
an unresolved result.

## Symbolic links and submodules

A symbolic link or submodule can stand in for a dependency file or a
directory of them, and the action does not trust the checkout to say
what it stands for. For every link or submodule, in the base tree or in
`HEAD`'s, whose path a pattern could match at or beneath (any path
inside `path-prefix`; above it, a path an anchored pattern reaches past,
such as `buildSrc` or `gradle`):

- if the entry appears in the diff (added, deleted, retargeted, mode
  changed, or pointer moved), the result is `changed=true`, with or
  without a changed dependency file beside it;
- otherwise the action reports unresolved, with a reason naming the
  entry, unless another change already proved `changed=true`: a matched
  dependency file, or another reachable entry that did change.

A link or submodule at a strict ancestor of `path-prefix` counts as
reachable too, since it stands in for the project directory itself: in
`HEAD`'s tree it makes the prefix unresolved, and in the base tree alone
it counts as a change. Links and submodules no pattern could reach cost
nothing.

## Presets

<!-- markdownlint-disable MD013 -->

| Preset   | Patterns                                                                                                                                                                                                                                            |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `node`   | `package.json` `package-lock.json` `npm-shrinkwrap.json` `yarn.lock` `.yarnrc.yml` `pnpm-lock.yaml` `pnpm-workspace.yaml` `bun.lock` `bun.lockb`                                                                                                    |
| `python` | `pyproject.toml` `uv.lock` `poetry.lock` `pdm.lock` `Pipfile` `Pipfile.lock` `setup.py` `setup.cfg` `requirements*.txt` `requirements/*.txt` `constraints*.txt` `tox.ini`                                                                           |
| `go`     | `go.mod` `go.sum` `go.work` `go.work.sum` `vendor/modules.txt`                                                                                                                                                                                      |
| `maven`  | `pom.xml` `.mvn/extensions.xml` `.mvn/maven.config` `.mvn/jvm.config`                                                                                                                                                                               |
| `gradle` | `build.gradle` `build.gradle.kts` `settings.gradle` `settings.gradle.kts` `*.gradle` `*.gradle.kts` `gradle.properties` `gradle/*.versions.toml` `gradle.lockfile` `settings-gradle.lockfile` `gradle/dependency-locks/` `buildSrc/` `build-logic/` |
| `rust`   | `Cargo.toml` `Cargo.lock` `.cargo/config.toml` `.cargo/config`                                                                                                                                                                                      |
| `docker` | `Dockerfile` `Dockerfile.*` `*.Dockerfile` `Containerfile` `Containerfile.*` `*.dockerfile`                                                                                                                                                         |

<!-- markdownlint-enable MD013 -->

`tox.ini`, `setup.cfg`, `gradle.properties`, `.mvn/maven.config`,
`.mvn/jvm.config`, applied Gradle scripts (`*.gradle`, `*.gradle.kts`)
and Gradle's convention-plugin builds (`buildSrc/`, `build-logic/`)
change for reasons unrelated to dependencies too; the presets include
them at the cost of a strict run.

`docker` covers the image recipe alone. A Docker lane building a Python
application combines presets (`ecosystems: docker,python`) and passes a
Dockerfile with a non-standard name through `patterns`.

## Implementation Details

The detector is a standard-library Python package under
`scripts/dependency_change/`, run as
`"$PYTHON" -I scripts/dependency_change/__main__.py`, where `PYTHON` is
the interpreter path the setup step reports, with the inputs passed
as environment variables. Isolated mode keeps the checkout, `PYTHONPATH`
and the user site off `sys.path`, so a file in the change under review
cannot shadow the detector or a standard-library module. It touches the
working tree twice: to run `git`, and to delete and write the sidecar.
It opens the sidecar path one component at a time relative to the
working directory's own descriptor, with `O_NOFOLLOW` at every step, so
nothing in the checkout can redirect the write outside the working
directory. When a sidecar write fails part way, the action removes the
partial file and reports unresolved; when that removal fails too, for
any reason other than a file that no longer exists, the step fails, so
a readable sidecar never outlives an exit 0 the action did not stand
behind.

Run the tests with `python3 -m unittest discover -s tests`. They build
real git repositories in temporary directories, and
`tests/test_mutation.py` disables each fail-closed guard, each setting
in git's environment and the `GIT_*` filter in turn to check that a
test notices.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/dependency-change-action/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/dependency-change-action/main.svg
