# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Entry point, run as a file in isolated mode or as ``-m dependency_change``.

The action runs ``python3 -I <this file>``: isolated mode keeps the
checkout's directory, ``PYTHONPATH`` and the user site out of ``sys.path``,
so a file in the change under review cannot shadow the detector or a
standard-library module it imports. The package is then found through
this file's own location, which belongs to the action, not the checkout.
"""

from __future__ import annotations

import os
import sys


def launch() -> int:
    """Put the action's ``scripts`` directory first on ``sys.path`` and run."""
    scripts = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if scripts not in sys.path:
        sys.path.insert(0, scripts)
    from dependency_change.action import main

    return main()


if __name__ == "__main__":
    sys.exit(launch())
