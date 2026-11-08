"""Bounded private V2 website projection, without a new application service.

The operator selects the mirror and registry identity. Inventory and canonical
payload checks do not verify signatures or retain rollback authority. Native
assembly fetch/install commands independently authenticate current TUF policy.
This module performs no network requests and executes no package code.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

from copy import deepcopy
import hashlib
import re
import shlex
from urllib.parse import urlsplit

import download_data as clock
import publication_check
import registry
import registry_distribution as distribution
import registry_log_import as logs

MAX_SITE_BYTES = 16 * 1024 * 1024
MAX_OBSERVATION_BYTES = 4 * 1024 * 1024
EVIDENCE = {"metadata": "validated", "artifacts": "not-run", "provenance": "not-run",
            "formal": "not-run", "agent_review": "not-run"}


def _mirrors(values):
    registry.require(isinstance(values, (tuple, list)) and 1 <= len(values) <= 3
                     and all(isinstance(value, str) for value in values)
                     and len(set(values)) == len(values), "select one to three distinct V2 mirror bases")
    for value in values:
        registry.require(isinstance(value, str) and 0 < len(value) <= 1024
                         and all(33 <= ord(char) < 127 for char in value), "invalid V2 mirror base")
        try:
            parsed = urlsplit(value)
            port = parsed.port
        except ValueError:
            raise registry.RegistryError("invalid V2 mirror base") from None
        registry.require(parsed.scheme == "https" and parsed.hostname and parsed.netloc == parsed.netloc.lower()
            and parsed.username is None and parsed.password is None and not parsed.query and not parsed.fragment
            and (port is None or 0 < port <= 65535) and not parsed.path.endswith("/")
            and re.fullmatch(r"(?:/[A-Za-z0-9_.~-]+)*", parsed.path) is not None
            and all(part not in (".", "..") for part in parsed.path.split("/"))
            and re.fullmatch(r"(?:[a-z0-9][a-z0-9.-]*|\[[0-9a-f:]+\])(?::[1-9][0-9]{0,4})?", parsed.netloc) is not None,
            "use a canonical HTTPS mirror base without credentials, query, fragment, or path aliases")
    return list(values)


def _policy(store, head, plan, releases):
    prefix = "targets/registries/" + head["registry_id"] + "/"
    selected = [item for item in plan["files"] if re.fullmatch(re.escape(prefix) + r"[0-9a-f]{64}\.policy\.tsv", item["key"])]
    registry.require(len(selected) == 1, "the selected inventory needs one lifecycle policy")
    raw = distribution._read_bound(store, selected[0]["key"], selected[0])
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        raise registry.RegistryError("lifecycle policy must use ASCII") from None
    header = "\t".join(("# asm-registry-policy-v2", head["registry_id"], head["publication_revision"], head["policy_revision"])) + "\n"
    registry.require(text.startswith(header) and text.endswith("\n")
                     and all(char in "\t\n" or 32 <= ord(char) <= 126 for char in text),
                     "lifecycle policy identity, revisions, or encoding differ")
    result, ordered = {}, []
    for line in text[len(header):].split("\n")[:-1]:
        fields = line.split("\t")
        registry.require(len(fields) == 6 and fields[4] in ("0", "1") and fields[5] in ("0", "1"),
                         "invalid lifecycle policy row")
        name, version, package, release, yanked, revoked = fields
        registry.require((name, version) in releases and releases[(name, version)] == (package, release)
                         and (name, version) not in result, "lifecycle policy release binding differs")
        ordered.append((name, version))
        result[(name, version)] = (yanked == "1", revoked == "1")
    registry.require(ordered == sorted(ordered) and set(result) == set(releases),
                     "lifecycle policy is unordered or incomplete")
    return result


def _checked_artifacts(store, publication):
    archive = publication["source"]["archive"]
    files = registry.read_archive(store.get_blob(archive["sha256"], archive["bytes"]))
    for artifact in publication["artifacts"]:
        target = publication_check.TARGETS[(artifact["isa"], artifact["os"], artifact["abi"])][0]
        project = registry.validate_project(files, publication["name"], publication["version"], target, v2_dependencies=True)
        registry.require(registry.v2_project_declarations(files["asm.toml"], project) == registry.v2_declarations(publication),
                         "source dependency and feature declarations differ from the signed metadata")
        if artifact["kind"] == "executable":
            registry.validate_executable(store.get_blob(artifact["sha256"], artifact["bytes"]), target)


def load_catalog(store, registry_id, mirrors: tuple[str, ...], *, verify_artifacts=False) -> dict:
    """Project selected local/S3 public bytes; no signature authority is granted.

    Metadata-only operation reads each bounded envelope and policy once. Explicit
    artifact verification additionally reads source archives and executables.
    A changed head or unfinished timestamp advancement refuses the projection.
    """
    distribution._identity(registry_id)
    selected_mirrors = _mirrors(mirrors)
    registry.require(type(verify_artifacts) is bool, "artifact verification must be explicit")
    current = distribution.load_current(store)
    registry.require(current is not None and current[0]["registry_id"] == registry_id,
                     "the selected distribution has a different or absent registry identity")
    head, plan, _ = current
    stamp = store.read_object("metadata/timestamp.json", 16384)
    registry.require(stamp is not None and hashlib.sha256(stamp[0]).hexdigest() == head["timestamp_sha256"],
                     "the selected distribution timestamp is incomplete")
    blob_sizes = {item["sha256"]: item["bytes"] for item in plan["blobs"]}
    packages, names, release_ids, selections = {}, {}, set(), {}
    for item in plan["files"]:
        if not item["key"].startswith("targets/registries/" + registry_id + "/releases/"):
            continue
        registry.require(item["bytes"] <= 131072, "release envelope exceeds its byte bound")
        raw = distribution._read_bound(store, item["key"], item)
        envelope = registry.strict_json(raw)
        fields = {"schema", "registry_id", "package_id", "release_id", "manifest_sha256", "publication"}
        registry.exact_keys(envelope, fields, fields, "site release envelope")
        registry.require(type(envelope["schema"]) is int and envelope["schema"] == 2
                         and envelope["registry_id"] == registry_id and registry.json_bytes(envelope) == raw,
                         "site release envelope identity or encoding differs")
        package_id, release_id = envelope["package_id"], envelope["release_id"]
        distribution._identity(package_id); distribution._identity(release_id)
        manifest = registry.json_bytes(envelope["publication"])
        publication, objects = publication_check.manifest(manifest)
        name, version = publication["name"], publication["version"]
        registry.require(envelope["manifest_sha256"] == hashlib.sha256(manifest).hexdigest()
            and item["key"] == f"targets/registries/{registry_id}/releases/{name}/{item['sha256']}.{version}.json"
            and all(blob_sizes.get(digest) == size for digest, size in objects.items()), "site release object binding differs")
        registry.require(release_id not in release_ids and (name, version) not in selections
            and names.get(name, package_id) == package_id
            and (package_id not in packages or packages[package_id]["name"] == name), "site package or release identity was rebound")
        release_ids.add(release_id); names[name] = package_id
        selections[(name, version)] = (package_id, release_id)
        package = packages.setdefault(package_id, {"name": name, "package_id": package_id, "summary": publication["summary"],
            "latest": None, "targets": [], "versions": []})
        if verify_artifacts:
            _checked_artifacts(store, publication)
        artifacts = []
        for artifact in publication["artifacts"]:
            target = publication_check.TARGETS[(artifact["isa"], artifact["os"], artifact["abi"])][0]
            tag = ".".join((registry_id, package_id, release_id, target, artifact["kind"]))
            artifacts.append(deepcopy(artifact) | {"target": target,
                "url": selected_mirrors[0] + "/blobs/sha256/" + artifact["sha256"] + "?x-asm=" + tag})
        package["versions"].append({"version": version, "release_id": release_id,
            "manifest_sha256": envelope["manifest_sha256"], "envelope_sha256": item["sha256"],
            "summary": publication["summary"], "license": publication["license"], "source": deepcopy(publication["source"]),
            "artifacts": sorted(artifacts, key=lambda artifact: (artifact["target"], artifact["kind"])),
            "evidence": EVIDENCE | {"artifacts": "validated" if verify_artifacts else "not-run"},
            "publication": deepcopy(publication)})
    registry.require(len(release_ids) <= 4095, "too many site releases")
    policy = _policy(store, head, plan, selections)
    for package in packages.values():
        package["versions"].sort(key=lambda release: registry.version_tuple(release["version"]))
        for release in package["versions"]:
            release["yanked"], release["revoked"] = policy[(package["name"], release["version"])]
            if not release["yanked"] and not release["revoked"]:
                package["latest"] = release["version"]
                package["summary"] = release["summary"]
                package["targets"] = sorted({item["target"] for item in release["artifacts"]})
    result = {"schema": 2, "registry_id": registry_id,
        "projection": {key: head[key] for key in ("version", "publication_revision", "policy_revision")},
        "mirrors": selected_mirrors, "packages": sorted(packages.values(), key=lambda package: package["name"])}
    registry.require(len(registry.json_bytes(result)) <= MAX_SITE_BYTES, "V2 site catalog exceeds its byte bound")
    after = distribution.load_current(store)
    stamp_after = store.read_object("metadata/timestamp.json", 16384)
    registry.require(after is not None and after[0] == head and stamp_after is not None and stamp_after[0] == stamp[0],
                     "distribution changed during website projection; retry the current selection")
    return result


def fetch_command(catalog, package, release, artifact) -> str:
    """Return a deliberate native authenticated download, never an execution."""
    registry.require(package in catalog["packages"] and release in package["versions"]
        and artifact in release["artifacts"] and not release["yanked"] and not release["revoked"],
        "select an active artifact from this catalog")
    registry.package_name(package["name"]); registry.version_tuple(release["version"])
    distribution._identity(catalog["registry_id"])
    mirrors = _mirrors(catalog["mirrors"])
    extension = ".tar.gz" if artifact["kind"] == "source" else (".exe" if artifact["format"] == "pe" else "")
    filename = package["name"].split("/")[1] + "-" + release["version"] + "-" + artifact["target"] + extension
    arguments = ["asm", "registry", "fetch", package["name"] + "@" + release["version"],
        "--registry-id", catalog["registry_id"], "--root", "/private/asm-trust/root.json",
        "--state", "/private/asm-trust/client-state"]
    for mirror in mirrors:
        arguments.extend(("--mirror", mirror))
    arguments.extend(("--target", artifact["target"], "--kind", artifact["kind"], "--output", "/absolute/download/" + filename))
    return shlex.join(arguments)


def observations(catalog, snapshot_or_none) -> dict:
    """Validate one same-inventory sender snapshot; missing data stays unknown."""
    packages = {package["package_id"]: package["name"] for package in catalog["packages"]}
    releases = {release["release_id"]: {"package_id": package["package_id"], "name": package["name"], "version": release["version"]}
                for package in catalog["packages"] for release in package["versions"]}
    unknown = {"schema": 2, "registry_id": catalog["registry_id"], "packages": packages, "releases": releases,
        "observed_at": None, "collection_started_at": None, "coverage_start": None, "coverage_end": None,
        "complete": False, "stale": True, "counts": dict.fromkeys(packages), "release_counts": dict.fromkeys(releases),
        "daily_counts": [], "coverage_intervals": [], "retained_counts": dict.fromkeys(packages),
        "retained_release_counts": dict.fromkeys(releases), "retained_coverage_start": None, "retained_complete": False,
        "sources": [], "reporting": "origin-log-lower-bounds-v2", "unattributed_requests": None,
        "retained_unattributed_requests": None}
    if snapshot_or_none is None:
        return unknown
    value = deepcopy(snapshot_or_none)
    registry.exact_keys(value, set(unknown), set(unknown), "V2 website observations")
    registry.require(len(registry.json_bytes(value)) <= MAX_OBSERVATION_BYTES, "V2 website observations exceed four MiB")
    registry.require(type(value["schema"]) is int and value["schema"] == 2 and value["registry_id"] == catalog["registry_id"]
        and value["packages"] == packages and value["releases"] == releases and value["reporting"] == unknown["reporting"],
        "observation identities differ from the selected V2 catalog")
    registry.require(value["complete"] is False and value["retained_complete"] is False and type(value["stale"]) is bool,
                     "V2 origin observations cannot claim complete coverage")
    sources = value["sources"]
    registry.require(isinstance(sources, list) and len(sources) <= 32
                     and all(isinstance(source, str) for source in sources) and sources == sorted(set(sources)),
                     "invalid V2 observation sources")
    for source in sources:
        clock._opaque(source)
    for field in ("observed_at", "collection_started_at", "coverage_start", "coverage_end", "retained_coverage_start"):
        if value[field] is not None:
            clock._time(value[field])
    end = value["coverage_end"]
    registry.require(value["coverage_start"] is None and value["coverage_intervals"] == [],
                     "unsupported complete origin coverage claims")
    if end is None:
        registry.require(value["collection_started_at"] is None and value["retained_coverage_start"] is None
                         and value["stale"] is True and value["daily_counts"] == [], "invalid unknown observation coverage")
    else:
        registry.require(sources and value["observed_at"] is not None and value["collection_started_at"] is not None
            and value["retained_coverage_start"] == value["collection_started_at"]
            and clock._time(value["collection_started_at"]) < clock._time(end) <= clock._time(value["observed_at"]),
            "invalid observation reporting interval")
        registry.require(value["stale"] == (clock._time(value["observed_at"]) - clock._time(end) > clock.DAY),
                         "observation stale state differs from its cutoff")
    for field, ids in (("counts", packages), ("retained_counts", packages), ("release_counts", releases), ("retained_release_counts", releases)):
        registry.require(isinstance(value[field], dict) and set(value[field]) == set(ids), "observation count identities differ")
        for count in value[field].values():
            registry.require(count is None if end is None else type(count) is int and 0 <= count <= logs.MAX_EVENTS,
                             "observation count is invalid or claims zero without reporting")
    for field in ("unattributed_requests", "retained_unattributed_requests"):
        count = value[field]
        registry.require(count is None if end is None else type(count) is int and 0 <= count <= logs.MAX_EVENTS,
                         "invalid unattributed observation count")
    registry.require(isinstance(value["daily_counts"], list) and len(value["daily_counts"]) <= logs.MAX_EVENTS,
                     "too many daily observations")
    keys, daily_totals = [], dict.fromkeys(releases, 0)
    for daily in value["daily_counts"]:
        fields = {"date", "package_id", "release_id", "count"}
        registry.exact_keys(daily, fields, fields, "daily V2 observations")
        date, package, release, count = (daily[key] for key in ("date", "package_id", "release_id", "count"))
        registry.require(isinstance(date, str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", date)
            and isinstance(package, str) and isinstance(release, str)
            and package in packages and release in releases and releases[release]["package_id"] == package
            and type(count) is int and 0 < count <= logs.MAX_EVENTS, "invalid daily V2 observation")
        stamp = clock._time(date + "T00:00:00Z")
        registry.require(end is not None and stamp <= clock._time(end) and stamp + clock.DAY > clock._time(end) - clock.WINDOW,
                         "daily observation is outside the reporting window")
        keys.append((date, package, release))
        daily_totals[release] += count
    registry.require(keys == sorted(set(keys)), "daily observations are duplicated or unordered")
    if end is not None:
        package_totals, retained_totals = dict.fromkeys(packages, 0), dict.fromkeys(packages, 0)
        for release in releases:
            registry.require(value["release_counts"][release] <= value["retained_release_counts"][release]
                and value["release_counts"][release] == daily_totals[release],
                "daily, rolling, and retained observations differ")
            package = releases[release]["package_id"]
            package_totals[package] += value["release_counts"][release]
            retained_totals[package] += value["retained_release_counts"][release]
        registry.require(value["counts"] == package_totals and value["retained_counts"] == retained_totals,
                         "package and release observation totals differ")
        registry.require(value["unattributed_requests"] <= value["retained_unattributed_requests"],
                         "unattributed rolling count exceeds its retained total")
    return value
