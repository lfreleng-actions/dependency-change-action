# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""The pattern dialect, the presets and their compilation to byte regexes."""

from __future__ import annotations

import dataclasses
import re
from collections.abc import Mapping

from dependency_change.common import InputError, display

PRESETS: Mapping[str, tuple[str, ...]] = {
    "node": (
        "package.json",
        "package-lock.json",
        "npm-shrinkwrap.json",
        "yarn.lock",
        ".yarnrc.yml",
        "pnpm-lock.yaml",
        "pnpm-workspace.yaml",
        "bun.lock",
        "bun.lockb",
    ),
    "python": (
        "pyproject.toml",
        "uv.lock",
        "poetry.lock",
        "pdm.lock",
        "Pipfile",
        "Pipfile.lock",
        "setup.py",
        "setup.cfg",
        "requirements*.txt",
        "requirements/*.txt",
        "constraints*.txt",
        "tox.ini",
    ),
    "go": ("go.mod", "go.sum", "go.work", "go.work.sum", "vendor/modules.txt"),
    "maven": ("pom.xml", ".mvn/extensions.xml", ".mvn/maven.config"),
    "gradle": (
        "build.gradle",
        "build.gradle.kts",
        "settings.gradle",
        "settings.gradle.kts",
        "gradle.properties",
        "gradle/*.versions.toml",
        "gradle.lockfile",
        "settings-gradle.lockfile",
        "gradle/dependency-locks/",
        "buildSrc/",
        "build-logic/",
    ),
    "rust": ("Cargo.toml", "Cargo.lock", ".cargo/config.toml", ".cargo/config"),
    "docker": (
        "Dockerfile",
        "Dockerfile.*",
        "*.Dockerfile",
        "*.dockerfile",
        "Containerfile",
        "Containerfile.*",
    ),
}


@dataclasses.dataclass(frozen=True)
class Pattern:
    """One pattern of the dialect, compiled for a given ``path-prefix``.

    A pattern without ``/`` matches a file name; one with ``/`` matches a
    path relative to the directory it is anchored at; one ending in ``/``
    matches everything beneath that directory. ``*`` matches within one
    segment and is the only metacharacter.

    Inside ``path-prefix`` a pattern is anchored at every directory, so it
    matches at any depth. Above the prefix it is anchored only at the
    prefix's ancestors, so a sibling project never matches.
    """

    source: bytes
    segments: tuple[bytes, ...]
    is_directory: bool
    match_re: re.Pattern[bytes]
    beneath_re: re.Pattern[bytes]

    def matches(self, path: bytes) -> bool:
        """Return whether ``path``, as git lists it, is a dependency file."""
        return self.match_re.match(path) is not None

    def could_match_beneath(self, path: bytes) -> bool:
        """Return whether the pattern matches ``path`` or something under it."""
        return self.matches(path) or self.beneath_re.match(path) is not None


def validate_pattern(source: bytes) -> tuple[tuple[bytes, ...], bool]:
    """Split a pattern into segments, rejecting anything outside the dialect."""
    text = display(source)
    if not source:
        raise InputError("pattern is empty")
    for forbidden in (b"**", b"?", b"[", b"]", b"\\"):
        if forbidden in source:
            raise InputError(
                f"pattern '{text}' uses '{forbidden.decode()}', which the dialect does not allow"
            )
    if source.startswith(b"/"):
        raise InputError(f"pattern '{text}' starts with '/'; patterns are relative")
    is_directory = source.endswith(b"/")
    body = source[:-1] if is_directory else source
    segments = tuple(body.split(b"/"))
    for segment in segments:
        if segment == b"":
            raise InputError(f"pattern '{text}' has an empty path segment")
        if segment in (b".", b".."):
            raise InputError(f"pattern '{text}' uses a '.' or '..' segment")
    return segments, is_directory


def segment_regex(segment: bytes) -> bytes:
    """Compile one segment: ``*`` matches within the segment, all else literally."""
    return b"[^/]*".join(re.escape(part) for part in segment.split(b"*"))


def path_regex(segments: tuple[bytes, ...]) -> bytes:
    """Compile a run of segments joined by ``/``."""
    return b"/".join(segment_regex(segment) for segment in segments)


def ancestor_directories(prefix: bytes) -> list[bytes]:
    """Return the strict ancestors of ``prefix``, root first, as ``b""`` for the root."""
    if not prefix:
        return []
    parts = prefix.split(b"/")
    return [b"/".join(parts[:index]) for index in range(len(parts))]


def anchor_regex(directory: bytes) -> bytes:
    """Compile a directory as the start of a path, ``b""`` for the root."""
    return re.escape(directory + b"/") if directory else b""


def compile_pattern(source: bytes, prefix: bytes) -> Pattern:
    """Compile ``source`` for a repository-relative ``prefix`` (``b""`` is the root)."""
    segments, is_directory = validate_pattern(source)
    body = path_regex(segments)
    if is_directory:
        body += b"/.+"

    ancestors = ancestor_directories(prefix)
    anchors = [anchor_regex(prefix) + rb"(?:[^/]+/)*"]
    anchors.extend(anchor_regex(ancestor) for ancestor in ancestors)
    # \Z, not $: $ also matches before a final newline, and 'package.json\n'
    # is a different file from 'package.json'.
    match = re.compile(b"^(?:" + b"|".join(anchors) + b")" + body + rb"\Z", re.DOTALL)

    # Directories a pattern can reach past: anything at or beneath the
    # prefix, every strict ancestor of the prefix (a link or submodule
    # there stands in for the project directory itself), and above the
    # prefix the leading segments of the pattern, or the whole directory
    # and everything below it for a directory pattern.
    beneath = [re.escape(prefix) + rb"(?:/.*)?" if prefix else rb".*"]
    for ancestor in ancestors:
        anchor = anchor_regex(ancestor)
        if ancestor:
            beneath.append(re.escape(ancestor))
        for depth in range(1, len(segments)):
            beneath.append(anchor + path_regex(segments[:depth]))
        if is_directory:
            beneath.append(anchor + path_regex(segments) + rb"(?:/.*)?")
    beneath_re = re.compile(b"^(?:" + b"|".join(beneath) + rb")\Z", re.DOTALL)
    return Pattern(source, segments, is_directory, match, beneath_re)
