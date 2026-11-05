"""Check the agent files produced by the static site builder."""

from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import build_site
import registry


class AgentSiteTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="asm-agent-site-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        for relative in ("site", "cli", "skills/asm-build"):
            shutil.copytree(ROOT / relative, self.repo / relative)
        # Record only a source-reference fixture, without changing repository history.
        for arguments in (("init", "-q"), ("add", "--force", "--", "cli"),
                          ("commit", "-qm", "Record source reference fixture")):
            subprocess.run(["git", "-C", str(self.repo), "-c", "core.hooksPath=/dev/null",
                            "-c", "commit.gpgSign=false", "-c", "user.name=asm site test fixture",
                            "-c", "user.email=fixture@example.invalid", *arguments],
                           check=True, capture_output=True, timeout=10)
        self.output = self.root / "output"

    def build(self):
        def forbidden(*args, **kwargs):
            raise AssertionError("Static agent packaging must not use the network")

        return build_site.build_site(self.repo, ROOT / "registry", self.output,
                                     artifact_reader=forbidden, metrics_fetcher=forbidden)

    def test_publishes_the_exact_canonical_skill_tree(self):
        self.build()
        canonical = ROOT / "skills/asm-build"
        published = self.output / "skills/asm-build"
        self.assertTrue(published.is_dir(), "The maintained skill must be published")
        expected = {path.relative_to(canonical): path.read_bytes()
                    for path in canonical.rglob("*") if path.is_file()}
        actual = {path.relative_to(published): path.read_bytes()
                  for path in published.rglob("*") if path.is_file()}
        self.assertEqual(actual, expected)

    def test_agent_entry_points_link_to_published_files(self):
        self.build()
        entry = self.output / "llms.txt"
        self.assertTrue(entry.is_file(), "The AI entry point must be published")
        links = re.findall(r"\]\((https://asm\.build/[^)]+)\)", entry.read_text(encoding="utf-8"))
        paths = {urlsplit(link).path for link in links}
        self.assertTrue({"/agents.md", "/skills/asm-build/SKILL.md", "/registry/v1/index.json"}.issubset(paths))
        for path in paths:
            with self.subTest(path=path):
                self.assertTrue((self.output / path.lstrip("/")).is_file())
        self.assertEqual((self.output / "agents.md").read_bytes(),
                         (ROOT / "site/agents.md").read_bytes())

    def test_existing_output_is_preserved(self):
        self.output.mkdir()
        original = self.output / "keep.txt"
        original.write_bytes(b"existing publication\n")
        with self.assertRaisesRegex(registry.RegistryError, "output already exists"):
            self.build()
        self.assertEqual(list(self.output.iterdir()), [original])
        self.assertEqual(original.read_bytes(), b"existing publication\n")

    def test_missing_skill_does_not_publish_an_incomplete_site(self):
        shutil.rmtree(self.repo / "skills/asm-build")
        with self.assertRaisesRegex(registry.RegistryError, "source directory must exist"):
            self.build()
        self.assertFalse(self.output.exists())

    def test_skill_links_are_rejected_before_publication(self):
        outside = self.root / "outside.txt"
        outside.write_bytes(b"not a published skill reference\n")
        reference = self.repo / "skills/asm-build/references/requirements.md"
        reference.unlink()
        reference.symlink_to(outside)
        with self.assertRaisesRegex(registry.RegistryError, "source links are not allowed"):
            self.build()
        self.assertFalse(self.output.exists())
        self.assertEqual(outside.read_bytes(), b"not a published skill reference\n")


if __name__ == "__main__":
    unittest.main()
