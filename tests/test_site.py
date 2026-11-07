"""Static checks for accessible references and local website assets."""

from html.parser import HTMLParser
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, unquote, urljoin, urlsplit
from urllib.robotparser import RobotFileParser
from xml.etree import ElementTree


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"
PAGES = ("index.html", "guide.html", "sponsors.html")
sys.path.insert(0, str(ROOT / "tools"))
import build_site
import registry
import site_routes


class SiteParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = []
        self.references = []
        self.assets = []
        self.input_ids = []
        self.labels = []
        self.headings = []
        self.scripts = []
        self.canonicals = []
        self.descriptions = []
        self.robots = []
        self.page_links = []
        self.links = []
        self.main_navigation_links = []
        self.footer_links = []
        self.text = []
        self.accessible_text = []
        self.in_main_navigation = False
        self.in_footer = False
        self.in_header = False
        self.header_count = 0
        self.footer_count = 0
        self.main_ids = []
        self.skip_links = []
        self.main_navigation = []
        self.main_links = []
        self.footer_link_elements = []
        self.footer_navigation_labels = []
        self.header_brands = []
        self.footer_brands = []
        self.controls = []
        self.label_elements = []
        self.buttons = []
        self.elements_by_id = {}
        self.metadata = []
        self.stylesheets = []
        self.icons = []
        self.elements = []
        self.definitions = []
        self._elements = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        element = {"tag": tag, "attrs": attrs, "text": [], "accessible_text": []}
        self.elements.append(element)
        if tag == "header" and "site-header" in attrs.get("class", "").split():
            self.in_header = True
            self.header_count += 1
        if tag == "nav" and attrs.get("aria-label") == "Main navigation":
            self.in_main_navigation = True
        if tag == "nav" and self.in_footer:
            self.footer_navigation_labels.append(attrs.get("aria-label", ""))
        if tag == "footer":
            self.in_footer = True
            self.footer_count += 1
        if tag == "main":
            self.main_ids.append(attrs.get("id"))
        if "id" in attrs:
            self.ids.append(attrs["id"])
            self.elements_by_id[attrs["id"]] = element
        if tag == "a" and attrs.get("href", "").startswith("#") and attrs["href"] != "#":
            self.references.append(attrs["href"][1:])
        if tag == "a":
            self.links.append(attrs)
            if any(parent["tag"] == "main" for parent in self._elements):
                self.main_links.append(element)
            if self.in_main_navigation:
                self.main_navigation_links.append(attrs.get("href", ""))
                self.main_navigation.append(element)
            if self.in_footer:
                self.footer_links.append(attrs.get("href", ""))
                self.footer_link_elements.append(element)
            if "skip-link" in attrs.get("class", "").split():
                self.skip_links.append(element)
            url = urlsplit(attrs.get("href", ""))
            if not url.scheme and not url.netloc and url.path in PAGES:
                self.page_links.append((url.path, url.fragment))
        for key in ("aria-labelledby", "aria-controls", "aria-describedby"):
            self.references.extend(attrs.get(key, "").split())
        if tag == "img":
            anchor = next((parent for parent in reversed(self._elements)
                           if parent["tag"] == "a"), None)
            if anchor and "wordmark" in anchor["attrs"].get("class", "").split():
                brand = {"anchor": anchor["attrs"], "image": attrs}
                if self.in_header:
                    self.header_brands.append(brand)
                if self.in_footer:
                    self.footer_brands.append(brand)
        if tag in ("script", "img") and "src" in attrs:
            self.assets.append(attrs["src"])
        if tag == "link" and attrs.get("rel") in ("stylesheet", "icon"):
            self.assets.append(attrs["href"])
            if attrs["rel"] == "stylesheet":
                self.stylesheets.append(attrs["href"])
            else:
                self.icons.append(attrs["href"])
        if tag in ("input", "select", "textarea") and attrs.get("type") != "hidden":
            self.input_ids.append(attrs.get("id"))
            element["wrapping_label"] = next((parent for parent in reversed(self._elements)
                                               if parent["tag"] == "label"), None)
            self.controls.append(element)
        if tag == "label":
            self.labels.append(attrs.get("for"))
            self.label_elements.append(element)
            if attrs.get("for"):
                self.references.append(attrs["for"])
        if tag == "button":
            self.buttons.append(element)
        if tag in {"dt", "dd"}:
            definition_list = next((parent for parent in reversed(self._elements)
                                    if parent["tag"] == "dl"), None)
            if definition_list is not None:
                if tag == "dt":
                    definition_list["term"] = element
                elif "term" in definition_list:
                    self.definitions.append((definition_list["term"], element))
        if tag == "h1":
            self.headings.append(tag)
        if tag == "script":
            self.scripts.append(attrs.get("src", ""))
        if tag == "link" and attrs.get("rel") == "canonical":
            self.canonicals.append(attrs.get("href", ""))
        if tag == "meta":
            self.metadata.append(attrs)
            name = attrs.get("name", "").lower()
            if name == "description":
                self.descriptions.append(attrs.get("content", ""))
            if name in ("robots", "googlebot", "bingbot"):
                self.robots.extend(re.split(r"[,\s]+", attrs.get("content", "").lower()))
        if tag not in {"area", "base", "br", "col", "embed", "hr", "img", "input",
                       "link", "meta", "param", "source", "track", "wbr"}:
            self._elements.append(element)

    def handle_endtag(self, tag):
        if tag == "header":
            self.in_header = False
        if tag == "nav":
            self.in_main_navigation = False
        if tag == "footer":
            self.in_footer = False
        for index in range(len(self._elements) - 1, -1, -1):
            if self._elements[index]["tag"] == tag:
                del self._elements[index:]
                break

    def handle_data(self, data):
        self.text.append(data)
        for element in self._elements:
            element["text"].append(data)
        if not any(item["attrs"].get("aria-hidden") == "true" for item in self._elements):
            self.accessible_text.append(data)
            for element in self._elements:
                element["accessible_text"].append(data)

    def control_has_label(self, control):
        attrs = control["attrs"]
        if attrs.get("aria-label", "").strip():
            return True
        labelled_by = attrs.get("aria-labelledby", "").split()
        if labelled_by and all(identifier in self.elements_by_id and
                               "".join(self.elements_by_id[identifier]["text"]).strip()
                               for identifier in labelled_by):
            return True
        wrapping = control["wrapping_label"]
        if wrapping and "".join(wrapping["text"]).strip():
            return True
        return bool(attrs.get("id")) and any(
            label["attrs"].get("for") == attrs["id"] and "".join(label["text"]).strip()
            for label in self.label_elements)


class HierarchyParser(SiteParser):
    """Keep structural ancestry local to semantic grouping checks."""
    def handle_starttag(self, tag, attrs):
        ancestors = tuple(id(parent) for parent in self._elements)
        super().handle_starttag(tag, attrs)
        self.elements[-1]["ancestors"] = ancestors


class DemoEvidenceParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.programs = []
        self.samples = []
        self.capture = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "code" and attrs.get("id") == "demo-full-program":
            self.programs.append("")
            self.capture = (tag, self.programs)
        elif tag == "samp":
            self.samples.append("")
            self.capture = (tag, self.samples)

    def handle_endtag(self, tag):
        if self.capture and tag == self.capture[0]:
            self.capture = None

    def handle_data(self, data):
        if self.capture:
            self.capture[1][-1] += data


class SiteTests(unittest.TestCase):
    def setUp(self):
        self.pages = {}
        for name in PAGES:
            page = SiteParser()
            page.feed((SITE / name).read_text(encoding="utf-8"))
            self.pages[name] = page

    def test_unique_ids_and_existing_accessible_references(self):
        for name, page in self.pages.items():
            with self.subTest(page=name):
                self.assertEqual(len(page.ids), len(set(page.ids)))
                self.assertTrue(set(page.references).issubset(set(page.ids)))
                self.assertEqual(len(page.headings), 1)
                for destination, fragment in page.page_links:
                    self.assertIn(destination, self.pages)
                    if fragment:
                        self.assertIn(fragment, self.pages[destination].ids)

    def test_homepage_focuses_on_search_statistics_and_three_activity_feeds(self):
        page = HierarchyParser()
        page.feed((SITE / "index.html").read_text())
        def within(element, parent): return id(parent) in element["ancestors"]
        def members(parent): return [element for element in page.elements if within(element, parent)]
        def has_class(element, name): return name in element["attrs"].get("class", "").split()
        self.assertNotIn("start", page.elements_by_id)
        for name in ("home-start", "discovery-directory", "discovery-data", "discovery-footer"):
            self.assertFalse(any(has_class(item, name) for item in page.elements), name)
        self.assertNotIn("More ways to explore", "".join(page.text))
        groups = [item for item in page.elements if has_class(item, "discovery-group")]
        self.assertEqual({item["attrs"].get("data-discovery-feed") for item in groups}, {"new", "popular", "updated"})
        for group in groups:
            headers = [item for item in members(group) if has_class(item, "discovery-group-header")]
            self.assertEqual(len(headers), 1)
            heading = page.elements_by_id[group["attrs"]["aria-labelledby"]]
            self.assertEqual(heading["tag"], "h3")
            self.assertTrue(within(heading, headers[0]))
            self.assertEqual(sum(has_class(item, "discovery-group-caption") for item in members(headers[0])), 1)
            actions = [item for item in members(headers[0]) if item["tag"] == "a"]
            self.assertEqual(len(actions), 1)
            self.assertEqual(actions[0]["attrs"]["href"], "browse/" + group["attrs"]["data-discovery-feed"] + "/")
            self.assertTrue(actions[0]["attrs"].get("aria-label", "").startswith("View all "))
        self.assertTrue(any(has_class(item, "discovery-state") for item in page.elements))
        self.assertIn("explore/", page.main_navigation_links)

    def test_search_controls_have_visible_labels(self):
        self.assertTrue(self.pages["index.html"].input_ids)
        for name, page in self.pages.items():
            with self.subTest(page=name):
                for control in page.controls:
                    self.assertTrue(page.control_has_label(control), control["attrs"])

    def test_static_assets_exist_and_stay_local(self):
        for name, page in self.pages.items():
            with self.subTest(page=name):
                for asset in page.assets:
                    self.assertNotIn(":", asset)
                    self.assertTrue((SITE / asset).is_file(), asset)

    def test_no_external_script_dependency(self):
        expected = {"index.html": ["navigation.js", "repository-stars.js", "app.js"],
                    "guide.html": ["navigation.js", "repository-stars.js", "app.js", "package-demo.js"],
                    "sponsors.html": ["navigation.js", "repository-stars.js"]}
        for name, page in self.pages.items():
            with self.subTest(page=name):
                scripts = [item for item in page.elements if item["tag"] == "script"
                           and item["attrs"].get("type") != "application/ld+json"]
                self.assertEqual([item["attrs"] for item in scripts],
                                 [{"src": src, **({} if src == "navigation.js" else {"defer": None})} for src in expected[name]])
                self.assertTrue(all(not "".join(item["text"]).strip() for item in scripts))

    def test_homepage_declares_the_actual_site_name_without_invented_search_or_ratings(self):
        for name, page in self.pages.items():
            data = [item for item in page.elements if item["tag"] == "script"
                    and item["attrs"].get("type") == "application/ld+json"]
            if name != "index.html":
                self.assertEqual(data, [])
                continue
            self.assertEqual(len(data), 1)
            self.assertEqual(data[0]["attrs"], {"type": "application/ld+json"})
            self.assertEqual(json.loads("".join(data[0]["text"])), {
                "@context": "https://schema.org", "@type": "WebSite", "name": "Asm",
                "alternateName": "asm.build", "url": "https://asm.build/"})

    def test_sponsorship_route_is_available_from_project_entry_points(self):
        for name in ("index.html", "guide.html"):
            with self.subTest(page=name):
                self.assertIn("sponsors.html", self.pages[name].footer_links)
                self.assertEqual(self.pages[name].main_navigation_links, ["explore/", "stats/", "blog/", "docs/"])
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn("https://asm.build/sponsors", readme)

    def test_sponsorship_enquiries_work_without_a_payment_provider_or_javascript(self):
        page = self.pages["sponsors.html"]
        self.assertEqual(page.scripts, ["navigation.js", "repository-stars.js"])
        enquiries = [link for link in page.links if "data-sponsor-tier" in link]
        self.assertEqual({link["data-sponsor-tier"] for link in enquiries},
                         {"principal", "lead", "core", "company", "individual"})
        for link in enquiries:
            with self.subTest(tier=link["data-sponsor-tier"]):
                url = urlsplit(link.get("href", ""))
                self.assertEqual(url.scheme, "mailto")
                self.assertEqual(url.path, "jannes.stubbemann@gmail.com")
                subjects = parse_qs(url.query).get("subject", [])
                self.assertEqual(len(subjects), 1)
                self.assertTrue(subjects[0].strip())
                self.assertIn(link["data-sponsor-tier"], subjects[0].lower())
                self.assertNotIn("\r", subjects[0])
                self.assertNotIn("\n", subjects[0])
        self.assertIn("jannes.stubbemann@gmail.com", "".join(page.text))
        for link in page.links:
            self.assertTrue(link.get("href", "").strip())
            self.assertNotIn("github.com/sponsors/stubbi", link["href"])

    def test_demo_source_and_result_are_bound_to_the_recorded_release(self):
        recording = json.loads((SITE / "demo/recording.json").read_bytes())
        source = (SITE / "demo/minimum.s").read_bytes()
        recorded_source = recording["project"]["src/main.s"]
        self.assertEqual(source, recorded_source["text"].encode("utf-8"))
        self.assertEqual(hashlib.sha256(source).hexdigest(), recorded_source["sha256"])

        demo = DemoEvidenceParser()
        demo.feed((SITE / "guide.html").read_text(encoding="utf-8"))
        self.assertEqual(demo.programs, [source.decode("utf-8")])

        provenance = recording["source_provenance"]
        record_path = (ROOT / "registry/packages" / provenance["package"] /
                       (provenance["version"] + ".json"))
        record_bytes = record_path.read_bytes()
        record = json.loads(record_bytes)
        self.assertEqual(provenance["registry_record"], record)
        self.assertEqual(hashlib.sha256(record_bytes).hexdigest(),
                         provenance["registry_record_sha256"])
        source_artifacts = [artifact for artifact in record["artifacts"]
                            if artifact["kind"] == "source"]
        self.assertEqual(len(source_artifacts), 1)
        artifact = source_artifacts[0]
        recorded_artifacts = [item for item in recording["artifacts"].values()
                              if item["url"] == artifact["url"]]
        self.assertEqual(recorded_artifacts, [
            {field: artifact[field] for field in ("url", "sha256", "bytes")}
        ])

        successful_runs = [command for command in recording["commands"]
                           if command["argv"][1:] == ["run", "--locked"]
                           and command["exit"] == 0]
        self.assertTrue(successful_runs)
        self.assertEqual(len(demo.samples), 1)
        for command in successful_runs:
            self.assertEqual(command["stdout"], demo.samples[0] + "\n")
            self.assertEqual(command["stderr"], "")

    def test_github_example_source_links_exist_in_the_checkout(self):
        html = (SITE / "index.html").read_text()
        links = re.findall(r'https://github\.com/stubbi/asm/(?:tree|blob)/main/(examples(?:/[^"#?]+)?)', html)
        self.assertTrue(links)
        for relative in links:
            with self.subTest(source=relative):
                self.assertTrue((ROOT / relative).exists(), f"The source link is missing: {relative}")



class SearchDiscoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="asm-search-tests-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.output = Path(cls.temporary.name) / "site"
        cls.records = registry.read_records(ROOT / "registry")
        names = {record["name"] for record in cls.records}
        owners = {name.split("/")[0] for name in names}
        cls.expected_html = {path.relative_to(SITE).as_posix() for path in SITE.rglob("*.html")}
        cls.expected_html.update({"reference/index.html", "packages/index.html", "404.html",
                                  "browse/popular/index.html", "browse/new/index.html", "browse/updated/index.html",
                                  "discovery/index.html", "browse/categories/developer-tools/index.html",
                                  "browse/categories/examples/index.html", "browse/categories/math/index.html"})
        cls.expected_html.update(f"packages/{owner}/index.html" for owner in owners)
        cls.expected_html.update(f"packages/{name}/index.html" for name in names)
        cls.expected_html.update(f"packages/{record['name']}/{record['version']}/index.html"
                                 for record in cls.records)
        cls.expected_html.update({"explore/index.html", "stats/index.html", "blog/index.html", "docs/index.html",
                                  "blog/articles/index.html", "blog/releases/index.html",
                                  "browse/architectures/index.html", "browse/architectures/aarch64/index.html",
                                  "browse/architectures/x86_64/index.html", "browse/architectures/riscv64/index.html",
                                  "browse/categories/index.html", "browse/keywords/index.html",
                                  "browse/depended-on/index.html", "browse/downloaded/index.html"})
        cls.expected_html.update(f"blog/releases/{record['version']}/index.html" for record in cls.records
                                 if record["name"] == "stubbi/asm")
        metadata = json.loads((ROOT / "registry/discovery-metadata.json").read_text())
        cls.expected_html.update(f"browse/keywords/{tag}/index.html" for package in metadata["packages"]
                                 for tag in package.get("keywords", []))
        cls.expected_html.update(path[:-len("/index.html")] + ".html"
                                 for path in list(cls.expected_html) if path.endswith("/index.html"))
        repo = Path(cls.temporary.name) / "repo"
        repo.mkdir()
        shutil.copytree(SITE, repo / "site")
        shutil.copytree(ROOT / "cli", repo / "cli")
        shutil.copytree(ROOT / "skills/asm-build", repo / "skills/asm-build")
        shutil.copyfile(ROOT / "CHANGELOG.md", repo / "CHANGELOG.md")
        # Source archives have no Git metadata. Record an isolated fixture so
        # the generated reference uses the same exact-commit path in either form.
        for arguments in (("init", "-q"), ("add", "--force", "--", "cli"),
                          ("commit", "-qm", "Record source reference fixture")):
            subprocess.run(["git", "-C", str(repo), "-c", "core.hooksPath=/dev/null",
                            "-c", "commit.gpgSign=false", "-c", "user.name=asm site test fixture",
                            "-c", "user.email=fixture@example.invalid", *arguments],
                           check=True, capture_output=True, timeout=10)

        def forbidden(*args, **kwargs):
            raise AssertionError("Search discovery checks must not use the network")

        build_site.build_site(repo, ROOT / "registry", cls.output,
                              artifact_reader=forbidden, metrics_fetcher=forbidden)
        cls.routes = site_routes.PageRoutes.from_directory(cls.output)
        cls.pages = {}
        for path in sorted(cls.output.rglob("*.html")):
            page = SiteParser()
            page.feed(path.read_text(encoding="utf-8"))
            cls.pages[path.relative_to(cls.output).as_posix()] = page

    def test_discovery_build_keeps_missing_history_unknown_and_generates_native_feeds(self):
        snapshot = registry.strict_json((self.output / "registry/v1/discovery.json").read_bytes())
        self.assertIsNone(snapshot["observed_at"])
        self.assertTrue(all(item["downloads_30d"] is None for item in snapshot["packages"]))
        self.assertEqual(snapshot["feeds"], {"popular": [], "new": [], "updated": []})
        self.assertEqual([item["id"] for item in snapshot["categories"]], ["developer-tools", "examples", "math"])
        for kind in ("popular", "new", "updated"):
            page = (self.output / "browse" / kind / "index.html").read_text()
            self.assertIn("Download data is unavailable", page) if kind == "popular" else self.assertIn("No packages have publication data", page)
            self.assertIn("Browse all packages", page)
        self.assertFalse(list(self.output.rglob("*.sqlite*")))

    def test_optional_metrics_parse_failure_keeps_the_site_available_without_retrying_urls(self):
        calls = []
        def unavailable(url):
            calls.append(url)
            raise ValueError("Malformed optional upstream metadata")
        candidate = Path(self.temporary.name) / "failed-metrics-site"
        state = Path(self.temporary.name) / "failed-metrics.sqlite3"
        build_site.build_site(Path(self.temporary.name) / "repo", ROOT / "registry", candidate, downloads=True,
                              discovery_state=state, publication_state=Path(self.temporary.name) / "publication-adapter.sqlite3",
                              metrics_fetcher=unavailable)
        snapshot = registry.strict_json((candidate / "registry/v1/discovery.json").read_bytes())
        self.assertIsNone(snapshot["observed_at"])
        self.assertTrue(snapshot["stale"])
        self.assertTrue((candidate / "packages/stubbi/math/index.html").exists())
        self.assertEqual(len(calls), len(set(calls)))

    def test_catalog_statistics_are_available_without_scripts_and_match_retained_records(self):
        page = self.pages["index.html"]
        expected = {"Packages": len({record["name"] for record in self.records}),
                    "Releases": len(self.records),
                    "Release files": sum(len(record["artifacts"]) for record in self.records),
                    "Package targets": len({item["target"] for record in self.records for item in record["artifacts"]})}
        for label, value in expected.items():
            with self.subTest(statistic=label):
                self.assertEqual(self.definition_values(page, label), [f"{value:,}"])

    def test_private_discovery_state_cannot_be_written_into_public_sources_or_output(self):
        candidate = Path(self.temporary.name) / "private-state-check"
        for state in (candidate / "state.sqlite3", ROOT / "site/state.sqlite3", ROOT / "skills/asm-build/state.sqlite3"):
            with self.subTest(state=state), self.assertRaisesRegex(registry.RegistryError, "outside published"):
                build_site.build_site(ROOT, ROOT / "registry", candidate, discovery_state=state)

    def test_github_counter_is_one_native_link_on_every_page_and_unknown_is_not_zero(self):
        snapshot = registry.strict_json((self.output / "registry/v1/github.json").read_bytes())
        self.assertIsNone(snapshot["stars"])
        for name, page in self.pages.items():
            with self.subTest(page=name):
                links = [item for item in page.elements if item["tag"] == "a" and
                         "github-stars" in item["attrs"].get("class", "").split()]
                self.assertEqual(len(links), 1)
                self.assertEqual(links[0]["attrs"]["href"], "https://github.com/stubbi/asm")
                self.assertEqual("".join(links[0]["accessible_text"]), "Star on GitHub")

    def test_build_publishes_repository_observation_as_json_without_freezing_header_counts(self):
        state = Path(self.temporary.name) / "github.json"
        candidate = Path(self.temporary.name) / "github-site"
        calls = []
        def fetch(url):
            calls.append(url)
            return {"full_name": "stubbi/asm", "html_url": "https://github.com/stubbi/asm", "stargazers_count": 1250}
        repo = Path(self.temporary.name) / "repo"
        large = repo / "site/large-fixture.html"
        large.write_text((SITE / "index.html").read_text().replace("</body>", "<!--" + "large generated directory " * 50000 + "--></body>"))
        try:
            build_site.build_site(repo, ROOT / "registry", candidate, repository_state=state,
                                  refresh_repository=True, repository_fetcher=fetch)
        finally:
            large.unlink()
        self.assertEqual(calls, ["https://api.github.com/repos/stubbi/asm"])
        snapshot = registry.strict_json((candidate / "registry/v1/github.json").read_bytes())
        self.assertEqual(snapshot["stars"], 1250)
        for path in candidate.rglob("*.html"):
            page = SiteParser()
            page.feed(path.read_text())
            stars = [item for item in page.elements if item["tag"] == "a" and
                     "github-stars" in item["attrs"].get("class", "").split()]
            self.assertEqual(len(stars), 1, path)
            self.assertEqual("".join(stars[0]["accessible_text"]), "Star on GitHub")
            self.assertNotIn('github-stars-count', path.read_text())
        self.assertFalse(list(candidate.rglob("*.sqlite*")))
        private_output = Path(self.temporary.name) / "github-private-check"
        for public in (private_output / "cache.json", ROOT / "site/cache.json", ROOT / "skills/asm-build/cache.json"):
            with self.subTest(path=public), self.assertRaisesRegex(registry.RegistryError, "outside published"):
                build_site.build_site(ROOT, ROOT / "registry", private_output, repository_state=public)

    def test_repository_api_reader_is_bounded_to_the_fixed_canonical_repository(self):
        expected = b'{"full_name":"stubbi/asm","stargazers_count":1200}'
        with patch.object(build_site, "read_https", return_value=expected) as read:
            self.assertEqual(build_site.repository_json("https://api.github.com/repos/stubbi/asm")["stargazers_count"], 1200)
            read.assert_called_once_with("https://api.github.com/repos/stubbi/asm", 256 * 1024, {"api.github.com"})
        for url in ("https://api.github.com/repos/other/repo", "https://api.github.com/repos/stubbi/asm?token=bad",
                    "https://api.github.com/repos/stubbi/asm/stargazers", "https://api.github.com/user"):
            with self.subTest(url=url), self.assertRaises(registry.RegistryError):
                build_site.check_https_url(url, {"api.github.com"})

    def test_repository_articles_publish_but_drafts_and_source_files_stay_outside_normal_output(self):
        repo = Path(self.temporary.name) / "article-repo"
        shutil.copytree(Path(self.temporary.name) / "repo", repo)
        posts = repo / "blog/posts"
        posts.mkdir(parents=True)
        (posts / "public-fixture.md").write_text('''+++
title = "A published repository article"
summary = "An authored article alongside automatic releases."
author = "Asm"
draft = false
date = 2000-01-01
updated = 2000-01-02
+++

## A real body

The repository supplies the article text.
''')
        (posts / "draft-fixture.md").write_text('''+++
title = "Unpublished draft sentinel"
summary = "Unpublished summary sentinel."
author = "Asm"
draft = true
+++

Unpublished body sentinel.
''')
        public = Path(self.temporary.name) / "article-public"
        build_site.build_site(repo, ROOT / "registry", public)
        self.assertTrue((public / "blog/articles/public-fixture/index.html").is_file())
        self.assertFalse((public / "blog/articles/draft-fixture").exists())
        self.assertFalse((public / "blog/posts").exists())
        self.assertFalse(list(public.rglob("*-fixture.md")))
        for path in list(public.rglob("*.html")) + [public / "blog/atom.xml", public / "sitemap.xml"]:
            self.assertNotIn("Unpublished", path.read_text(), path)
        self.assertIn("https://asm.build/blog/articles/public-fixture",
                      [item.text for item in ElementTree.parse(public / "sitemap.xml").findall(
                          "{http://www.sitemaps.org/schemas/sitemap/0.9}url/{http://www.sitemaps.org/schemas/sitemap/0.9}loc")])
        feed = ElementTree.parse(public / "blog/atom.xml").getroot()
        namespace = {"a": "http://www.w3.org/2005/Atom"}
        self.assertEqual(feed.findtext("a:entry/a:id", namespaces=namespace), "https://asm.build/blog/articles/public-fixture/")
        self.assertEqual(feed.findtext("a:entry/a:updated", namespaces=namespace), "2000-01-02T00:00:00Z")
        preview = Path(self.temporary.name) / "article-preview"
        result = build_site.build_site(repo, ROOT / "registry", preview, include_blog_drafts=True)
        self.assertTrue(result["blog_drafts_included"])
        draft = (preview / "blog/articles/draft-fixture/index.html").read_text()
        self.assertIn("Unpublished body sentinel.", draft)
        self.assertIn('name="robots" content="noindex"', draft)
        self.assertNotIn("draft-fixture", (preview / "blog/atom.xml").read_text())
        self.assertNotIn("draft-fixture", (preview / "sitemap.xml").read_text())
        for path in (preview / "blog").rglob("*.html"):
            self.assertIn('name="robots" content="noindex"', path.read_text(), path)
        (posts / "invalid-fixture.md").write_text('+++\ntitle = "Missing metadata"\n+++\nText.')
        invalid = Path(self.temporary.name) / "article-invalid"
        with self.assertRaisesRegex(registry.RegistryError, r"blog/posts/invalid-fixture\.md:.*blog/README\.md"):
            build_site.build_site(repo, ROOT / "registry", invalid)
        self.assertFalse(invalid.exists())
        self.assertTrue((public / "blog/articles/public-fixture/index.html").is_file())

    @classmethod
    def normalized_url(cls, base, value):
        url = urlsplit(urljoin(base, value))
        path = url.path
        if url.netloc == "asm.build":
            path = cls.routes.canonical_path(path)
        return url._replace(path=path).geturl()

    @staticmethod
    def canonical_url(path):
        path = path[:-len("index.html")] if path.endswith("index.html") else path[:-len(".html")]
        return "https://asm.build/" + path.rstrip("/")

    def link_urls(self, page, elements=None):
        base = page.canonicals[0]
        links = page.links if elements is None else [element["attrs"] for element in elements]
        return {self.normalized_url(base, link["href"]) for link in links}

    @staticmethod
    def definition_values(page, name):
        return [" ".join("".join(value["accessible_text"]).split()) for term, value in page.definitions
                if " ".join("".join(term["text"]).split()) == name]

    def test_every_built_page_has_complete_landmarks_and_accessible_controls(self):
        self.assertEqual(set(self.pages), self.expected_html)
        for name, page in self.pages.items():
            with self.subTest(page=name):
                self.assertEqual(page.main_ids, ["main"])
                self.assertEqual(page.header_count, 1)
                self.assertEqual(page.footer_count, 1)
                self.assertEqual(len(page.skip_links), 1)
                self.assertEqual(page.skip_links[0]["attrs"].get("href"), "#main")
                self.assertEqual(len(page.headings), 1)
                self.assertEqual(len(page.ids), len(set(page.ids)))
                for identifier in page.ids:
                    self.assertRegex(identifier, r"\A[A-Za-z][A-Za-z0-9_-]*\Z")
                self.assertTrue(set(page.references).issubset(page.ids),
                                set(page.references) - set(page.ids))
                for control in page.controls:
                    self.assertTrue(page.control_has_label(control), control["attrs"])
                for button in page.buttons:
                    attrs = button["attrs"]
                    self.assertIn(attrs.get("type"), {"button", "submit", "reset"})
                    if "data-copy" in attrs:
                        target = page.elements_by_id.get(attrs["data-copy"])
                        self.assertIsNotNone(target, attrs)
                        self.assertEqual(target["tag"], "code")
                        self.assertEqual(page.elements_by_id["copy-status"]["attrs"].get("role"), "status")

    def test_every_built_page_resolves_its_local_links_assets_and_fragments(self):
        for name, page in self.pages.items():
            self.assertEqual(len(page.canonicals), 1, name)
            base = page.canonicals[0]
            self.assertEqual(base, self.canonical_url(name), name)
            for asset in page.assets:
                url = urlsplit(urljoin(base, asset))
                self.assertEqual((url.scheme, url.netloc), ("https", "asm.build"), (name, asset))
            for value in [*page.assets, *(link.get("href", "") for link in page.links)]:
                with self.subTest(page=name, reference=value):
                    self.assertTrue(value.strip())
                    url = urlsplit(urljoin(base, value))
                    if url.netloc != "asm.build":
                        self.assertIn(url.scheme, {"https", "mailto"})
                        continue
                    self.assertEqual(url.scheme, "https")
                    relative = self.routes.file_for(unquote(url.path))
                    if relative is not None:
                        self.assertEqual(url.path, self.routes.canonical_path(url.path), (name, value))
                    path = (self.output / (relative if relative is not None else unquote(url.path).lstrip("/"))).resolve()
                    self.assertTrue(path.is_relative_to(self.output.resolve()))
                    if path.is_dir():
                        path /= "index.html"
                    self.assertTrue(path.is_file(), value)
                    if url.fragment and path.suffix == ".html":
                        destination = path.relative_to(self.output.resolve()).as_posix()
                        fragment = url.fragment
                        if fragment.startswith("from="):
                            context = parse_qs(fragment, strict_parsing=True)
                            self.assertEqual(set(context), {"from"})
                            self.assertEqual(len(context["from"]), 1)
                            self.assertTrue(context["from"][0].startswith("#search?"))
                            self.assertTrue(destination.startswith("packages/"))
                            fragment = context["from"][0][1:]
                        if fragment.startswith("search?"):
                            if not url.fragment.startswith("from="):
                                self.assertEqual(destination, "index.html")
                            state = parse_qs(fragment[7:], keep_blank_values=True, strict_parsing=True)
                            self.assertIn(state.get("architecture"), [["aarch64"], ["x86_64"], ["riscv64"]])
                            self.assertEqual(state, {"architecture": state["architecture"], "all": ["1"]})
                        else:
                            self.assertIn(unquote(fragment), self.pages[destination].ids)

    def test_shared_navigation_brand_and_styles_remain_consistent_on_every_page(self):
        def label(element):
            return element["attrs"].get("aria-label") or " ".join("".join(element["text"]).split())

        def signature(page):
            base = page.canonicals[0]
            links = lambda elements: [(label(item), self.normalized_url(base, item["attrs"]["href"]))
                                      for item in elements]
            brands = lambda items: [(
                self.normalized_url(base, item["anchor"]["href"]), item["anchor"].get("aria-label"),
                self.normalized_url(base, item["image"]["src"]), item["image"].get("alt"),
                item["image"].get("width"), item["image"].get("height")) for item in items]
            return (links(page.main_navigation), links(page.footer_link_elements),
                    page.footer_navigation_labels, brands(page.header_brands), brands(page.footer_brands))

        expected = signature(self.pages["index.html"])
        expected_theme = [meta.get("content") for meta in self.pages["index.html"].metadata
                          if meta.get("name") == "theme-color"]
        self.assertTrue(expected[0])
        self.assertTrue(expected[1])
        self.assertEqual(len(expected_theme), 1)
        for name, page in self.pages.items():
            with self.subTest(page=name):
                self.assertEqual(signature(page), expected)
                self.assertEqual(len(page.header_brands), 1)
                self.assertEqual(len(page.footer_brands), 1)
                self.assertTrue(all(page.footer_navigation_labels))
                base = page.canonicals[0]
                self.assertEqual([self.normalized_url(base, path) for path in page.stylesheets
                                  if path.endswith("styles.css")], ["https://asm.build/styles.css"])
                self.assertEqual([self.normalized_url(base, path) for path in page.icons],
                                 ["https://asm.build/icon.svg"])
                self.assertEqual([meta.get("content") for meta in page.metadata
                                  if meta.get("name") == "theme-color"], expected_theme)
                self.assertEqual([meta.get("content") for meta in page.metadata
                                  if meta.get("property") == "og:url"], [base])
                descriptions = [meta.get("content", "") for meta in page.metadata
                                if meta.get("property") == "og:description"]
                self.assertEqual(len(descriptions), 1)
                self.assertTrue(descriptions[0].strip())

    def test_every_page_has_one_labeled_header_search_and_native_catalog_fallback(self):
        for name, page in self.pages.items():
            with self.subTest(page=name):
                forms = [item for item in page.elements if item["tag"] == "form"
                         and "data-header-search" in item["attrs"]]
                self.assertEqual(len(forms), 1)
                attrs = forms[0]["attrs"]
                self.assertIn("hidden", attrs)
                self.assertEqual(attrs.get("role"), "search")
                self.assertEqual(attrs.get("aria-label"), "Package search")
                self.assertEqual(self.normalized_url(page.canonicals[0], attrs["action"]),
                                 "https://asm.build/")
                field = page.elements_by_id["header-package-search"]
                self.assertEqual(field["attrs"].get("maxlength"), "512")
                self.assertEqual(field["attrs"].get("type"), "search")
                self.assertTrue(any(label["attrs"].get("for") == "header-package-search"
                                    and "".join(label["text"]).strip() == "Search"
                                    for label in page.label_elements))
                fallback = [item for item in page.elements if item["tag"] == "a"
                            and "data-header-search-fallback" in item["attrs"]]
                self.assertEqual(len(fallback), 1)
                self.assertNotIn("hidden", fallback[0]["attrs"])
                self.assertEqual(self.normalized_url(page.canonicals[0], fallback[0]["attrs"]["href"]),
                                 "https://asm.build/packages")
                scripts = [item for item in page.elements if item["tag"] == "script"
                           and item["attrs"].get("src", "").endswith("navigation.js")]
                self.assertEqual(len(scripts), 1)
                self.assertEqual(set(scripts[0]["attrs"]), {"src"})
                self.assertEqual(self.normalized_url(page.canonicals[0], scripts[0]["attrs"]["src"]),
                                 "https://asm.build/navigation.js")
                stars_scripts = [item for item in page.elements if item["tag"] == "script"
                                 and item["attrs"].get("src", "").endswith("repository-stars.js")]
                self.assertEqual(len(stars_scripts), 1)
                self.assertEqual(set(stars_scripts[0]["attrs"]), {"src", "defer"})
                self.assertEqual(self.normalized_url(page.canonicals[0], stars_scripts[0]["attrs"]["src"]),
                                 "https://asm.build/repository-stars.js")
                head = (self.output / name).read_text().split("</head>")[0]
                self.assertIn('navigation.js"', head)
                self.assertLess(head.index('navigation.js"'), head.index('repository-stars.js"'))

    def test_catalog_namespaces_and_package_history_have_static_permalinks(self):
        catalog = self.pages["packages/index.html"]
        self.assertEqual(catalog.canonicals, ["https://asm.build/packages"])
        home = self.pages["index.html"]
        self.assertIn("https://asm.build/packages", self.link_urls(home, home.main_links))
        by_name = {}
        for record in self.records:
            by_name.setdefault(record["name"], []).append(record)
        for name, records in by_name.items():
            owner = name.split("/")[0]
            overview_path = f"packages/{name}/index.html"
            overview_url = self.canonical_url(overview_path)
            overview = self.pages[overview_path]
            namespace = self.pages[f"packages/{owner}/index.html"]
            with self.subTest(package=name):
                self.assertEqual(overview.canonicals, [overview_url])
                self.assertIn(overview_url, self.link_urls(catalog, catalog.main_links))
                self.assertIn(overview_url, self.link_urls(namespace, namespace.main_links))
                self.assertIn(self.canonical_url(f"packages/{owner}/index.html"), self.link_urls(overview))
                active = [record for record in records if not record["yanked"]]
                if active:
                    latest = max(active, key=lambda record: registry.version_tuple(record["version"]))
                    self.assertIn(latest["version"], "".join(overview.text))
                    self.assertIn(latest["summary"], "".join(catalog.text))
                for record in records:
                    self.assertIn(self.canonical_url(f"packages/{name}/{record['version']}/index.html"),
                                  self.link_urls(overview, overview.main_links))

    def test_version_pages_bind_exact_release_metadata_and_records(self):
        by_name = {}
        for record in self.records:
            by_name.setdefault(record["name"], []).append(record)
        for record in self.records:
            name, version = record["name"], record["version"]
            page_path = f"packages/{name}/{version}/index.html"
            page = self.pages[page_path]
            with self.subTest(package=name, version=version):
                self.assertEqual(page.canonicals, [self.canonical_url(page_path)])
                self.assertEqual(self.definition_values(page, "Version"), [version])
                self.assertEqual(self.definition_values(page, "License"), [record["license"]])
                summaries = ["".join(element["text"]).strip() for element in page.elements
                             if "package-summary" in element["attrs"].get("class", "").split()]
                self.assertEqual(summaries, [record["summary"]])
                self.assertEqual(self.definition_values(page, "Source commit"), [record["source"]["commit"]])
                self.assertEqual(self.definition_values(page, "Source path"), [record["source"]["path"]])
                links = self.link_urls(page)
                self.assertIn(record["source"]["repository"], links)
                raw_record_url = f"https://asm.build/registry/v1/packages/{name}/{version}.json"
                self.assertIn(raw_record_url, links)
                self.assertEqual(json.loads((self.output / f"registry/v1/packages/{name}/{version}.json").read_bytes()),
                                 record)
                self.assertIn(self.canonical_url(f"packages/{name}/index.html"), links)
                for release in by_name[name]:
                    self.assertIn(self.canonical_url(f"packages/{name}/{release['version']}/index.html"), links)
                text = "".join(page.text)
                for artifact in record["artifacts"]:
                    self.assertIn(artifact["target"], text)
                    self.assertIn(artifact["sha256"], text)
                    # This isolated build has not checked artifact bytes.
                    self.assertNotIn(artifact["url"], links)

    def test_missing_route_page_has_native_recovery_without_search_scripts(self):
        page = self.pages["404.html"]
        self.assertEqual(page.canonicals, ["https://asm.build/404"])
        self.assertIn("noindex", page.robots)
        links = self.link_urls(page, page.main_links)
        self.assertIn("https://asm.build/", links)
        self.assertIn("https://asm.build/packages", links)

    def test_sitemap_urls_have_html_metadata_and_allow_crawling(self):
        sitemap = ElementTree.parse(self.output / "sitemap.xml")
        namespace = "{http://www.sitemaps.org/schemas/sitemap/0.9}"
        self.assertEqual(sitemap.getroot().tag, namespace + "urlset")
        locations = [item.text for item in sitemap.findall(f"{namespace}url/{namespace}loc")]
        expected = {self.canonical_url(path) for path in self.expected_html if path != "404.html"}
        self.assertEqual(set(locations), expected)
        self.assertEqual(len(locations), len(expected))
        robots = RobotFileParser()
        robots.parse((self.output / "robots.txt").read_text(encoding="utf-8").splitlines())
        self.assertEqual(robots.site_maps(), ["https://asm.build/sitemap.xml"])
        for location in locations:
            with self.subTest(url=location):
                url = urlsplit(location)
                self.assertEqual((url.scheme, url.netloc, url.query, url.fragment),
                                 ("https", "asm.build", "", ""))
                page = SiteParser()
                relative = self.routes.file_for(url.path)
                self.assertIsNotNone(relative, location)
                path = self.output / relative
                page.feed(path.read_text(encoding="utf-8"))
                self.assertEqual(page.canonicals, [location])
                self.assertEqual(len(page.descriptions), 1)
                self.assertTrue(page.descriptions[0].strip())
                self.assertTrue({"noindex", "none", "nofollow"}.isdisjoint(page.robots))
                for crawler in ("Googlebot", "bingbot", "*"):
                    self.assertTrue(robots.can_fetch(crawler, location))
        for path in ("/styles.css", "/app.js", "/registry/v1/index.json"):
            self.assertTrue(robots.can_fetch("Googlebot", "https://asm.build" + path))

    def test_indexable_metadata_is_unique_and_uses_the_prose_brand_and_pipe_separator(self):
        titles, descriptions = set(), set()
        for entry in self.routes.pages.values():
            name = entry["file"].as_posix()
            page = self.pages[name]
            if "noindex" in page.robots:
                continue
            title = next("".join(item["text"]) for item in page.elements if item["tag"] == "title")
            self.assertTrue(title.endswith(" | Asm"), (name, title))
            self.assertFalse(any(character in title for character in ("\u2013", "\u2014")), name)
            self.assertNotIn(title, titles, (name, title))
            titles.add(title)
            description = page.descriptions[0]
            self.assertNotIn(description, descriptions, (name, description))
            descriptions.add(description)
            self.assertEqual([item.get("content") for item in page.metadata
                              if item.get("property") == "og:site_name"], ["Asm"])

    def test_every_built_head_describes_the_shared_image_and_discovers_the_native_blog_feed(self):
        image = (self.output / "social-preview.png").read_bytes()
        self.assertEqual(image[:8], b"\x89PNG\r\n\x1a\n")
        dimensions = (int.from_bytes(image[16:20], "big"), int.from_bytes(image[20:24], "big"))
        self.assertEqual(dimensions, (1280, 640))
        feed_path = self.output / "blog/atom.xml"
        feed = ElementTree.parse(feed_path).getroot()
        self.assertEqual(feed.tag, "{http://www.w3.org/2005/Atom}feed")
        self.assertEqual(feed.findtext("{http://www.w3.org/2005/Atom}title"), "Asm blog")
        for name, page in self.pages.items():
            with self.subTest(page=name):
                head = SiteParser()
                head.feed((self.output / name).read_text(encoding="utf-8").split("</head>", 1)[0])

                def values(attribute, key):
                    return [item.get("content") for item in head.metadata if item.get(attribute) == key]

                self.assertEqual(values("property", "og:image"), ["https://asm.build/social-preview.png"])
                self.assertEqual(values("property", "og:image:type"), ["image/png"])
                self.assertEqual(values("property", "og:image:width"), [str(dimensions[0])])
                self.assertEqual(values("property", "og:image:height"), [str(dimensions[1])])
                self.assertEqual(values("name", "twitter:image"), ["https://asm.build/social-preview.png"])
                image_alts = values("property", "og:image:alt")
                self.assertEqual(len(image_alts), 1)
                self.assertTrue(image_alts[0].strip())
                self.assertEqual(values("name", "twitter:image:alt"), image_alts)
                feeds = [element["attrs"] for element in head.elements if element["tag"] == "link"
                         and element["attrs"].get("rel") == "alternate"
                         and element["attrs"].get("type") == "application/atom+xml"]
                self.assertEqual(len(feeds), 1)
                self.assertEqual(feeds[0].get("title"), "Asm blog")
                self.assertEqual(urljoin(page.canonicals[0], feeds[0]["href"]),
                                 "https://asm.build/blog/atom.xml")

    def test_security_contact_is_published_unchanged_with_a_current_expiry(self):
        path = ".well-known/security.txt"
        content = (self.output / path).read_bytes()
        self.assertEqual(content, (SITE / path).read_bytes())
        self.assertTrue(content.endswith(b"\n"))
        fields = dict(line.split(": ", 1) for line in content.decode("utf-8").splitlines())
        policy = (ROOT / "SECURITY.md").read_text()
        self.assertIn(fields["Contact"], policy)
        self.assertEqual(fields["Canonical"], "https://asm.build/" + path)
        self.assertEqual(fields["Policy"], "https://github.com/stubbi/asm/blob/main/SECURITY.md")
        self.assertEqual(fields["Preferred-Languages"], "en")
        expires = datetime.fromisoformat(fields["Expires"].replace("Z", "+00:00"))
        self.assertGreater(expires, datetime.now(timezone.utc), "Review the security contact before renewing its expiry")

    def test_unreviewed_hidden_assets_cannot_reach_site_publication(self):
        repo = self.output.parent / "repo"
        for name in (".internal.txt", ".well-known/unreviewed.txt", "public/.private/data.txt"):
            with self.subTest(path=name):
                source = repo / "site" / name
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text("Synthetic private fixture.\n")
                try:
                    destination = self.output.parent / "hidden-asset-output"
                    with patch.object(build_site, "publish_directory", side_effect=AssertionError("Unreviewed hidden asset reached publication")):
                        with self.assertRaisesRegex(registry.RegistryError, "unreviewed hidden site path"):
                            build_site.build_site(repo, ROOT / "registry", destination)
                    self.assertFalse(destination.exists())
                finally:
                    source.unlink()
                    while source.parent != repo / "site" and not any(source.parent.iterdir()):
                        source.parent.rmdir()
                        source = source.parent

    def test_indexnow_ownership_file_is_published_with_exact_utf8_content(self):
        keys = [path for path in SITE.iterdir() if re.fullmatch(r"[0-9a-f]{32}\.txt", path.name)]
        self.assertEqual(len(keys), 1)
        key_file = keys[0]
        self.assertEqual(key_file.read_bytes(), key_file.stem.encode("utf-8"))
        self.assertEqual((self.output / key_file.name).read_bytes(), key_file.read_bytes())

    def test_site_build_writes_full_and_compatible_native_feeds(self):
        registry = build_site.registry
        full, _ = registry.make_indexes(registry.read_records(ROOT / "registry"))
        feeds = self.output / "registry/v1"
        self.assertTrue((feeds / "index-all.tsv").is_file(), "The full native feed is missing")
        self.assertEqual((feeds / "index-all.tsv").read_bytes(), full.encode("ascii"))
        self.assertEqual((feeds / "index.tsv").read_bytes(), registry.legacy_tsv(full).encode("ascii"))
        self.assertEqual((feeds / "index-macos.tsv").read_bytes(),
                         registry.macos_compat_tsv(full).encode("ascii"))



if __name__ == "__main__":
    unittest.main()
