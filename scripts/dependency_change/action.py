# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""The step: read inputs, clear the sidecar, detect, write outputs."""

from __future__ import annotations

import json
import os
import secrets
from collections.abc import Mapping, Sequence

from dependency_change.common import InputError, Unresolved, display, log, to_bytes
from dependency_change.detect import detect
from dependency_change.inputs import Inputs
from dependency_change.sidecar import remove_sidecar, write_sidecar

# The fail-closed guards, by the module each is looked up in.
# tests/test_mutation.py disables each one in turn and checks that a test
# notices; keep this in step with the functions themselves.
GUARDS: Mapping[str, str] = {
    "guard_git_refuses_lazy_fetch": "dependency_change.detect",
    "guard_head_is_github_sha": "dependency_change.detect",
    "guard_event_has_base": "dependency_change.detect",
    "guard_before_is_a_commit": "dependency_change.detect",
    "guard_base_in_checkout": "dependency_change.detect",
    "guard_prefix_inside_repository": "dependency_change.detect",
    "guard_prefix_not_through_link": "dependency_change.detect",
    "guard_prefix_in_tree": "dependency_change.detect",
    "guard_reachable_entries_changed": "dependency_change.detect",
    "remove_sidecar": "dependency_change.action",
    "remove_partial": "dependency_change.sidecar",
}

OUTPUT_NAMES = ("changed", "reason", "base", "manifest", "changed-paths")


def changed_paths_json(paths: Sequence[bytes]) -> bytes:
    """Render ``paths`` as a compact JSON array, or empty when one is not UTF-8.

    A path that does not decode cannot be represented faithfully, so the
    output is left unresolved rather than carrying a mangled name.
    """
    try:
        names = [path.decode("utf-8") for path in paths]
    except UnicodeDecodeError:
        log("::notice::changed-paths is empty: a changed path is not valid UTF-8")
        return b""
    return json.dumps(names, ensure_ascii=False, separators=(",", ":")).encode()


def write_outputs(env: Mapping[str, str], values: Mapping[str, bytes]) -> None:
    """Append outputs to ``GITHUB_OUTPUT`` in heredoc form, if it is set."""
    path = env.get("GITHUB_OUTPUT", "")
    if not path:
        return
    with open(path, "ab") as handle:
        for name, value in values.items():
            delimiter = b"ghadelim_" + secrets.token_hex(16).encode("ascii")
            while delimiter in value:
                delimiter = b"ghadelim_" + secrets.token_hex(16).encode("ascii")
            handle.write(
                b"%s<<%s\n%s\n%s\n"
                % (name.encode("ascii"), delimiter, value, delimiter)
            )


def fail(env: Mapping[str, str], outputs: Mapping[str, bytes], message: str) -> int:
    """Log ``message`` as an error, write the empty outputs and fail the step."""
    log(f"dependency change: error: {message}")
    write_outputs(env, outputs)
    return 1


def run(env: Mapping[str, str]) -> int:
    """Run the action against ``env``; return the exit code."""
    outputs: dict[str, bytes] = dict.fromkeys(OUTPUT_NAMES, b"")
    try:
        inputs = Inputs.from_env(env)
        remove_sidecar(inputs.output_components)
    except InputError as exc:
        return fail(env, outputs, str(exc))
    except Exception as exc:
        # A planted sidecar that survives would vouch for the change under
        # review: a consumer reading a fixed manifest path could take its
        # stale false. Unlike a detection surprise, this fails the step.
        return fail(
            env,
            outputs,
            "cannot clear the sidecar: "
            f"unexpected {type(exc).__name__}: {display(to_bytes(str(exc)))}",
        )
    try:
        result = detect(inputs, env)
        write_sidecar(inputs.output_components, result)
    except InputError as exc:
        return fail(env, outputs, str(exc))
    except Unresolved as exc:
        reason = f"unresolved: {exc}"
        outputs["reason"] = to_bytes(reason)
        log(f"dependency change: {reason}")
    except Exception as exc:
        # Any surprise in detection or in the sidecar write is an
        # unresolved result: never a crash and never false.
        reason = f"unresolved: unexpected {type(exc).__name__}: {display(to_bytes(str(exc)))}"
        outputs["reason"] = to_bytes(reason)
        log(f"dependency change: {reason}")
    else:
        outputs["changed"] = b"true" if result.changed else b"false"
        outputs["reason"] = to_bytes(result.reason)
        outputs["base"] = result.base
        outputs["manifest"] = inputs.output
        outputs["changed-paths"] = changed_paths_json(result.changed_paths)
        log(
            f"dependency change: changed={outputs['changed'].decode()} ({result.reason})"
        )
    write_outputs(env, outputs)
    return 0


def main() -> int:
    """Entry point for the composite action."""
    return run(os.environ)
