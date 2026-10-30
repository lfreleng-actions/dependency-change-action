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
  directory. What it finds never fails the step.
- It reads, never writes, git state and works offline. A shallow
  checkout that lacks the base leaves the result unresolved; the
  action does not deepen it.
- It logs one line per matched file and a final verdict, with no
  annotations or step summary. File names print on one line, with
  newlines escaped, so a name cannot forge a workflow command.

Each guard that leaves the result unresolved has a test that fails when
the guard goes; `tests/mutate.sh` proves it by disabling each guard in
turn.

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
  `/`, or `.` and `..` segments; such a pattern fails the step.
- A submodule pointer that changes inside `path-prefix` counts as a
  change.

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

The script runs on Bash 3.2, the version macOS ships, and CI runs the
tests on Linux and macOS.

[pre-commit.ci results page]: https://results.pre-commit.ci/latest/github/lfreleng-actions/dependency-change-action/main
[pre-commit.ci status badge]: https://results.pre-commit.ci/badge/github/lfreleng-actions/dependency-change-action/main.svg
