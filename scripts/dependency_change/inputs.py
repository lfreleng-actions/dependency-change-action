# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""The action's inputs, read from the environment and validated once."""

from __future__ import annotations

import dataclasses
import os
import posixpath
from collections.abc import Mapping

from dependency_change.common import InputError, display, to_bytes
from dependency_change.gitobjects import GIT_ON_PATH
from dependency_change.patterns import PRESETS, validate_pattern


class OutputPathError(InputError):
    """The ``output`` path cannot be used safely."""


def normalise_prefix(raw: bytes) -> bytes:
    """Normalise ``path-prefix`` lexically; the repository root becomes ``b""``."""
    if raw.strip() in (b"", b"."):
        return b""
    normalised = posixpath.normpath(raw)
    if normalised == b".":
        return b""
    return normalised


def normalise_output(raw: bytes) -> tuple[bytes, tuple[bytes, ...]]:
    """Normalise ``output`` lexically and split it under the working directory.

    Returns the path the action advertises as ``manifest`` and its
    components relative to the working directory, which the sidecar opens
    one at a time. An absolute path is accepted only when, after
    normalisation, it lies under the working directory as ``os.getcwd()``
    names it; it is advertised in that absolute form.
    """
    normalised = posixpath.normpath(raw)
    relative = normalised
    if normalised.startswith(b"/"):
        cwd = posixpath.normpath(os.getcwd().encode("utf-8", "surrogateescape"))
        if not normalised.startswith(cwd + b"/"):
            raise OutputPathError(
                f"output '{display(raw)}' is outside the working directory"
            )
        relative = normalised[len(cwd) + 1 :]
    if relative in (b"", b".", b"..") or relative.startswith(b"../"):
        raise OutputPathError(
            f"output '{display(raw)}' is outside the working directory"
        )
    return normalised, tuple(relative.split(b"/"))


def resolve_git(raw: str) -> str:
    """Validate the ``git`` input and return the executable to run.

    Empty keeps the PATH lookup. Anything else must be an absolute path
    that, after resolving symbolic links, is an executable regular file;
    the resolved path is what runs, so a link swapped later is not. The
    value is never trimmed: surrounding whitespace is an error, so a stray
    space or newline cannot select a different file.
    """
    if raw != raw.strip():
        raise InputError(
            f"git '{display(to_bytes(raw))}' has leading or trailing whitespace"
        )
    if not raw:
        return GIT_ON_PATH
    if not os.path.isabs(raw):
        raise InputError(f"git '{display(to_bytes(raw))}' is not an absolute path")
    resolved = os.path.realpath(raw)
    if not os.path.isfile(resolved) or not os.access(resolved, os.X_OK):
        raise InputError(f"git '{display(to_bytes(raw))}' is not an executable file")
    return resolved


def read_patterns(env: Mapping[str, str]) -> tuple[bytes, ...]:
    """Collect the preset and extra patterns, validated and without duplicates."""
    patterns: list[bytes] = []
    for raw_name in env.get("INPUT_ECOSYSTEMS", "").split(","):
        name = raw_name.strip()
        if not name:
            continue
        if name not in PRESETS:
            known = ", ".join(sorted(PRESETS))
            raise InputError(f"unknown ecosystem '{name}'; known presets: {known}")
        patterns.extend(to_bytes(pattern) for pattern in PRESETS[name])
    for line in env.get("INPUT_PATTERNS", "").splitlines():
        stripped = line.strip()
        if stripped:
            patterns.append(to_bytes(stripped))
    if not patterns:
        raise InputError(
            "set 'ecosystems' or 'patterns'; neither names a dependency file"
        )
    for pattern in patterns:
        validate_pattern(pattern)
    return tuple(dict.fromkeys(patterns))


@dataclasses.dataclass(frozen=True)
class Inputs:
    """The validated inputs."""

    patterns: tuple[bytes, ...]
    path_prefix: bytes
    gerrit_refspec: str
    base: str
    output: bytes
    output_components: tuple[bytes, ...]
    git: str

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> Inputs:
        """Read ``INPUT_*`` variables; raise ``InputError`` on anything unusable."""
        base = env.get("INPUT_BASE", "").strip()
        if base.startswith("-"):
            raise InputError(f"base '{base}' is not a revision")
        output, components = normalise_output(
            to_bytes(env.get("INPUT_OUTPUT", "") or "dependency-change.json")
        )
        return cls(
            patterns=read_patterns(env),
            path_prefix=normalise_prefix(to_bytes(env.get("INPUT_PATH_PREFIX", "."))),
            gerrit_refspec=env.get("INPUT_GERRIT_REFSPEC", "").strip(),
            base=base,
            output=output,
            output_components=components,
            git=resolve_git(env.get("INPUT_GIT", "")),
        )
