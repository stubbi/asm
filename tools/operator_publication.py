#!/usr/bin/env python3
"""Check bounded operator evidence through the trusted publication policy.

SPDX-License-Identifier: AGPL-3.0-or-later
This is release automation. It never executes an image or changes raw evidence.
"""
from __future__ import annotations

import argparse
import math
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import registry
from registry_admin import clean_environment, open_checked, require, run_bounded

ROOT = Path(__file__).resolve().parents[1]
MAX_JSON_BYTES = 1024 * 1024
MAX_EXACT_INTEGER = (1 << 53) - 1
MAX_DEPTH = 64


def canonical_input(path, *, report=False):
    """Snapshot one protected UTF-8 document; preserve exact numbers before jq.

    registry.strict_json rejects duplicate decoded keys and non-JSON constants.
    The schema-1 report permits a finite fractional number only at seconds.
    Other numbers must be integers that jq can represent without rounding.
    """
    descriptor, body = open_checked(path, MAX_JSON_BYTES)
    try:
        require(len(body) == os.fstat(descriptor).st_size, "Publication JSON changed or returned a short read.")
    finally:
        os.close(descriptor)
    value = registry.strict_json(body.decode("utf-8"))
    pending = [((), value)]
    while pending:
        location, item = pending.pop()
        require(len(location) <= MAX_DEPTH, "Publication JSON exceeds its nesting limit.")
        if type(item) is int:
            require(abs(item) <= MAX_EXACT_INTEGER, "Publication JSON has a lossy integer.")
        elif type(item) is float:
            require(report and location == ("seconds",) and math.isfinite(item)
                    and 0 <= item <= MAX_EXACT_INTEGER, "Publication JSON has an invalid number representation.")
        elif isinstance(item, str):
            item.encode("utf-8")  # Reject unpaired surrogates before jq can replace them.
        elif isinstance(item, dict):
            for name, child in item.items():
                name.encode("utf-8")
                pending.append(((*location, name), child))
        elif isinstance(item, list):
            pending.extend(((*location, index), child) for index, child in enumerate(item))
    canonical = registry.json_bytes(value)
    require(len(canonical) <= 4 * MAX_JSON_BYTES, "Canonical publication JSON exceeds its byte limit.")
    return canonical


def check(revision, qualification, image):
    require(re.fullmatch(r"[0-9a-f]{40}", revision or "") and revision != "0" * 40,
            "Supply the exact accepted source revision.")
    report = canonical_input(qualification, report=True)
    inspected = canonical_input(image)
    executable = shutil.which("jq")
    require(executable is not None, "Install jq before checking publication evidence.")
    # jq consumes only private canonical bytes, never the original mutable paths.
    with tempfile.NamedTemporaryFile(prefix="asm-operator-inspected-", mode="w+b") as snapshot:
        snapshot.write(inspected)
        snapshot.flush()
        run_bounded([executable, "--slurp", "--exit-status", "--arg", "revision", revision,
            "--slurpfile", "image", snapshot.name, "--from-file", str(ROOT / "containers/operator-publication.jq")],
            data=report, environment=clean_environment(), output_limit=16, timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--qualification", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    args = parser.parse_args()
    try:
        check(args.revision, args.qualification, args.image)
    except (ValueError, OSError, RecursionError):
        print("Publication evidence failed. Retain the raw report, image inspection, and complete logs.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
