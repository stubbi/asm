#!/usr/bin/env python3
"""Generate a Windows PowerShell bootstrap; never load or run its candidate.

Python is a build-tool dependency only. Native CLI logic remains in assembly.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import stat

if __package__:
    from . import bootstrap, registry, windows_layout
else:
    import bootstrap
    import registry
    import windows_layout

TARGETS = frozenset(("x86_64-windows", "aarch64-windows"))
TEMPLATE = Path(__file__).with_name("windows-install.ps1.in")


def _render(specification: dict) -> bytes:
    """Encode all variable data separately from the fixed ASCII script."""
    data = json.dumps(specification, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    registry.require(len(data) <= 16384, "Windows bootstrap specification exceeds its byte limit")
    script = TEMPLATE.read_text(encoding="ascii")
    registry.require(script.count("@@ASM_SPEC@@") == 1, "Windows bootstrap needs one specification insertion point")
    script = script.replace("@@ASM_SPEC@@", base64.b64encode(data).decode("ascii"))
    registry.require("@@" not in script, "Windows bootstrap contains an unexpanded template field")
    return script.encode("ascii")


def render_source_installer(artifact: Path, target: str) -> bytes:
    """Bind one deliberate source build without claiming publisher authentication.

    Inspect a bounded regular file through one descriptor. Record its absolute
    path, exact bytes and PE metadata. No process is created or artifact loaded.
    """
    registry.require(target in TARGETS, "unsupported Windows bootstrap target")
    artifact = Path(artifact).absolute()
    path = str(artifact)
    registry.require(len(path.encode("utf-8")) <= 4096 and not any(ord(c) < 32 for c in path),
                     "source artifact path exceeds its bound or contains a control character")
    before = artifact.lstat()
    registry.require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                     and 0 < before.st_size <= registry.MAX_ARTIFACT_BYTES,
                     "source artifact must be a bounded single-link regular file")
    descriptor = os.open(artifact, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0))
    with os.fdopen(descriptor, "rb") as source:
        held = os.fstat(source.fileno())
        registry.require((held.st_dev, held.st_ino, held.st_size) == (before.st_dev, before.st_ino, before.st_size),
                         "source artifact changed before it was opened")
        data = source.read(registry.MAX_ARTIFACT_BYTES + 1)
        after = os.fstat(source.fileno())
    current = artifact.lstat()
    registry.require(len(data) == before.st_size and stat.S_ISREG(current.st_mode)
                     and current.st_nlink == 1
                     and (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
                     == (held.st_dev, held.st_ino, held.st_size, held.st_mtime_ns)
                     and (current.st_dev, current.st_ino) == (held.st_dev, held.st_ino),
                     "source artifact changed during generation")
    metadata = windows_layout.read_pe_metadata(data, target)
    item = {"target": target, "path": str(artifact.resolve()), "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest()}
    return _render({"mode": "source", "version": metadata["version"], "artifacts": [item]})


def render_installer(release: dict) -> bytes:
    """Bind a published candidate to the existing fixed bootstrap policy.

    This generator neither publishes an installer nor admits a released host.
    The signed candidate and bundle follow the existing bootstrap policy;
    native self-update retains its separate three provenance bindings.
    """
    registry.require(isinstance(release, dict) and set(release)
                     == {"version", "source_commit", "repository_id", "bundle_url", "artifacts"},
                     "invalid Windows bootstrap release fields")
    version = release["version"]
    registry.require(registry.version_tuple(version) >= (0, 6, 0), "Windows bootstrap release is too old")
    source = release["source_commit"]
    registry.require(isinstance(source, str) and re.fullmatch(r"[0-9a-f]{40}", source) is not None
                     and source != "0" * 40, "invalid Windows bootstrap source commit")
    registry.require(release["repository_id"] == bootstrap.REPOSITORY_ID, "invalid Windows bootstrap repository identity")
    base = f"{bootstrap.REPOSITORY}/releases/download/v{version}"
    registry.require(release["bundle_url"] == base + "/release-attestation.sigstore.json",
                     "invalid Windows bootstrap bundle URL")
    artifacts = release["artifacts"]
    registry.require(isinstance(artifacts, list) and 0 < len(artifacts) <= len(TARGETS),
                     "Windows bootstrap needs supported executable artifacts")
    seen = set()
    for item in artifacts:
        registry.require(isinstance(item, dict) and set(item) == {"target", "bytes", "sha256", "url"},
                         "invalid Windows bootstrap artifact fields")
        target = item["target"]
        registry.require(isinstance(target, str) and target in TARGETS and target not in seen,
                         "unsupported or duplicate Windows bootstrap target")
        seen.add(target)
        windows_layout.encode_record(version, target, item["bytes"], item["sha256"])
        registry.require(item["url"] == f"{base}/asm-{version}-{target}",
                         "Windows executable URL must use its canonical target asset")
    return _render({"mode": "published", **release, "artifacts": sorted(artifacts, key=lambda item: item["target"])})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-artifact", type=Path, required=True)
    parser.add_argument("--target", required=True, choices=sorted(TARGETS))
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        data = render_source_installer(arguments.source_artifact, arguments.target)
        registry.write_atomic(arguments.output, data)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Windows bootstrap: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
