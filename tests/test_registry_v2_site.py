"""Private V2 website projections; fixtures establish no signature authority.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from copy import deepcopy
import hashlib
from pathlib import Path
import shlex
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry
import registry_distribution as distribution
import registry_log_import as logs
from registry_storage import LocalBlobStore

try:
    import registry_v2_site as site
except ImportError:
    site = None


class RegistryV2SiteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asm-v2-site-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.registry_id = "1" * 32
        self.package_id = "2" * 32
        self.release_id = "3" * 32
        self.mirrors = ("https://mirror.example/asm", "https://backup.example")
        self.object = b"synthetic source object"
        self.counter = 0

    def envelope(self, version="1.0.0", release_id=None):
        digest = hashlib.sha256(self.object).hexdigest()
        publication = {"schema": 2, "owner_id": "a" * 32, "name": "fixture/one", "version": version,
            "summary": "A synthetic website fixture.", "license": "MIT",
            "source": {"commit": {"algorithm": "git-sha256", "digest": "b" * 64}, "path": ".",
                "archive": {"sha256": digest, "bytes": len(self.object)}},
            "artifacts": [{"kind": "source", "format": "tar.gz", "isa": "x86_64", "os": "linux",
                "abi": "sysv-amd64", "cpu_features": [], "sha256": digest, "bytes": len(self.object)}]}
        return {"schema": 2, "registry_id": self.registry_id, "package_id": self.package_id,
            "release_id": release_id or self.release_id,
            "manifest_sha256": hashlib.sha256(registry.json_bytes(publication)).hexdigest(), "publication": publication}

    def stage(self, envelopes=None, *, flags=None, policy=None, mutable=True):
        self.counter += 1
        store = LocalBlobStore(self.root / f"public-{self.counter}")
        object_file = self.root / f"object-{self.counter}"
        object_file.write_bytes(self.object)
        digest = hashlib.sha256(self.object).hexdigest()
        store.put_blob(object_file, digest, len(self.object))
        envelopes = [self.envelope()] if envelopes is None else envelopes
        objects = {f"metadata/1.{role}.json": registry.json_bytes({"signed": {"_type": role, "version": 1}})
                   for role in ("root", "targets", "snapshot", "timestamp")}
        text = f"# asm-registry-policy-v2\t{self.registry_id}\t{len(envelopes)}\t0\n"
        for envelope in sorted(envelopes, key=lambda item: (item["publication"]["name"], item["publication"]["version"])):
            raw = registry.json_bytes(envelope)
            publication = envelope["publication"]
            sha = hashlib.sha256(raw).hexdigest()
            objects[f"targets/registries/{self.registry_id}/releases/{publication['name']}/{sha}.{publication['version']}.json"] = raw
            yanked, revoked = (flags or {}).get(envelope["release_id"], (0, 0))
            text += f"{publication['name']}\t{publication['version']}\t{envelope['package_id']}\t{envelope['release_id']}\t{yanked}\t{revoked}\n"
        raw = text.encode("ascii") if policy is None else policy
        objects[f"targets/registries/{self.registry_id}/{hashlib.sha256(raw).hexdigest()}.policy.tsv"] = raw
        files = []
        for key, data in sorted(objects.items()):
            store.create_object(key, data)
            files.append({"key": key, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
        plan = {"schema": 2, "registry_id": self.registry_id, "batch_id": "f" * 32, "version": "1",
            "publication_revision": str(len(envelopes)), "policy_revision": "0", "files": files,
            "blobs": [{"sha256": digest, "bytes": len(self.object)}]}
        distribution._store_plan(store, plan)
        store.compare_and_swap(distribution.HEAD_KEY, registry.json_bytes(distribution._head_for(plan)), None)
        if mutable:
            store.compare_and_swap("metadata/timestamp.json", objects["metadata/1.timestamp.json"], None)
        return store

    def catalog(self, store=None, **options):
        self.assertIsNotNone(site, "The private V2 site projection is absent.")
        return site.load_catalog(store or self.stage(), self.registry_id, self.mirrors, **options)

    def test_projection_preserves_v2_identity_and_emits_exact_selection_url_without_blob_reads(self):
        store = self.stage()
        with patch.object(store, "get_blob", side_effect=AssertionError("Metadata projection must not read blobs.")):
            catalog = self.catalog(store)
        self.assertEqual(catalog["schema"], 2)
        self.assertEqual(catalog["registry_id"], self.registry_id)
        self.assertEqual(catalog["projection"], {"version": "1", "publication_revision": "1", "policy_revision": "0"})
        package = catalog["packages"][0]
        self.assertEqual((package["name"], package["package_id"], package["latest"], package["targets"]),
                         ("fixture/one", self.package_id, "1.0.0", ["x86_64-linux"]))
        release = package["versions"][0]
        self.assertEqual(release["source"]["commit"], {"algorithm": "git-sha256", "digest": "b" * 64})
        self.assertNotIn("repository", release["source"])
        self.assertNotIn("published_at", release)
        self.assertEqual(release["evidence"], {"metadata": "validated", "artifacts": "not-run", "provenance": "not-run", "formal": "not-run", "agent_review": "not-run"})
        artifact = release["artifacts"][0]
        digest = hashlib.sha256(self.object).hexdigest()
        self.assertEqual(artifact["url"], "https://mirror.example/asm/blobs/sha256/" + digest + "?x-asm=" +
                         ".".join((self.registry_id, self.package_id, self.release_id, "x86_64-linux", "source")))
        self.assertEqual((artifact["format"], artifact["isa"], artifact["os"], artifact["abi"], artifact["cpu_features"]),
                         ("tar.gz", "x86_64", "linux", "sysv-amd64", []))

    def test_latest_uses_numeric_versions_and_excludes_yanked_and_revoked(self):
        old, newer, revoked = self.envelope("1.2.0"), self.envelope("1.10.0", "4" * 32), self.envelope("2.0.0", "5" * 32)
        newer["publication"]["artifacts"][0].update(isa="aarch64", abi="aapcs64")
        newer["manifest_sha256"] = hashlib.sha256(registry.json_bytes(newer["publication"])).hexdigest()
        store = self.stage([newer, revoked, old], flags={"5" * 32: (0, 1)})
        package = self.catalog(store)["packages"][0]
        self.assertEqual(package["latest"], "1.10.0")
        self.assertEqual(package["targets"], ["aarch64-linux"])
        self.assertEqual([item["version"] for item in package["versions"]], ["1.2.0", "1.10.0", "2.0.0"])
        all_blocked = self.catalog(self.stage([old], flags={self.release_id: (1, 0)}))["packages"][0]
        self.assertIsNone(all_blocked["latest"])
        self.assertEqual(all_blocked["targets"], [])

    def test_policy_rows_must_bind_exact_releases_and_distribution_revisions(self):
        good = f"# asm-registry-policy-v2\t{self.registry_id}\t1\t0\nfixture/one\t1.0.0\t{self.package_id}\t{self.release_id}\t0\t0\n"
        for text in (good.replace("\t1\t0\n", "\t2\t0\n", 1), good.replace(self.release_id, "0" * 32),
                     good + good.splitlines(True)[1], good.replace("\t0\t0\n", "\t2\t0\n"),
                     good.rstrip("\n"), good.splitlines(True)[0], good.replace("\nfixture/", "\vfixture/")):
            with self.subTest(policy=text), self.assertRaises(registry.RegistryError):
                self.catalog(self.stage(policy=text.encode("ascii")))

    def test_registry_identity_rebinding_and_incomplete_checkpoint_fail(self):
        self.assertIsNotNone(site)
        with self.assertRaises(registry.RegistryError):
            site.load_catalog(self.stage(), "9" * 32, self.mirrors)
        with self.assertRaises(registry.RegistryError):
            self.catalog(self.stage(mutable=False))
        wrong = self.envelope(); wrong["registry_id"] = "9" * 32
        with self.assertRaises(registry.RegistryError):
            self.catalog(self.stage([wrong]))
        duplicate = self.envelope("2.0.0")
        with self.assertRaises(registry.RegistryError):
            self.catalog(self.stage([self.envelope(), duplicate]))

    def test_policy_rejects_control_character_row_separators(self):
        other = "4" * 32
        policy = f"# asm-registry-policy-v2\t{self.registry_id}\t2\t0\nfixture/one\t1.0.0\t{self.package_id}\t{self.release_id}\t0\t0\vfixture/one\t2.0.0\t{self.package_id}\t{other}\t0\t0\n"
        with self.assertRaises(registry.RegistryError):
            self.catalog(self.stage([self.envelope(), self.envelope("2.0.0", other)], policy=policy.encode("ascii")))

    def test_mirror_urls_refuse_ambiguous_or_credentialed_bases(self):
        self.assertIsNotNone(site)
        for mirrors in ((), ("http://mirror.example",), ("https://user:secret@mirror.example",),
                        ("https://mirror.example?x=1",), ("https://mirror.example/a/../b",),
                        ("https://mirror.example/%61",), ("https://mirror.example/",), (["https://mirror.example"],),
                        (None,), self.mirrors * 2):
            with self.subTest(mirrors=mirrors), self.assertRaises(registry.RegistryError):
                site.load_catalog(self.stage(), self.registry_id, mirrors)

    def test_fetch_command_has_explicit_trust_all_mirrors_and_no_execution(self):
        catalog = self.catalog()
        package = catalog["packages"][0]; release = package["versions"][0]; artifact = release["artifacts"][0]
        self.assertEqual(shlex.split(site.fetch_command(catalog, package, release, artifact)), ["asm", "registry", "fetch",
            "fixture/one@1.0.0", "--registry-id", self.registry_id, "--root", "/private/asm-trust/root.json",
            "--state", "/private/asm-trust/client-state", "--mirror", "https://mirror.example/asm",
            "--mirror", "https://backup.example", "--target", "x86_64-linux", "--kind", "source",
            "--output", "/absolute/download/one-1.0.0-x86_64-linux.tar.gz"])
        release["yanked"] = True
        with self.assertRaises(registry.RegistryError):
            site.fetch_command(catalog, package, release, artifact)

    def test_real_archive_verification_is_required_before_checked_evidence(self):
        with self.assertRaises(registry.RegistryError):
            self.catalog(verify_artifacts=True)
        self.object = registry.make_archive({"asm.toml": (b'[package]\nname = "one"\nversion = "1.0.0"\n[build]\ntarget = "x86_64-linux"\nsource = "main.s"\n', 0o644),
            "main.s": (b".global _start\n_start:\n", 0o644), "README.md": (b"Synthetic fixture.\n", 0o644),
            "LICENSE": (b"Synthetic fixture license.\n", 0o644)})
        catalog = self.catalog(verify_artifacts=True)
        self.assertEqual(catalog["packages"][0]["versions"][0]["evidence"]["artifacts"], "validated")

    def dependency_envelope(self, *, declared="^1.0.0", source_requirement="^1.0.0", consumer_lock=False):
        project = b'[package]\nname = "one"\nversion = "1.0.0"\n[build]\ntarget = "x86_64-linux"\nsource = "main.s"\n'
        if source_requirement is not None:
            project += f'\n[dependencies]\n"fixture/leaf" = "{source_requirement}"\n'.encode()
        files = {"asm.toml": (project, 0o644),
            "main.s": (b".global _start\n_start:\n", 0o644), "README.md": (b"Synthetic fixture.\n", 0o644),
            "LICENSE": (b"Synthetic fixture license.\n", 0o644)}
        if consumer_lock:
            files["asm.lock"] = (b"# consumer-specific lock must not be published\n", 0o644)
        self.object = registry.make_archive(files)
        envelope = self.envelope()
        if declared is not None:
            envelope["publication"]["dependencies"] = [{"name": "fixture/leaf", "requirement": declared}]
        envelope["manifest_sha256"] = hashlib.sha256(registry.json_bytes(envelope["publication"])).hexdigest()
        return envelope

    def test_dependency_source_validation_preserves_the_signed_declaration_in_projection(self):
        envelope = self.dependency_envelope()
        store = self.stage([envelope])
        with patch.object(store, "get_blob", side_effect=AssertionError("Metadata projection must not read blobs.")):
            release = self.catalog(store)["packages"][0]["versions"][0]
        self.assertEqual(release["publication"]["dependencies"], [{"name": "fixture/leaf", "requirement": "^1.0.0"}])
        self.assertEqual(release["evidence"]["artifacts"], "not-run")
        try:
            checked = self.catalog(store, verify_artifacts=True)["packages"][0]["versions"][0]
        except registry.RegistryError as error:
            self.fail(f"A matching signed dependency source must validate: {error}")
        self.assertEqual(checked["publication"], envelope["publication"])
        self.assertEqual(checked["evidence"]["artifacts"], "validated")

    def test_checked_dependency_source_must_match_the_signed_declaration_exactly(self):
        for declared, source in (("^2.0.0", "^1.0.0"), (None, "^1.0.0"), ("^1.0.0", None)):
            with self.subTest(declared=declared, source=source):
                envelope = self.dependency_envelope(declared=declared, source_requirement=source)
                with self.assertRaises(registry.RegistryError):
                    self.catalog(self.stage([envelope]), verify_artifacts=True)

    def test_checked_features_bind_all_source_options_and_preserve_signed_metadata(self):
        project = b'[package]\nname = "one"\nversion = "1.0.0"\n[build]\ntarget = "x86_64-linux"\nsource = "main.s"\n'
        project += b'\n[dependencies]\n"fixture/leaf" = { version = "*", optional = true, default-features = false, features = ["portable"] }\n[features]\ndefault = ["bundle"]\nbundle = ["dep:fixture/leaf"]\n'
        self.object = registry.make_archive({"asm.toml": (project, 0o644), "main.s": (b"nop\n", 0o644),
            "README.md": (b"Synthetic fixture.\n", 0o644), "LICENSE": (b"Synthetic fixture license.\n", 0o644)})
        envelope = self.envelope()
        publication = envelope["publication"]
        publication["dependencies"] = [{"name": "fixture/leaf", "requirement": "*", "optional": True,
                                         "default_features": False, "features": ["portable"]}]
        publication["features"] = [{"name": "bundle", "members": ["dep:fixture/leaf"]},
                                   {"name": "default", "members": ["bundle"]}]
        envelope["manifest_sha256"] = hashlib.sha256(registry.json_bytes(publication)).hexdigest()
        store = self.stage([envelope])
        release = self.catalog(store, verify_artifacts=True)["packages"][0]["versions"][0]
        self.assertEqual(release["publication"], publication)
        for change in (lambda item: item["dependencies"][0].update(default_features=True),
                       lambda item: item["dependencies"][0].update(features=[]),
                       lambda item: item["features"][1].update(members=[])):
            altered = deepcopy(envelope)
            change(altered["publication"])
            altered["manifest_sha256"] = hashlib.sha256(registry.json_bytes(altered["publication"])).hexdigest()
            with self.assertRaises(registry.RegistryError):
                self.catalog(self.stage([altered]), verify_artifacts=True)

    def test_checked_source_archive_cannot_contain_a_consumer_lock(self):
        envelope = self.dependency_envelope(consumer_lock=True)
        store = self.stage([envelope])
        # Metadata alone cannot establish which archive members exist.
        self.assertEqual(self.catalog(store)["packages"][0]["versions"][0]["evidence"]["artifacts"], "not-run")
        with self.assertRaisesRegex(registry.RegistryError, "consumer lock"):
            self.catalog(store, verify_artifacts=True)

    def test_unknown_observations_remain_null_and_real_empty_report_is_zero(self):
        store = self.stage(); catalog = self.catalog(store)
        self.assertIsNotNone(site)
        absent = site.observations(catalog, None)
        self.assertEqual(absent["counts"], {self.package_id: None})
        self.assertEqual(absent["release_counts"], {self.release_id: None})
        self.assertIsNone(absent["coverage_end"])
        ledger = logs.LogStore.from_distribution(self.root / "stats/events.sqlite3", store, self.registry_id)
        empty = self.root / "empty.jsonl"; empty.write_bytes(b"")
        ledger.import_batch("asm-origin", "first", "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z", empty)
        result = site.observations(catalog, ledger.snapshot(at="2026-01-02T00:00:00Z"))
        self.assertEqual(result["counts"], {self.package_id: 0})
        self.assertEqual(result["release_counts"], {self.release_id: 0})
        self.assertFalse(result["complete"])

    def test_observations_refuse_foreign_counts_and_false_zero_or_exactness(self):
        catalog = self.catalog(); self.assertIsNotNone(site)
        unknown = site.observations(catalog, None)
        variants = []
        for key, value in (("registry_id", "9" * 32), ("counts", {self.package_id: 0}),
                           ("complete", True), ("sources", ["private?token=value"]), ("sources", [[]])):
            variant = deepcopy(unknown); variant[key] = value; variants.append(variant)
        variant = deepcopy(unknown); variant["releases"][self.release_id]["name"] = "other/name"; variants.append(variant)
        for value in variants:
            with self.subTest(value=value), self.assertRaises(registry.RegistryError):
                site.observations(catalog, value)

    def test_completed_observations_keep_scopes_and_reject_false_totals_or_daily_bindings(self):
        store = self.stage(); catalog = self.catalog(store)
        self.assertIsNotNone(site)
        ledger = logs.LogStore.from_distribution(self.root / "stats/events.sqlite3", store, self.registry_id)
        event = {"time": "2026-01-02T12:00:00Z", "request_id": "one", "method": "GET",
            "uri": "/downloads/v2/" + "/".join((self.registry_id, self.package_id, self.release_id, "x86_64-linux", "source", hashlib.sha256(self.object).hexdigest())),
            "status": 200, "bytes": len(self.object), "complete": "OK", "traffic": "public"}
        path = self.root / "events.jsonl"; path.write_bytes(registry.json_bytes(event).replace(b"\n", b"") + b"\n")
        ledger.import_batch("asm-origin", "first", "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z", path)
        snapshot = ledger.snapshot(at="2026-01-03T00:00:00Z")
        self.assertEqual(site.observations(catalog, snapshot)["daily_counts"],
            [{"date": "2026-01-02", "package_id": self.package_id, "release_id": self.release_id, "count": 1}])
        variants = []
        value = deepcopy(snapshot); value["counts"][self.package_id] = 2; variants.append(value)
        value = deepcopy(snapshot); value["retained_release_counts"][self.release_id] = 0; variants.append(value)
        value = deepcopy(snapshot); value["daily_counts"][0]["package_id"] = "8" * 32; variants.append(value)
        value = deepcopy(snapshot); value["daily_counts"][0]["package_id"] = []; variants.append(value)
        value = deepcopy(snapshot); value["daily_counts"][0]["count"] = 2; variants.append(value)
        value = deepcopy(snapshot); value["daily_counts"].append(deepcopy(value["daily_counts"][0])); variants.append(value)
        value = deepcopy(snapshot); value["daily_counts"][0]["date"] = "2025-01-01"; variants.append(value)
        value = deepcopy(snapshot); value["stale"] = True; variants.append(value)
        for value in variants:
            with self.subTest(value=value), self.assertRaises(registry.RegistryError):
                site.observations(catalog, value)

    def test_changed_envelope_or_advancing_head_cannot_become_a_mixed_catalog(self):
        store = self.stage()
        envelope = next((store.root / item["key"]) for item in distribution.load_current(store)[1]["files"] if "/releases/" in item["key"])
        envelope.write_bytes(envelope.read_bytes().replace(b"synthetic", b"changed!!"))
        with self.assertRaises(registry.RegistryError):
            self.catalog(store)
        store = self.stage()
        original = store.read_object
        def changed(key, limit):
            result = original(key, limit)
            if key.endswith(".policy.tsv"):
                current = original(distribution.HEAD_KEY, 4096)
                head = registry.strict_json(current[0]); head["batch_id"] = "9" * 32
                store.compare_and_swap(distribution.HEAD_KEY, registry.json_bytes(head), current[1])
            return result
        with patch.object(store, "read_object", side_effect=changed), self.assertRaises(registry.RegistryError):
            self.catalog(store)


if __name__ == "__main__":
    unittest.main()
