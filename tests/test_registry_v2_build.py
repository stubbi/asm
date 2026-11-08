"""Build the V2 website from selected mirror bytes and private observations.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from contextlib import redirect_stdout, redirect_stderr
import inspect
import io
import json
from pathlib import Path
import sys
import unittest
from urllib.parse import unquote, urljoin, urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import build_site
import registry
import site_routes
from test_site import SiteParser
import test_registry_v2_stats as fixtures


class RegistryV2BuildTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.RegistryV2StatsTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        stamp = self.fixture.public.read_object("metadata/1.timestamp.json", 16384)
        self.fixture.public.create_object("metadata/timestamp.json", stamp[0])
        self.output = self.fixture.root / "website"

    def build(self, **changes):
        self.assertIn("v2_distribution_root", inspect.signature(build_site.build_site).parameters,
                      "the site builder cannot select the V2 registry")
        options = dict(v2_distribution_root=self.fixture.public.root,
                       v2_registry_id=self.fixture.registry_id,
                       v2_mirrors=("https://mirror.example/asm",),
                       origin_log_state=self.fixture.state, origin_log_sources=("origin",))
        options.update(changes)
        return build_site.build_site(ROOT, ROOT / "registry", self.output, **options)

    def test_v2_build_uses_current_identity_and_keeps_unreported_counts_unknown(self):
        result = self.build()
        self.assertEqual(result["registry_schema"], 2)
        self.assertEqual(result["registry_id"], self.fixture.registry_id)
        index = json.loads((self.output / "registry/v2/index.json").read_text())
        self.assertEqual(index["schema"], 2)
        self.assertEqual({p["name"] for p in index["packages"]}, {"fixture/one", "fixture/two"})
        counts = json.loads((self.output / "registry/v2/downloads.json").read_text())
        self.assertEqual(counts["counts"], {"2" * 32: None, "4" * 32: None})
        self.assertFalse(self.fixture.state.exists())
        self.assertFalse((self.output / "registry/v1/index.json").exists())
        home = (self.output / "index.html").read_text()
        self.assertIn('data-registry-version="2"', home)
        self.assertIn('href="/registry/v2/index.json"', home)
        page = (self.output / "packages/fixture/one/1.0.0/index.html").read_text()
        self.assertIn("asm registry fetch fixture/one@1.0.0", page)
        self.assertIn(self.fixture.registry_id, page)
        self.assertNotIn("github.com/fixture/one", page)
        self.assertIn("Download activity is unavailable", page)
        self.assertTrue((self.output / "docs/index.html").is_file())
        docs = (self.output / "docs/index.html").read_text()
        self.assertIn("Use the V2 client", docs)
        self.assertIn("docs/specs/registry-v2.md", docs)
        self.assertNotIn("submit a registry pull request", docs)
        self.assertTrue((self.output / "blog/index.html").is_file())
        self.assertFalse((self.output / "blog/releases/0.6.0/index.html").exists())
        self.assertNotIn("events.sqlite3", [p.name for p in self.output.rglob("*")])

    def test_v2_stage_retains_shared_info_routes_policy_and_asset_finalization(self):
        self.build()
        for route in ("about", "contact", "privacy"):
            self.assertTrue((self.output / route / "index.html").is_file(), route)
        home = (self.output / "index.html").read_text()
        self.assertIn('http-equiv="Content-Security-Policy"', home)
        self.assertIn('href="/about"', home)
        self.assertNotIn('href="guide.html"', home)
        detail = (self.output / "packages/fixture/one/1.0.0/index.html").read_text()
        self.assertIn('data-registry-version="2"', detail)
        self.assertIn('href="https://asm.build/packages/fixture/one/1.0.0"', detail)
        self.assertIn('http-equiv="Content-Security-Policy"', detail)
        self.assertLess((self.output / "app.js").stat().st_size, (ROOT / "site/app.js").stat().st_size)
        self.assertTrue((self.output / ".well-known/security.txt").is_file())
        privacy = (self.output / "privacy/index.html").read_text()
        self.assertIn("private server observations", privacy)
        self.assertNotIn("GitHub Pages hosts asm.build", privacy)
        self.assertFalse((self.output / "registry/v1/index.json").exists())

    def test_actual_import_reaches_the_selected_package_without_crediting_shared_bytes(self):
        store = self.fixture.store()
        self.assertTrue(self.fixture.batch(store, [self.fixture.event()]))
        self.assertFalse(self.fixture.batch(store, [self.fixture.event()]))
        self.build()
        counts = json.loads((self.output / "registry/v2/downloads.json").read_text())
        self.assertEqual(counts["counts"], {"2" * 32: 1, "4" * 32: 0})
        self.assertEqual(counts["release_counts"], {"3" * 32: 1, "5" * 32: 0})
        self.assertFalse(counts["complete"])
        stats = (self.output / "stats/index.html").read_text()
        self.assertIn("Coverage is incomplete", stats)
        self.assertIn("fixture/one", stats)
        self.assertIn("stale", stats.lower())
        popular = (self.output / "browse/popular/index.html").read_text()
        self.assertIn("fixture/one", popular)
        self.assertNotIn('href="../../packages/fixture/two/"', popular)

    def test_v2_pages_resolve_all_local_navigation_assets_and_fragments(self):
        self.build()
        routes = site_routes.PageRoutes.from_directory(self.output)
        pages = {}
        for path in self.output.rglob("*.html"):
            page = SiteParser()
            page.feed(path.read_text())
            pages[path.relative_to(self.output)] = page
        for name, page in pages.items():
            self.assertEqual(len(page.canonicals), 1, name)
            base = page.canonicals[0]
            for value in [*page.assets, *(link.get("href", "") for link in page.links)]:
                with self.subTest(page=name, reference=value):
                    self.assertTrue(value.strip())
                    url = urlsplit(urljoin(base, value))
                    if url.netloc != "asm.build":
                        self.assertIn(url.scheme, {"https", "mailto"})
                        continue
                    relative = routes.file_for(unquote(url.path))
                    if relative is not None:
                        self.assertEqual(url.path, routes.canonical_path(url.path))
                    destination = relative if relative is not None else Path(unquote(url.path).lstrip("/"))
                    self.assertTrue((self.output / destination).is_file(), value)
                    if url.fragment and destination.suffix == ".html" and not url.fragment.startswith("search?"):
                        self.assertIn(unquote(url.fragment), pages[destination].ids)

    def test_wrong_registry_and_incomplete_configuration_do_not_publish_output(self):
        for changes in ({"v2_registry_id": "f" * 32}, {"v2_mirrors": ()},
                        {"v2_registry_id": None}, {"v2_distribution_root": None},
                        {"downloads": True}, {"delivery": True}):
            with self.subTest(changes=changes), self.assertRaises(registry.RegistryError):
                self.build(**changes)
            self.assertFalse(self.output.exists())

    def test_public_or_input_state_is_refused_before_publication(self):
        for path in (self.output / "private.sqlite3", self.fixture.public.root / "private.sqlite3"):
            with self.subTest(path=path), self.assertRaises(registry.RegistryError):
                self.build(origin_log_state=path)
            self.assertFalse(path.exists())
            self.assertFalse(self.output.exists())

    def test_existing_destination_remains_unchanged(self):
        self.output.mkdir()
        sentinel = self.output / "existing.txt"
        sentinel.write_bytes(b"Keep these existing bytes.")
        with self.assertRaises(registry.RegistryError):
            self.build()
        self.assertEqual(list(self.output.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), b"Keep these existing bytes.")

    def test_cli_selects_v2_without_upstream_or_v1_measurements(self):
        self.assertIn("v2_distribution_root", inspect.signature(build_site.build_site).parameters)
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            result = build_site.main(["--repo", str(ROOT), "--output", str(self.output),
                "--v2-distribution-root", str(self.fixture.public.root),
                "--v2-registry-id", self.fixture.registry_id, "--v2-mirror", "https://mirror.example/asm"])
        self.assertEqual(result, 0)
        self.assertEqual(json.loads((self.output / "registry/v2/index.json").read_text())["schema"], 2)

    def test_agent_instructions_describe_v2_trust_and_commands(self):
        self.build()
        instructions = (self.output / "agents.md").read_text()
        self.assertIn("asm registry fetch", instructions)
        self.assertIn("independent trusted channel", instructions)
        self.assertIn("make registry-cli", instructions)
        self.assertIn("do not supply V2 discovery", instructions)
        self.assertNotIn("It has no independent metadata signature", instructions)


if __name__ == "__main__":
    unittest.main()
