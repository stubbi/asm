"""Reviewed discovery metadata does not invent dependency relationships.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from copy import deepcopy
import importlib
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry


class DiscoveryMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.records = registry.read_records(ROOT / "registry")
        self.index = registry.make_indexes(self.records)[1]

    def module(self):
        self.assertTrue((ROOT / "tools/discovery_metadata.py").exists())
        return importlib.import_module("discovery_metadata")

    def declaration(self, name, dependencies, version=None):
        if version is None:
            version = max((item["version"] for item in self.records if item["name"] == name), key=registry.version_tuple)
        record = next(item for item in self.records if item["name"] == name and item["version"] == version)
        return {"version": version, "source_commit": record["source"]["commit"], "dependencies": dependencies}

    def test_missing_file_and_absent_declarations_remain_unknown_without_writing(self):
        result = self.module().read_metadata(self.root, self.index)
        self.assertEqual(result["dependency_coverage"], {"known": 0, "total": 3, "complete": False})
        self.assertTrue(all(row["dependencies"] is None for row in result["packages"]))
        self.assertTrue(all(row["count"] is None for row in result["dependents"]))
        self.assertEqual(result["feeds"], {"keywords": [], "depended_on": []})
        self.assertEqual(list(self.root.iterdir()), [])

    def test_keywords_rank_declared_active_package_membership_not_search_activity(self):
        value = {"schema": 1, "packages": [
            {"name": "stubbi/math", "keywords": ["assembly", "math"]},
            {"name": "stubbi/hello", "keywords": ["assembly", "examples"]}]}
        result = self.module().project_metadata(value, self.index)
        self.assertEqual(result["feeds"]["keywords"], ["assembly", "examples", "math"])
        self.assertEqual(result["keywords"][0], {"id": "assembly", "name": "assembly",
                         "packages": ["stubbi/hello", "stubbi/math"], "package_count": 2})
        self.assertTrue(all(row["count"] is None for row in result["dependents"]))

    def test_distinct_latest_active_consumers_supply_direct_dependency_lower_bounds(self):
        value = {"schema": 1, "packages": [
            {"name": "stubbi/hello", "releases": [self.declaration("stubbi/hello", ["stubbi/math"])]},
            {"name": "stubbi/asm", "releases": [self.declaration("stubbi/asm", ["stubbi/math", "stubbi/hello"])]}]}
        result = self.module().project_metadata(value, self.index)
        self.assertEqual(result["dependency_coverage"], {"known": 2, "total": 3, "complete": False})
        rows = {row["name"]: row for row in result["dependents"]}
        self.assertEqual(rows["stubbi/math"], {"name": "stubbi/math", "packages": ["stubbi/asm", "stubbi/hello"],
                                             "count": 2, "exact": False})
        self.assertEqual(rows["stubbi/hello"]["count"], 1)
        self.assertIsNone(rows["stubbi/asm"]["count"])
        self.assertEqual(result["feeds"]["depended_on"], ["stubbi/math", "stubbi/hello"])

    def test_explicit_empty_latest_declarations_establish_known_zero(self):
        value = {"schema": 1, "packages": [{"name": name,
                 "releases": [self.declaration(name, [])]} for name in sorted({r["name"] for r in self.records})]}
        result = self.module().project_metadata(value, self.index)
        self.assertEqual(result["dependency_coverage"], {"known": 3, "total": 3, "complete": True})
        self.assertTrue(all(row["count"] == 0 and row["exact"] for row in result["dependents"]))
        self.assertEqual(result["feeds"]["depended_on"], [])

    def test_historical_declarations_cannot_replace_latest_or_create_transitive_edges(self):
        value = {"schema": 1, "packages": [
            {"name": "stubbi/hello", "releases": [self.declaration("stubbi/hello", ["stubbi/math"], "0.1.0")]},
            {"name": "stubbi/asm", "releases": [self.declaration("stubbi/asm", ["stubbi/hello"])]}]}
        result = self.module().project_metadata(value, self.index)
        rows = {row["name"]: row for row in result["dependents"]}
        self.assertIsNone(rows["stubbi/math"]["count"])
        self.assertEqual(rows["stubbi/hello"]["count"], 1)
        self.assertEqual(result["dependency_coverage"]["known"], 1)

    def test_yanked_consumers_and_keyword_memberships_leave_rankings(self):
        for record in self.records:
            if record["name"] == "stubbi/hello": record.update(yanked=True, yank_reason="Fixture.")
        self.index = registry.make_indexes(self.records)[1]
        value = {"schema": 1, "packages": [{"name": "stubbi/hello", "keywords": ["example"],
                 "releases": [self.declaration("stubbi/hello", ["stubbi/math"])]}]}
        result = self.module().project_metadata(value, self.index)
        self.assertEqual(result["keywords"], [])
        self.assertEqual(result["feeds"]["depended_on"], [])
        self.assertEqual(result["dependency_coverage"]["total"], 2)

    def test_unknown_duplicate_unsafe_and_mismatched_declarations_fail_closed(self):
        fixture = {"schema": 1, "packages": [{"name": "stubbi/hello", "keywords": ["assembly"],
                   "releases": [self.declaration("stubbi/hello", ["stubbi/math"])]}]}
        variants = []
        for change in ({"name": "unknown/package"}, {"keywords": ["assembly", "assembly"]},
                       {"keywords": ["<script>"]}, {"keywords": ["a" * 41]}, {"extra": True}):
            value = deepcopy(fixture); value["packages"][0].update(change); variants.append(value)
        for change in ({"version": "9.0.0"}, {"source_commit": "f" * 40},
                       {"dependencies": ["stubbi/math", "stubbi/math"]}, {"dependencies": ["stubbi/hello"]},
                       {"dependencies": ["unknown/package"]}, {"dependencies": None}, {"extra": 1}):
            value = deepcopy(fixture); value["packages"][0]["releases"][0].update(change); variants.append(value)
        duplicate_package = deepcopy(fixture); duplicate_package["packages"] *= 2; variants.append(duplicate_package)
        duplicate_release = deepcopy(fixture); duplicate_release["packages"][0]["releases"] *= 2; variants.append(duplicate_release)
        variants += [{"schema": True, "packages": []}, {"schema": 2, "packages": []},
                     {"schema": 1, "packages": [], "extra": 1}]
        for value in variants:
            with self.subTest(value=value), self.assertRaises(registry.RegistryError):
                self.module().project_metadata(value, self.index)

    def test_reader_rejects_duplicate_json_fields_symlinks_and_oversized_input(self):
        path = self.root / "discovery-metadata.json"
        for content in (b'{"schema":1,"schema":1,"packages":[]}', b"x" * (256 * 1024 + 1)):
            path.write_bytes(content)
            with self.subTest(length=len(content)), self.assertRaises(registry.RegistryError):
                self.module().read_metadata(self.root, self.index)
        path.unlink()
        other = self.root / "other.json"; other.write_text('{"schema":1,"packages":[]}')
        path.symlink_to(other)
        with self.assertRaises(registry.RegistryError): self.module().read_metadata(self.root, self.index)

    def test_pure_projection_bounds_tags_and_rejects_an_inconsistent_selected_release(self):
        tags = ["tag-" + str(number) for number in range(33)]
        with self.assertRaises(registry.RegistryError):
            self.module().project_metadata({"schema": 1, "packages": [{"name": "stubbi/math", "keywords": tags}]}, self.index)
        index = deepcopy(self.index)
        index["packages"][0]["latest"] = "0.1.0"
        with self.assertRaises(registry.RegistryError):
            self.module().project_metadata({"schema": 1, "packages": []}, index)
        with self.assertRaises(registry.RegistryError):
            self.module().read_metadata(self.root, self.index, "../outside.json")

    def test_total_keyword_bound_accepts_4096_and_rejects_the_next_unique_tag(self):
        prototype = next(record for record in self.records if record["name"] == "stubbi/math" and record["version"] == "0.4.0")
        records, packages = [], []
        for number in range(129):
            record = deepcopy(prototype)
            record["name"] = "owner/pkg" + str(number)
            record["artifacts"][0]["url"] = "https://github.com/stubbi/asm/releases/download/v0.4.0/pkg" + str(number) + ".tar.gz"
            records.append(record)
            packages.append({"name": record["name"], "keywords": ["tag-" + str(number) + "-" + str(tag) for tag in range(32)]})
        index = registry.make_indexes(records)[1]
        at_limit = self.module().project_metadata({"schema": 1, "packages": packages[:128]}, index)
        self.assertEqual(len(at_limit["keywords"]), 4096)
        self.assertEqual(len(at_limit["feeds"]["keywords"]), 4096)
        import discovery
        import registry_explore
        (self.root / "index.html").write_text('<header><a href="explore/">Explore</a></header><footer>Asm</footer>')
        snapshot = discovery.delivery_snapshot(records)
        snapshot["categories"] = []
        html = registry_explore.explore_page(self.root, index, snapshot, at_limit,
                                             discovery.retained_counts(records, None), "keywords")
        self.assertEqual(html.count('class="discovery-item discovery-topic"'), 4096)
        # One declaration can reuse an existing tag without consuming another
        # distinct keyword. The cap concerns projected identities, not edges.
        repeated = packages[:128] + [{"name": packages[128]["name"], "keywords": ["tag-0-0"]}]
        self.assertEqual(len(self.module().project_metadata({"schema": 1, "packages": repeated}, index)["keywords"]), 4096)
        with self.assertRaises(registry.RegistryError):
            self.module().project_metadata({"schema": 1, "packages": packages}, index)


if __name__ == "__main__": unittest.main()
