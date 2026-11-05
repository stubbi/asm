"""Static checks for accessible references and local website assets."""

from html.parser import HTMLParser
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import urlsplit
from urllib.robotparser import RobotFileParser
from xml.etree import ElementTree


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"
sys.path.insert(0, str(ROOT / "tools"))
import build_site


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

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.append(attrs["id"])
        if tag == "a" and attrs.get("href", "").startswith("#") and attrs["href"] != "#":
            self.references.append(attrs["href"][1:])
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


class SiteTests(unittest.TestCase):
    def setUp(self):
        self.page = SiteParser()
        self.page.feed((SITE / "index.html").read_text())

    def test_unique_ids_and_existing_accessible_references(self):
        self.assertEqual(len(self.page.ids), len(set(self.page.ids)))
        self.assertTrue(set(self.page.references).issubset(set(self.page.ids)))
        self.assertEqual(len(self.page.headings), 1)

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
        for asset in self.page.assets:
            self.assertNotIn(":", asset)
            self.assertTrue((SITE / asset).is_file(), asset)

    def test_no_external_script_dependency(self):
        self.assertTrue(self.page.scripts)
        for script in self.page.scripts:
            self.assertFalse(script.startswith(("http:", "https:", "//")))


class SearchDiscoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="asm-search-tests-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.output = Path(cls.temporary.name) / "site"
        repo = Path(cls.temporary.name) / "repo"
        repo.mkdir()
        shutil.copytree(SITE, repo / "site")
        shutil.copytree(ROOT / "skills/asm-build", repo / "skills/asm-build")
        shutil.copytree(ROOT / "cli", repo / "cli")
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

    def test_sitemap_urls_have_html_metadata_and_allow_crawling(self):
        sitemap = ElementTree.parse(self.output / "sitemap.xml")
        namespace = "{http://www.sitemaps.org/schemas/sitemap/0.9}"
        self.assertEqual(sitemap.getroot().tag, namespace + "urlset")
        locations = [item.text for item in sitemap.findall(f"{namespace}url/{namespace}loc")]
        self.assertEqual(locations, ["https://asm.build/", "https://asm.build/reference/"])
        robots = RobotFileParser()
        robots.parse((self.output / "robots.txt").read_text(encoding="utf-8").splitlines())
        self.assertEqual(robots.site_maps(), ["https://asm.build/sitemap.xml"])
        for location in locations:
            with self.subTest(url=location):
                url = urlsplit(location)
                self.assertEqual((url.scheme, url.netloc, url.query, url.fragment),
                                 ("https", "asm.build", "", ""))
                page = SiteParser()
                page.feed((self.output / url.path.lstrip("/") / "index.html").read_text(encoding="utf-8"))
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
