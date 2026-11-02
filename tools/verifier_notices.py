#!/usr/bin/env python3
"""Collect license notices for modules linked into the verifier.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
import json
from pathlib import Path
import subprocess


def collect(go: str, repository: Path) -> bytes:
    stream = subprocess.check_output([go, "list", "-mod=readonly", "-deps", "-json", "."], cwd=repository / "verifier", timeout=120).decode()
    decoder = json.JSONDecoder()
    modules = {}
    while stream.strip():
        stream = stream.lstrip()
        package, end = decoder.raw_decode(stream)
        stream = stream[end:]
        module = package.get("Module")
        if module and not module.get("Main"):
            if module.get("Replace"):
                raise ValueError("release dependencies cannot use local replacements")
            modules[module["Path"] + "@" + module["Version"]] = Path(module["Dir"])
    goroot = Path(subprocess.check_output([go, "env", "GOROOT"], cwd=repository / "verifier", timeout=15).decode().strip())
    modules["Go standard library and runtime"] = goroot
    blocks = ["ASM verifier dependency notices\nASM adapter source: AGPL-3.0-or-later; see LICENSE and LICENSING.md.\n"]
    for name, directory in sorted(modules.items()):
        notices = [path for path in sorted(directory.iterdir())
                   if path.is_file() and path.name.upper().split(".")[0] in {"LICENSE", "LICENCE", "COPYING", "NOTICE"}]
        if not notices:
            raise ValueError("missing license notice for " + name)
        for path in notices:
            if path.is_symlink() or path.stat().st_size > 1 << 20:
                raise ValueError("invalid license notice for " + name)
            blocks.append(f"\n{name} — {path.name}\n\n{path.read_text()}\n")
    return "".join(blocks).encode()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--go", default="go")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.write_bytes(collect(args.go, Path(__file__).resolve().parents[1]))
