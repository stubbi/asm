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
from urllib.parse import urljoin, urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import discovery
import discovery_metadata
import registry
import registry_explore
import target_metadata
from test_site import HierarchyParser


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

    def test_explore_architecture_links_and_exact_counts_work_without_scripts_and_stay_off_home(self):
        records = registry.read_records(ROOT / "registry")
        index = registry.make_indexes(records)[1]
        before = deepcopy(index)
        with tempfile.TemporaryDirectory() as temporary:
            stage = Path(temporary)
            page = stage / "index.html"
            page.write_text((ROOT / "site/index.html").read_text())
            first = page.read_bytes()
            snapshot = discovery.delivery_snapshot(records)
            snapshot["categories"] = []
            metadata = discovery_metadata.project_metadata({"schema": 1, "packages": []}, index)
            retained = discovery.retained_counts(records, None)
            html = registry_explore.explore_page(stage, index, snapshot, metadata, retained)
            self.assertEqual(registry_explore.explore_page(stage, index, snapshot, metadata, retained), html)
            self.assertEqual(page.read_bytes(), first)
            self.assertEqual(index, before)
            self.assertNotIn(b"architecture-browse", first)
            self.assertNotIn(b"browse/architectures/", first)
            self.assertNotIn('src="../app.js"', html)
            parsed = HierarchyParser()
            parsed.feed(html)
            group = parsed.elements_by_id["explore-architectures"]
            self.assertEqual(group["tag"], "h2")
            self.assertEqual("".join(group["text"]), "Browse by architecture")
            links = [element for element in parsed.elements if element["tag"] == "a"
                     and "discovery-topic" in element["attrs"].get("class", "").split()]
            architecture_links = {urlsplit(urljoin("https://asm.build/explore/", link["attrs"]["href"])).path: link
                                  for link in links if "/browse/architectures/" in link["attrs"]["href"]}
            self.assertEqual(len(architecture_links), len(target_metadata.architecture_groups(index)))
            for row in target_metadata.architecture_groups(index):
                link = architecture_links["/browse/architectures/" + row["id"] + "/"]
                self.assertIn(row["name"], "".join(link["accessible_text"]))
                counts = [element for element in parsed.elements if id(link) in element["ancestors"]
                          and "compact-count" in element["attrs"].get("class", "").split()]
                self.assertEqual([element["attrs"].get("title") for element in counts], [str(len(row["packages"]))])


if __name__ == "__main__":
    unittest.main()
