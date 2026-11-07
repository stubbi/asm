"""Architecture discovery follows active declared profiles across renderers.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import package_pages
import registry
import target_metadata


class TargetMetadataTests(unittest.TestCase):
    def test_only_explicit_accepted_profiles_have_architecture_labels(self):
        self.assertEqual(set(target_metadata.TARGET_ARCHITECTURES), set(registry.TARGETS))
        self.assertEqual(target_metadata.architecture_for_target("aarch64-linux"), "aarch64")
        self.assertEqual(target_metadata.architecture_for_target("aarch64-macos"), "aarch64")
        self.assertEqual(target_metadata.architecture_for_target("aarch64-windows"), "aarch64")
        self.assertEqual(target_metadata.architecture_for_target("x86_64-windows"), "x86_64")
        for value in (None, [], {}, "aarch64", "aarch64-windows-extra", "x86_64-macos", "x86_64-linux-extra", "ARM64"):
            with self.subTest(value=value):
                self.assertIsNone(target_metadata.architecture_for_target(value))

    def test_latest_active_membership_deduplicates_formats_and_operating_systems(self):
        index = {"schema": 1, "packages": [{"name": "owner/math", "latest": "0.2.0", "versions": [
            {"version": "0.1.0", "yanked": False, "artifacts": [{"target": "x86_64-linux"}]},
            {"version": "0.2.0", "yanked": False, "artifacts": [{"target": "aarch64-linux"},
                {"target": "aarch64-macos"}, {"target": "aarch64-linux"}]}]},
            {"name": "owner/yanked", "latest": None, "versions": [{"version": "0.1.0", "yanked": True,
                "artifacts": [{"target": "riscv64-linux"}]}]}]}
        before = deepcopy(index)
        self.assertEqual(target_metadata.architecture_groups(index),
                         [{"id": "aarch64", "name": "ARM64", "packages": ["owner/math"]}])
        self.assertEqual(index, before)
        index["packages"][0]["latest"] = None
        self.assertEqual(target_metadata.architecture_groups(index), [])

    def test_duplicate_identity_or_missing_active_release_cannot_create_counts(self):
        package = {"name": "owner/math", "latest": "0.1.0", "versions": []}
        with self.assertRaises(registry.RegistryError):
            target_metadata.architecture_groups({"schema": 1, "packages": [package]})
        package["latest"] = None
        with self.assertRaises(registry.RegistryError):
            target_metadata.architecture_groups({"schema": 1, "packages": [package, package]})

    def test_python_and_browser_metadata_and_membership_agree(self):
        index = registry.make_indexes(registry.read_records(ROOT / "registry"))[1]
        script = ("const fs=require('node:fs'); const s=require('./site/app.js');"
                  "const i=JSON.parse(fs.readFileSync(0,'utf8'));"
                  "process.stdout.write(JSON.stringify({groups:s.architectureGroups(s.normalizeIndex(i)),"
                  "labels:Object.fromEntries(['aarch64','x86_64','riscv64'].map(k=>[k,s.architectureLabel(k)]))}));")
        completed = subprocess.run(["node", "-e", script], input=json.dumps(index), cwd=ROOT,
                                   capture_output=True, text=True, check=True, timeout=10)
        observed = json.loads(completed.stdout)
        self.assertEqual(observed["groups"], target_metadata.architecture_groups(index))
        self.assertEqual(observed["labels"], target_metadata.ARCHITECTURES)

    def test_homepage_architecture_links_and_exact_counts_work_without_scripts(self):
        index = registry.make_indexes(registry.read_records(ROOT / "registry"))[1]
        with tempfile.TemporaryDirectory() as temporary:
            stage = Path(temporary)
            page = stage / "index.html"
            page.write_text((ROOT / "site/index.html").read_text())
            package_pages.write_architecture_browse(stage, index)
            first = page.read_bytes()
            package_pages.write_architecture_browse(stage, index)
            self.assertEqual(page.read_bytes(), first)
            for row in target_metadata.architecture_groups(index):
                self.assertIn(('href="browse/architectures/' + row["id"] + '/"').encode(), first)
            self.assertIn(b'aria-label="Browse packages by architecture"', first)
            self.assertEqual(first.count(b'architecture-browse:start'), 1)
            self.assertIn(b'title="2"', first)


if __name__ == "__main__":
    unittest.main()
