"""Exercise the JavaScript bytes that the static site publishes.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
from html.parser import HTMLParser
import gzip
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
try:
    import site_assets
except ModuleNotFoundError:
    site_assets = None

NODE_SUITES = ("site.test.cjs", "package-demo.test.cjs", "package-navigation.test.cjs",
               "discovery.test.cjs", "navigation.test.cjs", "repository-stars.test.cjs")


class HeadPolicy(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tags = []
        self.in_head = False

    def handle_starttag(self, tag, attrs):
        if tag == "head":
            self.in_head = True
        if self.in_head:
            self.tags.append((tag, dict(attrs)))

    def handle_endtag(self, tag):
        if tag == "head":
            self.in_head = False


class SiteAssetTests(unittest.TestCase):
    def require_minifier(self):
        self.assertIsNotNone(site_assets, "The production asset minifier is not implemented")
        return site_assets

    def test_published_scripts_are_smaller_and_keep_all_existing_behavior(self):
        assets = self.require_minifier()
        originals = {path.name: path.read_bytes() for path in (ROOT / "site").glob("*.js")}
        self.assertTrue(originals)
        with tempfile.TemporaryDirectory(prefix="asm-site-assets-") as temporary:
            repo = Path(temporary)
            stage = repo / "site"
            stage.mkdir()
            for name, source in originals.items():
                (stage / name).write_bytes(source)
            assets.minify_scripts(stage)
            first = {name: (stage / name).read_bytes() for name in originals}
            self.assertLess(sum(map(len, first.values())), sum(map(len, originals.values())) * 0.65)
            self.assertLess(sum(len(gzip.compress(value, mtime=0)) for value in first.values()),
                            sum(len(gzip.compress(value, mtime=0)) for value in originals.values()) * 0.8)
            for name, source in originals.items():
                with self.subTest(asset=name):
                    compact = first[name]
                    self.assertLess(len(compact), len(source) * 0.9)
                    self.assertLess(len(gzip.compress(compact, mtime=0)), len(gzip.compress(source, mtime=0)))
                    if source.startswith(b"/*"):
                        notice = source.split(b"*/", 1)[0] + b"*/"
                        self.assertTrue(compact.startswith(notice), "The source notice must remain intact")
                    self.assertEqual((ROOT / "site" / name).read_bytes(), source)
            # Rebuild the same source, rather than minifying an already-built file.
            for name, source in originals.items():
                (stage / name).write_bytes(source)
            assets.minify_scripts(stage)
            self.assertEqual({name: (stage / name).read_bytes() for name in originals}, first)

            tests = repo / "tests"
            tests.mkdir()
            for name in (*NODE_SUITES, "count-format-cases.json"):
                shutil.copyfile(ROOT / "tests" / name, tests / name)
            shutil.copytree(ROOT / "examples/math", repo / "examples/math",
                            ignore=shutil.ignore_patterns("build"))
            result = subprocess.run(["node", "--test", *(str(tests / name) for name in NODE_SUITES)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_minifier_uses_the_reviewed_upstream_source_and_preserves_its_license(self):
        self.require_minifier()
        vendor = ROOT / "tools/vendor/terser"
        self.assertTrue((vendor / "bundle.min.js").is_file(), "The reviewed Terser bundle is missing")
        self.assertEqual(hashlib.sha256((vendor / "bundle.min.js").read_bytes()).hexdigest(),
                         "379f8758191b03c07745486e785cbf4bed6a7ae368aa40a5a819556743f3ad1c")
        self.assertEqual(hashlib.sha256((vendor / "LICENSE").read_bytes()).hexdigest(),
                         "901d0a7fcaccaae9917d165039c0473c354e5da2e0e94140dde67aad9ffb19da")

    def test_invalid_javascript_leaves_every_staged_asset_unchanged(self):
        assets = self.require_minifier()
        with tempfile.TemporaryDirectory(prefix="asm-site-invalid-js-") as temporary:
            stage = Path(temporary)
            originals = {"a.js": b"const valid = true;", "z.js": b"function ("}
            for name, content in originals.items():
                (stage / name).write_bytes(content)
            with self.assertRaisesRegex(ValueError, "JavaScript minification failed"):
                assets.minify_scripts(stage)
            self.assertEqual({name: (stage / name).read_bytes() for name in originals}, originals)

    def test_missing_node_identifies_the_standalone_build_prerequisite(self):
        assets = self.require_minifier()
        with tempfile.TemporaryDirectory(prefix="asm-site-node-") as temporary:
            stage = Path(temporary)
            (stage / "fixture.js").write_text("const missingNodeFixture = true;")
            with patch("shutil.which", return_value=None), self.assertRaisesRegex(ValueError, "Node.js 18"):
                assets.minify_scripts(stage)

    def test_nested_templates_keep_their_text_without_inherited_node_configuration(self):
        assets = self.require_minifier()
        source = 'const value = "value"; process.stdout.write(`outer ${`inner  ${value}`} end`);'
        with tempfile.TemporaryDirectory(prefix="asm-site-modern-js-") as temporary:
            stage = Path(temporary)
            fixture = stage / "fixture.js"
            fixture.write_text(source)
            with patch.dict(os.environ, {"NODE_OPTIONS": "--require=/asm-nonexistent-preload-fixture.cjs",
                                        "GITHUB_TOKEN": "synthetic-test-value"}):
                assets.minify_scripts(stage)
            result = subprocess.run(["node", str(fixture)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "outer inner  value end")

    def test_asset_symlinks_and_oversized_source_are_rejected_without_changing_the_source(self):
        assets = self.require_minifier()
        with tempfile.TemporaryDirectory(prefix="asm-site-assets-bound-") as temporary:
            directory = Path(temporary)
            stage = directory / "site"
            stage.mkdir()
            source = directory / "private.js"
            source.write_bytes(b"/* private fixture */\nconst untouched = true;\n")
            original = source.read_bytes()
            link = stage / "app.js"
            link.symlink_to(source)
            with self.assertRaises(ValueError):
                assets.minify_scripts(stage)
            self.assertEqual(source.read_bytes(), original)
            link.unlink()
            link.write_bytes(b" " * (1024 * 1024 + 1))
            with self.assertRaises(ValueError):
                assets.minify_scripts(stage)
            self.assertEqual(link.stat().st_size, 1024 * 1024 + 1)

    def test_minification_failure_does_not_publish_a_partial_site(self):
        self.require_minifier()
        import build_site
        with tempfile.TemporaryDirectory(prefix="asm-site-assets-failure-") as temporary:
            destination = Path(temporary) / "site"
            original = (ROOT / "site/app.js").read_bytes()
            with patch.object(site_assets, "minify_scripts", side_effect=ValueError("asset fixture failure")):
                with self.assertRaisesRegex(ValueError, "asset fixture failure"):
                    build_site.build_site(ROOT, ROOT / "registry", destination)
            self.assertFalse(destination.exists())
            self.assertEqual((ROOT / "site/app.js").read_bytes(), original)

    def test_every_built_page_has_an_early_policy_and_only_external_executable_scripts(self):
        assets = self.require_minifier()
        self.assertTrue(callable(getattr(assets, "with_content_policy", None)), "The document policy is not implemented")
        import build_site
        with tempfile.TemporaryDirectory(prefix="asm-site-csp-") as temporary:
            stage = Path(temporary) / "site"
            build_site.build_site(ROOT, ROOT / "registry", stage)
            pages = list(stage.rglob("*.html"))
            self.assertGreaterEqual(len(pages), 63)
            for path in pages:
                with self.subTest(page=path.relative_to(stage)):
                    head = HeadPolicy()
                    head.feed(path.read_text(encoding="utf-8"))
                    charsets = [index for index, (tag, attrs) in enumerate(head.tags)
                                if tag == "meta" and "charset" in attrs]
                    policies = [(index, attrs["content"]) for index, (tag, attrs) in enumerate(head.tags)
                                if tag == "meta" and attrs.get("http-equiv", "").lower() == "content-security-policy"]
                    self.assertEqual(len(charsets), 1)
                    self.assertEqual(len(policies), 1)
                    position, policy = policies[0]
                    self.assertEqual(position, charsets[0] + 1)
                    directives = {part.split()[0]: part.split()[1:] for part in policy.split(";") if part.strip()}
                    self.assertEqual(directives, {
                        "default-src": ["'none'"], "script-src": ["'self'"],
                        "style-src": ["'self'", "'unsafe-inline'"], "img-src": ["'self'"],
                        "font-src": ["'self'"], "connect-src": ["'self'", "https://api.github.com"],
                        "base-uri": ["'none'"], "form-action": ["'self'"], "object-src": ["'none'"]})
                    for index, (tag, attrs) in enumerate(head.tags):
                        if tag in {"link", "script", "style", "base"}:
                            self.assertGreater(index, position)
                        if tag == "script" and not attrs.get("src"):
                            self.assertIn(attrs.get("type"), {"application/json", "application/ld+json"})
            self.assertFalse((stage / "vendor").exists())
            self.assertFalse((stage / "site_assets.py").exists())

    def test_policy_rejects_ambiguous_charset_late_protection_and_inline_execution(self):
        assets = self.require_minifier()
        self.assertTrue(callable(getattr(assets, "with_content_policy", None)), "The document policy is not implemented")
        cases = (
            '<html><head><title>No encoding</title></head></html>',
            '<html><head><meta charset="utf-8"><meta charset="utf-8"></head></html>',
            '<html><head><script src="navigation.js"></script><meta charset="utf-8"></head></html>',
            '<html><head><meta charset="utf-8"><script>window.executed=true;</script></head></html>',
            '<html><head><meta charset="utf-8"><script type>window.executed=true;</script></head></html>',
            '<html><head><meta charset="utf-8"></head><body><button onclick="run()">Run</button></body></html>',
        )
        for content in cases:
            with self.subTest(content=content), self.assertRaises(ValueError):
                assets.with_content_policy(content)
