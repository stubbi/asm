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
        (self.stage / "index.html").write_text("Install GitHub CLI at /usr/bin/gh.")
        self.url = "https://github.com/stubbi/asm/releases/download/v0.5.0"
        self.payload = b"never execute candidate"
        self.installer = b"qualified installer"
        self.release = {"version":"0.5.0", "source_commit":"a" * 40,
                        "bundle_url":self.url + "/release-attestation.sigstore.json",
                        "artifacts":[{"url":self.url + "/asm-0.5.0-x86_64-linux", "bytes":len(self.payload),
                                      "sha256":hashlib.sha256(self.payload).hexdigest()}]}
        self.manifest = {"version":"0.5.0", "source_commit":"a" * 40,
                         "repository":trusted_site.bootstrap.REPOSITORY,
                         "distribution":{"profile":"asm-tuf-v1", "root_sha256":hashlib.sha256(b"public root fixture").hexdigest()},
                         "assets":[{"file":"install.sh", "bytes":len(self.installer),
                                    "sha256":hashlib.sha256(self.installer).hexdigest()}]}

    def reader(self, url, limit):
        data = {self.url + "/release.json":json.dumps(self.manifest).encode(),
                self.release["bundle_url"]:b"bundle fixture",
                self.url + "/install.sh":self.installer,
                self.release["artifacts"][0]["url"]:self.payload}[url]
        self.assertLessEqual(len(data), limit)
        return data

    def attach(self):
        trusted_site.attach(self.stage, self.source, self.publication, self.release, self.reader,
                            self.base / "verifier", self.base / "inspector")

    def assert_unpublished(self):
        self.assertEqual((self.stage / "install.sh").read_bytes(), b"old installer")
        self.assertFalse((self.stage / "trust").exists())

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
