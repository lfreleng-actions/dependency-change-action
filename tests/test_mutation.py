# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Mutation run: disabling any fail-closed guard must make its test fail.

Each guard in ``dependency_change.GUARDS`` is replaced with a function that
returns without raising, while the module is otherwise intact, and the test
aimed at that guard is run. A guard whose test still passes is not being
tested. The same holds for each setting in git's environment and for the
filter that drops the caller's ``GIT_*`` variables.
"""

from __future__ import annotations

import importlib
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import dependency_change as dc  # noqa: E402
import test_dependency_change as suite  # noqa: E402
from dependency_change import gitobjects  # noqa: E402

TARGETS: dict[str, str] = {
    "guard_git_refuses_lazy_fetch": "BaseSelectionTests.test_partial_clone_on_old_git_is_unresolved",
    "guard_head_is_github_sha": "BaseSelectionTests.test_head_not_github_sha_is_unresolved",
    "guard_event_has_base": "BaseSelectionTests.test_schedule_is_unresolved",
    "guard_before_is_a_commit": "BaseSelectionTests.test_push_creating_branch_is_unresolved",
    "guard_base_in_checkout": "BaseSelectionTests.test_shallow_checkout_is_unresolved",
    "guard_prefix_inside_repository": "PrefixTests.test_prefix_outside_repository_is_unresolved",
    "guard_prefix_not_through_link": "PrefixTests.test_symlinked_prefix_is_unresolved",
    "guard_prefix_in_tree": "PrefixTests.test_missing_prefix_is_unresolved",
    "guard_reachable_entries_changed": "LinkAndSubmoduleTests.test_unchanged_symlink_inside_prefix_is_unresolved",
    "remove_sidecar": "SidecarTests.test_planted_sidecar_is_removed",
    "remove_partial": "SidecarTests.test_failed_cleanup_after_failed_write_fails_the_step",
}

# Each setting git runs with, by the test that notices it is missing.
SETTING_TARGETS: dict[str, str] = {
    "GIT_NO_LAZY_FETCH": "BaseSelectionTests.test_partial_clone_with_base_tree_missing_is_unresolved",
    "GIT_NO_REPLACE_OBJECTS": "TrustedGitTests.test_replace_ref_cannot_empty_the_change",
    "GIT_GRAFT_FILE": "TrustedGitTests.test_grafts_file_cannot_move_the_base",
}
FILTER_TARGET = "TrustedGitTests.test_caller_git_dir_is_ignored"


def disabled(*_args: object, **_kwargs: object) -> None:
    """Stand in for a guard: accept anything, raise nothing."""
    return None


def run_target(name: str) -> unittest.TestResult:
    """Run one test from the main suite and return its result."""
    loader = unittest.TestLoader()
    tests = loader.loadTestsFromName(name, suite)
    result = unittest.TestResult()
    tests.run(result)
    return result


class MutationTests(unittest.TestCase):
    """One mutation per guard."""

    def test_every_guard_has_a_target(self) -> None:
        self.assertEqual(set(TARGETS), set(dc.GUARDS))

    def test_every_setting_has_a_target(self) -> None:
        self.assertEqual(set(SETTING_TARGETS), set(gitobjects.GIT_SETTINGS))

    def test_targets_pass_with_guards_intact(self) -> None:
        for name in [*TARGETS.values(), *SETTING_TARGETS.values(), FILTER_TARGET]:
            with self.subTest(test=name):
                result = run_target(name)
                self.assertEqual(result.testsRun, 1)
                self.assertTrue(result.wasSuccessful(), result.failures + result.errors)

    def test_disabling_a_guard_fails_its_target(self) -> None:
        for guard, name in TARGETS.items():
            module = importlib.import_module(dc.GUARDS[guard])
            with self.subTest(guard=guard), mock.patch.object(module, guard, disabled):
                result = run_target(name)
                self.assertEqual(result.testsRun, 1)
                self.assertFalse(
                    result.wasSuccessful(),
                    f"{name} did not notice {guard} being disabled",
                )

    def test_dropping_a_setting_fails_its_target(self) -> None:
        for setting, name in SETTING_TARGETS.items():
            with (
                self.subTest(setting=setting),
                mock.patch.dict(gitobjects.GIT_SETTINGS),
            ):
                del gitobjects.GIT_SETTINGS[setting]
                result = run_target(name)
                self.assertEqual(result.testsRun, 1)
                self.assertFalse(
                    result.wasSuccessful(), f"{name} did not notice {setting} missing"
                )

    def test_keeping_caller_git_variables_fails_its_target(self) -> None:
        with mock.patch.object(gitobjects, "without_git_variables", dict):
            result = run_target(FILTER_TARGET)
        self.assertEqual(result.testsRun, 1)
        self.assertFalse(
            result.wasSuccessful(),
            f"{FILTER_TARGET} did not notice caller GIT_* variables kept",
        )


if __name__ == "__main__":
    unittest.main()
