# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Base selection, the fail-closed guards and the detection itself."""

from __future__ import annotations

import dataclasses
import re
from collections.abc import Iterable, Mapping, Sequence

from dependency_change.common import Unresolved, display, log, to_bytes
from dependency_change.gitobjects import (
    LINK_MODE,
    MIN_NO_LAZY_FETCH_GIT,
    SUBMODULE_MODE,
    GitVersion,
    TreeEntry,
    diff_commits,
    git_version,
    has_promisor_remote,
    list_tree,
    resolve_commit,
    using_git,
)
from dependency_change.inputs import Inputs
from dependency_change.patterns import Pattern, compile_pattern

NULL_SHA_RE = re.compile(r"^0+$")


@dataclasses.dataclass(frozen=True)
class Result:
    """A resolved detection result."""

    changed: bool
    base: bytes
    reason: str
    files: tuple[bytes, ...]
    changed_paths: tuple[bytes, ...]


def guard_git_refuses_lazy_fetch(version: GitVersion) -> None:
    """Refuse a partial clone under a git that ignores ``GIT_NO_LAZY_FETCH``.

    Such a git would fetch a missing base tree from the promisor remote
    with the checkout's credential, which the action cannot allow; a
    clone with no promisor remote has nothing to fetch and is not checked.
    """
    if version.number < MIN_NO_LAZY_FETCH_GIT:
        wanted = ".".join(str(part) for part in MIN_NO_LAZY_FETCH_GIT)
        raise Unresolved(
            f"git {version.text} may fetch missing objects in this partial clone; "
            f"GIT_NO_LAZY_FETCH needs git {wanted}"
        )


def guard_head_is_github_sha(head: bytes, github_sha: str) -> None:
    """Refuse a checkout of another repository or ref than the event's."""
    if not github_sha or head != to_bytes(github_sha):
        raise Unresolved(
            f"HEAD {display(head[:12])} is not GITHUB_SHA {display(to_bytes(github_sha[:12]))}"
        )


def guard_event_has_base(event: str) -> None:
    """Refuse events whose base the table does not define."""
    if event not in ("push", "pull_request"):
        raise Unresolved(f"event '{event}' has no base to compare against")


def guard_before_is_a_commit(before: str) -> None:
    """Refuse a push that created the branch, where ``before`` is all zeros."""
    if not before or NULL_SHA_RE.match(before):
        raise Unresolved("push created the branch; there is no commit before it")


def guard_base_in_checkout(ref: bytes, sha: bytes | None) -> None:
    """Refuse a base the checkout does not hold, as in a shallow clone."""
    if sha is None:
        raise Unresolved(f"{display(ref)} is not in the checkout")


def guard_prefix_inside_repository(prefix: bytes) -> None:
    """Refuse a ``path-prefix`` that leaves the repository."""
    if prefix.startswith(b"/") or prefix == b".." or prefix.startswith(b"../"):
        raise Unresolved(f"path-prefix '{display(prefix)}' is outside the repository")


def guard_prefix_not_through_link(prefix: bytes, tree: Sequence[TreeEntry]) -> None:
    """Refuse a ``path-prefix`` with a symbolic link or submodule component."""
    parts = prefix.split(b"/")
    components = {b"/".join(parts[:index]) for index in range(1, len(parts) + 1)}
    for entry in tree:
        if entry.mode in (LINK_MODE, SUBMODULE_MODE) and entry.path in components:
            raise Unresolved(
                f"path-prefix '{display(prefix)}' passes through {entry.kind} '{display(entry.path)}'"
            )


def guard_prefix_in_tree(prefix: bytes, tree: Sequence[TreeEntry]) -> None:
    """Refuse a ``path-prefix`` that is not a directory in ``HEAD``'s tree."""
    if not prefix:
        return
    beneath = prefix + b"/"
    if not any(entry.path.startswith(beneath) for entry in tree):
        raise Unresolved(f"path-prefix '{display(prefix)}' is not a directory in HEAD")


def guard_reachable_entries_changed(
    reachable: Sequence[TreeEntry], changed_paths: Iterable[bytes]
) -> None:
    """Refuse to decide while a reachable link or submodule did not change.

    The action cannot read what a symbolic link or submodule stands for
    without touching the working tree, so an unchanged one a pattern could
    reach leaves the result unproven.
    """
    changed = set(changed_paths)
    for entry in reachable:
        if entry.path not in changed:
            raise Unresolved(
                f"{entry.kind} '{display(entry.path)}' could stand for a dependency file"
            )


def require_commit(ref: bytes) -> bytes:
    """Resolve ``ref`` to a commit the checkout holds, or raise ``Unresolved``."""
    sha = resolve_commit(ref)
    guard_base_in_checkout(ref, sha)
    return sha or b""


def choose_base(inputs: Inputs, env: Mapping[str, str]) -> bytes:
    """Pick the commit to compare ``HEAD`` against, or raise ``Unresolved``."""
    if inputs.base:
        ref = to_bytes(inputs.base)
    elif inputs.gerrit_refspec:
        ref = b"HEAD^1"
    else:
        guard_head_is_github_sha(require_commit(b"HEAD"), env.get("GITHUB_SHA", ""))
        event = env.get("GITHUB_EVENT_NAME", "")
        guard_event_has_base(event)
        if event == "pull_request":
            ref = b"HEAD^1"
        else:
            before = env.get("EVENT_BEFORE", "").strip()
            guard_before_is_a_commit(before)
            ref = to_bytes(before)
    return require_commit(ref)


def reachable_entries(
    trees: Iterable[Sequence[TreeEntry]], patterns: Sequence[Pattern]
) -> list[TreeEntry]:
    """Collect links and submodules some pattern could match at or beneath."""
    seen: dict[bytes, TreeEntry] = {}
    for tree in trees:
        for entry in tree:
            if entry.mode not in (LINK_MODE, SUBMODULE_MODE) or entry.path in seen:
                continue
            if any(pattern.could_match_beneath(entry.path) for pattern in patterns):
                seen[entry.path] = entry
    return sorted(seen.values(), key=lambda entry: entry.path)


def detect(inputs: Inputs, env: Mapping[str, str]) -> Result:
    """Run the detection and return a resolved result, or raise ``Unresolved``."""
    with using_git(inputs.git):
        return compare(inputs, env)


def compare(inputs: Inputs, env: Mapping[str, str]) -> Result:
    """Compare the base against ``HEAD`` with the git ``detect`` chose."""
    prefix = inputs.path_prefix
    guard_prefix_inside_repository(prefix)
    if has_promisor_remote():
        guard_git_refuses_lazy_fetch(git_version())
    head = require_commit(b"HEAD")
    head_tree = list_tree(head)
    guard_prefix_not_through_link(prefix, head_tree)
    guard_prefix_in_tree(prefix, head_tree)

    base = choose_base(inputs, env)
    base_tree = list_tree(base)
    diff = diff_commits(base, head)

    patterns = [compile_pattern(source, prefix) for source in inputs.patterns]
    changed_paths = {entry.path for entry in diff}
    matched: list[bytes] = []
    for entry in diff:
        if any(pattern.matches(entry.path) for pattern in patterns):
            matched.append(entry.path)
            log(f"dependency file changed: '{display(entry.path)}'")

    # A changed link or submodule a pattern could reach counts as a change;
    # an unchanged one leaves the result unproven unless a file already did.
    reachable = reachable_entries((base_tree, head_tree), patterns)
    for tree_entry in reachable:
        if tree_entry.path in changed_paths and tree_entry.path not in matched:
            matched.append(tree_entry.path)
            log(
                f"{tree_entry.kind} changed where a dependency file could be: '{display(tree_entry.path)}'"
            )
    if not matched:
        guard_reachable_entries_changed(reachable, changed_paths)

    short = base[:12].decode("ascii")
    if matched:
        noun = "file" if len(matched) == 1 else "files"
        reason = f"{len(matched)} dependency {noun} changed since {short}"
    else:
        reason = f"no dependency file changed since {short}"
    return Result(
        bool(matched), base, reason, tuple(matched), tuple(sorted(changed_paths))
    )
