"""Create a source-reference fixture in checkouts and source archives.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import shutil
import subprocess


def reference_repo(source: Path, destination: Path) -> Path:
    destination.mkdir()
    for relative in ('site', 'skills/asm-build', 'cli'):
        shutil.copytree(source / relative, destination / relative)
    # The site's reference path reads committed CLI bytes. Never depend on an
    # enclosing checkout, or change its Git configuration, from a test fixture.
    for arguments in (("init", "-q"), ("add", "--force", "--", "cli"),
                      ("commit", "-qm", "Record source reference fixture")):
        subprocess.run(["git", "-C", str(destination), "-c", "core.hooksPath=/dev/null",
                        "-c", "commit.gpgSign=false", "-c", "user.name=asm site test fixture",
                        "-c", "user.email=fixture@example.invalid", *arguments],
                       check=True, capture_output=True, timeout=10)
    return destination
