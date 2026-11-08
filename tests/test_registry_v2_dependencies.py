"""Observe complete dependency locks through the native signed V2 client.

SPDX-License-Identifier: AGPL-3.0-or-later
Copyright (c) 2026 ASM contributors
Python supplies signed metadata, HTTPS transport, and expected graph results.
All project parsing, resolution, locking, and materialization belong to Asm.
"""
from copy import deepcopy
import hashlib
import json
import subprocess
import unittest

from host import program
import test_registry_v2_cli as fixtures
from registry_graph_oracle import exhaustive_solutions


def canonical(value):
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()


class RegistryV2DependencyTests(unittest.TestCase):
    setUpClass = classmethod(fixtures.RegistryV2CliTests.setUpClass.__func__)
    tool = fixtures.RegistryV2DistributionTests.tool
    cli = fixtures.RegistryV2CliTests.cli
    sign = fixtures.RegistryV2DistributionTests.sign

    def setUp(self):
        fixtures.RegistryV2DistributionTests.setUp(self)
        self.project = self.work / "consumer with spaces"
        (self.project / "src").mkdir(parents=True)
        self.graph = []
        self.publication_number = 1
        self.root_requirements = {}
        self.write_project({"fixture/a": "*", "fixture/b": "1.0.0"})

    def write_project(self, roots, *, source=None):
        self.root_requirements = dict(roots)
        manifest = ('[package]\nname = "consumer"\nversion = "1.0.0"\n'
                    f'[target.{self.native_target}]\nsource = "src/main.s"\n')
        if roots:
            manifest += "\n[dependencies]\n" + "".join(
                f'"{name}" = "{requirement}"\n' for name, requirement in sorted(roots.items()))
        (self.project / "asm.toml").write_text(manifest)
        (self.project / "src/main.s").write_text(source or program(
            "mov x0, #0\nbl _exit" if self.native_target == "aarch64-macos" else
            "mov x0, #0\nmov x8, #93\nsvc #0" if self.native_target == "aarch64-linux" else
            "xor edi, edi\nmov eax, 60\nsyscall"))

    def package(self, name, version, dependencies=(), *, target=None, source=None, package_id=None):
        candidate = {"name": name, "version": version,
                     "dependencies": [{"name": other, "requirement": requirement} for other, requirement in sorted(dependencies)],
                     "target": target or self.native_target, "source": source}
        if package_id is not None:
            candidate["package_id"] = package_id
        return candidate

    def publish_graph(self, candidates=None, *, lifecycle=None, fresh=False):
        """Sign complete release envelopes; the HTTPS server serves opaque bytes."""
        if candidates is not None:
            self.graph = deepcopy(candidates)
        self.publication_number += 1
        number = self.publication_number
        directory = self.work / ("graph-input-" + str(number))
        directory.mkdir(mode=0o700)
        target_map, objects, envelopes = {}, {}, {}
        policy_rows = []
        tuples = {"x86_64-linux": ("x86_64", "linux", "sysv-amd64"),
                  "aarch64-linux": ("aarch64", "linux", "aapcs64"),
                  "aarch64-macos": ("aarch64", "macos", "apple-arm64")}
        from test_publish_cli import registry
        for candidate in sorted(self.graph, key=lambda value: (value["name"], value["version"])):
            name, version, target = candidate["name"], candidate["version"], candidate["target"]
            project = (f'[package]\nname = "{name.split("/")[-1]}"\nversion = "{version}"\n'
                       f'[target.{target}]\nsource = "src/main.s"\n')
            archive_dependencies = candidate.get("archive_dependencies", candidate["dependencies"])
            if archive_dependencies:
                project += "\n[dependencies]\n" + "".join(
                    f'"{edge["name"]}" = "{edge["requirement"]}"\n' for edge in archive_dependencies)
            files = {"asm.toml": (project.encode(), 0o644), "LICENSE": (b"Synthetic MIT fixture.\n", 0o644),
                     "README.md": (b"Synthetic dependency graph.\n", 0o644),
                     "src/main.s": ((candidate["source"] or ".text\n").encode(), 0o644)}
            archive = registry.make_archive(files)
            digest = hashlib.sha256(archive).hexdigest()
            objects[digest] = archive
            isa, system, abi = tuples[target]
            publication = {"schema": 2, "owner_id": "1" * 32, "name": name, "version": version,
                "summary": "Synthetic dependency graph fixture.", "license": "MIT",
                "source": {"archive": {"sha256": digest, "bytes": len(archive)},
                           "commit": {"algorithm": "git-sha1", "digest": "a" * 40}, "path": "."},
                "artifacts": [{"isa": isa, "os": system, "abi": abi, "cpu_features": [], "kind": "source",
                               "format": "tar.gz", "sha256": digest, "bytes": len(archive)}]}
            if candidate["dependencies"]:
                publication["dependencies"] = candidate["dependencies"]
            package_id = candidate.get("package_id", hashlib.sha256(name.encode()).hexdigest()[:32])
            release_id = hashlib.sha256((name + "@" + version).encode()).hexdigest()[:32]
            envelope = {"schema": 2, "registry_id": self.registry_id, "package_id": package_id,
                        "release_id": release_id, "manifest_sha256": hashlib.sha256(canonical(publication)).hexdigest(),
                        "publication": publication}
            record = directory / (release_id + ".json")
            record.write_bytes(canonical(envelope))
            path = f"registries/{self.registry_id}/releases/{name}/{version}.json"
            target_map[path] = str(record)
            envelopes[(name, version)] = {"path": path, "record": record, "sha256": hashlib.sha256(record.read_bytes()).hexdigest(),
                                        "package_id": package_id, "release_id": release_id, "archive_sha256": digest,
                                        "manifest_sha256": envelope["manifest_sha256"], "source_bytes": len(archive)}
            yanked, revoked = (lifecycle or {}).get((name, version), (0, 0))
            policy_rows.append(f"{name}\t{version}\t{package_id}\t{release_id}\t{yanked}\t{revoked}\n")
        policy = directory / "policy.tsv"
        policy.write_text(f"# asm-registry-policy-v2\t{self.registry_id}\t{number}\t0\n" + "".join(policy_rows))
        target_map[f"registries/{self.registry_id}/policy.tsv"] = str(policy)
        mapping = directory / "map.json"
        mapping.write_bytes(canonical(target_map))
        previous = "-" if fresh else self.delivery
        output = self.work / ("graph-delivery-" + str(number))
        self.tool(self.trust, "publish-registry", self.anchor, self.keys, previous, mapping,
                  output, self.registry_id, number)
        self.delivery = output
        blobs = output / "blobs/sha256"
        blobs.mkdir(parents=True)
        for digest, data in objects.items():
            (blobs / digest).write_bytes(data)
        self.envelopes = envelopes
        self.objects_by_digest = objects
        return output

    def diamond(self):
        return [self.package("fixture/a", "1.0.0", [("fixture/c", "^1.0.0")]),
                self.package("fixture/a", "2.0.0", [("fixture/c", "^2.0.0")]),
                self.package("fixture/b", "1.0.0", [("fixture/c", "^1.0.0")]),
                self.package("fixture/c", "1.0.0"), self.package("fixture/c", "2.0.0")]

    def graph_cli(self, command, *, code=0, mirrors=None, target=None):
        arguments = [command, "--project", self.project, "--registry-id", self.registry_id,
                     "--root", self.anchor, "--state", self.state,
                     "--target", target or self.native_target, "--ca", self.ca, "--json"]
        for mirror in mirrors or [self.api]:
            arguments.extend(("--mirror", mirror))
        result = self.cli(*arguments, code=code)
        if code:
            self.assertEqual(result.stdout, b"")
        return result

    def assert_no_blob_reads(self):
        self.assertFalse(any(path.startswith("/blobs/") for _, path in self.requests))

    def expected_lock(self, selection):
        """Encode the public lock contract from an explicit hand-selected graph."""
        lines = ["# asm-lock-v3\n",
                 "\t".join(("registry", self.registry_id, hashlib.sha256(self.anchor.read_bytes()).hexdigest(),
                             self.native_target, hashlib.sha256((self.project / "asm.toml").read_bytes()).hexdigest())) + "\n"]
        lines.extend(f"root\t{name}\t{requirement}\n" for name, requirement in sorted(self.root_requirements.items()))
        edges = []
        for name, version in sorted(selection):
            envelope = self.envelopes[(name, version)]
            lines.append("\t".join(("node", name, version, envelope["package_id"], envelope["release_id"],
                envelope["sha256"], envelope["manifest_sha256"], "a" * 40,
                str(envelope["source_bytes"]), envelope["archive_sha256"])) + "\n")
            candidate = next(item for item in self.graph if (item["name"], item["version"]) == (name, version))
            edges.extend((name, edge["name"], edge["requirement"]) for edge in candidate["dependencies"])
        lines.extend("edge\t" + "\t".join(edge) + "\n" for edge in sorted(edges))
        return "".join(lines).encode()

    def selected_diamond(self):
        return {("fixture/a", "1.0.0"), ("fixture/b", "1.0.0"), ("fixture/c", "1.0.0")}

    def package_cache(self, name, version="1.0.0"):
        return self.project / ".asm/packages" / name / version / self.native_target

    def native_cli(self, *arguments, code=0):
        result = subprocess.run([str(self.binary), *map(str, arguments)], cwd=self.project,
                                env=self.environment, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, code, (result.stdout, result.stderr))
        return result

    def test_diamond_backtracks_and_resolve_downloads_only_metadata(self):
        self.publish_graph(self.diamond(), fresh=True)
        result = self.graph_cli("resolve")
        self.assertEqual(json.loads(result.stdout), {"ok": True, "packages": 3, "resolved": True})
        lock = (self.project / "asm.lock").read_bytes()
        self.assertEqual(lock, self.expected_lock(self.selected_diamond()))
        self.assert_no_blob_reads()
        self.assertFalse((self.project / ".asm/packages").exists())
        # Compare existence independently; this graph has one hand-derived solution.
        candidates = [{key: value for key, value in candidate.items() if key in ("name", "version", "dependencies")}
                      for candidate in self.graph]
        roots = [{"name": name, "requirement": requirement} for name, requirement in self.root_requirements.items()]
        self.assertEqual(exhaustive_solutions(candidates, roots),
                         [frozenset({("fixture/a", "1.0.0"), ("fixture/b", "1.0.0"), ("fixture/c", "1.0.0")})])

    def test_deterministic_repeat_keeps_complete_lock_bytes(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve")
        before = (self.project / "asm.lock").read_bytes()
        self.graph_cli("resolve")
        self.assertEqual((self.project / "asm.lock").read_bytes(), before)
        self.assert_no_blob_reads()

    def test_resolve_refuses_changed_bytes_for_an_already_locked_release(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve")
        original = (self.project / "asm.lock").read_bytes()
        changed = deepcopy(self.graph)
        changed[0]["source"] = ".text\n# changed bytes for the same published version\n"
        # A malicious new signed view bypasses the private signer's normal
        # retained-release check. The client must retain its own binding.
        self.publish_graph(changed, fresh=True)
        self.requests.clear()
        result = self.graph_cli("resolve", code=1)
        self.assertRegex(result.stderr.lower(), b"changed|lock")
        self.assertEqual((self.project / "asm.lock").read_bytes(), original)
        self.assert_no_blob_reads()

    def test_resolve_refuses_a_locked_name_rebound_to_another_package_identity(self):
        self.write_project({"fixture/a": "1.0.0"})
        self.publish_graph([self.package("fixture/a", "1.0.0")], fresh=True)
        self.graph_cli("resolve")
        original = (self.project / "asm.lock").read_bytes()
        self.write_project({"fixture/a": "*"})
        # The new signed policy and envelope agree with each other, but they
        # disagree with the immutable identity already retained in the lock.
        self.publish_graph([self.package("fixture/a", "2.0.0", package_id="f" * 32)], fresh=True)
        self.requests.clear()
        result = self.graph_cli("resolve", code=1)
        self.assertRegex(result.stderr.lower(), b"changed|lock")
        self.assertEqual((self.project / "asm.lock").read_bytes(), original)
        self.assert_no_blob_reads()

    def test_initial_inventory_refuses_different_identities_for_versions_of_one_name(self):
        self.write_project({"fixture/a": "*"})
        candidates = [self.package("fixture/a", "1.0.0"),
                      self.package("fixture/a", "2.0.0", package_id="f" * 32)]
        for yanked in (0, 1):
            with self.subTest(old_version_yanked=yanked):
                self.publish_graph(candidates, lifecycle={("fixture/a", "1.0.0"): (yanked, 0)}, fresh=True)
                self.requests.clear()
                result = self.graph_cli("resolve", code=1)
                self.assertIn(b"metadata", result.stderr.lower())
                self.assertFalse((self.project / "asm.lock").exists())
                self.assert_no_blob_reads()

    def test_explicit_resolve_can_select_a_new_version_with_the_same_package_identity(self):
        self.write_project({"fixture/a": "*"})
        self.publish_graph([self.package("fixture/a", "1.0.0")], fresh=True)
        self.graph_cli("resolve")
        original = (self.project / "asm.lock").read_bytes()
        self.publish_graph(self.graph + [self.package("fixture/a", "2.0.0")])
        self.requests.clear()
        self.graph_cli("resolve")
        current = (self.project / "asm.lock").read_bytes()
        self.assertNotEqual(current, original)
        self.assertEqual(current, self.expected_lock({("fixture/a", "2.0.0")}))
        self.assert_no_blob_reads()

    def test_unsatisfiable_diamond_preserves_existing_lock(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve")
        before = (self.project / "asm.lock").read_bytes()
        self.write_project({"fixture/a": "2.0.0", "fixture/b": "1.0.0"})
        result = self.graph_cli("resolve", code=1)
        self.assertIn(b"no compatible dependency graph", result.stderr.lower())
        self.assertEqual((self.project / "asm.lock").read_bytes(), before)
        self.assert_no_blob_reads()

    def test_cycle_locks_each_package_once_with_both_edges(self):
        self.write_project({"fixture/a": "1.0.0"})
        self.publish_graph([self.package("fixture/a", "1.0.0", [("fixture/b", "1.0.0")]),
                            self.package("fixture/b", "1.0.0", [("fixture/a", "1.0.0")])], fresh=True)
        self.graph_cli("resolve")
        self.assertEqual((self.project / "asm.lock").read_bytes(), self.expected_lock({("fixture/a", "1.0.0"), ("fixture/b", "1.0.0")}))
        self.assert_no_blob_reads()

    def test_sync_materializes_exact_graph_without_selecting_new_release(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve")
        lock = self.project / "asm.lock"
        before = lock.read_bytes()
        self.publish_graph(self.graph + [self.package("fixture/c", "1.1.0")])
        self.requests.clear()
        result = self.graph_cli("sync")
        self.assertEqual(json.loads(result.stdout), {"ok": True, "packages": 3, "synchronized": True})
        self.assertEqual(lock.read_bytes(), before)
        for name in ("fixture/a", "fixture/b", "fixture/c"):
            self.assertTrue((self.package_cache(name) / "asm.toml").is_file())
        self.assertFalse(self.package_cache("fixture/c", "1.1.0").exists())
        self.assertFalse(any("/fixture/c/" in path and path.endswith("1.1.0.json") for _, path in self.requests))
        self.assertFalse((self.project / "build").exists(), "Synchronization built or executed package code")
        self.requests.clear()
        self.graph_cli("sync")
        self.assertEqual(lock.read_bytes(), before)
        self.assert_no_blob_reads()

    def test_transitive_source_build_and_explicit_execution_use_complete_lock(self):
        is_arm = self.native_target.startswith("aarch64-")
        function = (".text\n.global asm_answer\nasm_answer:\nmov x0, #42\nret\n" if is_arm else
                    ".intel_syntax noprefix\n.text\n.global asm_answer\nasm_answer:\nmov eax, 42\nret\n")
        candidates = [self.package("fixture/a", "1.0.0", [("fixture/c", "1.0.0")],
                                   source=f'.include "fixture/c/1.0.0/{self.native_target}/src/main.s"\n'),
                      self.package("fixture/b", "1.0.0", [("fixture/c", "1.0.0")]),
                      self.package("fixture/c", "1.0.0", source=function)]
        if is_arm:
            exit_code = "bl _exit" if self.native_target.endswith("-macos") else "mov x8, #93\nsvc #0"
            body = f"bl asm_answer\ncmp x0, #42\nb.ne failed\nmov x0, #0\n{exit_code}\nfailed:\nmov x0, #7\n{exit_code}"
        else:
            body = "call asm_answer\ncmp eax, 42\njne failed\nxor edi, edi\nmov eax, 60\nsyscall\nfailed:\nmov edi, 7\nmov eax, 60\nsyscall"
        source = f'.include "fixture/a/1.0.0/{self.native_target}/src/main.s"\n' + program(body)
        self.write_project({"fixture/a": "1.0.0", "fixture/b": "1.0.0"}, source=source)
        self.publish_graph(candidates, fresh=True)
        self.graph_cli("resolve")
        self.graph_cli("sync")
        self.assertFalse((self.project / "build").exists())
        self.native_cli("build", "--locked")
        executable = self.project / "build/app"
        self.assertTrue(executable.is_file())
        result = subprocess.run([str(executable)], capture_output=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
        before = executable.read_bytes()
        cached = self.package_cache("fixture/c") / "src/main.s"
        cached.write_text(cached.read_text() + "\n# changed transitive dependency\n")
        self.native_cli("build", "--locked", code=1)
        self.assertEqual(executable.read_bytes(), before)

    def test_stale_root_manifest_refuses_sync_before_artifact_download(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve")
        before = (self.project / "asm.lock").read_bytes()
        self.write_project({"fixture/a": "1.0.0", "fixture/b": "1.0.0"})
        self.requests.clear()
        result = self.graph_cli("sync", code=1)
        self.assertIn(b"lock", result.stderr.lower())
        self.assertEqual((self.project / "asm.lock").read_bytes(), before)
        self.assert_no_blob_reads()

    def test_signed_dependencies_must_match_the_source_archive_before_extraction(self):
        candidates = self.diamond()
        candidates[0]["archive_dependencies"] = [{"name": "fixture/c", "requirement": "^2.0.0"}]
        self.publish_graph(candidates, fresh=True)
        self.graph_cli("resolve")
        original = (self.project / "asm.lock").read_bytes()
        self.graph_cli("sync", code=1)
        self.assertEqual((self.project / "asm.lock").read_bytes(), original)
        self.assertFalse(self.package_cache("fixture/a").exists())
        self.assertFalse((self.project / "build").exists())

    def test_modified_managed_source_is_preserved_when_sync_refuses_it(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve")
        self.graph_cli("sync")
        original = (self.project / "asm.lock").read_bytes()
        source = self.package_cache("fixture/c") / "src/main.s"
        changed = source.read_bytes() + b"\n# locally modified managed source\n"
        source.write_bytes(changed)
        self.graph_cli("sync", code=1)
        self.assertEqual(source.read_bytes(), changed)
        self.assertEqual((self.project / "asm.lock").read_bytes(), original)

    def test_corrupt_artifact_preserves_lock_and_refuses_cache_exposure(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve")
        before = (self.project / "asm.lock").read_bytes()
        self.corrupt_blob = True
        self.graph_cli("sync", code=1)
        self.assertEqual((self.project / "asm.lock").read_bytes(), before)
        self.assertFalse(self.package_cache("fixture/a").exists())
        self.assertFalse((self.project / "build").exists())

    def test_removed_or_changed_graph_records_refuse_sync_without_rewriting_input(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve")
        lock = self.project / "asm.lock"
        original = lock.read_bytes()
        variants = [b"\n".join(line for line in original.split(b"\n") if not line.startswith(b"edge\tfixture/a\t")),
                    original.replace(b"node\tfixture/c\t1.0.0", b"node\tfixture/c\t2.0.0"),
                    original.replace(b"root\tfixture/a\t*", b"root\tfixture/a\t1.0.0")]
        for data in variants:
            with self.subTest(lock=data):
                lock.write_bytes(data)
                self.requests.clear()
                self.graph_cli("sync", code=1)
                self.assertEqual(lock.read_bytes(), data)
                self.assert_no_blob_reads()

    def test_network_failure_preserves_previous_lock_and_reports_metadata_failure(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve")
        lock = self.project / "asm.lock"
        original = lock.read_bytes()
        result = self.graph_cli("resolve", mirrors=["https://127.0.0.1:1"], code=1)
        self.assertIn(b"metadata", result.stderr.lower())
        self.assertNotIn(b"no compatible dependency graph", result.stderr.lower())
        self.assertEqual(lock.read_bytes(), original)
        self.assert_no_blob_reads()

    def test_missing_and_tampered_signed_release_are_metadata_failures(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve")
        lock = self.project / "asm.lock"
        original = lock.read_bytes()
        targets = [path for path in (self.delivery / "targets").rglob("*.json")
                   if "/fixture/c/" in str(path) and path.name.endswith("1.0.0.json")]
        self.assertEqual(len(targets), 1)
        path = targets[0]
        data = path.read_bytes()
        for replacement in (None, data + b" "):
            with self.subTest(missing=replacement is None):
                if replacement is None:
                    path.unlink()
                else:
                    path.write_bytes(replacement)
                self.requests.clear()
                result = self.graph_cli("resolve", code=1)
                self.assertIn(b"metadata", result.stderr.lower())
                self.assertEqual(lock.read_bytes(), original)
                self.assert_no_blob_reads()
        path.write_bytes(data)

    def test_incompatible_target_is_not_materialized(self):
        self.write_project({"fixture/a": "1.0.0"})
        target = "x86_64-linux" if self.native_target.startswith("aarch64-") else "aarch64-linux"
        self.publish_graph([self.package("fixture/a", "1.0.0", target=target)], fresh=True)
        self.graph_cli("resolve", code=1)
        self.assertFalse((self.project / "asm.lock").exists())
        self.assert_no_blob_reads()
        self.requests.clear()
        self.graph_cli("resolve", target="invented-target", code=2)
        self.assertEqual(self.requests, [])

    def test_revoked_transitive_release_blocks_entire_sync_before_artifact_download(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve")
        original = (self.project / "asm.lock").read_bytes()
        self.publish_graph(lifecycle={("fixture/c", "1.0.0"): (0, 1)})
        self.requests.clear()
        self.graph_cli("sync", code=1)
        self.assertEqual((self.project / "asm.lock").read_bytes(), original)
        self.assert_no_blob_reads()
        self.assertFalse(self.package_cache("fixture/a").exists())

    def test_ordered_mirror_failover_keeps_registry_identity(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve", mirrors=[self.api + "/unavailable", self.api])
        self.assertEqual((self.project / "asm.lock").read_bytes(), self.expected_lock(self.selected_diamond()))
        self.assertTrue(any(path.startswith("/unavailable/") for _, path in self.requests))
        self.assert_no_blob_reads()

    def test_symlink_cache_boundary_preserves_unrelated_files(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve")
        original = (self.project / "asm.lock").read_bytes()
        outside = self.work / "unrelated"
        outside.mkdir()
        (outside / "keep").write_bytes(b"preserve unrelated files")
        (self.project / ".asm").mkdir(exist_ok=True)
        (self.project / ".asm/packages").symlink_to(outside, target_is_directory=True)
        self.graph_cli("sync", code=1)
        self.assertEqual((self.project / "asm.lock").read_bytes(), original)
        self.assertEqual(list(outside.iterdir()), [outside / "keep"])
        self.assertEqual((outside / "keep").read_bytes(), b"preserve unrelated files")

    def test_empty_root_graph_has_no_unrelated_packages_or_blob_reads(self):
        self.write_project({})
        self.publish_graph(self.diamond(), fresh=True)
        result = self.graph_cli("resolve")
        self.assertEqual(json.loads(result.stdout), {"ok": True, "packages": 0, "resolved": True})
        self.assertEqual((self.project / "asm.lock").read_bytes(), self.expected_lock(set()))
        self.assert_no_blob_reads()

    def test_invalid_or_duplicate_root_requirements_fail_without_network(self):
        self.publish_graph(self.diamond(), fresh=True)
        manifest = self.project / "asm.toml"
        original = manifest.read_bytes()
        variants = [original + b'"fixture/a" = "1.0.0"\n',
                    original.replace(b'"fixture/a" = "*"', b'"fixture/a" = ">= 1.0.0"'),
                    original.replace(b'"fixture/a" = "*"', b'"fixture/a" = "1.0"'),
                    original.replace(b'"fixture/a" = "*"', b'"fixture/a" = "01.0.0"')]
        for data in variants:
            with self.subTest(manifest=data):
                manifest.write_bytes(data)
                self.requests.clear()
                self.graph_cli("resolve", code=1)
                self.assertEqual(self.requests, [])
                self.assertFalse((self.project / "asm.lock").exists())

    def test_legacy_lock_is_preserved_instead_of_implicitly_replaced(self):
        self.publish_graph(self.diamond(), fresh=True)
        lock = self.project / "asm.lock"
        original = b"# asm-lock-v2\n# registry local\n"
        lock.write_bytes(original)
        self.graph_cli("resolve", code=1)
        self.assertEqual(lock.read_bytes(), original)
        self.assert_no_blob_reads()

    def test_lock_authority_cannot_be_changed_by_mirror_or_root_selection(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve")
        original = (self.project / "asm.lock").read_bytes()
        self.requests.clear()
        self.registry_id = "f" * 32
        self.graph_cli("sync", code=1)
        self.assertEqual((self.project / "asm.lock").read_bytes(), original)
        self.assert_no_blob_reads()

    def test_revocation_during_blob_transfer_blocks_sync_success(self):
        self.publish_graph(self.diamond(), fresh=True)
        self.graph_cli("resolve")
        original = (self.project / "asm.lock").read_bytes()
        self.after_blob_read = lambda: self.publish_graph(lifecycle={("fixture/c", "1.0.0"): (0, 1)})
        self.graph_cli("sync", code=1)
        self.assertEqual((self.project / "asm.lock").read_bytes(), original)
        self.assertFalse((self.project / "build").exists())


if __name__ == "__main__":
    unittest.main()
