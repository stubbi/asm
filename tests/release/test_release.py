"""Check exact-commit packaging, deterministic builds, and publication boundaries."""

from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from urllib.error import URLError


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import build_site
import registry
import release
from test_macos_release import minimal_macho, native_evidence


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE).decode().strip()


class FakeResponse(io.BytesIO):
    def __init__(self, data, url, headers=None, status=200):
        super().__init__(data)
        self.url = url
        self.headers = headers or {}
        self.status = status

    def geturl(self):
        return self.url


class FakeOpener:
    def __init__(self, data, url, headers=None):
        self.data, self.url, self.headers = data, url, headers

    def open(self, request, timeout):
        return FakeResponse(self.data, self.url, self.headers)


class LicenseDeclarationTests(unittest.TestCase):
    def test_legacy_mit_source_keeps_its_license(self):
        files = {"LICENSE": (b"MIT License\nLegacy fixture.\n", 0o644)}
        self.assertEqual(release.core_license(files, {"version": "0.1.0"}), "MIT")
        with self.assertRaises(registry.RegistryError):
            release.core_license(files, {"version": "0.2.0"})

    def test_agpl_declaration_requires_separate_mit_template_notice(self):
        # Test source-layout checks, not the legal completeness of a notice.
        files = {
            "LICENSE": (b"GNU AFFERO GENERAL PUBLIC LICENSE\nVersion 3, 19 November 2007\n", 0o644),
            "LICENSING.md": (b"Fixture scope declaration.\n", 0o644),
            "LICENSES/MIT.txt": (b"MIT License\nTemplate fixture.\n", 0o644),
        }
        commands = {"version": "0.2.0", "license": "AGPL-3.0-or-later", "template_license": "MIT"}
        self.assertEqual(release.core_license(files, commands), "AGPL-3.0-or-later")
        for missing in ("LICENSE", "LICENSING.md", "LICENSES/MIT.txt"):
            candidate = dict(files)
            del candidate[missing]
            with self.subTest(missing=missing), self.assertRaises(registry.RegistryError):
                release.core_license(candidate, commands)
        for changes in ({"license": "AGPL-3.0-only"}, {"license": "MIT"}, {"template_license": "AGPL-3.0-or-later"}):
            with self.subTest(changes=changes), self.assertRaises(registry.RegistryError):
                release.core_license(files, {**commands, **changes})
        with self.assertRaises(registry.RegistryError):
            release.require_mit_example({"LICENSE": files["LICENSE"]}, "hello")
        release.require_mit_example({"LICENSE": files["LICENSES/MIT.txt"]}, "hello")


@unittest.skipUnless(platform.system() == "Linux" and platform.machine() == "x86_64" and
                     all(shutil.which(tool) for tool in ("git", "make", "as", "ld")),
                     "native release checks require Linux x86_64 and GNU build tools")
class ReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = ROOT / "build"
        scratch.mkdir(exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix="asm-release-tests-", dir=scratch)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.base = Path(cls.temporary.name)
        cls.repo = cls.base / "repo"
        cls.repo.mkdir()
        shutil.copytree(ROOT / "cli", cls.repo / "cli")
        cls.version = json.loads((cls.repo / "cli/commands.json").read_text())["version"]
        # This fixture qualifies the Linux producer. The separate native
        # fixture exercises Darwin; the fan-in test below declares that host.
        command_metadata = json.loads((cls.repo / "cli/commands.json").read_text())
        command_metadata["hosts"] = ["x86_64-linux", "aarch64-linux"]
        (cls.repo / "cli/commands.json").write_text(json.dumps(command_metadata) + "\n")
        shutil.copytree(ROOT / "examples/hello", cls.repo / "examples/hello", ignore=shutil.ignore_patterns("build"))
        if (ROOT / "examples/math").is_dir():
            shutil.copytree(ROOT / "examples/math", cls.repo / "examples/math", ignore=shutil.ignore_patterns("build"))
        shutil.copytree(ROOT / "site", cls.repo / "site")
        shutil.copytree(ROOT / "skills/asm-build", cls.repo / "skills/asm-build")
        (cls.repo / "README.md").write_text("# Release test fixture\n\nUses the project's actual assembly sources.\n")
        shutil.copyfile(ROOT / "LICENSE", cls.repo / "LICENSE")
        if (ROOT / "LICENSING.md").is_file():
            shutil.copyfile(ROOT / "LICENSING.md", cls.repo / "LICENSING.md")
        if (ROOT / "LICENSES").is_dir():
            shutil.copytree(ROOT / "LICENSES", cls.repo / "LICENSES")
        (cls.repo / "asm.toml").write_text(f'[package]\nname = "asm"\nversion = "{cls.version}"\n\n[build]\nsource = "cli/asm.s"\ntarget = "x86_64-linux"\n')
        shutil.copyfile(ROOT / "Makefile", cls.repo / "Makefile")
        git(cls.repo, "init", "-q")
        git(cls.repo, "config", "user.name", "Release test fixture")
        git(cls.repo, "config", "user.email", "fixture@example.invalid")
        git(cls.repo, "add", ".")
        git(cls.repo, "commit", "-qm", "Create isolated release fixture")
        cls.commit = git(cls.repo, "rev-parse", "HEAD")
        cls.first = cls.base / "first-release"
        cls.metadata = release.build_release(cls.repo, cls.first)
        cls.records = registry.read_records(cls.first / "registry")

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.case_dir = Path(tempfile.mkdtemp(prefix="case-", dir=self.base))

    def artifact_reader(self, url, limit, hosts, *, expected_size=None):
        filename = registry.artifact_url(url)[2]
        if filename == "release-attestation.sigstore.json":
            # The site checks bundle availability and shape, not signatures.
            return b'{"dsseEnvelope": {"payload": "unsigned test fixture"}}'
        return (self.first / filename).read_bytes()

    def test_two_releases_match_and_ignore_uncommitted_source(self):
        source = self.repo / "cli/asm.s"
        original = source.read_bytes()
        try:
            source.write_text("This uncommitted change cannot compile.\n")
            second = self.case_dir / "second"
            release.build_release(self.repo, second, self.commit)
        finally:
            source.write_bytes(original)
        first_files = {path.relative_to(self.first): path.read_bytes() for path in self.first.rglob("*") if path.is_file()}
        second_files = {path.relative_to(second): path.read_bytes() for path in second.rglob("*") if path.is_file()}
        self.assertEqual(first_files, second_files)
        archive = registry.read_archive((second / f"asm-{self.version}-source.tar.gz").read_bytes())
        self.assertEqual(archive["cli/asm.s"], original)
        self.assertFalse(any(name.startswith((".git/", "build/")) for name in archive))

    def test_release_checksums_and_runtime_results_are_real(self):
        for line in (self.first / "SHA256SUMS").read_text().splitlines():
            digest, name = line.split("  ", 1)
            self.assertEqual(hashlib.sha256((self.first / name).read_bytes()).hexdigest(), digest)
        self.assertEqual(self.metadata["source_commit"], self.commit)
        self.assertEqual(self.metadata["builds"]["hello"]["x86_64-linux"]["runtime"]["status"], "pass")
        self.assertEqual(self.metadata["builds"]["asm"]["version_check"]["status"], "pass")
        self.assertEqual(self.metadata["builds"]["asm_targets"]["aarch64-linux"]["version_check"]["status"], "pass")
        self.assertEqual(self.metadata["cli_hosts"], ["x86_64-linux", "aarch64-linux"])
        cli = next(record for record in self.records if record["name"] == "stubbi/asm")
        self.assertEqual({item["target"] for item in cli["artifacts"] if item["kind"] == "executable"},
                         {"x86_64-linux", "aarch64-linux"})
        self.assertEqual(registry.validate_local_artifacts(self.records, self.first),
                         {(item["name"], item["version"]) for item in self.records})

    def test_release_preserves_core_and_example_license_scopes(self):
        licenses = {record["name"]: record["license"] for record in self.records}
        self.assertEqual(licenses, {"stubbi/asm": "AGPL-3.0-or-later", "stubbi/hello": "MIT", "stubbi/math": "MIT"})
        self.assertEqual(self.metadata["license"], "AGPL-3.0-or-later")
        self.assertEqual(self.metadata["template_license"], "MIT")
        self.assertEqual(self.metadata["package_licenses"], licenses)
        source = registry.read_archive((self.first / f"asm-{self.version}-source.tar.gz").read_bytes())
        self.assertEqual(source["LICENSE"], (ROOT / "LICENSE").read_bytes())
        self.assertEqual(source["LICENSES/MIT.txt"], (ROOT / "LICENSES/MIT.txt").read_bytes())
        self.assertEqual(source["LICENSING.md"], (ROOT / "LICENSING.md").read_bytes())
        self.assertEqual(source["cli/templates.s"], (ROOT / "cli/templates.s").read_bytes())
        self.assertEqual(source["cli/aarch64/templates.s"], (ROOT / "cli/aarch64/templates.s").read_bytes())

    def test_mac_fan_in_preserves_exact_native_bytes_and_requires_declaration(self):
        repo = self.case_dir / "native-fan-in-repo"
        git(self.repo, "clone", "--quiet", "--no-hardlinks", str(self.repo), str(repo))
        metadata_path = repo / "cli/commands.json"
        commands = json.loads(metadata_path.read_text())
        commands["hosts"].append("aarch64-macos")
        metadata_path.write_text(json.dumps(commands) + "\n")
        git(repo, "add", "cli/commands.json")
        git(repo, "-c", "user.name=Release fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-qm", "Declare synthetic native input for fan-in test")
        commit = git(repo, "rev-parse", "HEAD")
        native = self.case_dir / "native-input"
        native.mkdir()
        binary = minimal_macho()
        evidence = native_evidence(commit, self.version, binary, selected_target=True)
        filename = evidence["asset"]["file"]
        (native / filename).write_bytes(binary)
        (native / release.NATIVE_EVIDENCE).write_bytes(registry.json_bytes(evidence))
        output = self.case_dir / "with-native-host"
        result = release.build_release(repo, output, native_input=native)
        self.assertEqual((output / filename).read_bytes(), binary)
        self.assertIn("aarch64-macos", result["cli_hosts"])
        self.assertEqual(result["builds"]["asm_targets"]["aarch64-macos"], evidence)
        self.assertIn(filename, {item["file"] for item in result["assets"]})
        # The same evidence must not authorize another source commit.
        with self.assertRaises(registry.RegistryError):
            release.build_release(self.repo, self.case_dir / "wrong-commit", native_input=native)
        # A valid optional qualification input does not add an undeclared host.
        evidence["source_commit"] = self.commit
        (native / release.NATIVE_EVIDENCE).write_bytes(registry.json_bytes(evidence))
        undeclared = self.case_dir / "linux-only"
        result = release.build_release(self.repo, undeclared, native_input=native)
        self.assertNotIn("aarch64-macos", result["cli_hosts"])
        self.assertFalse((undeclared / filename).exists())

    def test_version_mismatch_leaves_no_output(self):
        output = self.case_dir / "wrong-version"
        with self.assertRaises(registry.RegistryError):
            release.build_release(self.repo, output, version="99.0.0")
        self.assertFalse(output.exists())

    def test_existing_output_is_preserved(self):
        output = self.case_dir / "existing"
        output.mkdir()
        marker = output / "keep.txt"
        marker.write_text("Existing data")
        with self.assertRaises(registry.RegistryError):
            release.build_release(self.repo, output)
        self.assertEqual(marker.read_text(), "Existing data")

    def test_destination_created_after_initial_check_is_not_replaced(self):
        stage = self.case_dir / "stage"
        stage.mkdir()
        (stage / "asset").write_text("Complete artifact")
        output = release.output_path(self.case_dir / "race-output")
        output.mkdir()  # Deterministic interleaving after the early existence check.
        before = output.stat().st_ino
        with self.assertRaises(FileExistsError):
            release.publish_directory(stage, output)
        self.assertEqual(output.stat().st_ino, before)
        self.assertEqual(list(output.iterdir()), [])
        self.assertEqual((stage / "asset").read_text(), "Complete artifact")

    @unittest.skipUnless(all(shutil.which(tool) for tool in (
        "aarch64-linux-gnu-as", "aarch64-linux-gnu-ld", "riscv64-linux-gnu-as", "riscv64-linux-gnu-ld")) and
        all(release.target_runner(name, dict(os.environ)) for name in ("qemu-aarch64", "qemu-riscv64")),
        "cross-target release check requires GNU cross tools and QEMU")
    def test_requested_cross_targets_are_built_and_run(self):
        output = self.case_dir / "cross-release"
        result = release.build_release(self.repo, output, hello_targets=list(release.HELLO_TARGETS))
        self.assertEqual(result["cli_hosts"], ["x86_64-linux", "aarch64-linux"])
        for target in release.HELLO_TARGETS:
            self.assertEqual(result["builds"]["hello"][target]["runtime"]["status"], "pass")
        records = registry.read_records(output / "registry")
        hello = next(record for record in records if record["name"] == "stubbi/hello")
        self.assertEqual(len(hello["artifacts"]), 6)
        registry.validate_local_artifacts(records, output)

    def test_site_without_network_keeps_evidence_and_counts_unknown(self):
        def forbidden(*args, **kwargs):
            raise AssertionError("Offline site build made a network request")
        output = self.case_dir / "offline-site"
        result = build_site.build_site(self.repo, self.first / "registry", output,
                                      artifact_reader=forbidden, metrics_fetcher=forbidden)
        self.assertEqual(result["artifact_checked_releases"], 0)
        self.assertIsNone(result["bootstrap_version"])
        self.assertFalse((output / "install.sh").exists())
        index = json.loads((output / "registry/v1/index.json").read_text())
        for package in index["packages"]:
            self.assertTrue(all(version["evidence"]["artifacts"] == "not-run" for version in package["versions"]))
        counts = json.loads((output / "registry/v1/downloads.json").read_text())
        self.assertIsNone(counts["observed_at"])
        self.assertTrue(all(value["total"] is None for value in counts["packages"].values()))
        self.assertEqual((output / "reference/asm.s").read_bytes(), (self.repo / "cli/asm.s").read_bytes())

    def test_artifact_evidence_requires_all_exact_bytes(self):
        output = self.case_dir / "checked-site"
        result = build_site.build_site(self.repo, self.first / "registry", output,
                                      verify=True, artifact_reader=self.artifact_reader)
        self.assertEqual(result["artifact_checked_releases"], len(self.records))
        self.assertEqual(result["bootstrap_version"], self.version)
        self.assertTrue((output / "install.sh").is_file())
        index = json.loads((output / "registry/v1/index.json").read_text())
        self.assertTrue(all(v["evidence"]["artifacts"] == "validated" for p in index["packages"] for v in p["versions"]))
        failed = self.case_dir / "failed-site"
        with self.assertRaises(registry.RegistryError):
            build_site.build_site(self.repo, self.first / "registry", failed, verify=True,
                                  artifact_reader=lambda *args, **kwargs: b"tampered")
        self.assertFalse(failed.exists())

    def test_missing_release_bundle_preserves_the_unpublished_site(self):
        requests = []
        def missing_bundle(url, limit, hosts, *, expected_size=None):
            requests.append(url)
            if url.endswith("/release-attestation.sigstore.json"):
                raise URLError("release bundle does not exist")
            return self.artifact_reader(url, limit, hosts, expected_size=expected_size)
        output = self.case_dir / "missing-bundle-site"
        with self.assertRaises(URLError):
            build_site.build_site(self.repo, self.first / "registry", output,
                                  verify=True, artifact_reader=missing_bundle)
        self.assertFalse(output.exists())
        self.assertTrue(requests[-1].endswith("/release-attestation.sigstore.json"))

    def test_metrics_failure_does_not_become_success_or_zero(self):
        def unavailable(url):
            raise URLError("network unavailable")
        output = self.case_dir / "missing-metrics"
        result = build_site.build_site(self.repo, self.first / "registry", output,
                                      downloads=True, metrics_fetcher=unavailable)
        self.assertEqual(result["artifact_checked_releases"], 0)
        counts = json.loads((output / "registry/v1/downloads.json").read_text())
        self.assertTrue(all(value["total"] is None for value in counts["packages"].values()))


class DownloadPolicyTests(unittest.TestCase):
    URL = "https://github.com/stubbi/asm/releases/download/v0.1.0/asm-0.1.0-x86_64-linux"

    def test_redirects_reject_unapproved_origins_and_url_tricks(self):
        for url in ("http://github.com/stubbi/asm/releases/download/v0.1.0/a", "https://github.com.evil.example/a",
                    "https://user@github.com/a", "https://github.com:443/a", "https://127.0.0.1/a",
                    "https://github.com/stubbi/asm/releases/download/v0.1.0/a%2fb",
                    "https://release-assets.githubusercontent.com/a#fragment", " https://github.com/a"):
            with self.subTest(url=url), self.assertRaises(registry.RegistryError):
                build_site.check_https_url(url, build_site.ASSET_HOSTS)
        build_site.check_https_url("https://release-assets.githubusercontent.com/path?signature=value", build_site.ASSET_HOSTS)

    def test_declared_size_is_enforced_without_content_length(self):
        opener = FakeOpener(b"abcd", self.URL)
        with self.assertRaises(registry.RegistryError):
            build_site.read_https(self.URL, 64, build_site.ASSET_HOSTS, expected_size=3, opener=opener)
        opener = FakeOpener(b"abc", self.URL)
        self.assertEqual(build_site.read_https(self.URL, 64, build_site.ASSET_HOSTS, expected_size=3, opener=opener), b"abc")

    def test_oversize_header_and_unexpected_encoding_are_rejected(self):
        for headers in ({"Content-Length": "65"}, {"Content-Length": "-1"}, {"Content-Encoding": "gzip"}):
            with self.subTest(headers=headers), self.assertRaises(registry.RegistryError):
                build_site.read_https(self.URL, 64, build_site.ASSET_HOSTS, opener=FakeOpener(b"abc", self.URL, headers))

    def test_final_response_origin_is_checked_again(self):
        with self.assertRaises(registry.RegistryError):
            build_site.read_https(self.URL, 64, build_site.ASSET_HOSTS,
                                  opener=FakeOpener(b"abc", "https://example.invalid/payload"))


if __name__ == "__main__":
    unittest.main()
