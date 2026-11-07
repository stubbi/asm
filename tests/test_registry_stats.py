"""Registry statistics retain count scope without inventing adoption.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from copy import deepcopy
from html.parser import HTMLParser
import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry
from test_count_format import accessible_text


class Page(HTMLParser):
    def __init__(self, content):
        super().__init__()
        self.tags, self.text, self.links = [], [], []
        self.feed(content)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append((tag, attrs))
        if tag == "a": self.links.append(attrs)

    def handle_data(self, text): self.text.append(text)


class RegistryStatsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.stage = Path(self.temporary.name)
        self.initial = ('<header class="site-header"><nav aria-label="Main navigation">'
                        '<a href="explore/">Explore</a><a href="stats/">Stats</a>'
                        '<a href="blog/">Blog</a><a href="docs/">Docs</a></nav></header>'
                        '<footer class="site-footer"><a href="index.html">Asm home</a></footer>')
        (self.stage / "index.html").write_text(self.initial)
        self.records = registry.read_records(ROOT / "registry")
        _, self.index = registry.make_indexes(self.records)
        self.snapshot = {"source": "github-release-assets", "observed_at": "2026-11-07T01:00:00Z"}

    def module(self):
        self.assertTrue((ROOT / "tools/registry_stats.py").is_file(), "Stats renderer is not implemented")
        return importlib.import_module("registry_stats")

    def observation(self):
        """Private rendering fixture, never the live Asm ledger."""
        versions = {}
        names = sorted({record["name"] for record in self.records})
        for name in names:
            record = next(item for item in self.records if item["name"] == name)
            versions[name] = record["version"]
        retained = {name: 0 for name in names}
        retained.update({names[0]: 7, names[1]: 3})
        retained_versions = {record["name"] + "@" + record["version"]: 0 for record in self.records}
        retained_versions.update({names[0] + "@" + versions[names[0]]: 7, names[1] + "@" + versions[names[1]]: 3})
        return {"observed_at": "2026-11-07T12:00:00Z", "coverage_end": "2026-11-07T12:00:00Z",
                "collection_started_at": "2026-09-01T00:00:00Z", "coverage_start": "2026-11-07T11:59:00Z",
                "stale": True, "complete": False, "counts": {names[0]: 2},
                "version_counts": {names[0] + "@" + versions[names[0]]: 2},
                "retained_counts": retained, "retained_version_counts": retained_versions,
                "retained_complete": False, "retained_coverage_start": "2026-11-07T11:59:00Z",
                "daily_counts": [{"date": "2026-11-07", "name": names[0], "version": versions[names[0]], "count": 2}],
                "coverage_intervals": [{"start": "2026-11-07T11:59:00Z", "end": "2026-11-07T12:00:00Z"}]}

    def test_unknown_metrics_keep_catalog_facts_and_plain_navigation(self):
        module = self.module()
        html = module.stats_page(self.stage, self.index, self.snapshot, None, self.records)
        page = Page(html)
        text = " ".join(page.text)
        self.assertIn("Registered packages", text)
        self.assertIn("Retained releases", text)
        self.assertIn("Unavailable", text)
        self.assertNotIn("0 downloads", text)
        self.assertNotIn("<svg", html)
        self.assertEqual([attrs for tag, attrs in page.tags if tag == "script"],
                         [{"src": "../navigation.js"}, {"src": "../repository-stars.js", "defer": None}])
        self.assertEqual([link["href"] for link in page.links if link.get("aria-current") == "page"], ["../stats/"])
        self.assertIn(("link", {"rel": "canonical", "href": "https://asm.build/stats/"}), page.tags)
        self.assertIn("../browse/popular/", [link["href"] for link in page.links])
        self.assertIn("../registry/v1/stats.json", [link["href"] for link in page.links])

    def test_since_collection_totals_are_separate_from_rolling_chart(self):
        module = self.module()
        observation = self.observation()
        html = module.stats_page(self.stage, self.index, self.snapshot, observation, self.records)
        page = Page(html)
        text = accessible_text(html)
        self.assertIn("≥ 10", text)
        self.assertIn("≥ 7", text)
        self.assertIn("≥ 3", text)
        self.assertIn("≥ 2 downloads", text)
        self.assertIn("Since collection began", text)
        self.assertIn("2026-09-01", text)
        self.assertIn("stale", text.lower())
        self.assertIn("All packages · All versions", text)
        self.assertIn("<svg", html)
        self.assertNotIn("All time", text)
        names = sorted(observation["retained_counts"])
        self.assertLess(html.index('href="../packages/' + names[0]), html.index('href="../packages/' + names[1]))

    def test_complete_collection_can_have_an_incomplete_thirty_day_window(self):
        observation = self.observation()
        observation.update(collection_started_at="2026-11-01T00:00:00Z", retained_complete=True,
                           retained_coverage_start="2026-11-01T00:00:00Z", stale=False,
                           coverage_intervals=[{"start": "2026-11-01T00:00:00Z", "end": "2026-11-07T12:00:00Z"}])
        observation["retained_counts"] = {name: observation["counts"].get(name, 0) for name in observation["retained_counts"]}
        observation["retained_version_counts"] = {name: observation["version_counts"].get(name, 0) for name in observation["retained_version_counts"]}
        html = self.module().stats_page(self.stage, self.index, self.snapshot, observation, self.records)
        text = accessible_text(html)
        self.assertIn("2 transfers", text)
        self.assertNotIn("≥ 2 transfers", text)
        self.assertIn("≥ 2 downloads", text)
        self.assertIn("complete for this collection period", text)

    def test_json_and_html_share_one_explicit_source_and_do_not_change_homepage(self):
        module = self.module()
        observation = self.observation()
        routes = module.write_stats(self.stage, self.index, self.snapshot, observation, self.records)
        self.assertEqual(routes, ["stats/"])
        data = json.loads((self.stage / "registry/v1/stats.json").read_text())
        self.assertEqual(data["source"], "asm-delivery-events")
        self.assertEqual(data["policy"], "asm-deliveries-v1")
        self.assertEqual(data["catalog"]["packages"], len({record["name"] for record in self.records}))
        self.assertEqual(data["catalog"]["releases"], len(self.records))
        self.assertEqual(data["transfers"]["total"], 10)
        self.assertEqual(data["activity"]["total"], 2)
        self.assertEqual(data["activity"]["scope"], "registry")
        self.assertNotIn("name", data["activity"])
        self.assertNotIn("version", data["activity"])
        self.assertEqual(data["transfers"]["observed_at"], data["activity"]["observed_at"])
        self.assertEqual((self.stage / "index.html").read_text(), self.initial)

    def test_partial_zero_is_a_minimum_and_never_a_fabricated_ranking(self):
        observation = self.observation()
        for key in ("counts", "version_counts", "retained_counts", "retained_version_counts"):
            observation[key] = {identity: 0 for identity in observation[key]}
        observation["daily_counts"] = []
        html = self.module().stats_page(self.stage, self.index, self.snapshot, observation, self.records)
        text = " ".join(Page(html).text)
        self.assertIn("≥ 0", text)
        self.assertIn("No positive", text)
        self.assertNotIn("registry-ranking-item", html)

    def test_package_summaries_are_escaped_in_ranked_rows(self):
        index = deepcopy(self.index)
        for item in index["packages"]:
            item["summary"] = '<img src=x onerror="alert(1)">'
        html = self.module().stats_page(self.stage, index, self.snapshot, self.observation(), self.records)
        self.assertNotIn("<img", html)
        self.assertIn("&lt;img", html)


if __name__ == "__main__": unittest.main()
