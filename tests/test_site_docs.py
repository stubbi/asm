"""The Docs hub links existing tasks without copying their instructions.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from html.parser import HTMLParser
import importlib
from pathlib import Path
import re
import sys
import tempfile
import unittest
from urllib.parse import urljoin, urlsplit, unquote

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))


class Page(HTMLParser):
    def __init__(self, content):
        super().__init__()
        self.links, self.tags, self.text = [], [], []
        self.feed(content)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append((tag, attrs))
        if tag == "a": self.links.append(attrs)

    def handle_data(self, text): self.text.append(text)


class DocsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.repo, self.stage = self.base / "empty-checkout", self.base / "site"
        self.repo.mkdir()
        self.stage.mkdir()
        self.initial = ('<header class="site-header"><nav aria-label="Main navigation">'
                        '<a href="explore/">Explore</a><a href="stats/">Stats</a>'
                        '<a href="blog/">Blog</a><a href="docs/">Docs</a></nav></header>'
                        '<footer class="site-footer"><a href="index.html">Asm home</a></footer>')
        (self.stage / "index.html").write_text(self.initial)
        for route in ("guide.html", "agents.md", "styles.css", "packages.css", "icon.svg"):
            (self.stage / route).write_text("fixture")
        (self.stage / "reference").mkdir()
        (self.stage / "reference/index.html").write_text("fixture")

    def generate(self):
        self.assertTrue((ROOT / "tools/site_docs.py").is_file(), "Docs hub is not implemented")
        module = importlib.import_module("site_docs")
        routes = module.write_docs(self.repo, self.stage)
        return routes, (self.stage / "docs/index.html").read_text()

    def test_native_hub_has_canonical_metadata_shared_chrome_and_only_navigation_script(self):
        routes, content = self.generate()
        page = Page(content)
        self.assertEqual(routes, ["docs/"])
        self.assertEqual(sum(tag == "h1" for tag, _ in page.tags), 1)
        self.assertEqual(sum(tag == "header" and attrs.get("class") == "site-header" for tag, attrs in page.tags), 1)
        self.assertEqual(sum(tag == "footer" for tag, _ in page.tags), 1)
        self.assertEqual([attrs for tag, attrs in page.tags if tag == "script"],
                         [{"src": "../navigation.js"}, {"src": "../repository-stars.js", "defer": None}])
        self.assertIn(("link", {"rel": "canonical", "href": "https://asm.build/docs/"}), page.tags)
        self.assertIn(("meta", {"property": "og:url", "content": "https://asm.build/docs/"}), page.tags)
        self.assertTrue(any(tag == "main" and attrs.get("id") == "main" for tag, attrs in page.tags))
        self.assertEqual([link["href"] for link in page.links if link.get("aria-current") == "page"], ["../docs/"])
        self.assertEqual((self.stage / "index.html").read_text(), self.initial)

    def test_task_links_use_the_current_documents_and_real_repository_anchors(self):
        _, content = self.generate()
        page = Page(content)
        links = {link["href"] for link in page.links}
        base = "https://github.com/stubbi/asm/"
        self.assertTrue({base + "#install-the-command", base + "#run-your-first-project", base + "#status",
                         base + "blob/main/docs/use-a-package.md", base + "blob/main/docs/specs/registry.md#package-and-prepare-a-record",
                         base + "blob/main/docs/specs/registry.md#release-record", base + "blob/main/docs/target-distribution.md",
                         base + "blob/main/docs/specs/security.md", base + "blob/main/docs/agents.md",
                         "../guide.html", "../reference/", "../agents.md"}.issubset(links))
        for href in links:
            parsed = urlsplit(href)
            if parsed.netloc != "github.com":
                continue
            self.assertTrue(href.startswith(base), href)
            relative = unquote(parsed.path.removeprefix("/stubbi/asm/blob/main/")) if "/blob/main/" in parsed.path else "README.md"
            document = ROOT / relative
            self.assertTrue(document.is_file(), href)
            if parsed.fragment:
                headings = re.findall(r"^#{1,6} (.+)$", document.read_text(), re.M)
                anchors = {re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-") for heading in headings}
                self.assertIn(parsed.fragment, anchors, href)

    def test_search_metadata_describes_a_task_hub_and_record_preparation_remains_local(self):
        _, content = self.generate()
        head = content.split("</head>", 1)[0]
        self.assertIn("<title>Installation and package documentation", head)
        self.assertIn("installation", head)
        self.assertIn("maintained repository", head)
        self.assertIn("Prepare source-bound artifacts and a local release record without uploading.", content)
        self.assertNotIn("submit a registry pull request", content)

    def test_local_assets_and_cards_are_native_links_with_readable_task_labels(self):
        _, content = self.generate()
        page = Page(content)
        cards = [attrs for tag, attrs in page.tags if tag == "a" and "directory-card" in attrs.get("class", "").split()]
        self.assertGreaterEqual(len(cards), 10)
        self.assertTrue(all(attrs.get("href") and "onclick" not in attrs and "role" not in attrs for attrs in cards))
        self.assertTrue(all(tag != "button" for tag, _ in page.tags))
        for tag, attrs in page.tags:
            if tag == "link" and attrs.get("rel") in {"icon", "stylesheet"}:
                path = urlsplit(urljoin("https://asm.build/docs/", attrs["href"])).path.lstrip("/")
                self.assertTrue((self.stage / path).is_file(), path)
        text = " ".join(page.text)
        for group in ("Start", "Packages", "Reference"):
            self.assertIn(group, text)
        self.assertNotIn("curl ", text)
        self.assertNotIn("asm new", text)
        self.assertNotIn("<script>", content)


if __name__ == "__main__": unittest.main()
