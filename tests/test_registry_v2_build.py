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

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import build_site
import registry
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
        self.assertIn('href="registry/v2/index.json"', home)
        page = (self.output / "packages/fixture/one/1.0.0/index.html").read_text()
        self.assertIn("asm registry fetch fixture/one@1.0.0", page)
        self.assertIn(self.fixture.registry_id, page)
        self.assertNotIn("github.com/fixture/one", page)
        self.assertIn("Download activity is unavailable", page)
        self.assertTrue((self.output / "docs/index.html").is_file())
        docs = (self.output / "docs/index.html").read_text()
        self.assertIn("Build the V2 preview", docs)
        self.assertIn("docs/specs/registry-v2.md", docs)
        self.assertNotIn("submit a registry pull request", docs)
        self.assertTrue((self.output / "blog/index.html").is_file())
        self.assertFalse((self.output / "blog/releases/0.6.0/index.html").exists())
        self.assertNotIn("events.sqlite3", [p.name for p in self.output.rglob("*")])

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
