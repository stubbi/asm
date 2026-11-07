"""Discovery labels for the registry's explicit version-one target profiles.

Architecture groups describe declared artifacts, not host compatibility or
CPU features. Unknown profiles have no inferred architecture.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import registry

ARCHITECTURES = {"aarch64": "ARM64", "x86_64": "x86-64", "riscv64": "RISC-V64"}
TARGET_ARCHITECTURES = {"aarch64-linux": "aarch64", "aarch64-macos": "aarch64",
                        "x86_64-linux": "x86_64", "riscv64-linux": "riscv64",
                        "aarch64-windows": "aarch64", "x86_64-windows": "x86_64"}


def architecture_for_target(target):
    """Return the declared v1 profile's architecture, or None for other values."""
    return TARGET_ARCHITECTURES.get(target) if isinstance(target, str) else None


def architecture_groups(index):
    """Count each package once per architecture of its latest active release.

    Input is the accepted schema-one website index. Published records and
    artifact selections stay unchanged; grouping never executes a package.
    """
    registry.require(isinstance(index, dict) and type(index.get("schema")) is int and index["schema"] == 1
                     and isinstance(index.get("packages"), list) and len(index["packages"]) <= registry.MAX_ROWS,
                     "unsupported architecture index")
    members = {key: set() for key in ARCHITECTURES}
    names = set()
    for package in index["packages"]:
        name = registry.package_name(package["name"])
        registry.require(name not in names, "duplicate architecture package")
        names.add(name)
        if package.get("latest") is None:
            continue
        releases = [release for release in package["versions"]
                    if release.get("version") == package["latest"] and release.get("yanked") is False]
        registry.require(len(releases) == 1 and isinstance(releases[0].get("artifacts"), list),
                         "architecture package lacks its latest active release")
        for artifact in releases[0]["artifacts"]:
            architecture = architecture_for_target(artifact.get("target"))
            if architecture is not None:
                members[architecture].add(name)
    return [{"id": key, "name": ARCHITECTURES[key], "packages": sorted(members[key])}
            for key in sorted(ARCHITECTURES, key=lambda key: ARCHITECTURES[key].casefold()) if members[key]]
