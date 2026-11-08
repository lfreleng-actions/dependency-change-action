# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""The one subprocess wrapper and the parsers for ``-z`` git output."""

from __future__ import annotations

import contextlib
import contextvars
import dataclasses
import os
import re
import subprocess
from collections.abc import Generator, Mapping

from dependency_change.common import Unresolved, display

HEX_SHA_RE = re.compile(rb"^[0-9a-f]{40,64}$")
GIT_VERSION_RE = re.compile(rb"^git version (\d+(?:\.\d+)*)")
LINK_MODE = b"120000"
SUBMODULE_MODE = b"160000"
GIT_TIMEOUT_SECONDS = 120
# The release that introduced GIT_NO_LAZY_FETCH; older ones ignore it.
MIN_NO_LAZY_FETCH_GIT: tuple[int, ...] = (2, 46)
# What git reads as false in a boolean setting; a bare key is true.
FALSE_VALUES = frozenset((b"", b"false", b"no", b"off", b"0"))


# Settings every git command runs with, over a caller environment that
# has lost its own GIT_* variables.
#
# A partial clone fetches a missing object from its promisor remote the
# moment a command needs it, so ls-tree or diff on an absent tree would
# go to the network with whatever credential the checkout kept.
# GIT_NO_LAZY_FETCH (git 2.46) makes such a command fail instead, and the
# failure is an unresolved result like any other missing object.
#
# A replace ref in the clone can swap a dependency commit for one with
# its parent's tree, and a grafts file can reparent HEAD so HEAD^1 is
# another commit; either hides the change. GIT_NO_REPLACE_OBJECTS stops
# the first and pointing GIT_GRAFT_FILE at the null device the second.
GIT_SETTINGS: dict[str, str] = {
    "GIT_NO_LAZY_FETCH": "1",
    "GIT_NO_REPLACE_OBJECTS": "1",
    "GIT_GRAFT_FILE": os.devnull,
}
# The git to run: the caller's absolute path, or a PATH lookup by default.
GIT_ON_PATH = "git"
EXECUTABLE: contextvars.ContextVar[str] = contextvars.ContextVar(
    "git_executable", default=GIT_ON_PATH
)


def without_git_variables(env: Mapping[str, str]) -> dict[str, str]:
    """Copy ``env`` without any ``GIT_*`` variable an earlier step could set.

    GIT_DIR, GIT_OBJECT_DIRECTORY, GIT_ALTERNATE_OBJECT_DIRECTORIES and
    their kin point git at another repository or other objects.
    """
    return {name: value for name, value in env.items() if not name.startswith("GIT_")}


def git_environment() -> dict[str, str]:
    """The environment every git subprocess runs with.

    The rest of the caller's environment stays, ``HOME`` included, so
    system and global configuration such as ``safe.directory`` apply.
    """
    return {**without_git_variables(os.environ), **GIT_SETTINGS}


@contextlib.contextmanager
def using_git(executable: str) -> Generator[None, None, None]:
    """Run every git command inside the block with ``executable``."""
    token = EXECUTABLE.set(executable)
    try:
        yield
    finally:
        EXECUTABLE.reset(token)


def git(*args: bytes | str) -> bytes:
    """Run one git command and return its stdout; any failure is ``Unresolved``."""
    command: list[bytes | str] = [EXECUTABLE.get(), *args]
    try:
        completed = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=GIT_TIMEOUT_SECONDS,
            check=False,
            env=git_environment(),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Unresolved(f"git {args[0]!s} did not run: {exc}") from exc
    if completed.returncode != 0:
        lines = completed.stderr.strip().splitlines()
        raise Unresolved(
            f"git {args[0]!s} failed: {display(lines[0]) if lines else ''}"
        )
    return completed.stdout


@dataclasses.dataclass(frozen=True)
class GitVersion:
    """The running git's version, as printed and as numbers to compare."""

    text: str
    number: tuple[int, ...]


def parse_git_version(raw: bytes) -> GitVersion:
    """Parse ``git --version`` output such as ``git version 2.39.5 (Apple Git-154)``."""
    match = GIT_VERSION_RE.match(raw)
    if match is None:
        raise Unresolved(f"unexpected git version '{display(raw.strip())}'")
    text = match.group(1).decode("ascii")
    return GitVersion(text, tuple(int(part) for part in text.split(".")))


def git_version() -> GitVersion:
    """The version of the git the detector runs."""
    return parse_git_version(git("--version"))


def config_names_promisor(raw: bytes) -> bool:
    """Whether ``git config -z --list`` output declares a promisor remote.

    A partial clone names its promisor remote in ``extensions.partialClone``
    (older git) or sets ``remote.<name>.promisor`` (current git); either
    makes a command fetch a missing object lazily.
    """
    for record in raw.split(b"\0"):
        key, separator, value = record.partition(b"\n")
        key = key.lower()
        value = value.strip().lower()
        if key == b"extensions.partialclone" and value:
            return True
        if key.startswith(b"remote.") and key.endswith(b".promisor"):
            if not separator or value not in FALSE_VALUES:
                return True
    return False


def has_promisor_remote() -> bool:
    """Whether the checkout is a partial clone, by its configuration alone."""
    return config_names_promisor(git("config", "-z", "--list"))


def resolve_commit(ref: bytes) -> bytes | None:
    """Return the full commit id ``ref`` names in the checkout, or ``None``."""
    try:
        sha = git(
            "rev-parse", "--verify", "--quiet", "--end-of-options", ref + b"^{commit}"
        ).strip()
    except Unresolved:
        return None
    return sha if HEX_SHA_RE.match(sha) else None


@dataclasses.dataclass(frozen=True)
class DiffEntry:
    """One ``git diff --raw`` entry."""

    old_mode: bytes
    new_mode: bytes
    status: bytes
    path: bytes


def parse_diff(raw: bytes) -> list[DiffEntry]:
    """Parse ``git diff --raw -z --no-renames`` output."""
    entries: list[DiffEntry] = []
    fields = raw.split(b"\0")
    index = 0
    while index + 1 < len(fields) and fields[index]:
        meta = fields[index]
        parts = meta[1:].split(b" ")
        if not meta.startswith(b":") or len(parts) != 5:
            raise Unresolved(f"unexpected diff record {display(meta)}")
        entries.append(DiffEntry(parts[0], parts[1], parts[4], fields[index + 1]))
        index += 2
    return entries


@dataclasses.dataclass(frozen=True)
class TreeEntry:
    """One ``git ls-tree -r`` entry."""

    mode: bytes
    path: bytes

    @property
    def kind(self) -> str:
        """Name the entry for a log line or reason."""
        return "symbolic link" if self.mode == LINK_MODE else "submodule"


def parse_tree(raw: bytes) -> list[TreeEntry]:
    """Parse ``git ls-tree -r -z`` output."""
    entries: list[TreeEntry] = []
    for record in raw.split(b"\0"):
        if not record:
            continue
        meta, _, path = record.partition(b"\t")
        parts = meta.split(b" ")
        if len(parts) != 3 or not path:
            raise Unresolved(f"unexpected tree record {display(record)}")
        entries.append(TreeEntry(parts[0], path))
    return entries


def list_tree(commit: bytes) -> list[TreeEntry]:
    """List every entry of ``commit``'s tree, links and submodules included."""
    return parse_tree(git("ls-tree", "-r", "-z", commit))


def diff_commits(base: bytes, head: bytes) -> list[DiffEntry]:
    """Diff two commits without rename detection, so both sides of a move count.

    ``--ignore-submodules=none`` overrides ``diff.ignoreSubmodules`` and a
    submodule's ``ignore`` setting, which ``.gitmodules`` in the checkout
    can set; either would hide a moved pointer from the diff.
    """
    return parse_diff(
        git(
            "diff",
            "--raw",
            "-z",
            "--no-renames",
            "--ignore-submodules=none",
            base,
            head,
        )
    )
