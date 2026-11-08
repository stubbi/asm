"""Project information keeps real contact routes and scoped privacy facts.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from html.parser import HTMLParser
import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from urllib.parse import urljoin, urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import site_routes


class Page(HTMLParser):
    def __init__(self, content):
        super().__init__()
        self.tags, self.text, self.structured = [], [], []
        self.json_text = None
        self.feed(content)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append((tag, attrs))
        if tag == "script" and attrs.get("type") == "application/ld+json":
            self.json_text = ""

    def handle_data(self, text):
        if self.json_text is None: self.text.append(text)
        else: self.json_text += text

    def handle_endtag(self, tag):
        if tag == "script" and self.json_text is not None:
            self.structured.append(json.loads(self.json_text))
            self.json_text = None

    def links(self):
        return {attrs["href"] for tag, attrs in self.tags if tag == "a"}


class InfoTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name) / "empty-checkout"
        self.stage = Path(temporary.name) / "site"
        self.repo.mkdir()
        self.stage.mkdir()
        self.initial = ('<header class="site-header"><nav aria-label="Main navigation">'
                        '<a href="explore/">Explore</a><a href="stats/">Stats</a>'
                        '<a href="blog/">Blog</a><a href="docs/">Docs</a></nav></header>'
                        '<footer class="site-footer"><a href="index.html">Asm home</a></footer>')
        (self.stage / "index.html").write_text(self.initial)
        for relative in ("guide.html", "sponsors.html", "docs/index.html", "packages/index.html",
                         "explore/index.html", "stats/index.html", "blog/index.html", "discovery/index.html"):
            path = self.stage / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("<main>Existing route fixture.</main>")
        for relative in ("navigation.js", "repository-stars.js", "styles.css", "packages.css", "icon.svg"):
            (self.stage / relative).write_text("fixture")

    def generate(self):
        self.assertTrue((ROOT / "tools/site_info.py").is_file(), "Project information pages are not implemented.")
        routes = importlib.import_module("site_info").write_info(self.repo, self.stage)
        return routes, {route: (self.stage / route / "index.html").read_text() for route in routes}

    def test_pages_have_native_landmarks_shared_chrome_and_truthful_page_types(self):
        routes, pages = self.generate()
        self.assertEqual(routes, ["about/", "contact/", "privacy/"])
        descriptions = set()
        for route, kind in (("about/", "AboutPage"), ("contact/", "ContactPage"), ("privacy/", "WebPage")):
            with self.subTest(route=route):
                page = Page(pages[route])
                self.assertEqual(sum(tag == "h1" for tag, _ in page.tags), 1)
                self.assertEqual(sum(tag == "header" and attrs.get("class") == "site-header" for tag, attrs in page.tags), 1)
                self.assertEqual(sum(tag == "footer" for tag, _ in page.tags), 1)
                self.assertTrue(any(tag == "main" and attrs.get("id") == "main" for tag, attrs in page.tags))
                self.assertFalse(any("aria-current" in attrs for _, attrs in page.tags))
                self.assertEqual(len(page.structured), 1)
                data = page.structured[0]
                self.assertEqual(data["@type"], kind)
                self.assertEqual(data["url"], "https://asm.build/" + route.rstrip("/"))
                self.assertEqual(data["@id"], data["url"] + "#webpage")
                title = pages[route].split("<title>", 1)[1].split("</title>", 1)[0]
                expected_title, expected_name = {
                    "about/": ("About the assembly package project | Asm", "About Asm"),
                    "contact/": ("Project contact and issue reporting | Asm", "Contact Asm"),
                    "privacy/": ("Website privacy and data handling | Asm", "Privacy at Asm"),
                }[route]
                self.assertEqual(title, expected_title)
                self.assertEqual(data["name"], expected_name)
                self.assertEqual(title.count("Asm"), 1)
                self.assertFalse({"author", "publisher", "datePublished", "aggregateRating", "address"} & data.keys())
                self.assertNotIn(data["description"], descriptions)
                descriptions.add(data["description"])
                scripts = [attrs for tag, attrs in page.tags if tag == "script" and attrs.get("type") != "application/ld+json"]
                self.assertEqual(scripts, [{"src": "../navigation.js"}, {"src": "../repository-stars.js", "defer": None}])
                self.assertFalse(any(tag in {"form", "input", "button", "iframe"} for tag, _ in page.tags))
        self.assertEqual((self.stage / "index.html").read_text(), self.initial)

    def test_about_links_current_scope_and_maintained_evidence_without_a_second_feature_table(self):
        _, pages = self.generate()
        page = Page(pages["about/"])
        self.assertTrue({"../packages/", "../docs/", "../guide.html#why", "../explore/", "../stats/", "../blog/",
                         "https://github.com/stubbi/asm#status", "https://github.com/stubbi/asm#license",
                         "https://github.com/stubbi/asm/blob/main/docs/why-asm.md",
                         "https://github.com/stubbi/asm/blob/main/CONTRIBUTING.md"} <= page.links())
        text = " ".join(page.text)
        self.assertIn("package registry and command-line tool for assembly projects", text)
        self.assertIn("working assumption", text)
        self.assertNotIn("0.6.0", text)

    def test_contact_routes_keep_public_issues_private_security_and_deliberate_email_separate(self):
        _, pages = self.generate()
        page = Page(pages["contact/"])
        self.assertTrue({"https://github.com/stubbi/asm/issues",
                         "https://github.com/stubbi/asm/security/advisories/new",
                         "https://github.com/stubbi/asm/blob/main/SECURITY.md",
                         "mailto:jannes.stubbemann@gmail.com", "../sponsors.html"} <= page.links())
        self.assertIn("Do not include vulnerability details in that public issue.", " ".join(page.text))
        self.assertIn("jannes.stubbemann@gmail.com", " ".join(page.text))
        for document, value in (("site/sponsors.html", "jannes.stubbemann@gmail.com"),
                                ("SECURITY.md", "https://github.com/stubbi/asm/security/advisories/new")):
            self.assertIn(value, (ROOT / document).read_text())

    def test_privacy_discloses_host_logging_star_fallback_and_only_scoped_local_storage_claims(self):
        _, pages = self.generate()
        page = Page(pages["privacy/"])
        self.assertTrue({"https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages#data-collection",
                         "https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement",
                         "https://github.com/stubbi/asm/blob/main/docs/specs/security.md", "../contact/", "../discovery/"} <= page.links())
        text = " ".join(page.text)
        for fact in ("GitHub Pages", "IP addresses", "security purposes", "URL fragment", "site origin", "Session storage", "local delivery"):
            self.assertIn(fact, text)
        for unsupported in ("we collect no personal data", "GDPR compliant", "never leaves your device", "stored for 30 days"):
            self.assertNotIn(unsupported, text)
        self.assertTrue(any(tag == "time" and attrs.get("datetime") == "2026-11-08" for tag, attrs in page.tags))

    def test_clean_export_keeps_each_local_navigation_asset_and_canonical_resolvable(self):
        _, _ = self.generate()
        site_routes.PageRoutes.from_directory(self.stage).export(self.stage)
        for name in ("about", "contact", "privacy"):
            content = (self.stage / (name + ".html")).read_text()
            page = Page(content)
            base = "https://asm.build/" + name
            canonicals = [attrs["href"] for tag, attrs in page.tags if tag == "link" and attrs.get("rel") == "canonical"]
            self.assertEqual(canonicals, [base])
            for tag, attrs in page.tags:
                url = attrs.get("href") if tag == "a" else attrs.get("src") if tag == "script" else None
                if url is None: continue
                parsed = urlsplit(urljoin(base, url))
                if parsed.netloc != "asm.build": continue
                path = self.stage / parsed.path.lstrip("/")
                self.assertTrue(path.is_file() or (path / "index.html").is_file()
                                or (self.stage / (parsed.path.lstrip("/") + ".html")).is_file(), url)


if __name__ == "__main__": unittest.main()
