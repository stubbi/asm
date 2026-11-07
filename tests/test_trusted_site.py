"""Test publication gates; signed metadata itself is covered by the Go suite.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import trusted_site
from test_bootstrap import installer_page_fixture
from test_site import SiteParser


class TrustedSiteTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.stage = self.base / "stage"
        self.source = self.base / "source"
        self.publication = self.base / "publication"
        for path in (self.stage / "registry/v1", self.source / "verifier/trust", self.publication / "metadata"):
            path.mkdir(parents=True)
        (self.source / "verifier/trust/asm-root.json").write_bytes(b"public root fixture")
        (self.publication / "metadata/timestamp.json").write_bytes(b"timestamp fixture")
        for name in ("index.tsv", "index-macos.tsv"):
            (self.stage / "registry/v1" / name).write_bytes(name.encode())
        (self.stage / "install.sh").write_bytes(b"old installer")
        self.url = "https://github.com/stubbi/asm/releases/download/v0.5.0"
        self.payload = b"never execute candidate"
        self.installer = b"qualified installer"
        self.release = {"version":"0.5.0", "source_commit":"a" * 40,
                        "repository_id":trusted_site.bootstrap.REPOSITORY_ID,
                        "bundle_url":self.url + "/release-attestation.sigstore.json",
                        "artifacts":[{"target":target, "url":self.url + "/asm-0.5.0-" + target,
                                      "bytes":len(self.payload), "sha256":hashlib.sha256(self.payload).hexdigest()}
                                     for target in trusted_site.bootstrap.TARGETS]}
        self.manifest = {"version":"0.5.0", "source_commit":"a" * 40,
                         "repository":trusted_site.bootstrap.REPOSITORY,
                         "distribution":{"profile":"asm-tuf-v1", "root_sha256":hashlib.sha256(b"public root fixture").hexdigest()},
                         "assets":[{"file":"install.sh", "bytes":len(self.installer),
                                    "sha256":hashlib.sha256(self.installer).hexdigest()}]}
        before, rest = installer_page_fixture().split(trusted_site.bootstrap.START)
        _, after = rest.split(trusted_site.bootstrap.END)
        checked_page = (before + trusted_site.bootstrap.START +
                        trusted_site.bootstrap.installer_markup(self.release) +
                        trusted_site.bootstrap.END + after)
        self.initial_page = checked_page.encode("utf-8")
        (self.stage / "index.html").write_bytes(self.initial_page)

    def reader(self, url, limit):
        data = {self.url + "/release.json":json.dumps(self.manifest).encode(),
                self.release["bundle_url"]:b"bundle fixture",
                self.url + "/install.sh":self.installer,
                **{artifact["url"]:self.payload for artifact in self.release["artifacts"]}}[url]
        self.assertLessEqual(len(data), limit)
        return data

    def attach(self):
        trusted_site.attach(self.stage, self.source, self.publication, self.release, self.reader,
                            self.base / "verifier", self.base / "inspector")

    def assert_unpublished(self):
        self.assertEqual((self.stage / "install.sh").read_bytes(), b"old installer")
        self.assertEqual((self.stage / "index.html").read_bytes(), self.initial_page)
        self.assertFalse((self.stage / "trust").exists())

    def test_trusted_profile_preserves_homepage_structure_and_copy_targets(self):
        before = SiteParser()
        before.feed(self.initial_page.decode("utf-8"))
        with patch.object(trusted_site.subprocess, "run"):
            self.attach()
        result = (self.stage / "index.html").read_text(encoding="utf-8")
        self.assertNotIn("Install GitHub CLI at /usr/bin/gh.", result)
        self.assertNotIn("Install GitHub CLI at /opt/homebrew/bin/gh.", result)
        self.assertNotIn("https://cli.github.com/", result)
        self.assertIn("The installer downloads and checks its verifier.", result)
        after = SiteParser()
        after.feed(result)
        self.assertEqual(after.main_ids, ["main"])
        self.assertEqual(after.header_count, 1)
        self.assertEqual(after.footer_count, 1)
        self.assertEqual(len(after.headings), 1)
        self.assertEqual(len(after.ids), len(set(after.ids)))
        for field in ("ids", "references", "assets", "canonicals", "metadata", "main_navigation",
                      "footer_link_elements", "header_brands", "footer_brands", "buttons"):
            with self.subTest(field=field):
                self.assertEqual(getattr(after, field), getattr(before, field))
        self.assertTrue(set(after.references).issubset(after.ids))
        self.assertEqual(after.elements_by_id["copy-status"]["attrs"].get("role"), "status")
        for button in after.buttons:
            if "data-copy" in button["attrs"]:
                identifier = button["attrs"]["data-copy"]
                with self.subTest(copy_target=identifier):
                    target = after.elements_by_id[identifier]
                    self.assertEqual(target["tag"], "code")
                    self.assertEqual(target["text"], before.elements_by_id[identifier]["text"])

    def test_checks_release_and_target_bindings_before_copying(self):
        calls = []
        def run(argv, **kwargs):
            calls.append(argv[1])
            self.assert_unpublished()
            if argv[1] == "inspect":
                targets = json.loads(Path(argv[-1]).read_text())
                self.assertEqual(Path(targets["index.tsv"]).read_bytes(), b"index.tsv")
                self.assertEqual(Path(targets["asm-0.5.0-x86_64-linux"]).read_bytes(), self.payload)
        with patch.object(trusted_site.subprocess, "run", side_effect=run):
            self.attach()
        self.assertEqual(calls, ["check-root", "provenance", "inspect"])
        self.assertEqual((self.stage / "install.sh").read_bytes(), self.installer)
        self.assertEqual((self.stage / "trust/v1/metadata/timestamp.json").read_bytes(), b"timestamp fixture")

    def test_verification_failure_preserves_staged_installation(self):
        for command in ("check-root", "provenance", "inspect"):
            with self.subTest(command=command):
                def run(argv, **kwargs):
                    if argv[1] == command:
                        raise subprocess.CalledProcessError(1, argv)
                with patch.object(trusted_site.subprocess, "run", side_effect=run):
                    with self.assertRaises(subprocess.CalledProcessError):
                        self.attach()
                self.assert_unpublished()

    def test_wrong_root_and_changed_installer_are_rejected(self):
        for mutation in ("root", "installer"):
            with self.subTest(mutation=mutation):
                saved = json.loads(json.dumps(self.manifest))
                if mutation == "root":
                    self.manifest["distribution"]["root_sha256"] = "0" * 64
                else:
                    self.manifest["assets"][0]["sha256"] = "0" * 64
                with patch.object(trusted_site.subprocess, "run"):
                    with self.assertRaises(ValueError):
                        self.attach()
                self.assert_unpublished()
                self.manifest = saved

    def without_installation_section(self):
        # Incidental prerequisite text outside the optional marker region must
        # not be rewritten when the homepage no longer provides installer UI.
        self.initial_page = b'<main><h1>Find assembly packages</h1><p>Install GitHub CLI at /usr/bin/gh.</p></main>\n'
        (self.stage / "index.html").write_bytes(self.initial_page)

    def test_qualified_installer_without_homepage_commands_keeps_homepage_bytes(self):
        self.without_installation_section()
        with patch.object(trusted_site.subprocess, "run"):
            self.attach()
        self.assertEqual((self.stage / "install.sh").read_bytes(), self.installer)
        self.assertEqual((self.stage / "trust/v1/metadata/timestamp.json").read_bytes(), b"timestamp fixture")
        self.assertEqual((self.stage / "index.html").read_bytes(), self.initial_page)

    def test_no_homepage_commands_cannot_bypass_trust_or_artifact_checks(self):
        self.without_installation_section()
        for command in ("check-root", "provenance", "inspect"):
            with self.subTest(command=command):
                def run(argv, **kwargs):
                    if argv[1] == command: raise subprocess.CalledProcessError(1, argv)
                with patch.object(trusted_site.subprocess, "run", side_effect=run):
                    with self.assertRaises(subprocess.CalledProcessError): self.attach()
                self.assert_unpublished()
        for mutation in ("root", "installer", "artifact"):
            with self.subTest(mutation=mutation):
                saved = json.loads(json.dumps(self.manifest))
                saved_payload = self.payload
                if mutation == "root": self.manifest["distribution"]["root_sha256"] = "0" * 64
                elif mutation == "installer": self.manifest["assets"][0]["sha256"] = "0" * 64
                else: self.payload = b"changed artifact bytes"
                with patch.object(trusted_site.subprocess, "run"):
                    with self.assertRaises(ValueError): self.attach()
                self.assert_unpublished()
                self.manifest, self.payload = saved, saved_payload

    def test_malformed_optional_markers_cannot_publish_trusted_state(self):
        for content in (trusted_site.bootstrap.START, trusted_site.bootstrap.END,
                        trusted_site.bootstrap.START * 2 + trusted_site.bootstrap.END,
                        trusted_site.bootstrap.END + trusted_site.bootstrap.START):
            with self.subTest(content=content):
                self.initial_page = content.encode()
                (self.stage / "index.html").write_bytes(self.initial_page)
                with patch.object(trusted_site.subprocess, "run"):
                    with self.assertRaises(ValueError): self.attach()
                self.assert_unpublished()
