"""Release posts use accepted versions and retained notes, never invented dates.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from datetime import datetime, timezone
from html.parser import HTMLParser
import importlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from urllib.parse import urljoin, urlsplit
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry

ATOM = {"a": "http://www.w3.org/2005/Atom"}
CHANGELOG = """# Change log

## Unreleased

- Unreleased fixture must stay private to the change log.

## 0.3.0

- A planned record does not establish a released package.

## 0.2.0

- Add `asm self update` with exact release checks.
- Preserve a failed update and its previous installation.

See the [release notes](docs/releases/0.2.0.md).

## 0.1.0

The first alpha retains its MIT license.

- Build and run one assembly project.
"""


class Page(HTMLParser):
    def __init__(self, content):
        super().__init__()
        self.links, self.assets, self.scripts, self.ids, self.headings, self.mains, self.canonicals, self.event_attrs = [], [], [], [], [], [], [], []
        self.post_links, self.robots, self.current_links, self.in_h2 = [], [], [], False
        self.structured, self.json_text = [], None
        self.feed(content)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.event_attrs.extend(key for key in attrs if key.startswith("on"))
        if "id" in attrs: self.ids.append(attrs["id"])
        if tag == "a": self.links.append(attrs.get("href", ""))
        if tag == "a" and self.in_h2: self.post_links.append(attrs.get("href", ""))
        if tag == "a" and attrs.get("aria-current") == "page": self.current_links.append(attrs.get("href", ""))
        if tag == "h2": self.in_h2 = True
        if tag == "meta" and attrs.get("name") == "robots": self.robots.append(attrs.get("content"))
        if tag == "script":
            self.scripts.append(attrs)
            if attrs.get("type") == "application/ld+json": self.json_text = ""
        if tag == "h1": self.headings.append(attrs)
        if tag == "main": self.mains.append(attrs.get("id"))
        if tag == "link" and attrs.get("rel") == "canonical": self.canonicals.append(attrs.get("href"))
        if tag == "link" and attrs.get("rel") in {"stylesheet", "icon"}: self.assets.append(attrs["href"])
        if tag == "img": self.assets.append(attrs["src"])

    def handle_endtag(self, tag):
        if tag == "h2": self.in_h2 = False
        if tag == "script" and self.json_text is not None:
            self.structured.append(json.loads(self.json_text))
            self.json_text = None

    def handle_data(self, data):
        if self.json_text is not None: self.json_text += data


class ReleaseBlogTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo, self.stage = self.root / "repo", self.root / "site"
        self.repo.mkdir()
        shutil.copytree(ROOT / "site", self.stage)
        (self.repo / "CHANGELOG.md").write_text(CHANGELOG, encoding="utf-8")
        self.records = [self.record("0.1.0", "MIT", "a" * 40), self.record("0.2.0", "AGPL-3.0-or-later", "b" * 40)]
        _, self.index = registry.make_indexes(self.records)
        self.dates = {"0.1.0": "2026-01-02T04:05:06Z", "0.2.0": "2026-02-03T05:06:07Z"}

    def record(self, version, license_id, commit):
        return {"schema": 1, "name": "stubbi/asm", "version": version, "summary": "Native assembly CLI.",
                "license": license_id, "source": {"repository": "https://github.com/stubbi/asm", "commit": commit, "path": "."},
                "yanked": False, "artifacts": [{"target": "x86_64-linux", "kind": "executable", "bytes": 100,
                "sha256": "c" * 64, "url": f"https://github.com/stubbi/asm/releases/download/v{version}/asm-{version}-x86_64-linux"}]}

    def build(self, *, dates=None, publication=None, include_drafts=False):
        self.assertTrue((ROOT / "tools/release_blog.py").is_file(), "The release blog generator is not implemented.")
        self.module = importlib.import_module("release_blog")
        options = {"include_drafts": True} if include_drafts else {}
        return self.module.write_release_blog(self.repo, self.stage, self.index, publication,
                                              release_dates=dates, **options)

    def article(self, slug, *, title="A measured change", summary="The result and its limits.",
                author="Asm contributors", date="2026-02-01", updated=None, draft=False, body=None):
        posts = self.repo / "blog/posts"
        posts.mkdir(parents=True, exist_ok=True)
        header = "\n".join(key + " = " + json.dumps(value) for key, value in
                           (("title", title), ("summary", summary), ("author", author)))
        header += "\ndraft = " + str(draft).lower() + "\n"
        if date is not None: header += "date = " + date + "\n"
        if updated is not None: header += "updated = " + updated + "\n"
        path = posts / (slug + ".md")
        path.write_text("+++\n" + header + "+++\n" + (body or "## Result\n\nThe recorded result retains its limits.\n"), encoding="utf-8")
        return path

    def listing(self, route):
        content = (self.stage / route / "index.html").read_text(encoding="utf-8")
        links = [urlsplit(urljoin("https://asm.build/" + route, href)).path for href in Page(content).post_links]
        return content, links

    def post(self, version): return (self.stage / "blog/releases" / version / "index.html").read_text(encoding="utf-8")

    def feed(self): return ElementTree.parse(self.stage / "blog/atom.xml").getroot()

    def test_only_accepted_releases_become_posts_and_notes_keep_historical_license(self):
        before = (self.repo / "CHANGELOG.md").read_bytes()
        routes = self.build(dates=self.dates)
        self.assertEqual(set(routes), {"blog/", "blog/articles/", "blog/releases/", "blog/releases/0.1.0/", "blog/releases/0.2.0/"})
        self.assertFalse((self.stage / "blog/releases/0.3.0").exists())
        older = self.post("0.1.0")
        newer = self.post("0.2.0")
        self.assertIn("The first alpha retains its MIT license.", older)
        self.assertIn("Build and run one assembly project.", older)
        self.assertIn("<code>MIT</code>", older)
        self.assertIn("<code>AGPL-3.0-or-later</code>", newer)
        self.assertIn("Preserve a failed update and its previous installation.", newer)
        listing = (self.stage / "blog/index.html").read_text()
        self.assertIn("Add <code>asm self update</code> with exact release checks.", listing)
        self.assertIn("The first alpha retains its MIT license.", listing)
        for page in (older, newer):
            self.assertNotIn("Unreleased fixture", page)
            self.assertNotIn("A planned record", page)
        self.assertEqual((self.repo / "CHANGELOG.md").read_bytes(), before)

    def test_search_metadata_distinguishes_versions_and_archives_without_rewriting_feed_identity(self):
        self.build(dates=self.dates)
        for version, license_id in (("0.1.0", "MIT"), ("0.2.0", "AGPL-3.0-or-later")):
            head = self.post(version).split("</head>", 1)[0]
            self.assertIn("<title>Assembly CLI " + version + " release notes", head)
            title = head.split("<title>", 1)[1].split("</title>", 1)[0]
            self.assertTrue(title.endswith(" | Asm"))
            self.assertIn(license_id, head)
            self.assertIn("source commit", head)
        for route, title in (("blog", "Project blog and release notes"), ("blog/articles", "Assembly software article archive"),
                             ("blog/releases", "Assembly CLI release notes")):
            content = (self.stage / route / "index.html").read_text()
            self.assertIn("<title>" + title, content)
        article_head = (self.stage / "blog/articles/index.html").read_text().split("</head>", 1)[0]
        self.assertIn("No articles are published yet", article_head)
        entry = self.feed().find("a:entry", ATOM)
        self.assertEqual(entry.findtext("a:id", namespaces=ATOM), "https://asm.build/blog/releases/0.2.0/")
        self.assertEqual(entry.findtext("a:title", namespaces=ATOM), "Asm 0.2.0")

    def test_pages_have_shared_chrome_canonical_links_landmarks_and_only_navigation_script(self):
        routes = self.build(dates=self.dates)
        for route in routes:
            with self.subTest(route=route):
                content = (self.stage / route / "index.html").read_text(encoding="utf-8")
                page = Page(content)
                self.assertEqual(page.canonicals, ["https://asm.build/" + route])
                self.assertIn('property="og:url" content="https://asm.build/' + route + '"', content)
                self.assertEqual(page.mains, ["main"])
                self.assertEqual(len(page.headings), 1)
                self.assertEqual(len(page.ids), len(set(page.ids)))
                prefix = "../" * route.count("/")
                self.assertEqual(page.scripts, [{"src": prefix + "navigation.js"}, {"src": prefix + "repository-stars.js", "defer": None}])
                self.assertEqual(content.count('class="site-header"'), 1)
                self.assertEqual(content.count('class="site-footer"'), 1)
                for href in page.assets:
                    resolved = urljoin("https://asm.build/" + route, href)
                    if urlsplit(resolved).netloc == "asm.build": self.assertTrue((self.stage / urlsplit(resolved).path.lstrip("/")).is_file(), href)
                for href in page.links:
                    resolved = urlsplit(urljoin("https://asm.build/" + route, href))
                    if resolved.netloc == "asm.build" and resolved.path.startswith("/blog/"):
                        target = self.stage / resolved.path.lstrip("/")
                        self.assertTrue(target.is_file() or (target / "index.html").is_file(), href)
        newer = Page(self.post("0.2.0"))
        self.assertIn("https://github.com/stubbi/asm/blob/" + "b" * 40 + "/docs/releases/0.2.0.md", newer.links)
        self.assertTrue(any("/packages/stubbi/asm/0.2.0/" in urljoin("https://asm.build/blog/releases/0.2.0/", href) for href in newer.links))

    def test_atom_dates_bind_exact_versions_and_sort_by_real_publication(self):
        self.dates["0.1.0"] = "2026-03-04T06:07:08Z"
        self.build(dates=self.dates)
        feed = self.feed()
        self.assertEqual(feed.tag, "{http://www.w3.org/2005/Atom}feed")
        self.assertEqual(feed.findtext("a:updated", namespaces=ATOM), self.dates["0.1.0"])
        entries = feed.findall("a:entry", ATOM)
        self.assertEqual([entry.findtext("a:id", namespaces=ATOM) for entry in entries],
                         ["https://asm.build/blog/releases/0.1.0/", "https://asm.build/blog/releases/0.2.0/"])
        self.assertEqual([entry.findtext("a:published", namespaces=ATOM) for entry in entries],
                         [self.dates["0.1.0"], self.dates["0.2.0"]])
        self.assertTrue(feed.findtext("a:author/a:name", namespaces=ATOM))
        self.assertIn("GitHub release", self.post("0.1.0"))

    def test_missing_version_dates_do_not_reuse_package_wide_dates_or_invent_atom_entries(self):
        publication = {"publication_observed_at": "2026-04-01T00:00:00Z", "packages": [{"name": "stubbi/asm",
                       "first_published_at": "2026-01-01T00:00:00Z", "last_published_at": "2026-03-01T00:00:00Z"}]}
        self.build(dates={"0.2.0": self.dates["0.2.0"]}, publication=publication)
        self.assertIn("Publication date unavailable", self.post("0.1.0"))
        self.assertNotIn("2026-01-01", self.post("0.1.0"))
        self.assertEqual(len(self.feed().findall("a:entry", ATOM)), 1)

    def test_empty_feed_uses_only_an_explicit_feed_metadata_generation_time(self):
        before = datetime.now(timezone.utc)
        self.build()
        after = datetime.now(timezone.utc)
        feed = self.feed()
        self.assertEqual(feed.findall("a:entry", ATOM), [])
        self.assertIsNone(feed.find("a:published", ATOM))
        updated = datetime.fromisoformat(feed.findtext("a:updated", namespaces=ATOM).replace("Z", "+00:00"))
        self.assertLessEqual(before, updated)
        self.assertLessEqual(updated, after)
        self.assertIn("feed metadata", feed.findtext("a:subtitle", namespaces=ATOM))
        self.assertIn("Publication date unavailable", self.post("0.2.0"))

    def test_duplicate_malformed_or_missing_released_sections_fail_before_writing(self):
        for notes in (CHANGELOG + "\n## 0.2.0\n\nDuplicate.\n", CHANGELOG.replace("## 0.2.0", "## 0.2.0 candidate"),
                      CHANGELOG.replace("## 0.2.0", "## 01.2.0"), "# Change log\n\n## 0.1.0\n\nMissing newer notes.\n"):
            with self.subTest(notes=notes):
                (self.repo / "CHANGELOG.md").write_text(notes, encoding="utf-8")
                with self.assertRaises(registry.RegistryError): self.build()
                self.assertFalse((self.stage / "blog").exists())

    def test_named_change_sections_do_not_become_releases_or_join_release_notes(self):
        notes = CHANGELOG.replace("## 0.2.0", "## Website dependency display\n\nEditorial website notes.\n\n## 0.2.0")
        notes += "\n## Repository maintenance\n\nSeparate maintenance notes.\n"
        (self.repo / "CHANGELOG.md").write_text(notes, encoding="utf-8")
        self.build(dates=self.dates)
        sections = self.module._sections(self.repo)
        self.assertEqual(set(sections), {"Unreleased", "0.3.0", "0.2.0", "0.1.0"})
        self.assertNotIn("Editorial website notes", self.post("0.2.0"))
        self.assertNotIn("Separate maintenance notes", self.post("0.1.0"))

    def test_hostile_markdown_is_escaped_and_cannot_add_scripts_images_or_local_actions(self):
        notes = CHANGELOG.replace("- Add `asm self update` with exact release checks.",
                                 '<script>alert(1)</script>\n\n[Bad](javascript:alert) [Outside](//evil.invalid/a)\n\n![Remote](https://evil.invalid/pixel)\n\n[Quoted](https://example.invalid/?x=%22onclick=evil)')
        (self.repo / "CHANGELOG.md").write_text(notes, encoding="utf-8")
        self.build(dates=self.dates)
        text = self.post("0.2.0")
        page = Page(text)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt;", text)
        self.assertEqual(page.scripts, [{"src": "../../../navigation.js"}, {"src": "../../../repository-stars.js", "defer": None}])
        self.assertFalse(any(value.startswith(("javascript:", "//evil.invalid")) for value in page.links))
        self.assertNotIn("https://evil.invalid/pixel", page.assets)
        self.assertEqual(page.event_attrs, [])
        entry = self.feed().find("a:entry", ATOM)
        self.assertIn("&lt;script&gt;", entry.findtext("a:content", namespaces=ATOM))

    def test_invalid_or_foreign_publication_dates_fail_without_partial_output(self):
        for dates in ({"9.0.0": "2026-01-01T00:00:00Z"}, {"0.1.0": "not a timestamp"},
                      {"0.1.0": "2999-01-01T00:00:00Z"}, {"0.1.0": "2026-01-01T00:00:00"}):
            with self.subTest(dates=dates), self.assertRaises(registry.RegistryError): self.build(dates=dates)
            self.assertFalse((self.stage / "blog").exists())

    def test_missing_and_oversized_or_symlink_changelog_is_rejected_without_touching_source(self):
        path = self.repo / "CHANGELOG.md"
        path.unlink()
        with self.assertRaises((registry.RegistryError, OSError)): self.build()
        outside = self.root / "outside-notes.md"
        outside.write_text(CHANGELOG)
        path.symlink_to(outside)
        with self.assertRaises(registry.RegistryError): self.build()
        self.assertEqual(outside.read_text(), CHANGELOG)
        path.unlink()
        path.write_bytes(b"x" * (512 * 1024 + 1))
        with self.assertRaises(registry.RegistryError): self.build()
        self.assertEqual(path.stat().st_size, 512 * 1024 + 1)

    def test_heading_like_code_does_not_split_a_release_section(self):
        notes = CHANGELOG.replace("- Add `asm self update` with exact release checks.", "```text\n## 9.0.0\nKeep this literal code.\n```")
        (self.repo / "CHANGELOG.md").write_text(notes)
        self.build(dates=self.dates)
        self.assertIn("## 9.0.0\nKeep this literal code.", self.post("0.2.0"))

    def test_long_code_fences_do_not_turn_nested_examples_into_release_headings(self):
        for fence in ("````", "~~~~"):
            with self.subTest(fence=fence):
                sample = fence + "text\n```\n## An example inside code\n```\n" + fence
                notes = CHANGELOG.replace("- Add `asm self update` with exact release checks.", sample)
                (self.repo / "CHANGELOG.md").write_text(notes)
                self.build(dates=self.dates)
                page = self.post("0.2.0")
                self.assertIn('## An example inside code', page)
                self.assertNotIn('id="readme-an-example-inside-code"', page)

    def test_articles_and_releases_share_chronological_index_and_separate_archives(self):
        self.article("a-first", title="First article")
        self.article("z-second", title="Second article")
        routes = self.build(dates={"0.2.0": self.dates["0.2.0"]})
        listing, links = self.listing("blog/")
        self.assertEqual(links, ["/blog/releases/0.2.0/", "/blog/articles/a-first/",
                                 "/blog/articles/z-second/", "/blog/releases/0.1.0/"])
        self.assertIn('class="blog-kind">Article</span>', listing)
        self.assertIn('class="blog-kind">Release</span>', listing)
        self.assertIn("Asm contributors", listing)
        articles, article_links = self.listing("blog/articles/")
        releases, release_links = self.listing("blog/releases/")
        self.assertEqual(article_links, ["/blog/articles/a-first/", "/blog/articles/z-second/"])
        self.assertEqual(release_links, ["/blog/releases/0.2.0/", "/blog/releases/0.1.0/"])
        for route, page in (("blog/", listing), ("blog/articles/", articles), ("blog/releases/", releases)):
            self.assertIn("https://asm.build/" + route, Page(page).canonicals)
            self.assertIn("/" + route, [urlsplit(urljoin("https://asm.build/" + route, href)).path for href in Page(page).current_links])
        self.assertIn("blog/articles/a-first/", routes)
        self.assertNotIn("Unreleased fixture", listing + articles + releases)

    def test_article_atom_retains_author_summary_content_and_updated_date(self):
        self.article("measured-change", author="Jannes & contributors", summary="Measured <scope> & limits.",
                     updated="2026-04-01", body="## Result\n\nRead the `asm` result.\n")
        self.build(dates=self.dates)
        feed = self.feed()
        self.assertEqual(feed.findtext("a:title", namespaces=ATOM), "Asm blog")
        self.assertEqual(feed.findtext("a:updated", namespaces=ATOM), "2026-04-01T00:00:00Z")
        entries = feed.findall("a:entry", ATOM)
        self.assertEqual([entry.findtext("a:id", namespaces=ATOM) for entry in entries],
                         ["https://asm.build/blog/releases/0.2.0/", "https://asm.build/blog/articles/measured-change/",
                          "https://asm.build/blog/releases/0.1.0/"])
        article = entries[1]
        self.assertEqual(article.findtext("a:author/a:name", namespaces=ATOM), "Jannes & contributors")
        self.assertEqual(article.findtext("a:summary", namespaces=ATOM), "Measured <scope> & limits.")
        self.assertEqual(article.findtext("a:published", namespaces=ATOM), "2026-02-01T00:00:00Z")
        self.assertEqual(article.findtext("a:updated", namespaces=ATOM), "2026-04-01T00:00:00Z")
        self.assertIn("<code>asm</code>", article.findtext("a:content", namespaces=ATOM))
        release = entries[0]
        self.assertEqual(release.findtext("a:title", namespaces=ATOM), "Asm 0.2.0")
        self.assertEqual(release.findtext("a:updated", namespaces=ATOM), self.dates["0.2.0"])
        self.assertIn("GitHub release availability", release.findtext("a:summary", namespaces=ATOM))

    def test_published_article_metadata_uses_declared_dates_source_and_literal_credit(self):
        self.article("measured-change", title="A measured result", author="Jannes & contributors",
                     summary="Measured scope and limits.", updated="2026-04-01")
        self.article("original", date="2026-01-01")
        self.build(dates=self.dates)
        content = (self.stage / "blog/articles/measured-change/index.html").read_text()
        self.assertEqual(Page(content).structured, [{
            "@context": "https://schema.org", "@type": "BlogPosting",
            "@id": "https://asm.build/blog/articles/measured-change#article",
            "url": "https://asm.build/blog/articles/measured-change",
            "headline": "A measured result", "description": "Measured scope and limits.",
            "creditText": "Jannes & contributors", "datePublished": "2026-02-01",
            "dateModified": "2026-04-01", "inLanguage": "en",
            "isBasedOn": "https://github.com/stubbi/asm/blob/main/blog/posts/measured-change.md",
        }])
        self.assertIn('property="og:type" content="article"', content)
        original = Page((self.stage / "blog/articles/original/index.html").read_text()).structured
        self.assertEqual(len(original), 1)
        self.assertNotIn("dateModified", original[0])
        for route in ("blog/", "blog/articles/", "blog/releases/", "blog/releases/0.1.0/", "blog/releases/0.2.0/"):
            content = (self.stage / route / "index.html").read_text()
            self.assertEqual(Page(content).structured, [])
            self.assertIn('property="og:type" content="website"', content)

    def test_hostile_article_metadata_cannot_terminate_json_script_or_add_executable_markup(self):
        title = '</script><script>globalThis.evil=1</script> <&"title"'
        author = '</script><img src=x onerror=bad> & Writer'
        summary = '<!-- </ScRiPt><script>bad</script> & "Summary"'
        self.article("hostile", title=title, author=author, summary=summary)
        self.build()
        content = (self.stage / "blog/articles/hostile/index.html").read_text()
        page = Page(content)
        self.assertEqual(len(page.structured), 1)
        self.assertEqual(page.structured[0]["headline"], title)
        self.assertEqual(page.structured[0]["creditText"], author)
        self.assertEqual(page.structured[0]["description"], summary)
        self.assertEqual([script for script in page.scripts if script.get("type") != "application/ld+json"],
                         [{"src": "../../../navigation.js"}, {"src": "../../../repository-stars.js", "defer": None}])
        self.assertEqual(len(page.scripts), 3)
        self.assertEqual(page.event_attrs, [])
        self.assertNotIn("x", page.assets)

    def test_article_page_escapes_plain_metadata_and_keeps_native_source_and_back_links(self):
        path = self.article("safe-source", title='<img src=x onerror=bad> & "title"',
                            author="Writer <script>bad</script>", summary='Summary <b>plain</b> & "quoted".',
                            body="## Evidence\n\n<script>bad</script>\n\n[Unsafe](javascript:alert)\n")
        before = path.read_bytes()
        self.build()
        content = (self.stage / "blog/articles/safe-source/index.html").read_text(encoding="utf-8")
        page = Page(content)
        self.assertEqual(page.canonicals, ["https://asm.build/blog/articles/safe-source/"])
        self.assertEqual(page.mains, ["main"])
        self.assertEqual(len(page.headings), 1)
        self.assertEqual([script for script in page.scripts if script.get("type") != "application/ld+json"],
                         [{"src": "../../../navigation.js"}, {"src": "../../../repository-stars.js", "defer": None}])
        self.assertEqual(len(page.structured), 1)
        self.assertEqual(page.event_attrs, [])
        self.assertIn("&lt;img src=x onerror=bad&gt;", content)
        self.assertIn("Writer &lt;script&gt;bad&lt;/script&gt;", content)
        self.assertIn("Summary &lt;b&gt;plain&lt;/b&gt;", content)
        self.assertIn('class="blog-byline"', content)
        self.assertIn('<time datetime="2026-02-01T00:00:00Z">1 Feb 2026</time>', content)
        self.assertIn("https://github.com/stubbi/asm/blob/main/blog/posts/safe-source.md", page.links)
        resolved = [urlsplit(urljoin(page.canonicals[0], href)).path for href in page.links]
        self.assertIn("/blog/", resolved)
        self.assertIn("/blog/articles/", resolved)
        self.assertFalse(any(href.startswith("javascript:") for href in page.links))
        self.assertEqual(path.read_bytes(), before)
        self.assertFalse((self.stage / "blog/posts").exists())

    def test_drafts_are_local_noindex_previews_and_never_feed_or_sitemap_entries(self):
        self.article("unpublished", title="Draft architecture", date=None, draft=True)
        self.article("future-draft", title="Future draft", date="2999-01-01", draft=True)
        self.article("already-published")
        routes = self.build(dates=self.dates)
        self.assertFalse((self.stage / "blog/articles/unpublished").exists())
        self.assertFalse((self.stage / "blog/articles/future-draft").exists())
        self.assertNotIn("Draft architecture", (self.stage / "blog/index.html").read_text())
        self.assertEqual(len(self.feed().findall("a:entry", ATOM)), 3)
        routes = self.build(dates=self.dates, include_drafts=True)
        self.assertNotIn("blog/articles/unpublished/", routes)
        self.assertNotIn("blog/articles/future-draft/", routes)
        for route in routes + ["blog/articles/unpublished/", "blog/articles/future-draft/"]:
            content = (self.stage / route / "index.html").read_text(encoding="utf-8")
            self.assertIn("noindex", Page(content).robots)
            self.assertEqual(Page(content).structured, [])
            self.assertIn('property="og:type" content="website"', content)
        archive_head = (self.stage / "blog/articles/index.html").read_text().split("</head>", 1)[0]
        self.assertIn("unpublished drafts", archive_head)
        draft = (self.stage / "blog/articles/unpublished/index.html").read_text()
        self.assertIn("Draft", draft)
        self.assertIn("Unpublished", draft)
        self.assertNotIn("Publication date unavailable", draft)
        entries = self.feed().findall("a:entry", ATOM)
        self.assertEqual(len(entries), 3)
        self.assertEqual([entry.findtext("a:id", namespaces=ATOM) for entry in entries if "/articles/" in entry.findtext("a:id", namespaces=ATOM)],
                         ["https://asm.build/blog/articles/already-published/"])

    def test_invalid_articles_fail_before_any_release_or_archive_output(self):
        path = self.article("invalid", date="2999-01-01")
        before = path.read_bytes()
        with self.assertRaises(registry.RegistryError): self.build(dates=self.dates)
        self.assertFalse((self.stage / "blog").exists())
        self.assertEqual(path.read_bytes(), before)
        self.article("invalid", draft=True, date=None, body="# Duplicate page title\n")
        with self.assertRaises(registry.RegistryError): self.build(dates=self.dates)
        self.assertFalse((self.stage / "blog").exists())


if __name__ == "__main__": unittest.main()
