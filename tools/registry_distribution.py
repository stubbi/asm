"""Private signed-distribution operations; application policy remains assembly.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import os
from pathlib import Path
import re
import sys
import tempfile
import time
from urllib.parse import urlsplit

import publication_check
import publisher_admin
import registry
import registry_admin as admin
import registry_mirror
from registry_storage import MAX_OBJECT_BYTES, StorageConflict, _directory

HEAD_KEY = "distribution/head.json"
MAX_FILES = 8196
MAX_BLOBS = 61440
HEX32 = re.compile(r"[0-9a-f]{32}")


def _identity(value):
    registry.require(isinstance(value, str) and HEX32.fullmatch(value), "invalid distribution identity")
    return value


def _revision(value, *, positive=False):
    registry.require(isinstance(value, str) and re.fullmatch(r"0|[1-9][0-9]{0,18}", value)
                     and int(value) < 2**63 and (not positive or int(value) > 0), "invalid distribution revision")
    return int(value)


def _digest(value):
    registry.require(isinstance(value, str) and registry.HEX64.fullmatch(value), "invalid distribution digest")
    return value


def _checked(data, item):
    registry.require(isinstance(data, bytes) and len(data) == item["bytes"]
                     and hashlib.sha256(data).hexdigest() == item["sha256"], "distribution object differs from its binding")
    return data


def validate_plan(plan):
    fields = {"schema", "registry_id", "batch_id", "version", "publication_revision", "policy_revision", "files", "blobs"}
    registry.exact_keys(plan, fields, fields, "distribution plan")
    registry.require(type(plan["schema"]) is int and plan["schema"] == 2, "unsupported distribution plan")
    _identity(plan["registry_id"]); _identity(plan["batch_id"])
    version = _revision(plan["version"], positive=True)
    _revision(plan["publication_revision"]); _revision(plan["policy_revision"])
    registry.require(isinstance(plan["files"], list) and 3 <= len(plan["files"]) <= MAX_FILES
                     and isinstance(plan["blobs"], list) and len(plan["blobs"]) <= MAX_BLOBS, "distribution inventory exceeds its limit")
    keys, digests, online = [], [], {}
    for item in plan["files"]:
        registry.exact_keys(item, {"key", "sha256", "bytes"}, {"key", "sha256", "bytes"}, "distribution file")
        key = item["key"]
        registry.require(isinstance(key, str) and len(key) <= 640, "invalid distribution file key")
        metadata = re.fullmatch(r"metadata/([1-9][0-9]{0,18})\.(root|targets|snapshot|timestamp)\.json", key)
        target = re.fullmatch(r"targets/registries/" + plan["registry_id"] +
            r"/(?:[0-9a-f]{64}\.policy\.tsv|releases/[a-z][a-z0-9-]{0,38}/[a-z][a-z0-9-]{0,63}/[0-9a-f]{64}\.[0-9]+\.[0-9]+\.[0-9]+\.json)", key)
        registry.require(metadata is not None or target is not None, "invalid distribution file namespace")
        if metadata is not None:
            role, selected_version = metadata[2], int(metadata[1])
            registry.require(selected_version < 2**63 and (role == "root" or selected_version <= version),
                             "distribution metadata version differs")
            if role != "root":
                registry.require(role not in online, "distribution contains multiple current online roles")
                online[role] = selected_version
        _digest(item["sha256"])
        registry.require(type(item["bytes"]) is int and 0 < item["bytes"] <=
            (16384 if metadata is not None and metadata[2] == "timestamp" else 1048576), "distribution file exceeds its byte limit")
        if target:
            registry.require(key.rsplit("/", 1)[-1].startswith(item["sha256"] + "."), "consistent target path differs from its digest")
        keys.append(key)
    registry.require(keys == sorted(set(keys)) and set(online) == {"targets", "snapshot", "timestamp"}
        and online["timestamp"] == version and online["targets"] == online["snapshot"],
        "distribution files are duplicated, unordered, or incomplete")
    total = 0
    for item in plan["blobs"]:
        registry.exact_keys(item, {"sha256", "bytes"}, {"sha256", "bytes"}, "distribution blob")
        _digest(item["sha256"])
        registry.require(type(item["bytes"]) is int and 0 < item["bytes"] <= registry.MAX_ARTIFACT_BYTES,
                         "distribution blob exceeds its byte limit")
        total += item["bytes"]
        digests.append(item["sha256"])
    registry.require(digests == sorted(set(digests)) and total <= 34359738368, "distribution blobs exceed their retained budget")
    registry.require(len(registry.json_bytes(plan)) <= MAX_OBJECT_BYTES, "distribution plan exceeds four MiB")
    return plan


def _read_bound(store, key, item):
    result = store.read_object(key, item["bytes"])
    registry.require(result is not None, "distribution object is unavailable")
    return _checked(result[0], item)


def _head_for(plan):
    timestamp = next(item for item in plan["files"] if item["key"] == f"metadata/{plan['version']}.timestamp.json")
    return {key: plan[key] for key in ("schema", "registry_id", "batch_id", "version", "publication_revision", "policy_revision")} | {
        "plan_sha256": hashlib.sha256(_plan_bytes(plan)).hexdigest(), "timestamp_sha256": timestamp["sha256"]}


def _inventory_bytes(plan):
    return registry.json_bytes({"schema": 2, "registry_id": plan["registry_id"], "blobs": plan["blobs"],
        "files": [item for item in plan["files"] if not item["key"].endswith(".timestamp.json")]})


def _plan_bytes(plan):
    return registry.json_bytes({key: plan[key] for key in ("schema", "registry_id", "batch_id", "version", "publication_revision", "policy_revision")} | {
        "inventory_sha256": hashlib.sha256(_inventory_bytes(plan)).hexdigest(),
        "timestamp": next(item for item in plan["files"] if item["key"].endswith(".timestamp.json"))})


def _store_plan(store, plan, *, previous=None):
    inventory, raw = _inventory_bytes(plan), _plan_bytes(plan)
    digest = hashlib.sha256(inventory).hexdigest()
    if previous is None or hashlib.sha256(_inventory_bytes(previous)).hexdigest() != digest:
        store.create_object("distribution/inventories/" + digest + ".json", inventory)
    store.create_object("distribution/plans/" + hashlib.sha256(raw).hexdigest() + ".json", raw)


def _load_plan(store, digest):
    _digest(digest)
    result = store.read_object("distribution/plans/" + digest + ".json", 4096)
    registry.require(result is not None and hashlib.sha256(result[0]).hexdigest() == digest, "distribution plan is unavailable or corrupt")
    compact = registry.strict_json(result[0])
    header = {"schema", "registry_id", "batch_id", "version", "publication_revision", "policy_revision"}
    fields = header | {"inventory_sha256", "timestamp"}
    registry.exact_keys(compact, fields, fields, "compact distribution plan")
    inventory_digest = _digest(compact["inventory_sha256"])
    retained = store.read_object("distribution/inventories/" + inventory_digest + ".json", MAX_OBJECT_BYTES)
    registry.require(retained is not None and hashlib.sha256(retained[0]).hexdigest() == inventory_digest, "distribution inventory is unavailable or corrupt")
    inventory = registry.strict_json(retained[0])
    fields = {"schema", "registry_id", "files", "blobs"}
    registry.exact_keys(inventory, fields, fields, "distribution inventory")
    registry.require(type(inventory["schema"]) is int and inventory["schema"] == 2
        and inventory["registry_id"] == compact["registry_id"] and isinstance(inventory["files"], list), "distribution inventory identity differs")
    plan = validate_plan({key: compact[key] for key in header} | {
        "files": sorted(inventory["files"] + [compact["timestamp"]], key=lambda item: item.get("key", "") if isinstance(item, dict) else ""),
        "blobs": inventory["blobs"]})
    registry.require(_plan_bytes(plan) == result[0] and _inventory_bytes(plan) == retained[0], "distribution inventory encoding differs")
    return plan


def load_current(store):
    """Read the byte-copy inventory. It grants no signing or package authority."""
    current = store.read_object(HEAD_KEY, 4096)
    if current is None:
        return None
    head = registry.strict_json(current[0])
    fields = {"schema", "registry_id", "batch_id", "version", "publication_revision", "policy_revision", "plan_sha256", "timestamp_sha256"}
    registry.exact_keys(head, fields, fields, "distribution head")
    digest = _digest(head["plan_sha256"])
    plan = _load_plan(store, digest)
    registry.require(_head_for(plan) == head
                     and registry.json_bytes(head) == current[0], "distribution head binding differs")
    return head, plan, current[1]


def _timestamp_version(raw):
    value = registry.strict_json(raw)
    registry.require(isinstance(value, dict) and isinstance(value.get("signed"), dict)
        and value["signed"].get("_type") == "timestamp" and type(value["signed"].get("version")) is int
        and 0 < value["signed"]["version"] < 2**63, "stored timestamp is malformed")
    return value["signed"]["version"]


def _place_blobs(blobs, source, destination, known, prepared, heartbeat, work_root):
    registry.require(len(blobs) <= MAX_BLOBS and sum(item["bytes"] for item in blobs) <= 34359738368,
                     "distribution blobs exceed their retained budget")
    if prepared is not None:
        registry.require(prepared["store"] is destination, "placement receipt belongs to another destination")
    for item in blobs:
        if heartbeat:
            heartbeat()
        previous = known.get(item["sha256"])
        if previous is not None:
            registry.require(previous == item, "retained artifact declaration changed")
            continue
        if prepared is not None and prepared["blobs"].get(item["sha256"]) == item:
            continue
        data = source.get_blob(item["sha256"], item["bytes"])
        with tempfile.TemporaryDirectory(prefix="asm-distribution-object-", dir=work_root) as directory:
            path = Path(directory) / "object"
            _write_private(path, data)
            destination.put_blob(path, item["sha256"], item["bytes"])
        if prepared is not None:
            prepared["blobs"][item["sha256"]] = item


def publish_plan(plan, source, destination, *, sealed=False, authorize=None, heartbeat=None, work_root=None, prepared=None):
    """Copy checked bytes, then conditionally expose the inventory and timestamp.

    The signer/SQL coordinator supplies authorization; a byte mirror does not.
    Existing immutable bindings avoid rereading every historical artifact.
    This is synchronization, not a retention audit. Failures preserve existing
    heads and can leave unreferenced immutable objects. Retry the same plan.
    """
    validate_plan(plan)
    if prepared is not None:
        registry.require(prepared["store"] is destination, "placement receipt belongs to another destination")
    new_head = _head_for(plan)
    current = load_current(destination)
    if current is not None:
        old, previous, token = current
        if old["registry_id"] != plan["registry_id"] or int(old["version"]) > int(plan["version"]) or any(
            int(old[key]) > int(plan[key]) for key in ("publication_revision", "policy_revision")):
            raise StorageConflict("distribution authority or revision changed; do not roll back")
        if old["version"] == plan["version"] and old != new_head:
            raise StorageConflict("a retained distribution version cannot change bytes")
    else:
        previous, token = {"files": [], "blobs": []}, None
    known_files = {item["key"]: item for item in previous["files"]}
    known_blobs = {item["sha256"]: item for item in previous["blobs"]}
    for item in plan["files"]:
        if heartbeat:
            heartbeat()
        if item["key"] in known_files:
            registry.require(known_files[item["key"]] == item, "immutable distribution metadata changed")
            continue
        if prepared is not None and prepared["files"].get(item["key"]) == item:
            continue
        key = "distribution/files/" + item["sha256"] if sealed else item["key"]
        destination.create_object(item["key"], _read_bound(source, key, item))
        if prepared is not None:
            prepared["files"][item["key"]] = item
    _place_blobs(plan["blobs"], source, destination, known_blobs, prepared, heartbeat, work_root)
    _store_plan(destination, plan, previous=previous if current is not None else None)
    if authorize:
        authorize()
    # The inventory advertises only an already complete immutable bundle.
    # TUF clients use the separate standard timestamp, advanced last. A mirror
    # can finish a bundle after the origin fails between these two writes.
    head_bytes = registry.json_bytes(new_head)
    if current is None or current[0] != new_head:
        destination.compare_and_swap(HEAD_KEY, head_bytes, token)
    observed = destination.read_object(HEAD_KEY, 4096)
    registry.require(observed is not None and observed[0] == head_bytes, "distribution head changed before timestamp advancement")
    timestamp_item = next(item for item in plan["files"] if item["key"] == f"metadata/{plan['version']}.timestamp.json")
    timestamp = _read_bound(destination, timestamp_item["key"], timestamp_item)
    registry.require(_timestamp_version(timestamp) == int(plan["version"]), "timestamp differs from reserved version")
    existing = destination.read_object("metadata/timestamp.json", 16384)
    if existing is None or existing[0] != timestamp:
        if existing is not None:
            version = _timestamp_version(existing[0])
            if version >= int(plan["version"]):
                raise StorageConflict("timestamp changed; do not replace newer metadata")
            retained = destination.read_object(f"metadata/{version}.timestamp.json", 16384)
            registry.require(retained is not None and retained[0] == existing[0], "current timestamp has no retained immutable binding")
        if authorize:
            authorize()
        destination.compare_and_swap("metadata/timestamp.json", timestamp, None if existing is None else existing[1])
    final_head = destination.read_object(HEAD_KEY, 4096)
    final_timestamp = destination.read_object("metadata/timestamp.json", 16384)
    registry.require(final_head is not None and final_head[0] == head_bytes
        and final_timestamp is not None and final_timestamp[0] == timestamp, "distribution completion is uncertain; inspect before replay")
    return new_head


def sync(source, destination, *, work_root=None):
    current = load_current(source)
    registry.require(current is not None, "source has no completed distribution inventory")
    return publish_plan(current[1], source, destination, work_root=work_root)


def _write_private(path, data):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with _directory(path.parent, private=True) as parent:
        descriptor = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                             0o600, dir_fd=parent)
        try:
            registry.reject_extended_acl(descriptor)
            pending = memoryview(data)
            while pending:
                amount = os.write(descriptor, pending)
                registry.require(amount > 0, "private distribution write did not finish")
                pending = pending[amount:]
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def _read_private(path, limit):
    with _directory(Path(path).parent, private=True):
        descriptor, data = admin.open_checked(path, limit, private=True)
        os.close(descriptor)
        return data


def _call(connection, name, *arguments):
    registry.require(name in {"distribution_ready", "claim_distribution", "distribution_release", "seal_distribution", "renew_distribution",
        "authorize_distribution_head", "abandon_distribution", "finish_distribution"}, "invalid distribution database operation")
    encoded = []
    for value in arguments:
        if type(value) is bool:
            encoded.append("true" if value else "false")
        elif type(value) is int:
            registry.require(0 <= value < 2**63, "invalid distribution database integer")
            encoded.append(str(value))
        else:
            registry.require(isinstance(value, str) and len(value.encode("ascii")) <= MAX_OBJECT_BYTES,
                             "invalid distribution database text")
            encoded.append(admin.sql_text(value))
    raw = connection.execute("SELECT asm_publication." + name + "(" + ",".join(encoded) + ");").encode("ascii")
    registry.require(0 < len(raw) <= MAX_OBJECT_BYTES, "distribution database response exceeds its limit")
    if name == "distribution_release":
        # psql appends its one text-record terminator after the canonical LF.
        # Remove exactly that LF; declared length/hash reject any other change.
        return raw[:-1] if raw.endswith(b"\n\n") else raw
    return registry.strict_json(raw)


def _validate_lease(lease):
    fields = {"schema", "batch_id", "fence", "source_sha256", "source", "sealed"}
    registry.exact_keys(lease, fields, fields, "distribution lease")
    registry.require(type(lease["schema"]) is int and lease["schema"] == 2 and type(lease["fence"]) is int
                     and 0 < lease["fence"] < 2**63, "invalid distribution lease")
    _identity(lease["batch_id"]); _digest(lease["source_sha256"])
    source = lease["source"]
    fields = {"schema", "batch_id", "registry_id", "origin", "version", "publication_revision", "policy_revision", "policy_tsv", "releases"}
    registry.exact_keys(source, fields, fields, "distribution source")
    registry.require(type(source["schema"]) is int and source["schema"] == 2 and source["batch_id"] == lease["batch_id"]
        and hashlib.sha256(registry.json_bytes(source)).hexdigest() == lease["source_sha256"], "distribution source binding differs")
    _identity(source["registry_id"]); _revision(source["version"], positive=True)
    _revision(source["publication_revision"]); _revision(source["policy_revision"])
    registry.require(isinstance(source["releases"], list) and len(source["releases"]) <= 4095
        and isinstance(source["policy_tsv"], str) and 0 < len(source["policy_tsv"].encode("ascii")) <= 1048576,
        "distribution source exceeds its limit")
    names = []
    for release in source["releases"]:
        fields = {"name", "version", "package_id", "release_id", "target", "sha256", "bytes"}
        registry.exact_keys(release, fields, fields, "distribution release")
        registry.package_name(release["name"])
        registry.version_tuple(release["version"])
        _identity(release["package_id"]); _identity(release["release_id"]); _digest(release["sha256"])
        registry.require(type(release["bytes"]) is int and 0 < release["bytes"] <= 1048576
            and release["target"] == f"registries/{source['registry_id']}/releases/{release['name']}/{release['version']}.json",
            "distribution release identity differs")
        names.append((release["name"], release["version"]))
    registry.require(names == sorted(set(names)), "distribution releases are duplicated or unordered")
    return source


def _previous_bundle(public, directory, heartbeat, current):
    if current is None:
        return "-"
    plan = current[1]
    root_versions = []
    for item in plan["files"]:
        if not item["key"].startswith("metadata/"):
            continue
        heartbeat()
        raw = _read_bound(public, item["key"], item)
        _write_private(directory / item["key"], raw)
        role = item["key"].rsplit("/", 1)[-1].split(".", 1)[-1]
        if role == "root.json":
            root_versions.append((int(item["key"].split("/")[1].split(".")[0]), raw))
        else:
            _write_private(directory / "metadata" / role, raw)
    registry.require(root_versions, "previous distribution has no retained root")
    _write_private(directory / "metadata/root.json", max(root_versions, key=lambda item: item[0])[1])
    return str(directory)


def _descriptor(value, lease):
    fields = {"schema", "batch_id", "source_sha256", "plan_sha256", "bundle_sha256", "timestamp_sha256"}
    registry.exact_keys(value, fields, fields, "sealed distribution descriptor")
    registry.require(type(value["schema"]) is int and value["schema"] == 2 and value["batch_id"] == lease["batch_id"]
        and value["source_sha256"] == lease["source_sha256"], "sealed distribution identity differs")
    for field in ("source_sha256", "plan_sha256", "bundle_sha256", "timestamp_sha256"):
        _digest(value[field])
    return value


def _sealed_plan(retained, descriptor, lease):
    _descriptor(descriptor, lease)
    bundle = retained.read_object("distribution/bundles/" + descriptor["bundle_sha256"] + ".json", 4096)
    registry.require(bundle is not None and hashlib.sha256(bundle[0]).hexdigest() == descriptor["bundle_sha256"], "sealed bundle is missing or corrupt")
    expected = {key: descriptor[key] for key in ("schema", "batch_id", "source_sha256", "plan_sha256")}
    registry.require(bundle[0] == registry.json_bytes(expected), "sealed bundle binding differs")
    plan = _load_plan(retained, descriptor["plan_sha256"])
    registry.require(all(plan[key] == lease["source"][key] for key in
        ("schema", "registry_id", "batch_id", "version", "publication_revision", "policy_revision"))
        and _head_for(plan)["timestamp_sha256"] == descriptor["timestamp_sha256"], "sealed plan source differs")
    return plan


def _retain_bundle(retained, lease, plan):
    validate_plan(plan)
    raw_plan = _plan_bytes(plan)
    plan_digest = hashlib.sha256(raw_plan).hexdigest()
    _store_plan(retained, plan)
    bundle = {"schema": 2, "batch_id": lease["batch_id"], "source_sha256": lease["source_sha256"], "plan_sha256": plan_digest}
    raw_bundle = registry.json_bytes(bundle)
    bundle_digest = hashlib.sha256(raw_bundle).hexdigest()
    retained.create_object("distribution/bundles/" + bundle_digest + ".json", raw_bundle)
    return {**bundle, "bundle_sha256": bundle_digest, "timestamp_sha256": _head_for(plan)["timestamp_sha256"]}, plan


def prepare_bundle(connection, retained, public, lease, root_file, keys_dir, trust_executable, work_root, *, heartbeat, prepared):
    """Sign once, inspect through maintained TUF, then retain an immutable bundle.

    Package data cannot choose the executable, key directory, or trust root.
    Complete eligible payload placement before signing the short-lived timestamp.
    The exact descriptor is committed before public TUF roles or heads change.
    """
    source = _validate_lease(lease)
    with _directory(work_root, private=True), tempfile.TemporaryDirectory(prefix="asm-sign-", dir=work_root) as job:
        job = Path(job)
        current = load_current(public)
        previous = _previous_bundle(public, job / "previous", heartbeat, current)
        if current is not None and all(current[0][key] == source[key] for key in ("registry_id", "publication_revision", "policy_revision")):
            heartbeat()
            output = job / "renewed"
            result = admin.run_bounded([str(trust_executable), "refresh-registry", str(root_file), str(keys_dir), previous,
                str(output), source["registry_id"], source["version"]],
                environment=admin.clean_environment(), output_limit=4096, timeout=90)
            result = registry.strict_json(result)
            registry.exact_keys(result, {"status"}, {"status"}, "checkpoint renewal")
            registry.require(result["status"] in ("refreshed", "full-refresh-required"), "unexpected checkpoint renewal result")
            if result["status"] == "refreshed":
                timestamp = _read_private(output / "metadata/timestamp.json", 16384)
                item = {"key": f"metadata/{source['version']}.timestamp.json", "bytes": len(timestamp),
                        "sha256": hashlib.sha256(timestamp).hexdigest()}
                retained.create_object("distribution/files/" + item["sha256"], timestamp)
                files = sorted([item for item in current[1]["files"] if not item["key"].endswith(".timestamp.json")] + [item], key=lambda item: item["key"])
                plan = {key: source[key] for key in ("schema", "registry_id", "batch_id", "version", "publication_revision", "policy_revision")} | {
                    "files": files, "blobs": current[1]["blobs"]}
                return _retain_bundle(retained, lease, plan)
        mapping, blobs = {}, {}
        policy_name = "registries/" + source["registry_id"] + "/policy.tsv"
        policy = job / "inputs" / policy_name
        _write_private(policy, source["policy_tsv"].encode("ascii"))
        mapping[policy_name] = str(policy)
        for release in source["releases"]:
            heartbeat()
            cached = retained.read_object("distribution/files/" + release["sha256"], release["bytes"])
            raw = cached[0] if cached is not None else _call(connection, "distribution_release", lease["batch_id"], release["release_id"])
            _checked(raw, release)
            envelope = registry.strict_json(raw)
            fields = {"schema", "registry_id", "package_id", "release_id", "manifest_sha256", "publication"}
            registry.exact_keys(envelope, fields, fields, "signed release envelope")
            registry.require(type(envelope["schema"]) is int and envelope["schema"] == 2
                and envelope["registry_id"] == source["registry_id"] and all(envelope[key] == release[key] for key in ("package_id", "release_id"))
                and registry.json_bytes(envelope) == raw, "release envelope binding differs")
            manifest = registry.json_bytes(envelope["publication"])
            publication, objects = publication_check.manifest(manifest)
            registry.require(hashlib.sha256(manifest).hexdigest() == envelope["manifest_sha256"]
                and publication["name"] == release["name"] and publication["version"] == release["version"], "original manifest binding differs")
            for digest, size in objects.items():
                registry.require(digest not in blobs or blobs[digest] == size, "artifact length conflicts across releases")
                blobs[digest] = size
            filename = job / "inputs" / release["target"]
            _write_private(filename, raw)
            mapping[release["target"]] = str(filename)
        map_file = job / "targets.json"
        _write_private(map_file, registry.json_bytes(mapping))
        known_files = {} if current is None else {item["key"]: item for item in current[1]["files"]}
        known_blobs = {} if current is None else {item["sha256"]: item for item in current[1]["blobs"]}
        # Opaque immutable payloads have no installation authority by themselves.
        # Copy them before minting a five-minute checkpoint. Only committed
        # intent enters this path; staging and uncommitted uploads remain private.
        for target, filename in mapping.items():
            heartbeat()
            raw = _read_private(filename, 1048576)
            digest = hashlib.sha256(raw).hexdigest()
            directory, basename = target.rsplit("/", 1)
            key = "targets/" + directory + "/" + digest + "." + basename
            item = {"key": key, "sha256": digest, "bytes": len(raw)}
            if known_files.get(key) != item and prepared["files"].get(key) != item:
                public.create_object(key, raw)
                prepared["files"][key] = item
        object_list = [{"sha256": digest, "bytes": blobs[digest]} for digest in sorted(blobs)]
        _place_blobs(object_list, retained, public, known_blobs, prepared, heartbeat, work_root)
        output = job / "signed"
        heartbeat()
        admin.run_bounded([str(trust_executable), "publish-registry", str(root_file), str(keys_dir), previous,
            str(map_file), str(output), source["registry_id"], source["version"]],
            environment=admin.clean_environment(), output_limit=4096, timeout=90)
        admin.run_bounded([str(trust_executable), "inspect-registry", str(root_file), str(output), str(map_file), source["registry_id"]],
            environment=admin.clean_environment(), output_limit=4096, timeout=90)
        timestamp = _read_private(output / "metadata/timestamp.json", 16384)
        _write_private(output / ("metadata/" + source["version"] + ".timestamp.json"), timestamp)
        files = []
        for path in sorted(output.rglob("*")):
            registry.require(not path.is_symlink(), "signed bundle cannot contain links")
            if path.is_dir():
                continue
            key = path.relative_to(output).as_posix()
            if re.fullmatch(r"metadata/(root|timestamp|snapshot|targets)\.json", key):
                continue
            heartbeat()
            raw = _read_private(path, 1048576)
            digest = hashlib.sha256(raw).hexdigest()
            files.append({"key": key, "sha256": digest, "bytes": len(raw)})
            retained.create_object("distribution/files/" + digest, raw)
        plan = validate_plan({key: source[key] for key in ("schema", "registry_id", "batch_id", "version", "publication_revision", "policy_revision")} | {
            "files": files, "blobs": [{"sha256": digest, "bytes": blobs[digest]} for digest in sorted(blobs)]})
        return _retain_bundle(retained, lease, plan)


class CheckpointExpired(registry.RegistryError):
    """A sealed checkpoint needs a new reserved version, never replacement bytes."""


def _now():
    return datetime.now(timezone.utc)


def _ensure_checkpoint(retained, plan):
    item = next(item for item in plan["files"] if item["key"].endswith(".timestamp.json"))
    raw = _read_bound(retained, "distribution/files/" + item["sha256"], item)
    value = registry.strict_json(raw)
    registry.require(_timestamp_version(raw) == int(plan["version"]), "sealed checkpoint version differs")
    signed = value["signed"]
    registry.require(signed.get("asm_registry_id") == plan["registry_id"], "sealed checkpoint registry differs")
    times = []
    for key in ("asm_issued_at", "expires"):
        text = signed.get(key)
        registry.require(isinstance(text, str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", text),
                         "sealed checkpoint time is malformed")
        try:
            times.append(datetime.fromisoformat(text.replace("Z", "+00:00")))
        except ValueError:
            raise registry.RegistryError("sealed checkpoint time is invalid") from None
    issued, expiry = times
    now = _now()
    registry.require(expiry > issued and expiry <= issued + timedelta(minutes=5)
                     and issued <= now + timedelta(seconds=30), "sealed checkpoint lifetime or clock is invalid")
    # Retain a small write margin. A slow or failed write still requires the
    # same post-placement checks and cannot authorize an expired checkpoint.
    if now - issued > timedelta(minutes=5) or expiry <= now + timedelta(seconds=30):
        raise CheckpointExpired("sealed checkpoint expired or has insufficient write time")


def _abandon_checkpoint(connection, public, lease, worker_id):
    current = load_current(public)
    descriptor = _descriptor(lease["sealed"], lease)
    observed = "none"
    if current is not None:
        head = current[0]
        registry.require(head["registry_id"] == lease["source"]["registry_id"], "public registry identity differs during reconciliation")
        if int(head["version"]) > int(lease["source"]["version"]):
            raise StorageConflict("a newer public distribution requires reconciliation")
        registry.require(head["version"] != lease["source"]["version"] or head["plan_sha256"] == descriptor["plan_sha256"],
                         "the reserved public version has conflicting bytes")
        observed = head["version"] + "/" + head["plan_sha256"]
    timestamp = public.read_object("metadata/timestamp.json", 16384)
    stamp = "none"
    if timestamp is not None:
        if _timestamp_version(timestamp[0]) > int(lease["source"]["version"]):
            raise StorageConflict("a newer public timestamp requires reconciliation")
        stamp = hashlib.sha256(timestamp[0]).hexdigest()
    reference = "expired checkpoint; head=" + observed + "; timestamp=" + stamp
    result = _call(connection, "abandon_distribution", lease["batch_id"], worker_id, lease["fence"], lease["source_sha256"], reference)
    registry.require(isinstance(result, dict) and result.get("state") == "abandoned" and result.get("batch_id") == lease["batch_id"]
                     and result.get("version") == lease["source"]["version"], "checkpoint abandonment result differs")


def _run_batch(connection, retained, public, worker_id, root_file, keys_dir, trust_executable, work_root, lease, prepared):
    _validate_lease(lease)
    arguments = (lease["batch_id"], worker_id, lease["fence"], lease["source_sha256"])
    renewed = float("-inf")
    def heartbeat():
        nonlocal renewed
        if time.monotonic() - renewed < 20:
            return
        value = _call(connection, "renew_distribution", *arguments, 300)
        registry.require(value is not None, "distribution lease renewal was refused")
        _validate_lease(value)
        registry.require(value["batch_id"] == lease["batch_id"] and value["fence"] == lease["fence"]
            and value["source_sha256"] == lease["source_sha256"], "distribution lease changed")
        renewed = time.monotonic()
    heartbeat()
    descriptor = lease["sealed"]
    if descriptor is None:
        candidate_key = "distribution/candidates/" + lease["batch_id"] + ".json"
        candidate = retained.read_object(candidate_key, 4096)
        if candidate is not None:
            descriptor = registry.strict_json(candidate[0])
            plan = _sealed_plan(retained, descriptor, lease)
        else:
            descriptor, plan = prepare_bundle(connection, retained, public, lease, root_file, keys_dir,
                trust_executable, work_root, heartbeat=heartbeat, prepared=prepared)
            retained.create_object(candidate_key, registry.json_bytes(descriptor))
        value = _call(connection, "seal_distribution", *arguments, registry.json_bytes(descriptor).decode("ascii"))
        _validate_lease(value)
        registry.require(value["sealed"] == descriptor, "distribution seal result differs; inspect before replay")
    else:
        plan = _sealed_plan(retained, descriptor, lease)
    lease["sealed"] = descriptor
    _ensure_checkpoint(retained, plan)
    def authorize():
        _ensure_checkpoint(retained, plan)
        value = _call(connection, "authorize_distribution_head", *arguments)
        _validate_lease(value)
        registry.require(value["sealed"] == descriptor and value["source_sha256"] == lease["source_sha256"]
            and value["batch_id"] == lease["batch_id"] and value["fence"] == lease["fence"], "distribution authorization changed")
    publish_plan(plan, retained, public, sealed=True, authorize=authorize, heartbeat=heartbeat, work_root=work_root, prepared=prepared)
    _ensure_checkpoint(retained, plan)
    receipt = descriptor | {key: plan[key] for key in ("version", "publication_revision", "policy_revision")}
    return _call(connection, "finish_distribution", lease["batch_id"], worker_id, lease["fence"], registry.json_bytes(receipt).decode("ascii"))


def run_one(connection, retained, public, worker_id, root_file, keys_dir, trust_executable, work_root, *, refresh=False):
    """Complete one batch, permitting one fresh-version retry after expiry.

    Placement receipts live only in this invocation and bind the destination
    object instance. A new process verifies placement again. Immutable public
    payloads can precede signing; TUF roles and heads require the SQL seal.
    """
    _identity(worker_id)
    _separate_stores(retained, public)
    with _directory(work_root, private=True):
        pass
    ready = _call(connection, "distribution_ready", publisher_admin.DISTRIBUTION_MIGRATION_SHA384)
    registry.require(type(ready) is int and ready == 1, "the distributor identity or schema is not ready")
    prepared = {"store": public, "files": {}, "blobs": {}}
    for attempt in range(2):
        lease = _call(connection, "claim_distribution", worker_id, 300, refresh)
        if lease is None:
            return None
        try:
            return _run_batch(connection, retained, public, worker_id, root_file, keys_dir, trust_executable, work_root, lease, prepared)
        except CheckpointExpired:
            _abandon_checkpoint(connection, public, lease, worker_id)
            if attempt:
                raise registry.RegistryError("the storage deadline prevented a fresh checkpoint; inspect the retained attempts") from None


def verify(store):
    """Audit retained bytes against inventory; native TUF still supplies trust."""
    current = load_current(store)
    registry.require(current is not None, "store has no distribution inventory")
    head, plan, _ = current
    for item in plan["files"]:
        _read_bound(store, item["key"], item)
    for item in plan["blobs"]:
        store.get_blob(item["sha256"], item["bytes"])
    timestamp = store.read_object("metadata/timestamp.json", 16384)
    registry.require(timestamp is not None and hashlib.sha256(timestamp[0]).hexdigest() == head["timestamp_sha256"],
                     "mutable timestamp differs from the selected inventory")
    latest = load_current(store)
    registry.require(latest is not None and latest[0] == head, "distribution changed during its retention audit")
    return {"schema": 2, "registry_id": head["registry_id"], "version": head["version"],
            "files_checked": len(plan["files"]), "blobs_checked": len(plan["blobs"])}


def _contains_directory(ancestor, descendant):
    """Compare opened ancestry, including case aliases and mounted path aliases."""
    info = os.fstat(ancestor)
    identity = (info.st_dev, info.st_ino)
    current = os.dup(descendant)
    try:
        for _ in range(4096):
            info = os.fstat(current)
            selected = (info.st_dev, info.st_ino)
            if selected == identity:
                return True
            parent = os.open("..", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=current)
            info = os.fstat(parent)
            if (info.st_dev, info.st_ino) == selected:
                os.close(parent)
                return False
            os.close(current)
            current = parent
        raise registry.RegistryError("storage ancestry exceeds its bound")
    finally:
        os.close(current)


def _separate_stores(source, destination):
    if hasattr(source, "root") and hasattr(destination, "root"):
        with _directory(source.root, private=True) as first, _directory(destination.root, private=True) as second:
            registry.require(not _contains_directory(first, second) and not _contains_directory(second, first),
                             "source and destination storage directories must not overlap")
    elif hasattr(source, "bucket") and hasattr(destination, "bucket"):
        def endpoint(store):
            parsed = urlsplit(store.client.meta.endpoint_url)
            return parsed.scheme, parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80)
        same_bucket = source.bucket == destination.bucket and endpoint(source) == endpoint(destination)
        overlap = source.prefix.startswith(destination.prefix) or destination.prefix.startswith(source.prefix)
        registry.require(not (same_bucket and overlap), "source and destination S3 prefixes must not overlap")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    publication = commands.add_parser("publish", help="Complete one private signed distribution job")
    publication.add_argument("--connection-file", type=Path, required=True)
    publication.add_argument("--psql", required=True)
    publication.add_argument("--worker-id", required=True)
    publication.add_argument("--trust-root", type=Path, required=True)
    publication.add_argument("--keys-dir", type=Path, required=True)
    publication.add_argument("--trust-tool", type=Path, required=True)
    publication.add_argument("--refresh", action="store_true", help="Reserve a renewal when no release or policy changed")
    synchronization = commands.add_parser("sync", help="Synchronize a byte mirror without database or signing authority")
    audit = commands.add_parser("verify", help="Audit retained bytes without changing them")
    for command in (publication, synchronization, audit):
        registry_mirror._store_arguments(command)
    for command in (publication, synchronization):
        registry_mirror._store_arguments(command, "source-")
        command.add_argument("--work-root", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        destination = registry_mirror._store(args)
        if args.command == "verify":
            result = verify(destination)
        else:
            with _directory(args.work_root, private=True):
                pass
            source = registry_mirror._store(args, "source_")
            _separate_stores(source, destination)
            if args.command == "sync":
                result = sync(source, destination, work_root=args.work_root)
            else:
                _identity(args.worker_id)
                _read_private(args.trust_root, 1048576)
                with _directory(args.keys_dir, private=True):
                    pass
                registry.require(args.trust_tool.is_absolute() and args.trust_tool.is_file()
                    and os.access(args.trust_tool, os.X_OK), "select the reviewed absolute trust-tool executable")
                with admin.Connection(args.connection_file, args.psql, "asm_distributor") as connection:
                    result = run_one(connection, source, destination, args.worker_id, args.trust_root,
                        args.keys_dir, args.trust_tool, args.work_root, refresh=args.refresh)
        if result is not None:
            sys.stdout.buffer.write(registry.json_bytes(result))
        return 0
    except (registry.RegistryError, admin.AdminError, OSError, UnicodeError, TypeError, ValueError):
        print("Asm distribution: the operation failed or its result is unknown. Preserve the batch and inspect it before replay.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
