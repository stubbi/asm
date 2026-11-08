"""Clean page links retain native aliases, private fragments, and raw assets.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from html.parser import HTMLParser
import importlib
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry


class Links(HTMLParser):
    def __init__(self, content):
        super().__init__()
        self.tags = []
        self.feed(content)

    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, dict(attrs)))


class SiteRoutesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.stage = Path(temporary.name) / "site"
        self.stage.mkdir()
        self.write("index.html", '<link rel="canonical" href="https://asm.build/"><a href="docs/">Docs</a>')
        self.write("docs/index.html", '<link rel="canonical" href="https://asm.build/docs/"><a href="../index.html#search?q=asm&amp;all=1">Search</a><script src="../app.js"></script>')
        self.write("guide.html", '<a href="index.html">Home</a>')
        self.write("packages/owner/name/0.6.0/index.html", '<link rel="canonical" href="https://asm.build/packages/owner/name/0.6.0/">')

    def write(self, relative, content):
        path = self.stage / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def routes(self):
        self.assertTrue((ROOT / "tools/site_routes.py").exists(), "The canonical page route helper is missing")
        self.module = importlib.import_module("site_routes")
        return self.module.PageRoutes.from_directory(self.stage)

    def test_architecture_page_spelling_preserves_machine_ids_and_all_legacy_urls(self):
        legacy = "browse/architectures/x86_64/index.html"
        self.write(legacy, '<link rel="canonical" href="https://asm.build/browse/architectures/x86_64/">'
                   '<a href="../../../index.html#search?architecture=x86_64&amp;all=1">Search</a>'
                   '<a href="../../../registry/v1/x86_64.json">Record</a><code>x86_64</code>')
        routes = self.routes(); routes.export(self.stage)
        content = (self.stage / legacy).read_text()
        self.assertIn('href="https://asm.build/browse/architectures/x86-64"', content)
        self.assertIn('#search?architecture=x86_64&amp;all=1', content)
        self.assertIn('registry/v1/x86_64.json', content)
        self.assertIn('<code>x86_64</code>', content)
        self.assertEqual((self.stage / 'browse/architectures/x86-64.html').read_text(), content)
        self.assertEqual((self.stage / 'browse/architectures/x86_64.html').read_text(), content)
        for spelling in ('x86_64', 'x86-64'):
            for suffix in ('', '/', '.html', '/index.html'):
                with self.subTest(spelling=spelling, suffix=suffix):
                    self.assertEqual(routes.canonical_path('/browse/architectures/' + spelling + suffix),
                                     '/browse/architectures/x86-64')
                    self.assertEqual(routes.file_for('/browse/architectures/' + spelling + suffix), Path(legacy))
        self.routes().export(self.stage)
        self.assertEqual((self.stage / legacy).read_text(), content)

    def test_native_clean_pages_and_legacy_aliases_share_working_content(self):
        routes = self.routes()
        routes.export(self.stage)
        for alias in ("/docs", "/docs/", "/docs/index.html", "/docs.html"):
            with self.subTest(alias=alias):
                self.assertEqual(routes.canonical_path(alias), "/docs")
                self.assertEqual(routes.legacy_path(alias), "/docs/")
                self.assertEqual(routes.file_for(alias), Path("docs/index.html"))
        self.assertEqual(routes.canonical_path("/index.html"), "/")
        self.assertEqual(routes.canonical_path("/guide.html"), "/guide")
        self.assertEqual(routes.canonical_path("/packages/owner/name/0.6.0/"), "/packages/owner/name/0.6.0")
        self.assertEqual(routes.canonical_path("/missing/"), "/missing/")
        self.assertIsNone(routes.file_for("/registry/v1/index.json"))
        self.assertEqual((self.stage / "docs.html").read_bytes(), (self.stage / "docs/index.html").read_bytes())
        self.assertTrue((self.stage / "packages/owner/name/0.6.0.html").is_file())
        tags = Links((self.stage / "docs.html").read_text()).tags
        self.assertIn(("link", {"rel": "canonical", "href": "https://asm.build/docs"}), tags)
        self.assertIn(("a", {"href": "/#search?q=asm&all=1"}), tags)
        self.assertIn(("script", {"src": "/app.js"}), tags)

    def test_relative_urls_use_the_original_page_base_and_fragments_stay_private(self):
        routes = self.routes()
        content = '''<meta property="og:url" content="https://asm.build/packages/owner/name/0.6.0/">
<a data-package-link href="../../../../docs/index.html#from=%23search%3Fq%3Da%2526b">Docs</a>
<a href="#readme">Readme</a><form action="../../../../index.html"></form>
<img src="../../../../icon.svg"><div data-activity-url="../../../../registry/v1/activity/owner/name/0.6.0.json" data-downloads-version="0.6.0"></div>
<a href="../../../../reference/Makefile">Source</a><a href="../../../../registry/v1/index-macos.tsv">Feed</a>
<a href="https://github.com/stubbi/asm/tree/main/docs/">GitHub</a>'''
        html = routes.html(content, "/packages/owner/name/0.6.0/")
        tags = Links(html).tags
        self.assertIn(("meta", {"property": "og:url", "content": "https://asm.build/packages/owner/name/0.6.0"}), tags)
        self.assertIn(("a", {"data-package-link": None, "href": "/docs#from=%23search%3Fq%3Da%2526b"}), tags)
        self.assertIn(("a", {"href": "#readme"}), tags)
        self.assertIn(("form", {"action": "/"}), tags)
        self.assertIn(("img", {"src": "/icon.svg"}), tags)
        self.assertIn(("div", {"data-activity-url": "/registry/v1/activity/owner/name/0.6.0.json", "data-downloads-version": "0.6.0"}), tags)
        for destination in ("/reference/Makefile", "/registry/v1/index-macos.tsv", "https://github.com/stubbi/asm/tree/main/docs/"):
            self.assertIn(("a", {"href": destination}), tags)

    def test_rewriting_preserves_code_comments_and_unrelated_markup(self):
        content = '''<!DOCTYPE html><!-- marker href="docs/" -->
<DIV class='same' data-label='docs/'><a  href='docs/' aria-label="Docs">Docs</a></DIV>
<script>const example = '<a href="docs/">';</script><style>.x::after { content: "docs/"; }</style>
<pre><code>&lt;a href="docs/"&gt;</code></pre><textarea><a href="docs/">literal</a></textarea>'''
        actual = self.routes().html(content, "/index.html")
        self.assertEqual(actual, content.replace("href='docs/' aria-label", "href='/docs' aria-label"))

    def test_same_origin_root_links_without_a_slash_resolve_to_home(self):
        html = self.routes().html('<a href="https://asm.build">Website</a><a href="//asm.build/docs/">Docs</a>', "/docs/")
        self.assertEqual(Links(html).tags, [("a", {"href": "/"}), ("a", {"href": "/docs"})])

    def test_large_boolean_attributes_remain_bounded_and_unchanged(self):
        self.routes()
        code = '''import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from site_routes import PageRoutes
content = '<div ' + 'x' * 100000 + '></div><a href="docs/">Docs</a>'
result = PageRoutes.from_directory(Path(sys.argv[2])).html(content, '/')
assert result == content.replace('href="docs/"', 'href="/docs"')
'''
        try:
            result = subprocess.run([sys.executable, "-c", code, str(ROOT / "tools"), str(self.stage)],
                                    capture_output=True, timeout=3)
        except subprocess.TimeoutExpired:
            self.fail("A bounded HTML attribute must not cause an unbounded rewrite")
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_export_changes_navigation_urls_but_never_raw_registry_or_source_bytes(self):
        raw = {"registry/v1/index.json": '{"url":"https://asm.build/docs/"}',
               "registry/v1/index.tsv": "source\tindex.html\n", "reference/Makefile": "all: # docs/\n"}
        for relative, content in raw.items(): self.write(relative, content)
        self.routes().export(self.stage)
        for relative, content in raw.items():
            self.assertEqual((self.stage / relative).read_text(), content)

    def test_sitemap_deduplicates_canonicals_and_atom_keeps_permanent_ids(self):
        self.write("sitemap.xml", '''<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://asm.build/docs/</loc><lastmod>2026-11-07</lastmod></url><url><loc>https://asm.build/docs/index.html</loc></url><url><loc>https://asm.build/guide.html</loc></url></urlset>''')
        self.write("blog/atom.xml", '''<feed xmlns="http://www.w3.org/2005/Atom"><id>https://asm.build/blog/</id><updated>2026-11-07T00:00:00Z</updated><link rel="alternate" href="https://asm.build/docs/"/><link rel="self" href="https://asm.build/blog/atom.xml"/><entry><id>https://asm.build/guide.html</id><link href="https://asm.build/guide.html"/><published>2026-11-01T00:00:00Z</published><content type="html">&lt;a href="docs/"&gt;literal content&lt;/a&gt;</content></entry></feed>''')
        self.routes().export(self.stage)
        sitemap = ElementTree.parse(self.stage / "sitemap.xml")
        ns = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9"}
        self.assertEqual([item.text for item in sitemap.findall("s:url/s:loc", ns)], ["https://asm.build/docs", "https://asm.build/guide"])
        self.assertEqual(sitemap.find("s:url/s:lastmod", ns).text, "2026-11-07")
        feed = ElementTree.parse(self.stage / "blog/atom.xml")
        ns = {"a": "http://www.w3.org/2005/Atom"}
        self.assertEqual(feed.find("a:id", ns).text, "https://asm.build/blog/")
        self.assertEqual(feed.find("a:entry/a:id", ns).text, "https://asm.build/guide.html")
        self.assertEqual(feed.find("a:entry/a:published", ns).text, "2026-11-01T00:00:00Z")
        self.assertEqual(feed.find("a:entry/a:content", ns).text, '<a href="docs/">literal content</a>')
        self.assertEqual(feed.find("a:entry/a:link", ns).get("href"), "https://asm.build/guide")
        self.assertEqual(feed.find("a:link", ns).get("href"), "https://asm.build/docs")

    def test_conflicting_aliases_fail_before_replacing_any_content(self):
        original = (self.stage / "docs/index.html").read_bytes()
        self.write("docs.html", "Different existing content")
        with self.assertRaises(registry.RegistryError): self.routes()
        self.assertEqual((self.stage / "docs/index.html").read_bytes(), original)
        self.assertEqual((self.stage / "docs.html").read_text(), "Different existing content")

    def test_malformed_metadata_fails_before_any_export_writes(self):
        original = (self.stage / "index.html").read_bytes()
        self.write("sitemap.xml", "<not-closed>")
        routes = self.routes()
        with self.assertRaises(registry.RegistryError): routes.export(self.stage)
        self.assertEqual((self.stage / "index.html").read_bytes(), original)
        self.assertFalse((self.stage / "docs.html").exists())

    def test_symlinks_bounds_and_unsafe_page_bases_are_rejected(self):
        routes = self.routes()
        for path in ("/../outside", "/%2e%2e/outside", "//evil.invalid/", "https://evil.invalid/docs/"):
            with self.subTest(path=path), self.assertRaises(registry.RegistryError):
                routes.html('<a href="docs/">Docs</a>', path)
        with self.assertRaises(registry.RegistryError):
            routes.html("x" * (4 * 1024 * 1024 + 1), "/")
        other = self.stage.parent / "outside.html"; other.write_text("Keep outside")
        (self.stage / "linked.html").symlink_to(other)
        with self.assertRaises(registry.RegistryError): self.routes()
        self.assertEqual(other.read_text(), "Keep outside")

    def test_repeated_export_preserves_original_base_and_bytes(self):
        self.routes().export(self.stage)
        before = {str(path.relative_to(self.stage)): path.read_bytes() for path in self.stage.rglob("*") if path.is_file()}
        routes = self.routes()
        self.assertEqual(routes.legacy_path("/docs.html"), "/docs/")
        routes.export(self.stage)
        self.assertEqual({str(path.relative_to(self.stage)): path.read_bytes() for path in self.stage.rglob("*") if path.is_file()}, before)


if __name__ == "__main__": unittest.main()
