#!/usr/bin/env python3
"""Check one read-only /input task with the checker bundled in this image.

SPDX-License-Identifier: AGPL-3.0-or-later
No package code executes. Isolation requires the external runtime policy.
"""
import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from image_source import source_revision
import publication_check
import registry

INPUT = Path("/input")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--task", required=True)
    args = parser.parse_args(argv)
    try:
        revision = source_revision()
    except (registry.RegistryError, OSError, ValueError):
        print("Asm checker: image source identity is invalid. Use a qualified image.", file=sys.stderr)
        return 1
    try:
        result = publication_check.check(args.task, INPUT / "manifest.json", INPUT / "objects", revision)
        sys.stdout.buffer.write(registry.json_bytes(result))
        return 0
    except (registry.RegistryError, publication_check.InputUnavailable, OSError, ValueError, TypeError):
        print("Asm checker: input is unavailable or invalid. Inspect the retained task and staged files.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
