# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""The sidecar delete and write, through descriptor-relative opens only.

Every component of the output path is opened with ``O_NOFOLLOW`` relative
to the descriptor of its parent, starting from the working directory's
own descriptor, so nothing the checkout controls can redirect the delete
or the write outside the working directory.
"""

from __future__ import annotations

import errno
import json
import os
from collections.abc import Sequence

from dependency_change.common import display, to_bytes
from dependency_change.detect import Result
from dependency_change.inputs import OutputPathError


def open_directory(name: bytes, dir_fd: int) -> int:
    """Open a directory component without following a symbolic link."""
    try:
        return os.open(
            name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd
        )
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENOTDIR, errno.EMLINK):
            raise OutputPathError(
                f"output path component '{display(name)}' is not a directory"
            ) from exc
        raise


def walk_output(components: Sequence[bytes], create: bool) -> int | None:
    """Open the parent of the output file through ``dir_fd`` opens.

    Returns the descriptor of the parent, or ``None`` when ``create`` is
    false and a parent does not exist. The caller closes the descriptor.
    """
    for function in (os.open, os.mkdir, os.unlink):
        if function not in os.supports_dir_fd:
            raise OutputPathError(
                "this platform cannot open paths relative to a directory descriptor"
            )
    fd = os.open(b".", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for name in components[:-1]:
            try:
                child = open_directory(name, fd)
            except FileNotFoundError:
                if not create:
                    return None
                os.mkdir(name, 0o755, dir_fd=fd)
                child = open_directory(name, fd)
            os.close(fd)
            fd = child
    except BaseException:
        os.close(fd)
        raise
    return fd


def unlink_final(name: bytes, dir_fd: int) -> None:
    """Remove the final component; a directory there fails the step."""
    try:
        os.unlink(name, dir_fd=dir_fd)
    except FileNotFoundError:
        return
    except IsADirectoryError as exc:
        raise OutputPathError(f"output '{display(name)}' is a directory") from exc
    except PermissionError as exc:
        raise OutputPathError(f"output '{display(name)}' cannot be removed") from exc


def remove_sidecar(components: Sequence[bytes]) -> None:
    """Delete any sidecar at the output path before detection starts."""
    fd = walk_output(components, create=False)
    if fd is None:
        return
    try:
        unlink_final(components[-1], fd)
    finally:
        os.close(fd)


def remove_partial(name: bytes, dir_fd: int, cause: BaseException) -> None:
    """Remove the file a failed write left behind; failing that fails the step.

    An unresolved exit with a readable sidecar still at the output path
    would vouch for the change under review, so only a file that is
    already gone is ignored; any other cleanup failure is an
    ``OutputPathError``, which fails the step rather than exiting 0.
    """
    try:
        os.unlink(name, dir_fd=dir_fd)
    except FileNotFoundError:
        return
    except OSError as exc:
        raise OutputPathError(
            f"output '{display(name)}' cannot be removed after a failed write "
            f"({type(cause).__name__}: {display(to_bytes(str(cause)))})"
        ) from exc


def write_file(name: bytes, dir_fd: int, text: str) -> None:
    """Create ``name`` exclusively under ``dir_fd`` and write ``text`` to it.

    A write or close that fails leaves no partial file behind: the entry
    is removed through the same descriptor before the error propagates.
    """
    file_fd = os.open(
        name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=dir_fd
    )
    try:
        with os.fdopen(file_fd, "w", encoding="utf-8") as handle:
            handle.write(text)
    except BaseException as exc:
        remove_partial(name, dir_fd, exc)
        raise


def write_sidecar(components: Sequence[bytes], result: Result) -> None:
    """Write the sidecar through a fresh, exclusive, link-refusing open."""
    payload = {
        "schema": 1,
        "changed": result.changed,
        "base": result.base.decode("ascii"),
        "reason": result.reason,
        "files": [path.decode("utf-8", "surrogateescape") for path in result.files],
        "changed_paths": [
            path.decode("utf-8", "surrogateescape") for path in result.changed_paths
        ],
    }
    fd = walk_output(components, create=True)
    if fd is None:
        raise OutputPathError(
            f"output '{display(b'/'.join(components))}' has no parent directory"
        )
    try:
        unlink_final(components[-1], fd)
        write_file(components[-1], fd, json.dumps(payload, indent=2) + "\n")
    finally:
        os.close(fd)
