# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Mutation run: disabling any fail-closed guard must make its test fail.

Each guard in ``dependency_change.GUARDS`` is replaced with a function that
returns without raising, while the module is otherwise intact, and the test
aimed at that guard is run. A guard whose test still passes is not being
tested.
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

    def test_targets_pass_with_guards_intact(self) -> None:
        for name in TARGETS.values():
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


if __name__ == "__main__":
    unittest.main()
