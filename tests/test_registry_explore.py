"""Native Explore views preserve measurement scope and missing metadata.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from copy import deepcopy
from html.parser import HTMLParser
import importlib
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from urllib.parse import parse_qs, urljoin, urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry
from test_count_format import accessible_text
from test_site import HierarchyParser


class Page(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.links, self.scripts, self.canonicals, self.ids, self.mains, self.h1s, self.text = [], [], [], [], [], [], []
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "a": self.links.append(attrs.get("href", ""))
        if tag == "script": self.scripts.append(attrs)
        if tag == "link" and attrs.get("rel") == "canonical": self.canonicals.append(attrs["href"])
        if "id" in attrs: self.ids.append(attrs["id"])
        if tag == "main": self.mains.append(attrs.get("id"))
        if tag == "h1": self.h1s.append(attrs)

    def handle_data(self, text): self.text.append(text)


class RegistryExploreTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.stage = Path(temporary.name) / "site"
        shutil.copytree(ROOT / "site", self.stage)
        self.records = registry.read_records(ROOT / "registry")
        self.index = registry.make_indexes(self.records)[1]
        self.names = ["stubbi/asm", "stubbi/hello", "stubbi/math"]
        self.snapshot = {"schema": 1, "policy": "asm-deliveries-v1", "source": "asm-delivery-events",
            "observed_at": "2026-11-07T06:00:00Z", "publication_observed_at": "2026-11-07T06:00:00Z",
            "stale": False, "refresh_error": None, "collection_started_at": "2026-11-01T00:00:00Z",
            "coverage": {"start": "2026-11-01T00:00:00Z", "end": "2026-11-07T06:00:00Z", "complete": False},
            "packages": [{"name": name, "downloads_30d": count, "downloads_30d_exact": False,
                          "first_published_at": "2026-01-01T00:00:00Z", "last_published_at": "2026-02-01T00:00:00Z"}
                         for name, count in zip(self.names, (1, 0, 2))],
            "feeds": {"new": list(reversed(self.names)), "popular": ["stubbi/math", "stubbi/asm"], "updated": ["stubbi/hello"]},
            "categories": [{"id": "examples", "name": "Examples", "packages": ["stubbi/hello"]},
                           {"id": "developer-tools", "name": "Developer tools", "packages": ["stubbi/asm", "stubbi/math"]}]}
        self.metadata = {"schema": 1, "packages": [{"name": name, "version": "0.4.0", "keywords": ["assembly"], "dependencies": None} for name in self.names],
            "keywords": [{"id": "assembly", "name": "assembly", "packages": self.names[:], "package_count": 3},
                         {"id": "math", "name": "math", "packages": ["stubbi/math"], "package_count": 1}],
            "dependents": [{"name": name, "packages": [], "count": None, "exact": False} for name in self.names],
            "dependency_coverage": {"known": 0, "total": 3, "complete": False},
            "feeds": {"keywords": ["assembly", "math"], "depended_on": []}}
        self.retained = {"schema": 1, "policy": "asm-deliveries-v1", "source": "asm-delivery-events", "scope": "since-collection",
            "observed_at": "2026-11-07T06:00:00Z", "collection_started_at": "2026-11-01T00:00:00Z", "stale": False,
            "window": {"start": "2026-11-01T00:00:00Z", "end": "2026-11-07T06:00:00Z", "basis": "since-collection"},
            "coverage": {"start": "2026-11-01T00:00:00Z", "end": "2026-11-07T06:00:00Z", "complete": False},
            "complete": False, "total": 11,
            "packages": {name: {"total": count, "versions": {"0.4.0": count}} for name, count in zip(self.names, (1, 0, 10))}}

    def module(self):
        self.assertTrue((ROOT / "tools/registry_explore.py").is_file(), "Native Explore rendering is not implemented.")
        return importlib.import_module("registry_explore")

    def render(self, kind="explore"):
        return self.module().explore_page(self.stage, self.index, self.snapshot, self.metadata, self.retained, kind)

    def test_write_routes_are_native_canonical_and_link_to_complete_discovery_views(self):
        routes = self.module().write_explore(self.stage, self.index, self.snapshot, self.metadata, self.retained)
        self.assertEqual(set(routes), {"explore/", "browse/categories/", "browse/keywords/", "browse/keywords/assembly/",
                                      "browse/keywords/math/", "browse/depended-on/", "browse/downloaded/",
                                      "browse/architectures/", "browse/architectures/aarch64/", "browse/architectures/x86_64/", "browse/architectures/riscv64/"})
        for route in routes:
            with self.subTest(route=route):
                html = (self.stage / route / "index.html").read_text()
                page = Page(html)
                self.assertEqual(page.canonicals, ["https://asm.build/" + route])
                self.assertEqual(page.mains, ["main"])
                self.assertEqual(len(page.h1s), 1)
                prefix = "../" * route.count("/")
                self.assertEqual(page.scripts, [{"src": prefix + "navigation.js"}, {"src": prefix + "repository-stars.js", "defer": None}])
                self.assertEqual(len(page.ids), len(set(page.ids)))
                self.assertEqual(html.count('class="site-header"'), 1)
                self.assertEqual(html.count('class="site-footer"'), 1)
        links = {urlsplit(urljoin("https://asm.build/explore/", href)).path for href in Page(self.render()).links}
        self.assertTrue({"/browse/new/", "/browse/popular/", "/browse/updated/", "/browse/depended-on/",
                         "/browse/keywords/", "/browse/categories/", "/browse/architectures/"}.issubset(links))

    def test_dashboard_uses_native_cards_and_correct_first_or_latest_publication_signal(self):
        html = self.render()
        self.assertIn('name="description" content="Find packages by activity, purpose, and dependencies."', html)
        self.assertIn('class="discovery-groups"', html)
        self.assertEqual(html.count('class="discovery-group"'), 7)
        self.assertIn('class="discovery-item"', html)
        self.assertIn('class="discovery-target"', html)
        self.assertIn('datetime="2026-01-01T00:00:00Z"', html)
        self.assertIn('datetime="2026-02-01T00:00:00Z"', html)
        self.assertIn("Last 30 days", html)
        self.assertIn("incomplete", html.lower())
        self.assertIn("≥ 2", html)

    def test_dashboard_group_headers_keep_headings_routes_and_scope_above_rows(self):
        page = HierarchyParser()
        page.feed(self.render())
        def within(element, parent): return id(parent) in element["ancestors"]
        def has_class(element, name): return name in element["attrs"].get("class", "").split()
        groups = [item for item in page.elements if has_class(item, "discovery-group")]
        self.assertEqual(len(groups), 7)
        expected = {"explore-new": "../browse/new/", "explore-popular": "../browse/popular/", "explore-updated": "../browse/updated/"}
        for group in groups:
            headers = [item for item in page.elements if within(item, group) and has_class(item, "discovery-group-header")]
            self.assertEqual(len(headers), 1)
            heading = page.elements_by_id[group["attrs"]["aria-labelledby"]]
            self.assertEqual(heading["tag"], "h2")
            self.assertTrue(within(heading, headers[0]))
            self.assertEqual(sum(within(item, headers[0]) and has_class(item, "discovery-group-caption") for item in page.elements), 1)
            actions = [item for item in page.elements if within(item, headers[0]) and item["tag"] == "a"]
            self.assertEqual(len(actions), 1)
            self.assertTrue(actions[0]["attrs"].get("aria-label", "").startswith("View all "))
            if heading["attrs"]["id"] in expected:
                self.assertEqual(actions[0]["attrs"]["href"], expected[heading["attrs"]["id"]])
            self.assertFalse(any(within(item, headers[0]) and has_class(item, "discovery-item") for item in page.elements))

    def test_keyword_routes_use_exact_membership_and_latest_active_artifact_targets(self):
        math = next(item for item in self.index["packages"] if item["name"] == "stubbi/math")
        latest = next(release for release in math["versions"] if release["version"] == math["latest"])
        latest["artifacts"] = [deepcopy(latest["artifacts"][0])]
        latest["artifacts"][0]["target"] = "x86_64-linux"
        html = self.render("keywords/math")
        page = Page(html)
        package_links = [urlsplit(urljoin("https://asm.build/browse/keywords/math/", href)).path for href in page.links]
        self.assertIn("/packages/stubbi/math/", package_links)
        self.assertNotIn("/packages/stubbi/hello/", package_links)
        self.assertIn("x86_64-linux", html)
        self.assertNotIn("riscv64-linux", html)
        self.assertIn(math["latest"], html)

    def test_direct_dependency_unknowns_never_appear_as_zero_rankings(self):
        html = self.render("depended-on")
        self.assertIn("unavailable", html.lower())
        self.assertIn("0 of 3", accessible_text(html))
        self.assertNotIn('class="discovery-item"', html)
        self.assertNotIn("0 dependents", html)
        self.metadata["packages"][0]["dependencies"] = ["stubbi/math"]
        self.metadata["packages"][1]["dependencies"] = ["stubbi/math"]
        self.metadata["dependency_coverage"]["known"] = 2
        self.metadata["dependents"][2].update(packages=["stubbi/asm", "stubbi/hello"], count=2)
        self.metadata["feeds"]["depended_on"] = ["stubbi/math"]
        measured = self.render("depended-on")
        self.assertIn("≥ 2", measured)
        self.assertIn("direct", measured.lower())
        self.assertIn("incomplete", measured.lower())
        self.assertEqual(measured.count('class="discovery-item"'), 1)

    def test_keyword_and_category_directories_rank_actual_active_package_membership(self):
        self.metadata["keywords"].reverse()
        keywords = self.render("keywords")
        categories = self.render("categories")
        self.assertLess(keywords.index('class="discovery-name">assembly'), keywords.index('class="discovery-name">math'))
        self.assertLess(categories.index('class="discovery-name">Developer tools'), categories.index('class="discovery-name">Examples'))
        self.assertIn("3 packages", accessible_text(keywords))
        self.assertIn("2 packages", accessible_text(categories))

    def test_downloaded_ranking_uses_own_since_collection_totals_and_preserves_coverage(self):
        html = self.render("downloaded")
        self.assertIn("Since collection started", html)
        self.assertIn("2026-11-01", html)
        self.assertIn("2026-11-07", html)
        self.assertIn("≥ 10", html)
        self.assertNotIn("all-time", html.lower())
        self.assertNotIn("Last 30 days", html)
        self.assertLess(html.index('class="discovery-name">stubbi/math'), html.index('class="discovery-name">stubbi/asm'))
        self.assertEqual(html.count('class="discovery-item"'), 2)
        self.retained["stale"] = True
        self.assertIn("stale", self.render("downloaded").lower())

    def test_unknown_downloads_and_absent_metadata_have_useful_empty_routes(self):
        self.retained.update(observed_at=None, collection_started_at=None, total=None, stale=True)
        self.retained["window"].update(start=None, end=None)
        for item in self.retained["packages"].values(): item["total"] = None
        html = self.render("downloaded")
        self.assertIn("unavailable", html.lower())
        self.assertNotIn('class="discovery-item"', html)
        self.metadata["keywords"], self.metadata["feeds"]["keywords"] = [], []
        self.snapshot["categories"] = []
        self.assertIn("No keywords", self.render("keywords"))
        self.assertIn("No categories", self.render("categories"))

    def test_unknown_keyword_and_malformed_routes_are_missing_not_empty_successes(self):
        for kind in ("keywords/unknown", "keywords/../math", "keywords/math/extra", "keywords/<script>", "unknown"):
            with self.subTest(kind=kind), self.assertRaises(KeyError): self.render(kind)
        self.assertFalse((self.stage / "explore").exists())

    def test_rendering_is_read_only_and_untrusted_labels_cannot_create_html(self):
        before = deepcopy((self.index, self.snapshot, self.metadata, self.retained))
        self.render()
        self.assertEqual((self.index, self.snapshot, self.metadata, self.retained), before)
        package = next(item for item in self.index["packages"] if item["name"] == "stubbi/math")
        package["summary"] = '<img src=x onerror="bad">'
        self.snapshot["categories"][0]["name"] = '<script>alert(1)</script>'
        html = self.render()
        self.assertIn("&lt;script&gt;", html)
        self.assertIn("&lt;img", html)
        self.assertNotIn('<script>alert', html)

    def test_malformed_metric_sources_and_foreign_feed_members_fail_closed(self):
        self.retained["source"] = "github-release-assets"
        with self.assertRaises(registry.RegistryError): self.render("downloaded")
        self.retained["source"] = "asm-delivery-events"
        self.snapshot["feeds"]["popular"] = ["unknown/package"]
        with self.assertRaises(registry.RegistryError): self.render()

    def test_architecture_directory_uses_explicit_labels_and_distinct_active_members(self):
        html = self.render("architectures")
        text = accessible_text(html)
        self.assertIn("ARM64 (aarch64)", text)
        self.assertIn("x86-64 (x86_64)", text)
        self.assertIn("RISC-V64 (riscv64)", text)
        self.assertIn("2 packages", text)
        self.assertIn("3 packages", text)
        self.assertIn("1 package", text)
        links = {urlsplit(urljoin("https://asm.build/browse/architectures/", href)).path for href in Page(html).links}
        self.assertTrue({"/browse/architectures/aarch64/", "/browse/architectures/x86_64/", "/browse/architectures/riscv64/"}.issubset(links))
        self.assertIn("Browse by architecture", accessible_text(self.render()))

    def test_architecture_package_previews_keep_only_matching_latest_target_pairs(self):
        before = deepcopy(self.index)
        html = self.render("architectures/aarch64")
        self.assertEqual(html.count('class="discovery-name">stubbi/asm'), 1, "Two ARM64 operating systems still identify one package.")
        self.assertEqual(html.count('class="discovery-name">stubbi/hello'), 1)
        self.assertNotIn('class="discovery-name">stubbi/math', html)
        self.assertIn('class="discovery-target">aarch64-linux', html)
        self.assertIn('class="discovery-target">aarch64-macos', html)
        self.assertNotIn('class="discovery-target">x86_64-linux', html)
        self.assertNotIn('class="discovery-target">riscv64-linux', html)
        search = [urlsplit(urljoin("https://asm.build/browse/architectures/aarch64/", href)) for href in Page(html).links]
        refinements = [url for url in search if url.path == "/index.html" and url.fragment.startswith("search?")]
        self.assertEqual(len(refinements), 1)
        self.assertEqual(parse_qs(refinements[0].fragment.split("?", 1)[1]), {"architecture": ["aarch64"], "all": ["1"]})
        package_links = [url for url in search if url.path.startswith("/packages/stubbi/")]
        self.assertEqual({url.path for url in package_links}, {"/packages/stubbi/asm/", "/packages/stubbi/hello/"})
        for url in package_links:
            self.assertEqual(parse_qs(url.fragment), {"from": ["#search?architecture=aarch64&all=1"]})
        keyword_links = [urlsplit(urljoin("https://asm.build/browse/keywords/math/", href))
                         for href in Page(self.render("keywords/math")).links]
        self.assertTrue(all(not url.fragment for url in keyword_links if url.path == "/packages/stubbi/math/"))
        self.assertEqual(self.index, before)

    def test_architecture_routes_need_only_the_accepted_catalog(self):
        for kind in ("architectures", "architectures/aarch64", "architectures/x86_64", "architectures/riscv64"):
            expected = self.render(kind)
            for snapshot, metadata, retained in ((None, None, None), ({"schema": -1}, {"keywords": "corrupt"}, {"source": "foreign"})):
                with self.subTest(kind=kind, snapshot=snapshot):
                    self.assertEqual(self.module().explore_page(self.stage, self.index, snapshot, metadata, retained, kind), expected)
        self.metadata["keywords"] = "corrupt"
        with self.assertRaises(registry.RegistryError): self.render("keywords")
        with self.assertRaises(KeyError):
            self.module().explore_page(self.stage, self.index, None, None, None, "architectures/arm64")

    def test_historical_and_yanked_architectures_cannot_create_current_membership(self):
        import discovery_metadata
        hello = next(package for package in self.index["packages"] if package["name"] == "stubbi/hello")
        latest = next(release for release in hello["versions"] if release["version"] == hello["latest"])
        latest["artifacts"] = [deepcopy(next(item for item in latest["artifacts"] if item["target"] == "x86_64-linux"))]
        math = next(package for package in self.index["packages"] if package["name"] == "stubbi/math")
        math["latest"] = None
        for release in math["versions"]: release.update(yanked=True, yank_reason="Architecture fixture.")
        for key, names in self.snapshot["feeds"].items(): self.snapshot["feeds"][key] = [name for name in names if name != "stubbi/math"]
        self.metadata = discovery_metadata.project_metadata({"schema": 1, "packages": []}, self.index)
        directory = self.render("architectures")
        self.assertNotIn("RISC-V64", accessible_text(directory))
        self.assertIn("2 packages", accessible_text(directory))
        with self.assertRaises(KeyError): self.render("architectures/riscv64")
        arm = self.render("architectures/aarch64")
        self.assertEqual(arm.count('class="discovery-item"'), 1)
        self.assertIn('class="discovery-name">stubbi/asm', arm)
        self.assertNotIn('class="discovery-name">stubbi/hello', arm)

    def test_unknown_architecture_or_unrecognized_target_never_guesses_a_match(self):
        for kind in ("architectures/arm64", "architectures/unknown", "architectures/../aarch64", "architectures/aarch64/extra"):
            with self.subTest(kind=kind), self.assertRaises(KeyError): self.render(kind)
        package = self.index["packages"][0]
        latest = next(release for release in package["versions"] if release["version"] == package["latest"])
        latest["artifacts"][0]["target"] = "aarch64-unknown"
        with self.assertRaises(registry.RegistryError): self.render("architectures")

    def test_empty_architecture_directory_does_not_invent_supported_packages(self):
        import discovery_metadata
        self.index = registry.make_indexes([])[1]
        self.snapshot.update(packages=[], categories=[], feeds={"popular": [], "new": [], "updated": []})
        self.metadata = discovery_metadata.project_metadata({"schema": 1, "packages": []}, self.index)
        self.retained.update(packages={}, total=None)
        html = self.render("architectures")
        self.assertIn("No active packages", accessible_text(html))
        self.assertNotIn('discovery-topic"', html)
        with self.assertRaises(KeyError): self.render("architectures/x86_64")


if __name__ == "__main__": unittest.main()
