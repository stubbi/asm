"""Repository articles stay bounded, explicit, and separate from publication.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from datetime import datetime, timezone
from html.parser import HTMLParser
import importlib
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry

NOW = datetime(2026, 11, 7, 12, tzinfo=timezone.utc)
HEADER = 'title = "A measured change"\nsummary = "A concrete result and its limits."\nauthor = "Asm contributors"\ndraft = false\ndate = 2026-11-07\n'


class Markup(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.tags, self.links, self.events = [], [], []
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        self.tags.append(tag)
        self.events.extend(key for key, _ in attrs if key.startswith("on"))
        if tag == "a": self.links.append(dict(attrs)["href"])


class BlogPostsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name) / "repo"
        self.repo.mkdir()
        self.posts = self.repo / "blog/posts"

    def module(self):
        self.assertTrue((ROOT / "tools/blog_posts.py").is_file(), "The repository article loader is not implemented.")
        return importlib.import_module("blog_posts")

    def write(self, slug="measured-change", *, header=HEADER, body="## Result\n\nThe recorded result retains its limits.\n"):
        self.posts.mkdir(parents=True, exist_ok=True)
        path = self.posts / (slug + ".md")
        path.write_text("+++\n" + header + "+++\n" + body, encoding="utf-8")
        return path

    def load(self, **kwargs):
        return self.module().load_posts(self.repo, now=NOW, **kwargs)

    def test_published_record_keeps_plain_metadata_real_dates_and_safe_body(self):
        path = self.write(header=HEADER + "updated = 2026-11-07\n")
        before = path.read_bytes()
        records = self.load()
        self.assertEqual(len(records), 1)
        post = records[0]
        self.assertEqual(set(post), {"kind", "title", "summary", "author", "date", "updated", "route", "html", "source", "draft"})
        self.assertEqual(post["kind"], "article")
        self.assertEqual(post["title"], "A measured change")
        self.assertEqual(post["summary"], "A concrete result and its limits.")
        self.assertEqual(post["author"], "Asm contributors")
        self.assertEqual(post["date"], "2026-11-07T00:00:00Z")
        self.assertEqual(post["updated"], post["date"])
        self.assertEqual(post["route"], "blog/articles/measured-change/")
        self.assertEqual(post["source"], "https://github.com/stubbi/asm/blob/main/blog/posts/measured-change.md")
        self.assertFalse(post["draft"])
        self.assertIn("The recorded result retains its limits.", post["html"])
        self.assertNotIn("h1", Markup(post["html"]).tags)
        self.assertEqual(path.read_bytes(), before)

    def test_absent_and_empty_source_directories_are_empty_without_writes(self):
        self.assertEqual(self.load(), [])
        self.assertFalse((self.repo / "blog").exists())
        self.posts.mkdir(parents=True)
        self.assertEqual(self.load(), [])
        self.assertEqual(list(self.posts.iterdir()), [])

    def test_drafts_are_validated_but_omitted_and_optional_dates_are_not_invented(self):
        self.write("unfinished", header=HEADER.replace("draft = false", "draft = true").replace("date = 2026-11-07\n", ""))
        self.write("future-draft", header=HEADER.replace("draft = false", "draft = true").replace("2026-11-07", "2027-01-01"))
        self.assertEqual(self.load(), [])
        preview = self.load(include_drafts=True)
        self.assertEqual([post["route"] for post in preview], ["blog/articles/future-draft/", "blog/articles/unfinished/"])
        self.assertTrue(all(post["draft"] for post in preview))
        self.assertIsNone(preview[1]["date"])
        self.assertIsNone(preview[1]["updated"])
        self.write("bad-draft", header=HEADER.replace("draft = false", "draft = true") + "unknown = 1\n")
        with self.assertRaises(registry.RegistryError): self.load()

    def test_posts_sort_by_declared_date_then_stable_slug(self):
        self.write("z-last")
        self.write("a-first")
        self.write("older", header=HEADER.replace("2026-11-07", "2026-11-06"))
        self.assertEqual([post["route"] for post in self.load()], ["blog/articles/a-first/", "blog/articles/z-last/", "blog/articles/older/"])

    def test_metadata_is_strict_toml_with_only_required_typed_fields(self):
        invalid = [HEADER + 'title = "Duplicate"\n', HEADER + 'tags = ["assembly"]\n', HEADER + '[nested]\nvalue = 1\n',
                   HEADER.replace("draft = false\n", ""), HEADER.replace("draft = false", 'draft = "false"'),
                   HEADER.replace('title = "A measured change"', "title = 5"), HEADER.replace('author = "Asm contributors"', 'author = ""'),
                   HEADER.replace('summary = "A concrete result and its limits."', 'summary = "   "'),
                   HEADER.replace('title = "A measured change"', 'title = "' + "t" * 121 + '"'),
                   HEADER.replace('summary = "A concrete result and its limits."', 'summary = "' + "s" * 241 + '"'),
                   HEADER.replace('author = "Asm contributors"', 'author = "' + "a" * 81 + '"'),
                   HEADER.replace('title = "A measured change"', 'title = "Line\\nbreak"')]
        for header in invalid:
            with self.subTest(header=header):
                self.write(header=header)
                with self.assertRaises(registry.RegistryError): self.load()

    def test_published_dates_require_calendar_dates_and_cannot_be_future_or_reversed(self):
        invalid = [HEADER.replace("date = 2026-11-07\n", ""), HEADER.replace("2026-11-07", '"2026-11-07"'),
                   HEADER.replace("2026-11-07", "2026-11-07T00:00:00Z"), HEADER.replace("2026-11-07", "2026-11-08"),
                   HEADER.replace("2026-11-07", "2026-02-30"), HEADER + "updated = 2026-11-06\n",
                   HEADER + "updated = 2026-11-08\n", HEADER + 'updated = "2026-11-07"\n']
        for header in invalid:
            with self.subTest(header=header):
                self.write(header=header)
                with self.assertRaises(registry.RegistryError): self.load()

    def test_markdown_escapes_html_omits_images_and_restricts_links_without_execution(self):
        sentinel = self.repo / "executed"
        body = ('<script>alert(1)</script><img src=x onerror="bad">\n\n![remote](https://example.com/a.png)\n\n'
                '[unsafe](javascript:alert) [relative](other.md#result) [section](#result) [safe](https://example.com/result)\n\n'
                '```python\n# This is code, not the article title.\n__import__("pathlib").Path("' + str(sentinel) + '").touch()\n```\n')
        self.write(body=body)
        html = self.load()[0]["html"]
        markup = Markup(html)
        self.assertNotIn("script", markup.tags)
        self.assertNotIn("img", markup.tags)
        self.assertEqual(markup.events, [])
        self.assertFalse(any(href.startswith("javascript:") for href in markup.links))
        self.assertIn("https://github.com/stubbi/asm/blob/main/blog/posts/other.md#result", markup.links)
        self.assertIn("https://github.com/stubbi/asm/blob/main/blog/posts/measured-change.md#result", markup.links)
        self.assertIn("https://example.com/result", markup.links)
        self.assertIn("&lt;script&gt;", html)
        self.assertFalse(sentinel.exists())

    def test_metadata_remains_plain_text_for_the_page_renderer_to_escape(self):
        self.write(header=HEADER.replace("A measured change", "<img src=x onerror=bad>"))
        self.assertEqual(self.load()[0]["title"], "<img src=x onerror=bad>")

    def test_article_sections_use_h2_h3_and_fenced_titles_remain_code(self):
        self.write(body="## Result\n\n### Limits\n\n~~~markdown\n# Tilde-fenced example\n~~~\n\n"
                        "````markdown\n# Long-fenced example\n```\n# Short delimiter stays inside code\n````\n")
        html = self.load()[0]["html"]
        tags = Markup(html).tags
        self.assertEqual(tags.count("h2"), 1)
        self.assertEqual(tags.count("h3"), 1)
        self.assertEqual(tags.count("pre"), 2)
        self.assertNotIn("h1", tags)
        self.assertIn("# Tilde-fenced example", html)
        self.assertIn("# Short delimiter stays inside code", html)

    def test_encoding_controls_delimiters_empty_body_and_extra_h1_fail(self):
        invalid = [b"\xff", ("+++\n" + HEADER).encode(), (" ---\n" + HEADER + "---\nBody").encode(),
                   ("+++\n" + HEADER + "+++\n\t\n").encode(),
                   ("+++\n" + HEADER + "+++\nBody\x00").encode(),
                   ("+++\n" + HEADER + "+++\nBody\x7f").encode(),
                   ("+++\n" + HEADER + "+++\n# Another title\n").encode(),
                   ("+++\n" + HEADER + "+++\nAnother title\n===\n").encode()]
        path = self.write()
        for raw in invalid:
            with self.subTest(raw=raw[-35:]):
                path.write_bytes(raw)
                with self.assertRaises(registry.RegistryError): self.load()

    def test_post_count_byte_and_body_line_limits_are_enforced(self):
        overhead = len(("+++\n" + HEADER + "+++\n").encode())
        path = self.write(body="a" * (128 * 1024 - overhead))
        self.assertEqual(len(path.read_bytes()), 128 * 1024)
        self.assertEqual(len(self.load()), 1)
        path.write_bytes(path.read_bytes() + b"a")
        with self.assertRaises(registry.RegistryError): self.load()
        self.write(body="a\n" * 4096)
        self.assertEqual(len(self.load()), 1)
        self.write(body="a\n" * 4097)
        with self.assertRaises(registry.RegistryError): self.load()
        path.unlink()
        for number in range(128): self.write("post-" + str(number))
        self.assertEqual(len(self.load()), 128)
        self.write("one-too-many")
        with self.assertRaises(registry.RegistryError): self.load()

    def test_invalid_slugs_or_unexpected_directory_entries_fail(self):
        for name in ("Uppercase", "has--gap", "trailing-", "a" * 65, "1-start", "has space"):
            with self.subTest(name=name):
                path = self.write(name)
                with self.assertRaises(registry.RegistryError): self.load()
                path.unlink()
        (self.posts / "nested").mkdir()
        with self.assertRaises(registry.RegistryError): self.load()

    def test_symlink_files_directories_and_nonregular_sources_fail(self):
        outside = self.repo / "outside.md"
        outside.write_text("Not an article.")
        self.posts.mkdir(parents=True)
        linked = self.posts / "linked.md"
        linked.symlink_to(outside)
        with self.assertRaises(registry.RegistryError): self.load()
        linked.unlink()
        os.mkfifo(linked)
        with self.assertRaises(registry.RegistryError): self.load()
        linked.unlink()
        self.posts.rmdir()
        self.posts.symlink_to(self.repo, target_is_directory=True)
        with self.assertRaises(registry.RegistryError): self.load()
        self.posts.unlink()
        (self.repo / "blog").rmdir()
        (self.repo / "blog").symlink_to(self.repo, target_is_directory=True)
        with self.assertRaises(registry.RegistryError): self.load()

    def test_hardlinked_article_and_invalid_call_options_fail(self):
        path = self.write()
        os.link(path, self.repo / "second-link")
        with self.assertRaises(registry.RegistryError): self.load()
        (self.repo / "second-link").unlink()
        for value in (None, 1, "true"):
            with self.subTest(value=value), self.assertRaises(registry.RegistryError): self.load(include_drafts=value)
        with self.assertRaises(registry.RegistryError): self.module().load_posts(self.repo, now=datetime(2026, 11, 7))

    def test_deeply_nested_metadata_has_a_controlled_failure(self):
        self.write(header=HEADER.replace('author = "Asm contributors"', "author = " + "[" * 2048 + "0" + "]" * 2048))
        program = '''import sys
from datetime import datetime, timezone
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import blog_posts, registry
try:
    blog_posts.load_posts(Path(sys.argv[2]), now=datetime(2026,11,7,tzinfo=timezone.utc))
except registry.RegistryError:
    sys.exit(0)
raise SystemExit("Deep metadata was accepted")
'''
        result = subprocess.run([sys.executable, "-c", program, str(ROOT / "tools"), str(self.repo)],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr[:500])

    def test_oversized_numeric_metadata_has_a_controlled_failure(self):
        self.write(header=HEADER.replace('author = "Asm contributors"', "author = " + "9" * 5000))
        with self.assertRaises(registry.RegistryError): self.load()


if __name__ == "__main__": unittest.main()
