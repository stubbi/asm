"""Static checks for accessible references and local website assets."""

from html.parser import HTMLParser
from pathlib import Path
import re
import sys
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit
from urllib.robotparser import RobotFileParser
from xml.etree import ElementTree


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"
PAGES = ("index.html", "sponsors.html")
sys.path.insert(0, str(ROOT / "tools"))
import build_site
from site_fixtures import reference_repo


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
        self.in_main_navigation = False
        self.in_footer = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "nav" and attrs.get("aria-label") == "Main navigation":
            self.in_main_navigation = True
        if tag == "footer":
            self.in_footer = True
        if "id" in attrs:
            self.ids.append(attrs["id"])
        if tag == "a" and attrs.get("href", "").startswith("#") and attrs["href"] != "#":
            self.references.append(attrs["href"][1:])
        if tag == "a":
            self.links.append(attrs)
            if self.in_main_navigation:
                self.main_navigation_links.append(attrs.get("href", ""))
            if self.in_footer:
                self.footer_links.append(attrs.get("href", ""))
            url = urlsplit(attrs.get("href", ""))
            if not url.scheme and not url.netloc and url.path in PAGES:
                self.page_links.append((url.path, url.fragment))
        for key in ("aria-labelledby", "aria-controls"):
            self.references.extend(attrs.get(key, "").split())
        if tag in ("script", "img") and "src" in attrs:
            self.assets.append(attrs["src"])
        if tag == "link" and attrs.get("rel") in ("stylesheet", "icon"):
            self.assets.append(attrs["href"])
        if tag in ("input", "select"):
            self.input_ids.append(attrs.get("id"))
        if tag == "label":
            self.labels.append(attrs.get("for"))
        if tag == "h1":
            self.headings.append(tag)
        if tag == "script":
            self.scripts.append(attrs.get("src", ""))
        if tag == "link" and attrs.get("rel") == "canonical":
            self.canonicals.append(attrs.get("href", ""))
        if tag == "meta":
            name = attrs.get("name", "").lower()
            if name == "description":
                self.descriptions.append(attrs.get("content", ""))
            if name in ("robots", "googlebot", "bingbot"):
                self.robots.extend(re.split(r"[,\s]+", attrs.get("content", "").lower()))

    def handle_endtag(self, tag):
        if tag == "nav":
            self.in_main_navigation = False
        if tag == "footer":
            self.in_footer = False

    def handle_data(self, data):
        self.text.append(data)


class SiteTests(unittest.TestCase):
    def setUp(self):
        self.pages = {}
        for name in PAGES:
            page = SiteParser()
            page.feed((SITE / name).read_text(encoding="utf-8"))
            self.pages[name] = page
        self.page = self.pages["index.html"]

    def test_unique_ids_and_existing_accessible_references(self):
        for name, page in self.pages.items():
            with self.subTest(page=name):
                self.assertEqual(len(page.ids), len(set(page.ids)))
                self.assertTrue(set(page.references).issubset(set(page.ids)))
                self.assertEqual(len(page.headings), 1)
                for destination, fragment in page.page_links:
                    if fragment:
                        self.assertIn(fragment, self.pages[destination].ids)

    def test_github_example_source_links_exist_in_the_checkout(self):
        html = (SITE / "index.html").read_text()
        links = re.findall(r'https://github\.com/stubbi/asm/(?:tree|blob)/main/(examples/[^"#?]+)', html)
        self.assertTrue(links)
        for relative in links:
            with self.subTest(source=relative):
                self.assertTrue((ROOT / relative).exists(), f"The source link is missing: {relative}")

    def test_search_controls_have_visible_labels(self):
        self.assertTrue(self.page.input_ids)
        self.assertTrue(set(self.page.input_ids).issubset(set(self.page.labels)))

    def test_static_assets_exist_and_stay_local(self):
        for name, page in self.pages.items():
            with self.subTest(page=name):
                for asset in page.assets:
                    self.assertNotIn(":", asset)
                    self.assertTrue((SITE / asset).is_file(), asset)

    def test_no_external_script_dependency(self):
        self.assertTrue(self.page.scripts)
        for name, page in self.pages.items():
            with self.subTest(page=name):
                for script in page.scripts:
                    self.assertFalse(script.startswith(("http:", "https:", "//")))

    def test_sponsorship_route_is_available_from_project_entry_points(self):
        self.assertIn("sponsors.html", self.page.main_navigation_links)
        self.assertIn("sponsors.html", self.page.footer_links)
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn("https://asm.build/sponsors.html", readme)

    def test_sponsorship_enquiries_work_without_a_payment_provider_or_javascript(self):
        page = self.pages["sponsors.html"]
        self.assertEqual(page.scripts, [])
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
            url = urlsplit(link["href"])
            if not url.scheme and not url.netloc and url.path:
                self.assertTrue((SITE / url.path).is_file(), link["href"])


class SearchDiscoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="asm-search-tests-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.output = Path(cls.temporary.name) / "site"
        repo = reference_repo(ROOT, Path(cls.temporary.name) / "repo")

        def forbidden(*args, **kwargs):
            raise AssertionError("Search discovery checks must not use the network")

        build_site.build_site(repo, ROOT / "registry", cls.output,
                              artifact_reader=forbidden, metrics_fetcher=forbidden)

    def test_site_build_writes_full_and_compatible_native_feeds(self):
        registry = build_site.registry
        full, _ = registry.make_indexes(registry.read_records(ROOT / "registry"))
        feeds = self.output / "registry/v1"
        self.assertTrue((feeds / "index-all.tsv").is_file(), "The full native feed is missing")
        self.assertEqual((feeds / "index-all.tsv").read_bytes(), full.encode("ascii"))
        self.assertEqual((feeds / "index.tsv").read_bytes(), registry.legacy_tsv(full).encode("ascii"))
        self.assertEqual((feeds / "index-macos.tsv").read_bytes(),
                         registry.macos_compat_tsv(full).encode("ascii"))

    def test_sitemap_urls_have_html_metadata_and_allow_crawling(self):
        sitemap = ElementTree.parse(self.output / "sitemap.xml")
        namespace = "{http://www.sitemaps.org/schemas/sitemap/0.9}"
        self.assertEqual(sitemap.getroot().tag, namespace + "urlset")
        locations = [item.text for item in sitemap.findall(f"{namespace}url/{namespace}loc")]
        self.assertEqual(locations, ["https://asm.build/", "https://asm.build/sponsors.html",
                                     "https://asm.build/reference/"])
        robots = RobotFileParser()
        robots.parse((self.output / "robots.txt").read_text(encoding="utf-8").splitlines())
        self.assertEqual(robots.site_maps(), ["https://asm.build/sitemap.xml"])
        for location in locations:
            with self.subTest(url=location):
                url = urlsplit(location)
                self.assertEqual((url.scheme, url.netloc, url.query, url.fragment),
                                 ("https", "asm.build", "", ""))
                page = SiteParser()
                path = self.output / url.path.lstrip("/")
                if url.path.endswith("/"):
                    path /= "index.html"
                page.feed(path.read_text(encoding="utf-8"))
                self.assertEqual(page.canonicals, [location])
                self.assertEqual(len(page.descriptions), 1)
                self.assertTrue(page.descriptions[0].strip())
                self.assertTrue({"noindex", "none", "nofollow"}.isdisjoint(page.robots))
                for crawler in ("Googlebot", "bingbot", "*"):
                    self.assertTrue(robots.can_fetch(crawler, location))
        for path in ("/styles.css", "/app.js", "/registry/v1/index.json"):
            self.assertTrue(robots.can_fetch("Googlebot", "https://asm.build" + path))

    def test_indexnow_ownership_file_is_published_with_exact_utf8_content(self):
        keys = [path for path in SITE.iterdir() if re.fullmatch(r"[0-9a-f]{32}\.txt", path.name)]
        self.assertEqual(len(keys), 1)
        key_file = keys[0]
        self.assertEqual(key_file.read_bytes(), key_file.stem.encode("utf-8"))
        self.assertEqual((self.output / key_file.name).read_bytes(), key_file.read_bytes())


if __name__ == "__main__":
    unittest.main()
