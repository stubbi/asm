"""Validate reviewed discovery labels and exact-release direct dependencies.

This rebuildable sidecar does not change published manifests or authorize
installation. Missing dependency declarations remain unknown, not empty.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import re

import registry

MAX_BYTES = 256 * 1024
MAX_KEYWORDS = 32
MAX_TOTAL_KEYWORDS = registry.MAX_ROWS
MAX_DEPENDENCIES = 256
KEYWORD = re.compile(r"[a-z][a-z0-9-]{0,39}\Z")


def _catalog(index: dict) -> dict:
    registry.require(isinstance(index, dict) and type(index.get("schema")) is int and index["schema"] == 1
                     and isinstance(index.get("packages"), list) and len(index["packages"]) <= registry.MAX_ROWS,
                     "invalid discovery metadata catalog")
    known, release_count = {}, 0
    for package in index["packages"]:
        registry.require(isinstance(package, dict), "invalid discovery metadata package")
        name = registry.package_name(package.get("name"))
        registry.require(name not in known and isinstance(package.get("versions"), list),
                         "ambiguous discovery metadata package")
        releases = {}
        for release in package["versions"]:
            registry.require(isinstance(release, dict), "invalid discovery metadata release")
            version = release.get("version")
            registry.version_tuple(version)
            source = release.get("source")
            registry.require(version not in releases and type(release.get("yanked")) is bool
                             and isinstance(source, dict) and isinstance(source.get("commit"), str)
                             and registry.HEX40.fullmatch(source["commit"]) is not None
                             and source["commit"] != "0" * 40, "invalid discovery metadata release binding")
            releases[version] = release
            release_count += 1
        active = [version for version, release in releases.items() if not release["yanked"]]
        latest = max(active, key=registry.version_tuple) if active else None
        registry.require(releases and package.get("latest") == latest and release_count <= registry.MAX_ROWS,
                         "discovery metadata latest release differs from the catalog")
        known[name] = {"latest": latest, "releases": releases}
    return known


def project_metadata(value: dict, index: dict) -> dict:
    """Count declared membership and distinct latest-active direct consumers.

    Dependencies are package-level declarations across any declared target.
    They establish neither transitive relationships nor target compatibility.
    Partial declarations supply positive observed minima, never unknown zeroes.
    """
    known = _catalog(index)
    registry.exact_keys(value, {"schema", "packages"}, {"schema", "packages"}, "discovery metadata")
    registry.require(type(value["schema"]) is int and value["schema"] == 1
                     and isinstance(value["packages"], list) and len(value["packages"]) <= len(known),
                     "unsupported discovery metadata")
    declared = {}
    for package in value["packages"]:
        registry.exact_keys(package, {"name", "keywords", "releases"}, {"name"}, "discovery package metadata")
        name = registry.package_name(package["name"])
        registry.require(name in known and name not in declared, "unknown or duplicate discovery metadata package")
        keywords = package.get("keywords", [])
        registry.require(isinstance(keywords, list) and len(keywords) <= MAX_KEYWORDS
                         and all(isinstance(tag, str) and KEYWORD.fullmatch(tag) is not None
                                 and not tag.endswith("-") and "--" not in tag for tag in keywords)
                         and len(set(keywords)) == len(keywords), "invalid discovery keywords")
        declarations = package.get("releases", [])
        registry.require(isinstance(declarations, list) and len(declarations) <= len(known[name]["releases"]),
                         "too many discovery dependency declarations")
        releases = {}
        for release in declarations:
            registry.exact_keys(release, {"version", "source_commit", "dependencies"},
                                {"version", "source_commit", "dependencies"}, "discovery dependency declaration")
            version = release["version"]
            registry.version_tuple(version)
            registry.require(version in known[name]["releases"] and version not in releases
                             and release["source_commit"] == known[name]["releases"][version]["source"]["commit"],
                             "discovery dependency source binding differs from the release")
            dependencies = release["dependencies"]
            registry.require(isinstance(dependencies, list) and len(dependencies) <= MAX_DEPENDENCIES
                             and all(isinstance(other, str) and other in known and other != name for other in dependencies)
                             and len(set(dependencies)) == len(dependencies), "invalid direct dependency declaration")
            releases[version] = sorted(dependencies)
        declared[name] = {"keywords": sorted(keywords), "releases": releases}
    active = {name for name, package in known.items() if package["latest"] is not None}
    packages, tags = [], {}
    consumers = {name: set() for name in active}
    covered = 0
    for name in sorted(known):
        latest = known[name]["latest"]
        metadata = declared.get(name, {"keywords": [], "releases": {}})
        dependencies = metadata["releases"].get(latest) if latest is not None else None
        packages.append({"name": name, "version": latest, "keywords": metadata["keywords"], "dependencies": dependencies})
        if name not in active:
            continue
        for tag in metadata["keywords"]:
            registry.require(tag in tags or len(tags) < MAX_TOTAL_KEYWORDS,
                             "too many distinct discovery keywords")
            tags.setdefault(tag, []).append(name)
        if dependencies is not None:
            covered += 1
            for other in dependencies:
                if other in consumers:
                    consumers[other].add(name)
    complete = covered == len(active)
    keywords = [{"id": tag, "name": tag, "packages": names, "package_count": len(names)}
                for tag, names in tags.items()]
    keywords.sort(key=lambda tag: (-tag["package_count"], tag["id"]))
    dependents = [{"name": name, "packages": sorted(names),
                   "count": len(names) if names or complete else None, "exact": complete}
                  for name, names in sorted(consumers.items())]
    ranked = sorted((row for row in dependents if row["count"] is not None and row["count"] > 0),
                    key=lambda row: (-row["count"], row["name"]))
    return {"schema": 1, "packages": packages, "keywords": keywords, "dependents": dependents,
            "dependency_coverage": {"known": covered, "total": len(active), "complete": complete},
            "feeds": {"keywords": [row["id"] for row in keywords], "depended_on": [row["name"] for row in ranked]}}


def read_metadata(root: Path, index: dict, filename="discovery-metadata.json") -> dict:
    """Read a bounded regular sidecar. Missing files leave declarations unknown."""
    registry.portable_path(filename)
    path = root / filename
    if not path.exists() and not path.is_symlink():
        return project_metadata({"schema": 1, "packages": []}, index)
    value = registry.strict_json(registry.read_regular(root, filename, MAX_BYTES))
    return project_metadata(value, index)
