<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 🔎 Dependency Change Detection

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[![Linux Foundation](https://img.shields.io/badge/Linux-Foundation-blue)](https://linuxfoundation.org/) [![Source Code](https://img.shields.io/badge/GitHub-100000?logo=github&logoColor=white&color=blue)](https://github.com/lfreleng-actions/dependency-change-action) [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0) [![pre-commit.ci status badge]][pre-commit.ci results page] [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lfreleng-actions/dependency-change-action/badge)](https://scorecard.dev/viewer/?uri=github.com/lfreleng-actions/dependency-change-action)
<!-- prettier-ignore-end -->

Answers one question for a Gerrit change or GitHub pull request: **did
the change touch the files that declare or lock its dependencies?** It
writes the answer as a `{"changed": true|false}` sidecar that
[`grype-scan-action`](https://github.com/lfreleng-actions/grype-scan-action)
reads through `dependency-change-manifest`, and as a `changed` output
that feeds its `dependencies-changed` input.

With `gate-when: dependencies-changed`, Grype still scans the full SBOM
on every run. This action decides whether findings block the change
or warn:

<!-- markdownlint-disable MD013 -->

| The change...            | `changed` | Findings at or above `fail-on` |
| ------------------------ | --------- | ------------------------------ |
| touched dependency files | `true`    | fail                           |
| did not touch them       | `false`   | warn                           |
| has no provable answer   | empty     | fail                           |

<!-- markdownlint-enable MD013 -->

## Usage Example

<!-- markdownlint-disable MD046 -->

```yaml
steps:
  # Pull requests and Gerrit changes need depth 2, for HEAD^1
  - uses: actions/checkout@<sha>  # v7
    with:
      fetch-depth: 2

  - name: "Detect dependency changes"
    uses: lfreleng-actions/dependency-change-action@<sha>  # v0.1.0
    with:
      ecosystems: "node"
      path-prefix: ${{ inputs.path_prefix }}
      gerrit-refspec: ${{ inputs.gerrit_refspec }}

  # Upload dependency-change.json in the same artefact as the SBOM, so
  # matrix jobs each carry their own signal; job outputs would collapse.

  - name: "Grype audit SBOM"
    uses: lfreleng-actions/grype-scan-action@<sha>  # v0.4.0
    with:
      sbom: "sbom-cyclonedx.json"
      gate-when: "dependencies-changed"
      dependency-change-manifest: "dependency-change.json"
```

<!-- markdownlint-enable MD046 -->

## Inputs

<!-- markdownlint-disable MD013 -->

| Name           | Required | Default                  | Description                                                                                                             |
| -------------- | -------- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| ecosystems     | False    |                          | Comma-separated presets (see below). An unknown name fails the step. Set this, `patterns`, or both                      |
| patterns       | False    |                          | Extra patterns, one per line, added to the presets                                                                      |
| path-prefix    | False    | `.`                      | Project directory, as the workflow families' `path_prefix`                                                              |
| gerrit-refspec | False    |                          | Set on Gerrit-triggered runs; the checkout is then the change itself                                                    |
| base           | False    |                          | Explicit base commit, overriding event detection; a value naming no commit in the checkout leaves the result unresolved |
| output         | False    | `dependency-change.json` | Sidecar path; the action writes it when it resolves the result                                                          |

<!-- markdownlint-enable MD013 -->

## Outputs

<!-- markdownlint-disable MD013 -->

| Name     | Description                                                                                       |
| -------- | ------------------------------------------------------------------------------------------------- |
| changed  | `true`, `false`, or **empty** when unresolved; feeds `grype-scan-action`'s `dependencies-changed` |
| reason   | One line saying why, such as `since a1b2c3d4e5f6` or `unresolved: HEAD^1 is not in the checkout`  |
| base     | The base commit compared against; empty when unresolved                                           |
| manifest | Path to the sidecar; empty when unresolved                                                        |

<!-- markdownlint-enable MD013 -->

`changed` is empty, never a word such as `unresolved`, when the answer
is unknown: `grype-scan-action` rejects any other non-empty value.

## The fail-closed contract

- When the action cannot prove what the change touched, it writes **no**
  sidecar and leaves `changed`, `base` and `manifest` empty, so
  `grype-scan-action` gates as it would without this action. It
  never writes `false` from an unproven position.
- Before detection starts it deletes any file already at `output`, so
  the change under review cannot vouch for itself by committing a
  sidecar.
- Invalid inputs fail the step: an unknown preset, an
  invalid pattern, no patterns at all, or an `output` that names a
  directory or whose directory passes through a symbolic link inside
  the working directory, which could reach a file outside the
  checkout. The check follows the path as the file system does, so an
  absolute spelling such as `/work/./repo/out` or one through a link
  above the checkout gets no exemption, and it knows the working
  directory by identity, not spelling, so it treats `/work/REPO/out`
  on a file system that folds case as `/work/repo/out`. It expands a
  link outside the working directory one component at a time, never
  in a single step, and catches a link outside that targets one
  inside. It checks a directory name ending in a newline as spelt,
  and a working directory whose name ends in one, and fails when it
  lacks search permission on a directory on the path. What it finds
  never fails the step.
- It reads, never writes, git state and works offline. A shallow
  checkout that lacks the base leaves the result unresolved; the
  action does not deepen it.
- It logs one line per matched file and a final verdict, with no
  annotations or step summary. File names print on one line, with
  newlines escaped and the runner's legacy `##[` marker written as
  `#\#[`, so a name cannot forge a workflow command.

Each guard that leaves the result unresolved has a test that fails when
the guard goes; `tests/mutate.sh` proves it by disabling each guard in
turn. A mutant still runs the guard's condition, with everything it
writes or sets, then forces the decision to false, so no unrelated
breakage can kill it: a test has to reach the guarded failure.

## Choosing the base

<!-- markdownlint-disable MD013 -->

| Context                                               | Base                                                    |
| ----------------------------------------------------- | ------------------------------------------------------- |
| `base` input set                                      | That commit                                             |
| `gerrit-refspec` set                                  | `HEAD^1`, the parent of the change                      |
| `pull_request`, with `HEAD` = `GITHUB_SHA`            | `HEAD^1`, the base-branch side of GitHub's merge commit |
| `push`, with `HEAD` = `GITHUB_SHA`                    | `github.event.before`, covering every pushed commit     |
| `HEAD` ≠ `GITHUB_SHA` (another `repository` or `ref`) | unresolved                                              |
| `push` creating a branch (`before` is all zeros)      | unresolved                                              |
| `schedule`, `workflow_dispatch`, anything else        | unresolved                                              |
| Base, or its tree, not present in the checkout        | unresolved                                              |

<!-- markdownlint-enable MD013 -->

Unresolved on `schedule` and `workflow_dispatch` is deliberate: a
scheduled run of a verify workflow always applies the full gate.
`merge_group` and `pull_request_target` events stay unresolved too.

Callers need `fetch-depth: 2` for `pull_request` and Gerrit runs;
`checkout-gerrit-change-action` already fetches depth 2 by default.

## Matching

The action compares `git diff --raw -z --no-renames <base> HEAD`, so a
rename or deletion counts on both sides and paths compare as git
stores them, byte for byte.

- **Inside `path-prefix`**, a pattern matches at any depth.
- **Above `path-prefix`**, a pattern needs an ancestor directory as
  its anchor, where workspace roots keep shared lock files and
  parent build files. A sibling project never matches.
- A pattern without `/` matches a file name. One with `/` matches a path
  relative to its anchor directory, and one ending in `/`
  matches everything beneath that directory. `*` matches within one
  path segment. Patterns may not use `**`, `?`, `[`, `]`, `\`, a leading
  `/`, or `.` and `..` segments; such a pattern fails the step. Every
  other character, `(`, `|`, `+`, `@` and `!` included, matches itself.
- A submodule pointer or a symbolic link that changes counts as a
  change when a pattern could match beneath it, as either may stand
  for a directory: any inside `path-prefix`, and above it one such as
  `buildSrc` or `gradle` that an anchored pattern reaches past.
- A change reached through an unchanged symbolic link counts under the
  link's name. With `package.json -> manifests/node.json`, a change to
  `manifests/node.json` is a change to `package.json`; with
  `buildSrc -> shared/build`, a change beneath `shared/build` is a
  change beneath `buildSrc`. The action resolves each link a pattern
  could reach, in the base and in `HEAD`, through chains of links and
  links beneath a linked directory, and also counts a change to any
  link it followed on the way. A target spelt with `.`, `..` or `//`,
  or reached through a link outside the checkout, resolves as the file
  system would, so `/work/./repo/x` and `../repo/x` both name `x` in
  the checkout at `/work/repo`. A lookup that enters a submodule
  continues through its checked-out files, so a `..` or a link there
  that leads back into the repository still counts; a target that
  stays inside the submodule counts when its pointer moves. A file
  outside the repository is not part of the change, but a change to a
  link followed to reach it still counts. The result stays unresolved
  when a link's target is missing from the checkout, a lookup follows
  more than 40 links, the links a pattern could reach lead to more
  than 1000 paths in one revision, as a link to its own parent
  directory does, or a link reaches a directory outside the repository
  beneath which a pattern could match, since a file there could link
  back into the checkout. A lookup that lacks search permission on a
  directory, or fails to read a link, also leaves it unresolved: a
  failed probe never counts as "not a link".
- On a file system that folds case, as macOS and Windows do by
  default, `package.json -> manifests/NODE.json` reads a tracked
  `manifests/node.json`, and `/work/REPO` is the checkout at
  `/work/repo`. A lookup leaving the repository recognises the
  checkout, and each submodule's checkout, by identity rather than
  spelling. Inside the repository, the result stays unresolved when a
  link target, or a directory on its way, is a path the tree spells
  otherwise, whatever the runner's file system. Git folds ASCII
  letters alone, so a target with any other byte must match a tracked
  path byte for byte. A target the tree holds in no spelling is
  missing, as any other dangling target is.
- A submodule is part of the path, not the end of it. Once
  initialised, its files sit in the checkout, and the action resolves
  every link among them that a pattern could reach, whether a pattern
  reaches the submodule directly (`gradle` is itself a submodule) or
  through a link (`gradle -> vendor/lib`), under the same limits. With
  the `gradle` preset, `path-prefix: app`, an unchanged
  `gradle -> vendor/lib` link and
  `libs.versions.toml -> ../../manifests/deps.toml` in the submodule
  at `vendor/lib`, a change to `manifests/deps.toml` is a change to
  `gradle/libs.versions.toml`. Its files count when the checkout
  holds the submodule at its pointer in `HEAD`, which the action
  checks on every path that enters it: a file link passing through,
  such as `app/package.json -> ../vendor/lib/node.json`, as much as a
  directory link. The rule recurses: a submodule nested in another
  counts at the pointer its owner's recorded commit holds, never at
  another. The result stays unresolved when a submodule is not at its
  pointer, or when the action cannot read its root, list its files or
  list the submodules nested in it; an unreadable root, or one whose
  entries all have names made of newlines, is never taken for an
  empty one. A submodule that nobody initialised has no files
  for the build to read, so its pointer stands for everything beneath
  it.

`path-prefix` resolves against the working directory. The result stays
unresolved when the prefix does not exist, names no directory tracked
at `HEAD`, leaves the checkout, or passes through a symbolic link: a change could
retarget the link and swap the project without touching any matched
file.

## Presets

<!-- markdownlint-disable MD013 -->

| Preset | Patterns                                                                                                                                                                                                                  |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| node   | `package.json` `package-lock.json` `npm-shrinkwrap.json` `yarn.lock` `.yarnrc.yml` `pnpm-lock.yaml` `pnpm-workspace.yaml` `bun.lock` `bun.lockb`                                                                          |
| python | `pyproject.toml` `uv.lock` `poetry.lock` `pdm.lock` `Pipfile` `Pipfile.lock` `setup.py` `setup.cfg` `requirements*.txt` `requirements/*.txt` `constraints*.txt` `tox.ini`                                                 |
| go     | `go.mod` `go.sum` `go.work` `go.work.sum` `vendor/modules.txt`                                                                                                                                                            |
| maven  | `pom.xml` `.mvn/extensions.xml` `.mvn/maven.config`                                                                                                                                                                       |
| gradle | `build.gradle` `build.gradle.kts` `settings.gradle` `settings.gradle.kts` `gradle.properties` `gradle/*.versions.toml` `gradle.lockfile` `settings-gradle.lockfile` `gradle/dependency-locks/` `buildSrc/` `build-logic/` |
| rust   | `Cargo.toml` `Cargo.lock` `.cargo/config.toml` `.cargo/config`                                                                                                                                                            |
| docker | `Dockerfile` `Dockerfile.*` `*.Dockerfile` `Containerfile` `Containerfile.*` `*.dockerfile`                                                                                                                               |

<!-- markdownlint-enable MD013 -->

Over-matching costs one strict run; under-matching weakens the gate
unnoticed. So the presets include files that often change for other reasons,
such as `tox.ini`, `setup.cfg`, `gradle.properties` and Gradle's
convention-plugin builds.

`docker` covers the image recipe alone. A Docker lane building, say, a
Python application combines presets (`ecosystems: docker,python`) and
passes any Dockerfile with a non-standard name through `patterns`.

The action does not parse manifests or check that a lock file matches
its manifest; that is the SBOM generator's job.

## Testing

```sh
bash tests/dependency-change-test.sh   # scratch git repositories
bash tests/mutate.sh                   # every guard has a failing test
```

`tests/mutate.sh` runs the mutants in parallel, one per CPU unless
`MUTATE_JOBS` says otherwise, and stops each mutant's suite at its
first failing case, since one is all a kill needs.

The script runs on Bash 3.2, the version macOS ships, and CI runs the
tests on Linux and macOS.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/dependency-change-action/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/dependency-change-action/main.svg
