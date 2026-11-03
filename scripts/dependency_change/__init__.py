# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Detect whether a change touched dependency files, reading git objects only.

The detector compares a base commit against ``HEAD`` with ``git diff`` and
``git ls-tree`` and never consults the working tree to decide the answer.
When it cannot prove what the change touched it reports an unresolved
result: no sidecar and an empty ``changed`` output, so the consumer gates
exactly as it would without this action.
"""

from __future__ import annotations

from dependency_change.action import GUARDS, main, run
from dependency_change.common import InputError, Unresolved, display, to_bytes
from dependency_change.detect import Result, detect
from dependency_change.gitobjects import parse_diff, parse_tree
from dependency_change.inputs import Inputs
from dependency_change.patterns import PRESETS, Pattern, compile_pattern

__all__ = [
    "GUARDS",
    "PRESETS",
    "InputError",
    "Inputs",
    "Pattern",
    "Result",
    "Unresolved",
    "compile_pattern",
    "detect",
    "display",
    "main",
    "parse_diff",
    "parse_tree",
    "run",
    "to_bytes",
]
