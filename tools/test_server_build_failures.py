#!/usr/bin/env python3
"""Check failed builds in disposable copies of the two server projects.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reject_build(arguments, directory, binary):
    before = digest(binary)
    result = subprocess.run(arguments, cwd=directory, capture_output=True, text=True, timeout=40)
    if result.returncode == 0:
        raise AssertionError("A failed ABI assertion was accepted.")
    if "intentional qualification rejection" not in result.stdout + result.stderr:
        raise AssertionError("Build failure did not reach the intentional ABI assertion.")
    if not binary.is_file() or digest(binary) != before:
        raise AssertionError("A failed build changed the previous executable.")
    if list(binary.parent.glob(".asm-*")):
        raise AssertionError("A failed build left a private build stage.")
    return {"exit_code": result.returncode, "preserved_sha256": before}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ("reference", "hosted", "hosted-build", "asm", "mhd-prefix", "pg-prefix"):
        parser.add_argument("--" + field, type=Path, required=True)
    parser.add_argument("--target", choices=("x86_64-linux", "aarch64-linux", "riscv64-linux"), required=True)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.revision) or args.revision == "0" * 40:
        parser.error("revision must be an exact nonzero source commit")
    reference = args.reference.resolve(strict=True)
    hosted = args.hosted.resolve(strict=True)
    common = [f"MHD_PREFIX={args.mhd_prefix.resolve(strict=True)}", f"PG_PREFIX={args.pg_prefix.resolve(strict=True)}"]
    with tempfile.TemporaryDirectory(prefix="asm-server-build-failures-") as temporary:
        work = Path(temporary)
        copied_reference = work / "reference"
        copied_hosted = work / "hosted"
        shutil.copytree(reference, copied_reference)
        shutil.copytree(hosted, copied_hosted, ignore=shutil.ignore_patterns("build", "__pycache__"))
        hosted_build = work / "hosted-build"
        hosted_build.mkdir()
        shutil.copy2(args.hosted_build.resolve(strict=True) / "asm-hub", hosted_build / "asm-hub")
        rejection = '\n_Static_assert(0, "intentional qualification rejection");\n'
        for project in (copied_reference, copied_hosted):
            checker = project / "abi-check.c"
            checker.write_bytes(checker.read_bytes() + rejection.encode())
        reference_result = reject_build(
            ["make", "all", f"ASM={args.asm.resolve(strict=True)}", *common],
            copied_reference, copied_reference / "build/app",
        )
        hosted_result = reject_build(
            ["make", "all", f"TARGET={args.target}", f"BUILD={hosted_build}",
             f"SOURCE_REVISION={args.revision}", *common],
            copied_hosted, hosted_build / "asm-hub",
        )
        (copied_hosted / "abi-check.c").write_bytes((hosted / "abi-check.c").read_bytes())
        symbolic_results = {}
        for kind in ("file", "directory"):
            destination = hosted_build / "asm-hub"
            destination.unlink()
            outside = work / ("outside-" + kind)
            if kind == "directory":
                outside.mkdir()
                marker = outside / "user-file"
            else:
                marker = outside
            marker.write_bytes(b"retain this external file\n")
            destination.symlink_to(outside, target_is_directory=kind == "directory")
            result = subprocess.run(
                ["make", "all", f"TARGET={args.target}", f"BUILD={hosted_build}",
                 f"SOURCE_REVISION={args.revision}", *common],
                cwd=copied_hosted, capture_output=True, text=True, timeout=40,
            )
            if result.returncode == 0 or not destination.is_symlink():
                raise AssertionError("A symbolic build destination was accepted or replaced.")
            if "asm-hub must not be a symlink or directory" not in result.stderr:
                raise AssertionError("Build failure did not reach the symbolic destination guard.")
            if marker.read_bytes() != b"retain this external file\n" or list(hosted_build.glob(".asm-*")):
                raise AssertionError("A rejected symbolic destination changed external data or retained a stage.")
            if kind == "directory" and sorted(path.name for path in outside.iterdir()) != ["user-file"]:
                raise AssertionError("The builder wrote through a symbolic target directory.")
            symbolic_results[kind] = {"exit_code": result.returncode, "outside_unchanged": True}
    print(json.dumps({"status": "pass", "tests": 4, "reference": reference_result,
                      "hosted": hosted_result, "symbolic_destinations": symbolic_results}))


if __name__ == "__main__":
    main()
