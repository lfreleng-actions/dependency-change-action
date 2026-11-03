# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Exceptions, byte handling and logging shared by the detector's modules."""

from __future__ import annotations

import sys


class InputError(Exception):
    """An input the action cannot work with; fails the step."""


class Unresolved(Exception):
    """The detector cannot prove what the change touched."""


def to_bytes(value: str) -> bytes:
    """Encode an environment value back to the bytes the OS handed over."""
    return value.encode("utf-8", "surrogateescape")


def display(path: bytes) -> str:
    """Render a path for a log line so it stays on that one line.

    Newlines, carriage returns, other control bytes and undecodable bytes
    are escaped. The caller always prefixes the result, so a path cannot
    place ``::`` at the start of a line and forge a workflow command. The
    runner's legacy parser recognises ``##[`` anywhere in a line, so that
    marker is escaped wherever it appears.
    """
    text = path.decode("utf-8", "surrogateescape")
    out: list[str] = []
    for index, char in enumerate(text):
        code = ord(char)
        if char == "\\":
            out.append("\\\\")
        elif char == "\n":
            out.append("\\n")
        elif char == "\r":
            out.append("\\r")
        elif code < 0x20 or code == 0x7F or 0xDC80 <= code <= 0xDCFF:
            out.append(f"\\x{code & 0xFF:02x}")
        elif char == "[" and text[max(index - 2, 0) : index] == "##":
            out.append("\\x5b")
        else:
            out.append(char)
    return "".join(out)


def log(message: str) -> None:
    """Write one line to the step log."""
    sys.stdout.write(message + "\n")
    sys.stdout.flush()
