# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Tests for scripts/dependency_change against real git repositories."""

from __future__ import annotations

import contextlib
import dataclasses
import errno
import importlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Generator, Mapping
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import dependency_change as dc  # noqa: E402
from dependency_change import gitobjects, sidecar  # noqa: E402

NULL_SHA = "0" * 40


@contextlib.contextmanager
def working_directory(path: str | bytes | Path) -> Generator[None, None, None]:
    """Run the block with ``path`` as the process working directory."""
    previous = os.getcwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(previous)


class GitRepo:
    """A real git repository in a temporary directory."""

    def __init__(self, path: Path) -> None:
        self.path = path
        path.mkdir(parents=True, exist_ok=True)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "tests@example.invalid")
        self.git("config", "user.name", "Tests")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", os.devnull)

    def git(self, *args: str | bytes, stdin: bytes = b"") -> str:
        completed = subprocess.run(
            ["git", *args],
            cwd=self.path,
            input=stdin,
            capture_output=True,
            check=True,
        )
        return completed.stdout.decode("utf-8", "surrogateescape").strip()

    def add(self, relative: str | bytes) -> None:
        # The literal magic keeps a path starting with ':' from being read as magic.
        path = relative if isinstance(relative, bytes) else os.fsencode(relative)
        self.git(
            "add",
            "-A",
            "--pathspec-from-file=-",
            "--pathspec-file-nul",
            stdin=b":(literal)" + path + b"\0",
        )

    def write(self, relative: str | bytes, content: bytes = b"content\n") -> None:
        target = (
            Path(os.fsdecode(relative))
            if isinstance(relative, bytes)
            else Path(relative)
        )
        full = self.path / target
        full.parent.mkdir(parents=True, exist_ok=True)
        full.write_bytes(content)
        self.add(relative)

    def remove(self, relative: str) -> None:
        self.git("rm", "-q", "--", relative)

    def symlink(self, relative: str, target: str) -> None:
        full = self.path / relative
        full.parent.mkdir(parents=True, exist_ok=True)
        if full.is_symlink() or full.exists():
            full.unlink()
        os.symlink(target, full)
        self.add(relative)

    def gitlink(self, relative: str, sha: str) -> None:
        self.git("update-index", "--add", "--cacheinfo", f"160000,{sha},{relative}")

    def commit(self, message: str = "change") -> str:
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.head()

    def head(self) -> str:
        return self.git("rev-parse", "HEAD")

    def object_count(self) -> int:
        counts = dict(
            line.split(": ", 1) for line in self.git("count-objects", "-v").splitlines()
        )
        return int(counts["count"]) + int(counts["in-pack"])

    def clone(
        self,
        destination: Path,
        depth: int | None = None,
        object_filter: str | None = None,
    ) -> GitRepo:
        args = ["clone", "-q"]
        if depth is not None:
            args.extend(["--depth", str(depth)])
        if object_filter is not None:
            # The server decides whether a filter applies; this side is it.
            self.git("config", "uploadpack.allowFilter", "true")
            args.append(f"--filter={object_filter}")
        subprocess.run(
            ["git", *args, self.path.as_uri(), str(destination)],
            capture_output=True,
            check=True,
        )
        repo = GitRepo.__new__(GitRepo)
        repo.path = destination
        return repo


@dataclasses.dataclass
class Outcome:
    """What one run of the action produced."""

    exit_code: int
    outputs: dict[str, str]
    log: str
    sidecar: dict[str, object] | None


def parse_outputs(raw: bytes) -> dict[str, str]:
    """Parse the heredoc form the action appends to ``GITHUB_OUTPUT``."""
    outputs: dict[str, str] = {}
    lines = raw.split(b"\n")
    index = 0
    while index < len(lines) and lines[index]:
        name, _, delimiter = lines[index].partition(b"<<")
        index += 1
        value: list[bytes] = []
        while lines[index] != delimiter:
            value.append(lines[index])
            index += 1
        index += 1
        outputs[name.decode()] = b"\n".join(value).decode("utf-8", "surrogateescape")
    return outputs


@contextlib.contextmanager
def fake_git_version(output: bytes) -> Generator[None, None, None]:
    """Answer ``git --version`` with ``output``; every other git call is real."""
    real_git = gitobjects.git

    def fake(*args: bytes | str) -> bytes:
        if args == ("--version",):
            return output
        return real_git(*args)

    with mock.patch.object(gitobjects, "git", fake):
        yield


class FailingClose(io.TextIOWrapper):
    """A text handle whose close writes everything out and then fails with EIO."""

    def close(self) -> None:
        super().close()
        raise OSError(errno.EIO, "I/O error")


def failing_fdopen(fd: int, *_args: object, **_kwargs: object) -> io.TextIOWrapper:
    """Stand in for ``os.fdopen`` with a handle that cannot be closed."""
    return FailingClose(io.FileIO(fd, "w"), encoding="utf-8")


class ActionTestCase(unittest.TestCase):
    """Shared fixtures: a temporary directory and a repository with history."""

    def setUp(self) -> None:
        # realpath: macOS hands out /var/folders/..., and /var is a link.
        self.tmp = Path(os.path.realpath(tempfile.mkdtemp(prefix="dependency-change-")))
        self.repo = GitRepo(self.tmp / "repo")

    def run_action(
        self,
        repo: GitRepo,
        *,
        ecosystems: str = "node",
        patterns: str = "",
        prefix: str = ".",
        event: str = "pull_request",
        github_sha: str | None = None,
        before: str = "",
        base: str = "",
        gerrit: str = "",
        output: str | bytes = "dependency-change.json",
        git: str = "",
        env: Mapping[str, str] | None = None,
    ) -> Outcome:
        output_file = self.tmp / "github_output"
        output_file.write_bytes(b"")
        output_text = (
            output.decode("utf-8", "surrogateescape")
            if isinstance(output, bytes)
            else output
        )
        variables = {
            "INPUT_ECOSYSTEMS": ecosystems,
            "INPUT_PATTERNS": patterns,
            "INPUT_PATH_PREFIX": prefix,
            "INPUT_GERRIT_REFSPEC": gerrit,
            "INPUT_BASE": base,
            "INPUT_OUTPUT": output_text,
            "INPUT_GIT": git,
            "GITHUB_EVENT_NAME": event,
            "GITHUB_SHA": repo.head() if github_sha is None else github_sha,
            "EVENT_BEFORE": before,
            "GITHUB_OUTPUT": str(output_file),
        }
        if env:
            variables.update(env)
        log = io.StringIO()
        with working_directory(repo.path), contextlib.redirect_stdout(log):
            exit_code = dc.run(variables)
        sidecar_path = Path(os.fsdecode(repo.path / os.fsdecode(output)))
        sidecar: dict[str, object] | None = None
        # Only components beneath the repository can be links the action
        # must refuse; the temporary root itself is outside its remit.
        through_link = False
        for parent in [sidecar_path, *sidecar_path.parents]:
            if parent == repo.path:
                break
            through_link = through_link or parent.is_symlink()
        if sidecar_path.is_file() and not through_link:
            loaded: object = json.loads(sidecar_path.read_text(encoding="utf-8"))
            assert isinstance(loaded, dict)
            sidecar = {}
            for key, value in loaded.items():  # pyright: ignore[reportUnknownVariableType]
                assert isinstance(key, str)
                sidecar[key] = value
        return Outcome(
            exit_code, parse_outputs(output_file.read_bytes()), log.getvalue(), sidecar
        )

    def assert_changed(self, outcome: Outcome, expected: bool) -> None:
        self.assertEqual(outcome.exit_code, 0, outcome.log)
        self.assertEqual(
            outcome.outputs["changed"], "true" if expected else "false", outcome.outputs
        )
        self.assertEqual(outcome.outputs["manifest"], "dependency-change.json")
        self.assertRegex(outcome.outputs["base"], r"^[0-9a-f]{40}$")
        self.assertIsNotNone(outcome.sidecar)
        assert outcome.sidecar is not None
        self.assertEqual(outcome.sidecar["changed"], expected)
        self.assertEqual(outcome.sidecar["base"], outcome.outputs["base"])

    def assert_unresolved(self, outcome: Outcome, reason_fragment: str) -> None:
        self.assertEqual(outcome.exit_code, 0, outcome.log)
        self.assertEqual(outcome.outputs["changed"], "")
        self.assertEqual(outcome.outputs["base"], "")
        self.assertEqual(outcome.outputs["manifest"], "")
        self.assertTrue(
            outcome.outputs["reason"].startswith("unresolved: "),
            outcome.outputs["reason"],
        )
        self.assertIn(reason_fragment, outcome.outputs["reason"])
        self.assertIsNone(outcome.sidecar)

    def assert_input_error(self, outcome: Outcome, fragment: str) -> None:
        self.assertEqual(outcome.exit_code, 1, outcome.log)
        self.assertEqual(outcome.outputs["changed"], "")
        self.assertIn(fragment, outcome.log)
        self.assertIsNone(outcome.sidecar)

    def seed(self, *paths: str) -> str:
        for path in paths:
            self.repo.write(path)
        return self.repo.commit("seed")

    def commit_two(self) -> None:
        self.seed("package.json")
        self.repo.write("package.json", b"two\n")
        self.repo.commit("two")


class BaseSelectionTests(ActionTestCase):
    """The base-selection table."""

    def test_pull_request_uses_first_parent_of_merge(self) -> None:
        self.seed("package.json", "src/app.js")
        self.repo.git("checkout", "-q", "-b", "feature")
        self.repo.write("src/app.js", b"feature\n")
        self.repo.commit("feature work")
        self.repo.git("checkout", "-q", "main")
        self.repo.write("package.json", b"main side\n")
        self.repo.commit("main dependency bump")
        self.repo.git("merge", "-q", "--no-ff", "--no-edit", "feature")
        # HEAD^1 is the main side, so the dependency bump there is not the change's.
        self.assert_changed(self.run_action(self.repo), False)

    def test_pull_request_merge_sees_change_side(self) -> None:
        self.seed("package.json", "src/app.js")
        self.repo.git("checkout", "-q", "-b", "feature")
        self.repo.write("package.json", b"feature\n")
        self.repo.commit("feature dependency bump")
        self.repo.git("checkout", "-q", "main")
        self.repo.write("src/app.js", b"main\n")
        self.repo.commit("main work")
        self.repo.git("merge", "-q", "--no-ff", "--no-edit", "feature")
        outcome = self.run_action(self.repo)
        self.assert_changed(outcome, True)
        self.assertIn("since", outcome.outputs["reason"])

    def test_push_covers_every_pushed_commit(self) -> None:
        before = self.seed("package.json", "src/app.js")
        self.repo.write("src/app.js", b"one\n")
        self.repo.commit("one")
        self.repo.write("package.json", b"two\n")
        self.repo.commit("two")
        self.repo.write("src/app.js", b"three\n")
        self.repo.commit("three")
        outcome = self.run_action(self.repo, event="push", before=before)
        self.assert_changed(outcome, True)
        self.assertEqual(outcome.outputs["base"], before)

    def test_push_without_dependency_change_is_false(self) -> None:
        before = self.seed("package.json", "src/app.js")
        self.repo.write("src/app.js", b"one\n")
        self.repo.commit("one")
        self.assert_changed(
            self.run_action(self.repo, event="push", before=before), False
        )

    def test_push_creating_branch_is_unresolved(self) -> None:
        self.seed("package.json")
        outcome = self.run_action(self.repo, event="push", before=NULL_SHA)
        self.assert_unresolved(outcome, "push created the branch")

    def test_push_without_before_is_unresolved(self) -> None:
        self.seed("package.json")
        self.assert_unresolved(
            self.run_action(self.repo, event="push", before=""),
            "push created the branch",
        )

    def test_head_not_github_sha_is_unresolved(self) -> None:
        self.seed("package.json")
        self.repo.write("package.json", b"two\n")
        self.repo.commit("two")
        other = "f" * 40
        outcome = self.run_action(self.repo, github_sha=other)
        self.assert_unresolved(outcome, "is not GITHUB_SHA ffffffffffff")

    def test_empty_github_sha_is_unresolved(self) -> None:
        self.seed("package.json")
        self.assert_unresolved(
            self.run_action(self.repo, github_sha=""), "is not GITHUB_SHA"
        )

    def test_schedule_is_unresolved(self) -> None:
        self.seed("package.json")
        self.assert_unresolved(
            self.run_action(self.repo, event="schedule"), "event 'schedule' has no base"
        )

    def test_other_events_are_unresolved(self) -> None:
        self.seed("package.json")
        for event in ("workflow_dispatch", "merge_group", "pull_request_target", ""):
            with self.subTest(event=event):
                self.assert_unresolved(
                    self.run_action(self.repo, event=event),
                    f"event '{event}' has no base",
                )

    def test_gerrit_refspec_uses_first_parent(self) -> None:
        self.seed("package.json")
        self.repo.write("package.json", b"two\n")
        self.repo.commit("two")
        outcome = self.run_action(
            self.repo,
            event="workflow_dispatch",
            gerrit="refs/changes/01/1/1",
            github_sha="",
        )
        self.assert_changed(outcome, True)

    def test_explicit_base_overrides_event(self) -> None:
        first = self.seed("package.json")
        self.repo.write("package.json", b"two\n")
        second = self.repo.commit("two")
        self.repo.write("src/app.js")
        self.repo.commit("three")
        changed = self.run_action(
            self.repo, event="schedule", base=first, github_sha=""
        )
        self.assert_changed(changed, True)
        self.assertEqual(changed.outputs["base"], first)
        unchanged = self.run_action(
            self.repo, event="schedule", base=second[:10], github_sha=""
        )
        self.assert_changed(unchanged, False)
        self.assertEqual(unchanged.outputs["base"], second)

    def test_explicit_base_that_does_not_resolve_is_unresolved(self) -> None:
        self.seed("package.json")
        outcome = self.run_action(self.repo, base="no-such-ref")
        self.assert_unresolved(outcome, "no-such-ref is not in the checkout")

    def test_explicit_base_looking_like_an_option_fails(self) -> None:
        self.seed("package.json")
        self.assert_input_error(
            self.run_action(self.repo, base="--output=/tmp/x"), "is not a revision"
        )

    def test_shallow_checkout_is_unresolved(self) -> None:
        self.seed("package.json")
        self.repo.write("package.json", b"two\n")
        self.repo.commit("two")
        shallow = self.repo.clone(self.tmp / "shallow", depth=1)
        outcome = self.run_action(shallow)
        self.assert_unresolved(outcome, "HEAD^1 is not in the checkout")

    def test_depth_two_checkout_resolves(self) -> None:
        self.seed("package.json")
        self.repo.write("package.json", b"two\n")
        self.repo.commit("two")
        shallow = self.repo.clone(self.tmp / "shallow", depth=2)
        self.assert_changed(self.run_action(shallow), True)

    def test_partial_clone_with_base_tree_missing_is_unresolved(self) -> None:
        # A tree:0 clone holds HEAD's tree from the checkout and no other;
        # the base tree is one a lazy fetch would otherwise pull in.
        self.seed("package.json")
        self.repo.write("package.json", b"two\n")
        self.repo.commit("two")
        partial = self.repo.clone(self.tmp / "partial", object_filter="tree:0")
        before = partial.object_count()
        outcome = self.run_action(partial)
        self.assert_unresolved(outcome, "git ls-tree failed")
        self.assertEqual(partial.object_count(), before, "the action fetched")

    def test_partial_clone_with_both_trees_present_resolves(self) -> None:
        self.seed("package.json")
        self.repo.write("package.json", b"two\n")
        self.repo.commit("two")
        partial = self.repo.clone(self.tmp / "partial", object_filter="blob:none")
        before = partial.object_count()
        self.assert_changed(self.run_action(partial), True)
        self.assertEqual(partial.object_count(), before, "the action fetched")

    def test_partial_clone_on_old_git_is_unresolved(self) -> None:
        # Git before 2.46 ignores GIT_NO_LAZY_FETCH, so the action cannot
        # promise not to fetch: the result is unresolved even though both
        # trees are present and the run would otherwise resolve.
        self.commit_two()
        partial = self.repo.clone(self.tmp / "partial", object_filter="blob:none")
        before = partial.object_count()
        with fake_git_version(b"git version 2.45.2\n"):
            outcome = self.run_action(partial)
        self.assert_unresolved(outcome, "git 2.45.2 may fetch missing objects")
        self.assertIn("needs git 2.46", outcome.outputs["reason"])
        self.assertEqual(partial.object_count(), before, "the action fetched")

    def test_partial_clone_by_extension_on_old_git_is_unresolved(self) -> None:
        # Older git recorded the promisor remote in extensions.partialClone
        # rather than remote.<name>.promisor; both spellings count.
        self.commit_two()
        self.repo.git("config", "extensions.partialClone", "origin")
        with fake_git_version(b"git version 2.39.5 (Apple Git-154)\n"):
            outcome = self.run_action(self.repo)
        self.assert_unresolved(outcome, "git 2.39.5 may fetch missing objects")

    def test_partial_clone_on_git_2_46_resolves(self) -> None:
        self.commit_two()
        partial = self.repo.clone(self.tmp / "partial", object_filter="blob:none")
        with fake_git_version(b"git version 2.46.0\n"):
            self.assert_changed(self.run_action(partial), True)

    def test_full_clone_on_old_git_is_not_checked(self) -> None:
        self.commit_two()
        with fake_git_version(b"git version 2.45.2\n"):
            self.assert_changed(self.run_action(self.repo), True)

    def test_partial_clone_with_unreadable_git_version_is_unresolved(self) -> None:
        self.commit_two()
        partial = self.repo.clone(self.tmp / "partial", object_filter="blob:none")
        with fake_git_version(b"gti version two\n"):
            outcome = self.run_action(partial)
        self.assert_unresolved(outcome, "unexpected git version 'gti version two'")

    def test_root_commit_has_no_parent(self) -> None:
        self.seed("package.json")
        self.assert_unresolved(
            self.run_action(self.repo), "HEAD^1 is not in the checkout"
        )

    def test_unexpected_exception_is_unresolved(self) -> None:
        self.seed("package.json")
        self.repo.write("package.json", b"two\n")
        self.repo.commit("two")
        with mock.patch.object(
            gitobjects, "parse_diff", side_effect=RuntimeError("boom")
        ):
            outcome = self.run_action(self.repo)
        self.assert_unresolved(outcome, "unexpected RuntimeError: boom")


class MatchingTests(ActionTestCase):
    """Pattern matching against the diff."""

    def change(self, *paths: str, delete: tuple[str, ...] = ()) -> None:
        for path in paths:
            self.repo.write(path, b"changed\n")
        for path in delete:
            self.repo.remove(path)
        self.repo.commit("change")

    def test_look_alike_names_do_not_match(self) -> None:
        self.seed("src/app.js")
        self.change(
            "package.jsonx",
            "mypackage.json",
            "package.json.bak",
            "requirements.txt.lock",
            "go.modx",
            "src/Dockerfile.d/x",
            "yarn.lock/inner",
        )
        self.assert_changed(
            self.run_action(self.repo, ecosystems="node,python,go,docker"), False
        )

    def test_deletion_counts(self) -> None:
        self.seed("package.json", "src/app.js")
        self.change(delete=("package.json",))
        self.assert_changed(self.run_action(self.repo), True)

    def test_rename_counts_on_both_sides(self) -> None:
        self.seed("package.json", "src/app.js")
        self.repo.git("mv", "package.json", "renamed.json")
        self.repo.commit("rename")
        outcome = self.run_action(self.repo)
        self.assert_changed(outcome, True)
        assert outcome.sidecar is not None
        self.assertEqual(outcome.sidecar["files"], ["package.json"])

    def test_inside_prefix_matches_at_any_depth(self) -> None:
        self.seed("apps/web/src/app.js")
        self.change("apps/web/packages/ui/package.json")
        self.assert_changed(self.run_action(self.repo, prefix="apps/web"), True)

    def test_sibling_project_never_matches(self) -> None:
        self.seed("apps/web/src/app.js", "apps/api/package.json")
        self.change("apps/api/package.json", "libs/shared/package.json")
        self.assert_changed(self.run_action(self.repo, prefix="apps/web"), False)

    def test_ancestor_directory_matches(self) -> None:
        self.seed("apps/web/src/app.js")
        self.change("package.json")
        self.assert_changed(self.run_action(self.repo, prefix="apps/web"), True)
        self.change("apps/pnpm-lock.yaml")
        self.assert_changed(self.run_action(self.repo, prefix="apps/web"), True)

    def test_ancestor_match_is_anchored_not_deep(self) -> None:
        self.seed("apps/web/src/app.js")
        self.change("tools/package.json")
        self.assert_changed(self.run_action(self.repo, prefix="apps/web"), False)

    def test_path_pattern_relative_to_anchor(self) -> None:
        self.seed("apps/web/src/app.js")
        self.change("requirements/dev.txt")
        self.assert_changed(
            self.run_action(self.repo, ecosystems="python", prefix="apps/web"), True
        )
        self.change("other/requirements/dev.txt")
        self.assert_changed(
            self.run_action(self.repo, ecosystems="python", prefix="apps/web"), False
        )
        self.change("apps/web/deep/requirements/dev.txt")
        self.assert_changed(
            self.run_action(self.repo, ecosystems="python", prefix="apps/web"), True
        )

    def test_directory_pattern_matches_everything_beneath(self) -> None:
        self.seed("apps/web/src/app.js")
        self.change("buildSrc/src/main/kotlin/Plugin.kt")
        self.assert_changed(
            self.run_action(self.repo, ecosystems="gradle", prefix="apps/web"), True
        )
        self.change("apps/web/x/build-logic/conventions/build.gradle.kts.bak")
        self.assert_changed(
            self.run_action(self.repo, ecosystems="gradle", prefix="apps/web"), True
        )
        self.change("buildSrcX/file")
        self.assert_changed(
            self.run_action(self.repo, ecosystems="gradle", prefix="apps/web"), False
        )

    def test_star_stays_within_a_segment(self) -> None:
        self.seed("src/app.js")
        self.change("gradle/sub/libs.versions.toml")
        self.assert_changed(self.run_action(self.repo, ecosystems="gradle"), False)
        self.change("gradle/libs.versions.toml")
        self.assert_changed(self.run_action(self.repo, ecosystems="gradle"), True)

    def test_maven_jvm_config_counts(self) -> None:
        self.seed("src/Main.java")
        self.change(".mvn/jvm.config")
        self.assert_changed(self.run_action(self.repo, ecosystems="maven"), True)
        self.change(".mvn/wrapper/maven-wrapper.properties")
        self.assert_changed(self.run_action(self.repo, ecosystems="maven"), False)

    def test_gradle_applied_scripts_count(self) -> None:
        self.seed("src/Main.java")
        for script in (
            "dependencies.gradle",
            "gradle/libs.gradle.kts",
            "app/versions.gradle",
        ):
            with self.subTest(script=script):
                self.change(script)
                self.assert_changed(
                    self.run_action(self.repo, ecosystems="gradle"), True
                )
        self.change("docs/build.gradle.md", "gradle.png")
        self.assert_changed(self.run_action(self.repo, ecosystems="gradle"), False)

    def test_patterns_only_use(self) -> None:
        self.seed("src/app.js")
        self.change("deps/custom.lock")
        outcome = self.run_action(
            self.repo, ecosystems="", patterns="\n  custom.lock \n\n"
        )
        self.assert_changed(outcome, True)

    def test_patterns_add_to_presets(self) -> None:
        self.seed("src/app.js")
        self.change("docker/app.Dockerfile.tmpl")
        self.assert_changed(self.run_action(self.repo, ecosystems="docker"), False)
        self.assert_changed(
            self.run_action(
                self.repo, ecosystems="docker", patterns="*.Dockerfile.tmpl"
            ),
            True,
        )

    def test_every_preset_pattern_matches_its_file(self) -> None:
        self.seed("src/app.js")
        # Each sample gets its own directory: on a case-insensitive file
        # system 'x.Dockerfile' and 'x.dockerfile' would otherwise be one
        # file, and the second write an empty change.
        samples = [
            (name, pattern)
            for name, patterns in dc.PRESETS.items()
            for pattern in patterns
        ]
        for index, (name, pattern) in enumerate(samples):
            sample = pattern.replace("*", "x")
            if sample.endswith("/"):
                sample += "inner/file"
            path = f"app/p{index}/{sample}"
            with self.subTest(preset=name, pattern=pattern):
                self.change(path)
                outcome = self.run_action(self.repo, ecosystems=name)
                self.assert_changed(outcome, True)
                assert outcome.sidecar is not None
                self.assertEqual(outcome.sidecar["files"], [path])

    def test_every_preset_ignores_source_files(self) -> None:
        self.seed("src/app.js")
        self.change(
            "src/main.py",
            "src/main.go",
            "src/Main.java",
            "src/main.rs",
            "docs/index.md",
        )
        self.assert_changed(
            self.run_action(self.repo, ecosystems=",".join(dc.PRESETS)), False
        )

    def test_combined_presets(self) -> None:
        self.seed("src/app.js")
        self.change("Dockerfile")
        self.assert_changed(self.run_action(self.repo, ecosystems="python"), False)
        self.assert_changed(
            self.run_action(self.repo, ecosystems="docker, python"), True
        )

    def test_one_log_line_per_match_and_a_verdict(self) -> None:
        self.seed("src/app.js")
        self.change("package.json", "yarn.lock", "src/app.js")
        outcome = self.run_action(self.repo)
        lines = outcome.log.splitlines()
        self.assertEqual(
            lines,
            [
                "dependency file changed: 'package.json'",
                "dependency file changed: 'yarn.lock'",
                "dependency change: changed=true (2 dependency files changed since "
                + outcome.outputs["base"][:12]
                + ")",
            ],
        )
        self.assertEqual(
            outcome.outputs["reason"],
            lines[-1][len("dependency change: changed=true (") : -1],
        )


class NewlinePathTests(ActionTestCase):
    """Paths carrying newlines stay byte-exact and cannot forge log lines."""

    def assert_log_is_safe(self, outcome: Outcome) -> None:
        for line in outcome.log.splitlines():
            self.assertFalse(line.startswith("::"), line)
            self.assertNotIn("##[", line)
        self.assertNotIn("\n", outcome.outputs["reason"])
        self.assertNotIn("##[", outcome.outputs["reason"])

    def test_legacy_command_marker_is_escaped_anywhere(self) -> None:
        self.seed("src/app.js")
        path = "##[error]injected/package.json"
        self.repo.write(path)
        self.repo.commit("change")
        outcome = self.run_action(self.repo)
        self.assert_changed(outcome, True)
        self.assert_log_is_safe(outcome)
        self.assertIn(
            "dependency file changed: '##\\x5berror]injected/package.json'", outcome.log
        )
        assert outcome.sidecar is not None
        self.assertEqual(outcome.sidecar["files"], [path])
        self.repo.symlink("##[warning]x", "src")
        self.repo.commit("link")
        self.repo.write("src/app.js", b"two\n")
        self.repo.commit("two")
        outcome = self.run_action(self.repo)
        self.assert_unresolved(outcome, "symbolic link '##\\x5bwarning]x' could stand")
        self.assert_log_is_safe(outcome)

    def test_newline_at_start_middle_and_end_of_component(self) -> None:
        for name in ("\n::warning::x", "mid\ndle", "end\n"):
            with self.subTest(name=name):
                repo = GitRepo(self.tmp / ("repo-" + str(abs(hash(name)))))
                repo.write("src/app.js")
                repo.commit("seed")
                path = f"{name}/package.json"
                repo.write(path)
                repo.commit("change")
                outcome = self.run_action(repo)
                self.assert_changed(outcome, True)
                self.assert_log_is_safe(outcome)
                assert outcome.sidecar is not None
                self.assertEqual(outcome.sidecar["files"], [path])
                self.assertIn(dc.display(path.encode()), outcome.log)

    def test_trailing_newline_makes_a_different_name(self) -> None:
        # 'package.json\n' is not 'package.json'; a regex ending in $ would
        # say otherwise, because $ also matches before a final newline.
        self.seed("src/app.js")
        self.repo.write("package.json\n")
        self.repo.write("sub/go.mod\n")
        self.repo.commit("change")
        outcome = self.run_action(self.repo, ecosystems="node,go")
        self.assert_changed(outcome, False)
        self.assert_log_is_safe(outcome)

    def test_newline_in_unresolved_reason_is_escaped(self) -> None:
        self.seed("src/app.js")
        self.repo.symlink("::error::\nfile", "src/app.js")
        self.repo.commit("link")
        self.repo.write("src/app.js", b"two\n")
        self.repo.commit("two")
        outcome = self.run_action(self.repo)
        self.assert_unresolved(
            outcome,
            "symbolic link '::error::\\nfile' could stand for a dependency file",
        )
        self.assert_log_is_safe(outcome)

    def test_working_directory_and_output_ending_in_newline(self) -> None:
        repo = GitRepo(self.tmp / "repo\n")
        repo.write("package.json")
        repo.commit("seed")
        repo.write("package.json", b"two\n")
        repo.commit("two")
        outcome = self.run_action(repo, output="out\n/dependency-change.json\n")
        self.assertEqual(outcome.exit_code, 0, outcome.log)
        self.assertEqual(outcome.outputs["changed"], "true")
        self.assertEqual(outcome.outputs["manifest"], "out\n/dependency-change.json\n")
        self.assertTrue((repo.path / "out\n" / "dependency-change.json\n").is_file())


class PrefixTests(ActionTestCase):
    """Validation of ``path-prefix`` against ``HEAD``'s tree."""

    def test_prefix_is_normalised(self) -> None:
        self.seed("apps/web/src/app.js")
        self.repo.write("apps/web/package.json")
        self.repo.commit("change")
        self.assert_changed(self.run_action(self.repo, prefix="./apps//web/"), True)
        self.assert_changed(self.run_action(self.repo, prefix="apps/api/../web"), True)
        self.assert_changed(self.run_action(self.repo, prefix=""), True)

    def test_missing_prefix_is_unresolved(self) -> None:
        self.seed("apps/web/package.json")
        self.repo.write("apps/web/package.json", b"two\n")
        self.repo.commit("change")
        self.assert_unresolved(
            self.run_action(self.repo, prefix="apps/missing"),
            "is not a directory in HEAD",
        )

    def test_file_as_prefix_is_unresolved(self) -> None:
        self.seed("apps/web/package.json")
        self.repo.commit("two")
        outcome = self.run_action(self.repo, prefix="apps/web/package.json")
        self.assert_unresolved(
            outcome, "'apps/web/package.json' is not a directory in HEAD"
        )

    def test_prefix_outside_repository_is_unresolved(self) -> None:
        self.seed("apps/web/package.json")
        self.repo.commit("two")
        self.assert_unresolved(
            self.run_action(self.repo, prefix="../other"), "is outside the repository"
        )
        self.assert_unresolved(
            self.run_action(self.repo, prefix="apps/../.."), "is outside the repository"
        )
        self.assert_unresolved(
            self.run_action(self.repo, prefix="/apps/web"), "is outside the repository"
        )

    def test_symlinked_prefix_is_unresolved(self) -> None:
        self.seed("real/package.json")
        self.repo.symlink("apps/web", "../real")
        self.repo.commit("link")
        self.repo.write("real/package.json", b"two\n")
        self.repo.commit("two")
        outcome = self.run_action(self.repo, prefix="apps/web")
        self.assert_unresolved(
            outcome, "path-prefix 'apps/web' passes through symbolic link 'apps/web'"
        )
        outcome = self.run_action(self.repo, prefix="apps/web/sub")
        self.assert_unresolved(outcome, "passes through symbolic link 'apps/web'")

    def test_submodule_prefix_is_unresolved(self) -> None:
        first = self.seed("src/app.js")
        self.repo.gitlink("vendor/lib", first)
        self.repo.commit("gitlink")
        self.repo.write("src/app.js", b"two\n")
        self.repo.commit("two")
        outcome = self.run_action(self.repo, prefix="vendor/lib")
        self.assert_unresolved(outcome, "passes through submodule 'vendor/lib'")


class LinkAndSubmoduleTests(ActionTestCase):
    """Symbolic links and submodules fail closed unless they changed."""

    def test_unchanged_symlink_inside_prefix_is_unresolved(self) -> None:
        self.seed("src/app.js")
        self.repo.symlink("docs", "src")
        self.repo.commit("link")
        self.repo.write("src/app.js", b"two\n")
        self.repo.commit("two")
        outcome = self.run_action(self.repo)
        self.assert_unresolved(
            outcome, "symbolic link 'docs' could stand for a dependency file"
        )

    def test_changed_symlink_inside_prefix_is_changed(self) -> None:
        self.seed("src/app.js", "real.json")
        self.repo.symlink("package.json", "real.json")
        self.repo.commit("link")
        outcome = self.run_action(self.repo)
        self.assert_changed(outcome, True)
        self.assertIn("dependency file changed: 'package.json'", outcome.log)

    def test_changed_link_a_pattern_reaches_beneath_is_changed(self) -> None:
        self.seed("src/app.js", "real/x")
        self.repo.symlink("docs", "real")
        self.repo.commit("link")
        outcome = self.run_action(self.repo)
        self.assert_changed(outcome, True)
        self.assertIn(
            "symbolic link changed where a dependency file could be: 'docs'",
            outcome.log,
        )
        assert outcome.sidecar is not None
        self.assertEqual(outcome.sidecar["files"], ["docs"])

    def test_retargeted_symlink_is_changed(self) -> None:
        self.seed("src/app.js", "a.json", "b.json")
        self.repo.symlink("deps", "a.json")
        self.repo.commit("link")
        self.repo.symlink("deps", "b.json")
        self.repo.commit("retarget")
        self.assert_changed(self.run_action(self.repo), True)

    def test_removed_symlink_is_changed(self) -> None:
        self.seed("src/app.js", "a.json")
        self.repo.symlink("deps", "a.json")
        self.repo.commit("link")
        self.repo.remove("deps")
        self.repo.commit("unlink")
        self.assert_changed(self.run_action(self.repo), True)

    def test_unchanged_submodule_inside_prefix_is_unresolved(self) -> None:
        first = self.seed("src/app.js")
        self.repo.gitlink("vendor/lib", first)
        self.repo.commit("gitlink")
        self.repo.write("src/app.js", b"two\n")
        self.repo.commit("two")
        self.assert_unresolved(
            self.run_action(self.repo), "submodule 'vendor/lib' could stand for"
        )

    def test_moved_submodule_pointer_is_changed(self) -> None:
        first = self.seed("src/app.js")
        self.repo.gitlink("vendor/lib", first)
        second = self.repo.commit("gitlink")
        self.repo.gitlink("vendor/lib", second)
        self.repo.commit("bump")
        self.assert_changed(self.run_action(self.repo), True)

    def bump_submodule_pointer(self) -> None:
        """Move 'vendor/lib', registered in .gitmodules under another name."""
        first = self.seed("src/app.js")
        self.repo.write(
            ".gitmodules",
            b'[submodule "lib"]\n\tpath = vendor/lib\n\turl = ./vendor/lib\n',
        )
        self.repo.gitlink("vendor/lib", first)
        second = self.repo.commit("gitlink")
        self.repo.gitlink("vendor/lib", second)
        self.repo.commit("bump")

    def test_moved_pointer_hidden_by_diff_config_is_changed(self) -> None:
        self.bump_submodule_pointer()
        self.repo.git("config", "diff.ignoreSubmodules", "all")
        outcome = self.run_action(self.repo)
        self.assert_changed(outcome, True)
        assert outcome.sidecar is not None
        self.assertEqual(outcome.sidecar["files"], ["vendor/lib"])

    def test_moved_pointer_hidden_by_submodule_config_is_changed(self) -> None:
        self.bump_submodule_pointer()
        self.repo.git("config", "submodule.lib.ignore", "all")
        self.assert_changed(self.run_action(self.repo), True)

    def test_moved_pointer_hidden_by_gitmodules_in_checkout_is_changed(self) -> None:
        # The working tree's .gitmodules, which the change under review
        # controls, is what git reads; it is not even staged here.
        self.bump_submodule_pointer()
        (self.repo.path / ".gitmodules").write_bytes(
            b'[submodule "lib"]\n\tpath = vendor/lib\n\turl = ./vendor/lib\n'
            b"\tignore = all\n"
        )
        self.assert_changed(self.run_action(self.repo), True)

    def test_unchanged_submodule_hidden_by_diff_config_is_unresolved(self) -> None:
        first = self.seed("src/app.js")
        self.repo.gitlink("vendor/lib", first)
        self.repo.commit("gitlink")
        self.repo.write("src/app.js", b"two\n")
        self.repo.commit("two")
        self.repo.git("config", "diff.ignoreSubmodules", "all")
        self.assert_unresolved(
            self.run_action(self.repo), "submodule 'vendor/lib' could stand for"
        )

    def test_unchanged_symlink_above_prefix_is_unresolved_when_reachable(self) -> None:
        self.seed("apps/web/src/app.js", "real.json")
        self.repo.symlink("package.json", "real.json")
        self.repo.commit("link")
        self.repo.write("apps/web/src/app.js", b"two\n")
        self.repo.commit("two")
        outcome = self.run_action(self.repo, prefix="apps/web")
        self.assert_unresolved(
            outcome, "symbolic link 'package.json' could stand for a dependency file"
        )

    def test_symlink_a_pattern_reaches_past_above_prefix_is_unresolved(self) -> None:
        self.seed("apps/web/src/app.js", "real/x")
        self.repo.symlink("gradle", "real")
        self.repo.symlink("buildSrc", "real")
        self.repo.commit("links")
        self.repo.write("apps/web/src/app.js", b"two\n")
        self.repo.commit("two")
        outcome = self.run_action(self.repo, ecosystems="gradle", prefix="apps/web")
        self.assert_unresolved(
            outcome, "symbolic link 'buildSrc' could stand for a dependency file"
        )
        outcome = self.run_action(
            self.repo,
            ecosystems="",
            patterns="gradle/*.versions.toml",
            prefix="apps/web",
        )
        self.assert_unresolved(
            outcome, "symbolic link 'gradle' could stand for a dependency file"
        )

    def test_unreachable_links_above_prefix_are_ignored(self) -> None:
        first = self.seed("apps/web/src/app.js", "real/x", "apps/api/package.json")
        self.repo.symlink("docs", "real")
        self.repo.symlink("apps/other", "api")
        self.repo.gitlink("third-party", first)
        self.repo.commit("links")
        self.repo.write("apps/web/src/app.js", b"two\n")
        self.repo.commit("two")
        self.assert_changed(self.run_action(self.repo, prefix="apps/web"), False)

    def test_changed_dependency_file_wins_over_unchanged_link(self) -> None:
        self.seed("src/app.js")
        self.repo.symlink("docs", "src")
        self.repo.commit("link")
        self.repo.write("package.json")
        self.repo.commit("dep")
        self.assert_changed(self.run_action(self.repo), True)

    def test_link_replacing_prefix_ancestor_in_base_is_changed(self) -> None:
        # In the base, 'apps' is a link and 'apps/web' lives wherever it
        # points; HEAD turns it into a plain directory with no dependency
        # file. The project directory's own identity changed, so the
        # dependency set may have moved: a removed ancestor entry counts.
        self.seed("real/web/src/app.js", "real/web/package.json")
        self.repo.symlink("apps", "real")
        self.repo.commit("link")
        self.repo.remove("apps")
        self.repo.write("apps/web/src/app.js")
        self.repo.commit("materialise")
        outcome = self.run_action(self.repo, prefix="apps/web")
        self.assert_changed(outcome, True)
        assert outcome.sidecar is not None
        self.assertEqual(outcome.sidecar["files"], ["apps"])

    def test_submodule_replacing_prefix_ancestor_in_base_is_changed(self) -> None:
        first = self.seed("src/app.js")
        self.repo.gitlink("apps", first)
        self.repo.commit("gitlink")
        self.repo.git("rm", "-q", "--cached", "apps")
        self.repo.write("apps/web/src/app.js")
        self.repo.commit("materialise")
        self.assert_changed(self.run_action(self.repo, prefix="apps/web"), True)

    def test_unchanged_prefix_ancestor_directory_is_not_reachable(self) -> None:
        self.seed("apps/web/src/app.js", "real/x")
        self.repo.symlink("apps/docs", "../real")
        self.repo.commit("link")
        self.repo.write("apps/web/src/app.js", b"two\n")
        self.repo.commit("two")
        self.assert_changed(self.run_action(self.repo, prefix="apps/web"), False)

    def test_link_in_base_tree_only_counts(self) -> None:
        self.seed("src/app.js", "a.json")
        self.repo.symlink("yarn.lock", "a.json")
        self.repo.commit("link")
        self.repo.remove("yarn.lock")
        self.repo.write("src/app.js", b"two\n")
        self.repo.commit("drop")
        self.assert_changed(self.run_action(self.repo), True)


class SidecarTests(ActionTestCase):
    """The sidecar delete and write through descriptor-relative opens."""

    def test_planted_sidecar_is_removed(self) -> None:
        self.commit_two()
        planted = self.repo.path / "dependency-change.json"
        planted.write_text('{"changed": false}\n', encoding="utf-8")
        outcome = self.run_action(self.repo, event="schedule")
        self.assert_unresolved(outcome, "event 'schedule'")
        self.assertFalse(planted.exists())

    def test_planted_sidecar_in_missing_directory_is_fine(self) -> None:
        self.commit_two()
        outcome = self.run_action(
            self.repo, event="schedule", output="missing/dir/out.json"
        )
        self.assert_unresolved(outcome, "event 'schedule'")
        self.assertFalse((self.repo.path / "missing").exists())

    def test_sidecar_is_written_into_new_directories(self) -> None:
        self.commit_two()
        outcome = self.run_action(
            self.repo, output="build/reports/dependency-change.json"
        )
        self.assertEqual(outcome.exit_code, 0, outcome.log)
        self.assertEqual(
            outcome.outputs["manifest"], "build/reports/dependency-change.json"
        )
        written = json.loads(
            (self.repo.path / "build/reports/dependency-change.json").read_text()
        )
        self.assertEqual(written["changed"], True)
        self.assertEqual(written["files"], ["package.json"])
        self.assertEqual(written["schema"], 1)

    def test_sidecar_is_replaced(self) -> None:
        self.commit_two()
        (self.repo.path / "dependency-change.json").write_text(
            "stale", encoding="utf-8"
        )
        outcome = self.run_action(self.repo)
        self.assert_changed(outcome, True)

    def test_absolute_output_inside_working_directory(self) -> None:
        self.commit_two()
        absolute = os.path.join(os.path.realpath(self.repo.path), "sub", "out.json")
        with working_directory(os.path.realpath(self.repo.path)):
            outcome = self.run_action(self.repo, output=absolute)
        self.assertEqual(outcome.exit_code, 0, outcome.log)
        self.assertTrue((self.repo.path / "sub" / "out.json").is_file())

    def test_output_outside_working_directory_fails(self) -> None:
        self.commit_two()
        for output in (
            "../escape.json",
            "sub/../../escape.json",
            "/tmp/escape.json",
            ".",
            "",
        ):
            with self.subTest(output=output):
                outcome = self.run_action(self.repo, output=output)
                if output == "":
                    self.assertEqual(outcome.exit_code, 0)
                    continue
                self.assert_input_error(outcome, "outside the working directory")
        self.assertFalse((self.tmp / "escape.json").exists())

    def test_output_directory_component_that_is_a_file_fails(self) -> None:
        self.commit_two()
        (self.repo.path / "file").write_text("x", encoding="utf-8")
        self.assert_input_error(
            self.run_action(self.repo, output="file/out.json"), "is not a directory"
        )

    def test_output_that_is_a_directory_fails(self) -> None:
        self.commit_two()
        (self.repo.path / "dir.json").mkdir()
        self.assert_input_error(
            self.run_action(self.repo, output="dir.json"), "dir.json"
        )
        self.assertTrue((self.repo.path / "dir.json").is_dir())

    def test_link_at_each_directory_position_of_output_is_refused(self) -> None:
        self.commit_two()
        outside = self.tmp / "outside"
        outside.mkdir()
        victim = outside / "c.json"
        victim.write_text("precious", encoding="utf-8")
        output = "a/b/c.json"
        cases = {
            "a": (self.repo.path / "a", str(outside)),
            "a/b": (self.repo.path / "a" / "b", str(outside)),
        }
        for position, (link, target) in cases.items():
            with self.subTest(position=position):
                link.parent.mkdir(parents=True, exist_ok=True)
                os.symlink(target, link)
                try:
                    outcome = self.run_action(self.repo, output=output)
                    self.assertEqual(outcome.exit_code, 1, outcome.log)
                    self.assertIn("is not a directory", outcome.log)
                    self.assertEqual(outcome.outputs["changed"], "")
                    self.assertTrue(link.is_symlink())
                    self.assertEqual(victim.read_text(encoding="utf-8"), "precious")
                    self.assertEqual(
                        sorted(path.name for path in outside.iterdir()), ["c.json"]
                    )
                finally:
                    link.unlink()
                    for directory in (self.repo.path / "a" / "b", self.repo.path / "a"):
                        if directory.is_dir():
                            directory.rmdir()

    def test_link_as_output_file_is_replaced_not_followed(self) -> None:
        # The final component is deleted before detection, like any planted
        # sidecar; the link's target is never opened or written.
        self.commit_two()
        victim = self.tmp / "victim.json"
        victim.write_text("precious", encoding="utf-8")
        os.symlink(victim, self.repo.path / "dependency-change.json")
        outcome = self.run_action(self.repo)
        self.assert_changed(outcome, True)
        self.assertEqual(victim.read_text(encoding="utf-8"), "precious")
        self.assertFalse((self.repo.path / "dependency-change.json").is_symlink())

    def test_link_as_output_file_is_removed_on_unresolved_run(self) -> None:
        self.commit_two()
        victim = self.tmp / "victim.json"
        victim.write_text("precious", encoding="utf-8")
        os.symlink(victim, self.repo.path / "dependency-change.json")
        outcome = self.run_action(self.repo, event="schedule")
        self.assert_unresolved(outcome, "event 'schedule'")
        self.assertEqual(victim.read_text(encoding="utf-8"), "precious")
        self.assertFalse((self.repo.path / "dependency-change.json").exists())
        self.assertFalse((self.repo.path / "dependency-change.json").is_symlink())

    def test_failed_sidecar_write_is_unresolved_and_leaves_no_file(self) -> None:
        self.commit_two()
        disk_full = OSError(errno.ENOSPC, "No space left on device")
        with mock.patch.object(json, "dumps", side_effect=disk_full):
            outcome = self.run_action(self.repo)
        self.assert_unresolved(outcome, "unexpected OSError")
        self.assertFalse((self.repo.path / "dependency-change.json").exists())

    def test_failed_sidecar_close_removes_the_partial_file(self) -> None:
        self.commit_two()
        with mock.patch.object(os, "fdopen", failing_fdopen):
            outcome = self.run_action(self.repo)
        self.assert_unresolved(outcome, "unexpected OSError")
        self.assertFalse((self.repo.path / "dependency-change.json").exists())

    @contextlib.contextmanager
    def cleanup_failing_with(
        self, exc: OSError, *, gone: bool = False
    ) -> Generator[None, None, None]:
        """Make the close of the sidecar fail, then its cleanup unlink too.

        With ``gone``, the file is really removed before the unlink raises,
        as when something else cleared it first.
        """
        real_unlink = os.unlink
        opened: list[int] = []

        def tracking_fdopen(
            fd: int, *args: object, **kwargs: object
        ) -> io.TextIOWrapper:
            opened.append(fd)
            return failing_fdopen(fd, *args, **kwargs)

        def unlink(path: bytes, *, dir_fd: int | None = None) -> None:
            if opened:
                if gone:
                    real_unlink(path, dir_fd=dir_fd)
                raise exc
            real_unlink(path, dir_fd=dir_fd)

        # The stand-in must count as dir_fd-capable for the platform check.
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(os, "fdopen", tracking_fdopen))
            stack.enter_context(mock.patch.object(os, "unlink", unlink))
            stack.enter_context(
                mock.patch.object(os, "supports_dir_fd", os.supports_dir_fd | {unlink})
            )
            yield

    def test_failed_cleanup_after_failed_write_fails_the_step(self) -> None:
        self.commit_two()
        partial = self.repo.path / "dependency-change.json"
        with self.cleanup_failing_with(OSError(errno.EIO, "I/O error")):
            outcome = self.run_action(self.repo)
        # The flushed JSON is readable at the fixed path a consumer
        # configures, so an unresolved exit 0 would let it read a verdict
        # the action never stood behind: the step fails instead.
        self.assertEqual(outcome.exit_code, 1, outcome.log)
        self.assertIn(
            "error: output 'dependency-change.json' cannot be removed after a "
            "failed write (OSError: [Errno 5] I/O error)",
            outcome.log,
        )
        self.assertEqual(outcome.outputs["changed"], "")
        self.assertEqual(outcome.outputs["manifest"], "")
        self.assertEqual(outcome.outputs["reason"], "")
        # What survived is a complete, readable verdict: exactly the file a
        # consumer must not be allowed to trust after exit 0.
        self.assertTrue(partial.is_file())
        self.assertIsNotNone(outcome.sidecar)
        assert outcome.sidecar is not None
        self.assertIs(outcome.sidecar["changed"], True)

    def test_cleanup_finding_no_file_is_still_unresolved(self) -> None:
        self.commit_two()
        with self.cleanup_failing_with(
            FileNotFoundError(errno.ENOENT, "gone"), gone=True
        ):
            outcome = self.run_action(self.repo)
        self.assert_unresolved(outcome, "unexpected OSError")

    def test_failed_sidecar_removal_fails_the_step(self) -> None:
        self.commit_two()
        planted = self.repo.path / "dependency-change.json"
        planted.write_text('{"changed": false}\n', encoding="utf-8")
        with mock.patch.object(
            sidecar, "unlink_final", side_effect=OSError(errno.EIO, "I/O error")
        ):
            outcome = self.run_action(self.repo)
        # The planted file survived, where a consumer reading a fixed
        # manifest path would take its stale false: the step fails rather
        # than reporting unresolved, and no output points at the file.
        self.assertEqual(outcome.exit_code, 1, outcome.log)
        self.assertIn("error: cannot clear the sidecar", outcome.log)
        self.assertIn("unexpected OSError", outcome.log)
        self.assertEqual(outcome.outputs["changed"], "")
        self.assertEqual(outcome.outputs["manifest"], "")
        self.assertEqual(outcome.outputs["reason"], "")
        self.assertEqual(planted.read_text(encoding="utf-8"), '{"changed": false}\n')

    def test_output_path_error_still_fails_the_step_after_detection(self) -> None:
        self.commit_two()
        (self.repo.path / "reports").write_text("x", encoding="utf-8")
        outcome = self.run_action(self.repo, output="reports/out.json")
        self.assert_input_error(outcome, "is not a directory")

    def test_manifest_output_is_the_normalised_path(self) -> None:
        self.commit_two()
        outcome = self.run_action(self.repo, output="./reports/../signal.json")
        self.assertEqual(outcome.exit_code, 0, outcome.log)
        self.assertEqual(outcome.outputs["manifest"], "signal.json")
        self.assertTrue((self.repo.path / "signal.json").is_file())
        self.assertFalse((self.repo.path / "reports").exists())
        absolute = os.path.join(str(self.repo.path), "sub", ".", "out.json")
        outcome = self.run_action(self.repo, output=absolute)
        self.assertEqual(
            outcome.outputs["manifest"], str(self.repo.path / "sub" / "out.json")
        )

    def test_unsupported_platform_fails(self) -> None:
        self.commit_two()
        with mock.patch.object(os, "supports_dir_fd", frozenset[object]()):
            outcome = self.run_action(self.repo)
        self.assert_input_error(outcome, "directory descriptor")


class TrustedGitTests(ActionTestCase):
    """Git runs from the ``git`` input, with no caller ``GIT_*`` settings."""

    def setUp(self) -> None:
        super().setUp()
        real = shutil.which("git")
        assert real is not None
        self.real_git = os.path.realpath(real)

    def script(self, name: str, body: str, mode: int = 0o755) -> Path:
        """Write a shell script outside the repository and return its path."""
        path = self.tmp / "bin" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!/bin/sh\n{body}\n", encoding="utf-8")
        path.chmod(mode)
        return path

    def test_replace_ref_cannot_empty_the_change(self) -> None:
        first = self.seed("package.json")
        self.repo.write("package.json", b"two\n")
        head = self.repo.commit("two")
        tree = self.repo.git("rev-parse", f"{first}^{{tree}}")
        forged = self.repo.git("commit-tree", tree, "-p", first, "-m", "two")
        self.repo.git("replace", head, forged)
        self.assert_changed(self.run_action(self.repo, github_sha=head), True)

    def test_grafts_file_cannot_move_the_base(self) -> None:
        first = self.seed("package.json", "src/app.js")
        self.repo.write("package.json", b"two\n")
        parent = self.repo.commit("two")
        self.repo.write("src/app.js", b"three\n")
        head = self.repo.commit("three")
        grafts = self.repo.path / ".git" / "info" / "grafts"
        grafts.parent.mkdir(parents=True, exist_ok=True)
        grafts.write_text(f"{head} {first}\n", encoding="utf-8")
        outcome = self.run_action(self.repo)
        self.assert_changed(outcome, False)
        self.assertEqual(outcome.outputs["base"], parent)

    def test_caller_git_dir_is_ignored(self) -> None:
        self.commit_two()
        head = self.repo.head()
        other = GitRepo(self.tmp / "other")
        other.write("README.md")
        other.commit("other")
        with mock.patch.dict(os.environ, {"GIT_DIR": str(other.path / ".git")}):
            outcome = self.run_action(self.repo, github_sha=head)
        self.assert_changed(outcome, True)

    def test_git_environment_drops_caller_git_variables(self) -> None:
        caller = {
            "GIT_DIR": "/elsewhere",
            "GIT_OBJECT_DIRECTORY": "/elsewhere/objects",
            "GIT_NO_REPLACE_OBJECTS": "0",
            "HOME": "/home/caller",
        }
        with mock.patch.dict(os.environ, caller):
            environment = gitobjects.git_environment()
        self.assertNotIn("GIT_DIR", environment)
        self.assertNotIn("GIT_OBJECT_DIRECTORY", environment)
        self.assertEqual(environment["HOME"], "/home/caller")
        self.assertEqual(environment["GIT_NO_LAZY_FETCH"], "1")
        self.assertEqual(environment["GIT_NO_REPLACE_OBJECTS"], "1")
        self.assertEqual(environment["GIT_GRAFT_FILE"], os.devnull)

    def test_git_input_is_what_runs(self) -> None:
        self.commit_two()
        empty_diff = self.script(
            "empty-diff-git",
            f'[ "$1" = diff ] && exit 0\nexec "{self.real_git}" "$@"',
        )
        self.assert_changed(self.run_action(self.repo, git=str(empty_diff)), False)

    def test_relative_git_fails(self) -> None:
        self.commit_two()
        self.assert_input_error(
            self.run_action(self.repo, git="git"), "git 'git' is not an absolute path"
        )

    def test_unusable_git_fails(self) -> None:
        self.commit_two()
        not_executable = self.script("not-executable", "exit 0", mode=0o644)
        link_to_directory = self.tmp / "bin" / "directory-link"
        link_to_directory.symlink_to(self.tmp)
        for path in (
            not_executable,
            self.tmp / "missing",
            self.tmp,
            link_to_directory,
        ):
            with self.subTest(path=path):
                self.assert_input_error(
                    self.run_action(self.repo, git=str(path)),
                    "is not an executable file",
                )

    def test_absolute_git_through_a_link_resolves(self) -> None:
        self.commit_two()
        link = self.tmp / "git-link"
        link.symlink_to(self.real_git)
        self.assert_changed(self.run_action(self.repo, git=str(link)), True)

    def test_clean_absolute_git_resolves(self) -> None:
        self.commit_two()
        self.assert_changed(self.run_action(self.repo, git=self.real_git), True)

    def test_git_with_surrounding_whitespace_fails(self) -> None:
        # The input is used exactly as given, never trimmed, so a stray
        # space or newline fails loudly instead of selecting another file.
        self.commit_two()
        body = f'exec "{self.real_git}" "$@"'
        trimmed = self.script("exact-git", body)
        self.script("exact-git ", body)
        for value in (f"{trimmed} ", f"{trimmed}\n", f" {trimmed}"):
            with self.subTest(value=value):
                self.assert_input_error(
                    self.run_action(self.repo, git=value),
                    "has leading or trailing whitespace",
                )

    def test_empty_git_runs_the_first_git_on_path(self) -> None:
        # The default keeps the PATH lookup, so a git earlier on PATH runs;
        # callers that cannot trust PATH pass the git input.
        self.commit_two()
        head = self.repo.head()
        marker = self.tmp / "fake-git-ran"
        fake = self.script("git", f'touch "{marker}"\nexec "{self.real_git}" "$@"')
        path = f"{fake.parent}{os.pathsep}{os.environ.get('PATH', '')}"
        with mock.patch.dict(os.environ, {"PATH": path}):
            outcome = self.run_action(self.repo, github_sha=head)
        self.assert_changed(outcome, True)
        self.assertTrue(marker.exists(), "the git on PATH did not run")


class InputTests(ActionTestCase):
    """Input validation fails the step with a message."""

    def test_unknown_preset_fails(self) -> None:
        self.seed("package.json")
        self.assert_input_error(
            self.run_action(self.repo, ecosystems="node,ruby"),
            "unknown ecosystem 'ruby'",
        )

    def test_no_patterns_fails(self) -> None:
        self.seed("package.json")
        self.assert_input_error(
            self.run_action(self.repo, ecosystems="", patterns="\n"), "set 'ecosystems'"
        )

    def test_rejected_pattern_characters(self) -> None:
        self.seed("package.json")
        rejected = {
            "**/package.json": "'**'",
            "package.?son": "'?'",
            "[p]ackage.json": "'['",
            "package.json]": "']'",
            "package\\.json": "'\\'",
            "/package.json": "starts with '/'",
            "./package.json": "'.' or '..' segment",
            "a/../package.json": "'.' or '..' segment",
            "a//package.json": "empty path segment",
        }
        for pattern, fragment in rejected.items():
            with self.subTest(pattern=pattern):
                self.assert_input_error(
                    self.run_action(self.repo, patterns=pattern), fragment
                )

    def test_input_error_leaves_outputs_empty(self) -> None:
        self.seed("package.json")
        outcome = self.run_action(self.repo, ecosystems="ruby")
        self.assertEqual(
            outcome.outputs, {"changed": "", "reason": "", "base": "", "manifest": ""}
        )


class EntryPointTests(ActionTestCase):
    """The action's entry point imports nothing from the checkout."""

    ENTRY = (
        Path(__file__).resolve().parents[1]
        / "scripts"
        / "dependency_change"
        / "__main__.py"
    )

    def test_checkout_cannot_shadow_the_detector(self) -> None:
        self.seed("package.json")
        forged = (
            b"import os\n"
            b"with open(os.environ['GITHUB_OUTPUT'], 'a') as handle:\n"
            b"    handle.write('changed=false\\n')\n"
            b"raise SystemExit(0)\n"
        )
        self.repo.write("package.json", b"two\n")
        for shadow in (
            "dependency_change/__init__.py",
            "dependency_change/__main__.py",
            "dependency_change.py",
            "json.py",
            "subprocess.py",
            "sitecustomize.py",
        ):
            self.repo.write(shadow, forged)
        self.repo.commit("two")
        output_file = self.tmp / "github_output"
        output_file.write_bytes(b"")
        env = {
            "PATH": os.environ.get("PATH", ""),
            "HOME": str(self.tmp),
            "PYTHONPATH": str(self.repo.path),
            "INPUT_ECOSYSTEMS": "node",
            "GITHUB_EVENT_NAME": "pull_request",
            "GITHUB_SHA": self.repo.head(),
            "GITHUB_OUTPUT": str(output_file),
        }
        completed = subprocess.run(
            [sys.executable, "-I", str(self.ENTRY)],
            cwd=self.repo.path,
            env=env,
            capture_output=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        outputs = parse_outputs(output_file.read_bytes())
        self.assertEqual(outputs["changed"], "true", completed.stdout)
        self.assertEqual(outputs["manifest"], "dependency-change.json")
        written = json.loads(
            (self.repo.path / "dependency-change.json").read_text(encoding="utf-8")
        )
        self.assertEqual(written["files"], ["package.json"])


class UnitTests(unittest.TestCase):
    """Pure functions."""

    def test_display_escapes_control_bytes(self) -> None:
        self.assertEqual(
            dc.display(b"a\nb\rc\\d\x01e\xff"), "a\\nb\\rc\\\\d\\x01e\\xff"
        )

    def test_parse_diff(self) -> None:
        raw = b":100644 100644 aaaa bbbb M\x00package.json\x00:000000 120000 0000 cccc A\x00link\nname\x00"
        entries = dc.parse_diff(raw)
        self.assertEqual(
            [entry.path for entry in entries], [b"package.json", b"link\nname"]
        )
        self.assertEqual(entries[1].new_mode, b"120000")
        self.assertEqual(entries[0].status, b"M")

    def test_parse_tree(self) -> None:
        raw = b"100644 blob aaaa\tpackage.json\x00160000 commit bbbb\tvendor/lib\x00"
        entries = dc.parse_tree(raw)
        self.assertEqual(
            [(entry.mode, entry.path) for entry in entries],
            [(b"100644", b"package.json"), (b"160000", b"vendor/lib")],
        )

    def test_could_match_beneath(self) -> None:
        pattern = dc.compile_pattern(b"gradle/*.versions.toml", b"apps/web")
        self.assertTrue(pattern.could_match_beneath(b"gradle"))
        self.assertTrue(pattern.could_match_beneath(b"apps/gradle"))
        self.assertTrue(pattern.could_match_beneath(b"apps/web/anything"))
        self.assertTrue(pattern.could_match_beneath(b"apps"))
        self.assertFalse(pattern.could_match_beneath(b"apps/api"))
        self.assertFalse(pattern.could_match_beneath(b"docs"))
        plain = dc.compile_pattern(b"package.json", b"apps/web/ui")
        self.assertTrue(plain.could_match_beneath(b"apps"))
        self.assertTrue(plain.could_match_beneath(b"apps/web"))
        self.assertFalse(plain.could_match_beneath(b"app"))
        self.assertFalse(plain.could_match_beneath(b"apps/web-old"))
        directory = dc.compile_pattern(b"buildSrc/", b"apps/web")
        self.assertTrue(directory.could_match_beneath(b"buildSrc"))
        self.assertTrue(directory.could_match_beneath(b"buildSrc/deep"))
        self.assertFalse(directory.could_match_beneath(b"buildSrcX"))

    def test_trailing_newline_never_matches(self) -> None:
        plain = dc.compile_pattern(b"package.json", b"apps/web")
        self.assertTrue(plain.matches(b"package.json"))
        self.assertTrue(plain.matches(b"apps/web/dir\n/package.json"))
        self.assertFalse(plain.matches(b"package.json\n"))
        self.assertFalse(plain.matches(b"apps/web/package.json\n"))
        self.assertFalse(plain.could_match_beneath(b"apps\n"))
        nested = dc.compile_pattern(b"gradle/*.versions.toml", b"apps/web")
        self.assertFalse(nested.matches(b"gradle/libs.versions.toml\n"))
        self.assertFalse(nested.could_match_beneath(b"gradle\n"))
        self.assertFalse(nested.could_match_beneath(b"apps/web\n"))
        directory = dc.compile_pattern(b"buildSrc/", b"apps/web")
        self.assertTrue(directory.matches(b"buildSrc/file\n"))
        self.assertFalse(directory.could_match_beneath(b"buildSrc\n"))

    def test_guards_are_all_functions(self) -> None:
        for name, module_name in dc.GUARDS.items():
            self.assertTrue(
                callable(getattr(importlib.import_module(module_name), name)), name
            )

    def test_parse_git_version(self) -> None:
        cases = {
            b"git version 2.46.0\n": ("2.46.0", (2, 46, 0)),
            b"git version 2.39.5 (Apple Git-154)\n": ("2.39.5", (2, 39, 5)),
            b"git version 2.47.1.windows.2\n": ("2.47.1", (2, 47, 1)),
            b"git version 2.45.2.rc0\n": ("2.45.2", (2, 45, 2)),
        }
        for raw, (text, number) in cases.items():
            with self.subTest(raw=raw):
                version = gitobjects.parse_git_version(raw)
                self.assertEqual((version.text, version.number), (text, number))
        self.assertTrue((2, 45, 2) < gitobjects.MIN_NO_LAZY_FETCH_GIT)
        self.assertFalse((2, 46, 0) < gitobjects.MIN_NO_LAZY_FETCH_GIT)
        with self.assertRaises(dc.Unresolved):
            gitobjects.parse_git_version(b"")

    def test_config_names_promisor(self) -> None:
        names = gitobjects.config_names_promisor
        self.assertFalse(names(b""))
        self.assertFalse(names(b"core.bare\nfalse\0remote.origin.url\nx\0"))
        self.assertTrue(names(b"remote.origin.promisor\ntrue\0"))
        self.assertTrue(names(b"remote.Up.promisor\nYES\0"))
        self.assertTrue(names(b"remote.origin.promisor\0"), "a bare key is true")
        self.assertFalse(names(b"remote.origin.promisor\nfalse\0"))
        self.assertFalse(names(b"remote.origin.promisor\n\0"), "empty is false")
        self.assertTrue(names(b"extensions.partialclone\norigin\0"))
        self.assertFalse(names(b"extensions.partialclone\n\0"))
        self.assertFalse(names(b"remote.origin.partialclonefilter\nblob:none\0"))


if __name__ == "__main__":
    unittest.main()
