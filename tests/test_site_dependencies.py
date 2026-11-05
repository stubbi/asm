"""Export source-bound declarations without executing packages.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
import hashlib
import json
import struct
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import build_site
import registry
import agent_catalog

DECLARATIONS = '''[resolution]
schema = "1"
[dependencies]
"stubbi/core" = "^1.2.0"
"stubbi/simd" = { version = "~2.3.0", optional = true, default-features = false, features = ["portable"] }
[features]
default = ["simd"]
simd = ["dep:stubbi/simd", "stubbi/core/checked"]
'''


class SiteDependencyExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="site-dependencies-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.payloads = {}
        self.requests = []
        self.record = {"schema": 1, "name": "owner/hello", "version": "1.0.0",
                       "summary": "A source dependency fixture.", "license": "MIT",
                       "source": {"repository": "https://github.com/owner/hello", "commit": "a" * 40, "path": "."},
                       "artifacts": [], "yanked": False}

    def source(self, target="x86_64-linux", declarations=DECLARATIONS):
        manifest = ('[package]\nname = "hello"\nversion = "1.0.0"\n'
                    f'[build]\nsource = "src/main.s"\ntarget = "{target}"\n' + declarations)
        files = {"asm.toml": (manifest.encode(), 0o644), "README.md": (b"Dependency export fixture.\n", 0o644),
                 "LICENSE": (b"MIT fixture.\n", 0o644), "src/main.s": (b".text\n", 0o644)}
        data = registry.make_archive(files)
        artifact = {"target": target, "kind": "source", "sha256": hashlib.sha256(data).hexdigest(),
                    "url": f"https://github.com/owner/hello/releases/download/v1.0.0/hello-{target}.tar.gz",
                    "bytes": len(data)}
        self.record["artifacts"].append(artifact)
        self.payloads[artifact["url"]] = data
        return artifact

    def read(self, url, limit, hosts, *, expected_size=None):
        self.requests.append(url)
        self.assertEqual(expected_size, len(self.payloads[url]))
        return self.payloads[url]

    def export(self, verify=True):
        record_path = self.work / "registry/packages/owner/hello/1.0.0.json"
        record_path.parent.mkdir(parents=True, exist_ok=True)
        record_path.write_bytes(registry.json_bytes(self.record))
        output = self.work / "site"
        build_site.build_site(ROOT, self.work / "registry", output, verify=verify, artifact_reader=self.read)
        return output, json.loads((output / "registry/v1/index.json").read_bytes())

    def declarations(self, output):
        data = json.loads((output / "registry/v1/dependencies.json").read_bytes())
        self.assertEqual(data["schema"], 1)
        return data["sources"]

    def test_checked_source_exports_declared_dependencies_and_feature_members(self):
        artifact = self.source()
        output, index = self.export()
        release = index["packages"][0]["versions"][0]
        declarations = self.declarations(output)
        self.assertEqual(len(declarations), 1)
        exported = declarations[0]
        self.assertEqual((exported["name"], exported["version"], exported["target"]), ("owner/hello", "1.0.0", "x86_64-linux"))
        self.assertEqual(exported["metadata"], {
            "schema": 1, "source_sha256": artifact["sha256"],
            "dependencies": [
                {"name": "stubbi/core", "requirement": "^1.2.0", "optional": False, "default_features": True, "features": []},
                {"name": "stubbi/simd", "requirement": "~2.3.0", "optional": True, "default_features": False, "features": ["portable"]},
            ], "features": {"default": ["simd"], "simd": ["dep:stubbi/simd", "stubbi/core/checked"]}})
        self.assertEqual(self.requests, [artifact["url"]])
        self.assertEqual(release["evidence"]["artifacts"], "validated")
        self.assertEqual(json.loads((output / "registry/v1/packages/owner/hello/1.0.0.json").read_bytes()), self.record)

    def test_checked_index_remains_compatible_with_existing_catalog_clients(self):
        self.source()
        output, index = self.export()
        try:
            packages = agent_catalog._validate((output / "registry/v1/index.json").read_bytes())
        except registry.RegistryError as error:
            self.fail(f"Checked catalog changed its existing artifact contract: {error}")
        self.assertEqual([package["name"] for package in packages], ["owner/hello"])
        self.assertNotIn("dependency_metadata", index["packages"][0]["versions"][0]["artifacts"][0])

    def test_checked_legacy_source_exports_known_empty_declarations(self):
        artifact = self.source(declarations="")
        output, _ = self.export()
        declarations = self.declarations(output)
        self.assertEqual(len(declarations), 1)
        self.assertEqual(declarations[0]["metadata"], {
            "schema": 1, "source_sha256": artifact["sha256"], "dependencies": [], "features": {}})

    def test_unchecked_source_metadata_remains_unavailable(self):
        self.source()
        output, index = self.export(verify=False)
        release = index["packages"][0]["versions"][0]
        self.assertNotIn("dependency_metadata", release["artifacts"][0])
        self.assertEqual(release["evidence"]["artifacts"], "not-run")
        self.assertEqual(self.declarations(output), [])
        self.assertEqual(self.requests, [])

    def test_source_targets_retain_their_separate_declarations(self):
        self.source()
        targets = {"aarch64-linux": "stubbi/arm", "aarch64-macos": "stubbi/macos", "riscv64-linux": "stubbi/riscv"}
        sources = {target: self.source(target, '[resolution]\nschema = "1"\n[dependencies]\n'
                                      f'"{name}" = ">=3.0.0"\n') for target, name in targets.items()}
        output, _ = self.export()
        declarations = {item["target"]: item["metadata"] for item in self.declarations(output)}
        for target, name in targets.items():
            with self.subTest(target=target):
                self.assertEqual(declarations[target]["dependencies"][0]["name"], name)
                self.assertEqual(declarations[target]["source_sha256"], sources[target]["sha256"])
        self.assertEqual(len(declarations["x86_64-linux"]["dependencies"]), 2)
        self.assertEqual(len(self.requests), 4)

    def test_corrupt_bytes_and_malformed_manifests_stop_site_publication(self):
        artifact = self.source()
        data = self.payloads[artifact["url"]]
        self.payloads[artifact["url"]] = bytes([data[0] ^ 1]) + data[1:]
        with self.assertRaises(registry.RegistryError):
            self.export()
        self.assertFalse((self.work / "site").exists())
        self.record["artifacts"] = []
        self.source(declarations='[resolution]\nschema = "2"\n')
        with self.assertRaises(registry.RegistryError):
            self.export()
        self.assertFalse((self.work / "site").exists())

    def test_verification_keeps_its_return_contract_and_does_not_mutate_records(self):
        artifact = self.source()
        original = copy.deepcopy(self.record)
        self.assertEqual(build_site.verify_artifacts([self.record], self.read), {("owner/hello", "1.0.0")})
        self.assertEqual(self.record, original)
        self.assertEqual(self.requests, [artifact["url"]])

    def test_checked_executable_does_not_inherit_source_declarations(self):
        source = self.source()
        header = bytearray(64)
        header[:7] = b"\x7fELF\x02\x01\x01"
        struct.pack_into("<HHI", header, 16, 2, 62, 1)
        struct.pack_into("<Q", header, 32, 64)
        struct.pack_into("<HHH", header, 52, 64, 56, 1)
        data = bytes(header) + struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 120, 120, 4096)
        artifact = {"target": "x86_64-linux", "kind": "executable", "sha256": hashlib.sha256(data).hexdigest(),
                    "url": "https://github.com/owner/hello/releases/download/v1.0.0/hello-bin", "bytes": len(data)}
        self.record["artifacts"].append(artifact)
        self.payloads[artifact["url"]] = data
        output, index = self.export()
        artifacts = {item["kind"]: item for item in index["packages"][0]["versions"][0]["artifacts"]}
        self.assertNotIn("dependency_metadata", artifacts["executable"])
        declarations = self.declarations(output)
        self.assertEqual(len(declarations), 1)
        self.assertEqual(declarations[0]["metadata"]["source_sha256"], source["sha256"])
        self.assertNotEqual(declarations[0]["metadata"]["source_sha256"], artifact["sha256"])
        self.assertEqual(len(self.requests), 2)
