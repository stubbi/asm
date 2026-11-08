"""Exercise the bootstrap's user-visible behavior and trust boundaries.

SPDX-License-Identifier: AGPL-3.0-or-later

The installer always uses fixed production executable paths. These tests replace
four literal paths in a disposable script copy with controlled tool doubles.
There is no test switch, custom root, custom URL, or verifier override in the
published installer. Filesystem, hashes, shell execution, and final ln are real.
"""

from __future__ import annotations

from copy import deepcopy
import hashlib
from html import unescape
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import bootstrap
import registry


PAYLOAD = b"ASM installer fixture; this must never execute.\n".ljust(8192, b".")
COMMIT = "a" * 40
# Generation checks availability and JSON shape. Runtime tests exercise the
# verifier contract separately; this fixture is not a valid signed bundle.
BUNDLE = b'{"dsseEnvelope": {"payload": "fixture"}}'


def installer_page_fixture():
    """Keep optional installer markup checks independent of the live homepage."""
    return ('<!doctype html><html lang="en"><head><title>Installer fixture</title></head><body>'
            '<header class="site-header"><a href="index.html">Asm</a></header><main id="main"><h1>Install Asm</h1>' +
            bootstrap.START + '<p>Build the CLI from source.</p>' + bootstrap.END +
            '<details class="source-fallback" open><summary>Build from source</summary><p>Source instructions.</p></details>'
            '</main><footer><a href="index.html">Packages</a></footer>'
            '<p id="copy-status" role="status" aria-live="polite"></p></body></html>')


def release_record(version="0.2.0"):
    return {
        "schema": 1, "name": "stubbi/asm", "version": version,
        "summary": "Native assembly CLI", "license": "AGPL-3.0-or-later",
        "source": {"repository": "https://github.com/stubbi/asm", "commit": COMMIT, "path": "."},
        "yanked": False,
        "artifacts": [{"kind": "executable", "target": "x86_64-linux",
                       "sha256": hashlib.sha256(PAYLOAD).hexdigest(), "bytes": len(PAYLOAD),
                       "url": f"https://github.com/stubbi/asm/releases/download/v{version}/asm-{version}-x86_64-linux"}],
    }


def first_party_payloads():
    """Small executable containers for byte validation, never execution."""
    payloads = {}
    for target, machine in (("x86_64-linux", 62), ("aarch64-linux", 183), ("riscv64-linux", 243)):
        header = bytearray(64)
        header[:7] = b"\x7fELF\x02\x01\x01"
        struct.pack_into("<HHI", header, 16, 2, machine, 1)
        struct.pack_into("<Q", header, 32, 64)
        struct.pack_into("<HHH", header, 52, 64, 56, 1)
        payloads[target] = bytes(header) + struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 120, 120, 4096)
    macho = bytearray(160)
    struct.pack_into("<8I", macho, 0, 0xFEEDFACF, 0x100000C, 0, 2, 3, 120, 0x200000, 0)
    struct.pack_into("<II16sQQQQIIII", macho, 32, 0x19, 72, b"__TEXT", 0, 160, 0, 160, 5, 5, 0, 0)
    struct.pack_into("<IIQQ", macho, 104, 0x80000028, 24, 152, 0)
    struct.pack_into("<6I", macho, 128, 0x32, 24, 1, 0xF0000, 0xF0000, 0)
    payloads["aarch64-macos"] = bytes(macho)
    return payloads


def first_party_record():
    record = release_record("0.6.0")
    record["artifacts"] = [{"kind": "executable", "target": target, "bytes": len(data),
                             "sha256": hashlib.sha256(data).hexdigest(),
                             "url": f"https://github.com/stubbi/asm/releases/download/v0.6.0/asm-0.6.0-{target}"}
                            for target, data in first_party_payloads().items()]
    record["artifacts"].append({"kind": "source", "target": "x86_64-linux", "bytes": 7,
                                 "sha256": hashlib.sha256(b"archive").hexdigest(),
                                 "url": "https://github.com/stubbi/asm/releases/download/v0.6.0/asm-source.tar.gz"})
    return record


TOOL_DOUBLE = r'''#!/usr/bin/python3
import json, os, pathlib, signal, stat, sys, time
base = pathlib.Path(__file__).parent
cfg = json.loads((base / "config.json").read_text())
tool = pathlib.Path(__file__).name
args = sys.argv[1:]
log = {"tool": tool, "args": args, "env_keys": sorted(os.environ),
       "home": os.environ.get("HOME"), "config": os.environ.get("GH_CONFIG_DIR"),
       "proxy": os.environ.get("https_proxy"), "time": time.monotonic_ns()}
log_path = base / "logs" / (tool + "-" + str(os.getpid()) + ".json")
log_path.write_text(json.dumps(log))
if tool == "uname":
    print(cfg.get("system", "Linux") if args == ["-s"] else cfg.get("machine", "x86_64"))
elif tool == "gh":
    if args == ["--version"]:
        if cfg.get("inspect_version_home"):
            for key in ("HOME", "GH_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "TMPDIR"):
                directory = pathlib.Path(os.environ[key])
                info = directory.lstat()
                assert stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700, key
                assert info.st_uid == os.geteuid(), key
            config = pathlib.Path(os.environ["GH_CONFIG_DIR"])
            assert list(config.iterdir()) == []
            probe = config / "config.yml"
            with probe.open("x") as output:
                output.write("# Controlled version-probe configuration.\n")
            assert probe.read_text() == "# Controlled version-probe configuration.\n"
            log["private_config_checked"] = True
            log["install_directory_existed"] = (pathlib.Path(cfg["expected_install_home"]) / ".local").exists()
            log["bin_directory_existed"] = (pathlib.Path(cfg["expected_install_home"]) / ".local/bin").exists()
            log_path.write_text(json.dumps(log))
        if cfg.get("interrupt_version"):
            pathlib.Path(cfg["interrupt_marker"]).write_text("ready")
            time.sleep(60)
        if cfg.get("stall_version"):
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(60)
        if cfg.get("version_error"):
            print("Controlled verifier startup failure", file=sys.stderr)
            sys.exit(1)
        print("gh version " + cfg.get("gh_version", "2.93.0") + " (fixture)")
        sys.exit(0)
    if cfg.get("inspect_version_home"):
        assert list(pathlib.Path(os.environ["GH_CONFIG_DIR"]).iterdir()) == []
    required = {
        "--repo": "stubbi/asm",
        "--cert-identity": "https://github.com/stubbi/asm/.github/workflows/release.yml@refs/heads/main",
        "--cert-oidc-issuer": "https://token.actions.githubusercontent.com",
        "--source-ref": "refs/heads/main",
        "--source-digest": cfg["commit"], "--signer-digest": cfg["commit"],
        "--predicate-type": "https://slsa.dev/provenance/v1", "--hostname": "github.com",
        "--format": "json", "--jq": ".[].verificationResult.signature.certificate.sourceRepositoryIdentifier",
    }
    assert args[:2] == ["attestation", "verify"]
    assert "--deny-self-hosted-runners" in args
    assert "--bundle" in args
    assert not any(key in args for key in ("--custom-trusted-root", "--no-public-good", "--insecure-ignore-sct"))
    for flag, expected in required.items():
        assert args[args.index(flag) + 1] == expected, flag
    if cfg.get("verification_error"):
        print("Controlled attestation rejection", file=sys.stderr)
        sys.exit(1)
    sys.stdout.buffer.write(cfg.get("verifier_output", "1441332955\n").encode().replace(b"\\n", b"\n"))
elif tool == "curl":
    assert args[0] == "-q"
    for flag in ("--proto", "--proto-redir"):
        assert args[args.index(flag) + 1] == "=https"
    assert "--tlsv1.2" in args and "--max-filesize" in args and "--max-time" in args
    url = args[args.index("--url") + 1]
    output = pathlib.Path(args[args.index("--output") + 1])
    artifact_urls = (cfg["artifact_url"], cfg.get("artifact_api_url"), cfg.get("artifact_delivery_url"))
    bundle_urls = (cfg["bundle_url"], cfg.get("bundle_api_url"), cfg.get("bundle_delivery_url"))
    assert url in artifact_urls + bundle_urls
    if url in (cfg.get("artifact_api_url"), cfg.get("bundle_api_url")):
        assert args[args.index("--header") + 1] == "Accept: application/octet-stream"
        assert "X-GitHub-Api-Version: 2022-11-28" in args
    response = cfg.get("responses", {}).get(url, {})
    if "--write-out" in args:
        print(str(response.get("status", 200)) + " " + str(response.get("connect", "000")), end="")
    if response.get("exit_code"):
        output.write_bytes(b"partial response")
        sys.exit(response["exit_code"])
    if cfg.get("network_error"):
        sys.exit(22)
    if url in artifact_urls:
        data = pathlib.Path(cfg["payload_path"]).read_bytes()
        if cfg.get("corrupt") or response.get("corrupt"):
            data = b"!" + data[1:]
        if cfg.get("truncated"):
            data = data[:-1]
        output.write_bytes(data)
        if cfg.get("interrupt"):
            pathlib.Path(cfg["interrupt_marker"]).write_text("ready")
            time.sleep(60)
    else:
        output.write_bytes(b"{}" if not cfg.get("oversized_bundle") else b"x" * 1048577)
        if cfg.get("move_install_dir"):
            current = pathlib.Path.cwd()
            current.rename(current.with_name("bin-moved"))
            current.mkdir(mode=0o700)
elif tool == "ln":
    if cfg.get("destination_race"):
        pathlib.Path("asm").write_bytes(b"Keep the concurrently created command.\n")
    if cfg.get("link_error"):
        sys.exit(1)
    os.execv("/usr/bin/ln", ["/usr/bin/ln"] + args)
else:
    raise AssertionError(tool)
'''


class BootstrapGenerationTests(unittest.TestCase):
    def test_first_party_files_bind_only_latest_checked_supported_executables_and_bundle(self):
        record = first_party_record()
        original = deepcopy(record)
        payloads = first_party_payloads()
        calls = []
        def read(url, limit, *, expected_size):
            calls.append((url, limit, expected_size))
            target = url.removeprefix("https://github.com/stubbi/asm/releases/download/v0.6.0/asm-0.6.0-")
            self.assertIn(target, ("x86_64-linux", "aarch64-linux", "aarch64-macos"))
            self.assertEqual(expected_size, len(payloads[target]))
            return payloads[target]
        with tempfile.TemporaryDirectory() as temp:
            stage = Path(temp)
            (stage / "index.html").write_text("<main><h1>Packages</h1></main>")
            try:
                selected = bootstrap.write_bootstrap(stage, [release_record("0.5.0"), record],
                    {("stubbi/asm", "0.5.0"), ("stubbi/asm", "0.6.0")},
                    bundle_reader=lambda url, limit: BUNDLE, artifact_reader=read)
            except TypeError as error:
                self.fail("The checked site must stage the bounded first-party bootstrap files: " + str(error))
            expected = {f"bootstrap/sha256/{hashlib.sha256(data).hexdigest()}/asm-0.6.0-{target}": data
                        for target, data in payloads.items() if target in ("x86_64-linux", "aarch64-linux", "aarch64-macos")}
            expected[f"bootstrap/sha256/{hashlib.sha256(BUNDLE).hexdigest()}/release-attestation.sigstore.json"] = BUNDLE
            actual = {path.relative_to(stage).as_posix(): path.read_bytes() for path in (stage / "bootstrap").rglob("*") if path.is_file()}
            self.assertEqual(actual, expected)
            self.assertEqual(set(selected["delivery"].values()), {"https://asm.build/" + path for path in expected})
            self.assertEqual(len(calls), 3)
            self.assertEqual(record, original, "Transport copies must not rewrite immutable records")

    def test_delivery_urls_cannot_select_other_bytes_hosts_or_paths(self):
        release = bootstrap.installer_release([release_record()], {("stubbi/asm", "0.2.0")})
        artifact = release["artifacts"][0]
        primary = f"https://asm.build/bootstrap/sha256/{artifact['sha256']}/asm-0.2.0-x86_64-linux"
        bundle = "https://asm.build/bootstrap/sha256/" + "a" * 64 + "/release-attestation.sigstore.json"
        mapping = {artifact["url"]: primary, release["bundle_url"]: bundle}
        try:
            bootstrap.render_installer({**release, "delivery": mapping})
        except registry.RegistryError as error:
            self.fail("A complete exact first-party map must render: " + str(error))
        for invalid in (None, {}, {artifact["url"]: primary}, {**mapping, "extra": primary},
                        {**mapping, artifact["url"]: primary.replace("asm.build", "other.invalid")},
                        {**mapping, artifact["url"]: primary.replace(artifact["sha256"], "0" * 64)},
                        {**mapping, artifact["url"]: primary.replace("asm-0.2.0-x86_64-linux", "different")},
                        {**mapping, artifact["url"]: primary + "?token=bad"},
                        {**mapping, artifact["url"]: primary.replace("/asm-0.2.0-", "/../asm-0.2.0-")},
                        {**mapping, release["bundle_url"]: bundle.replace("a" * 64, "A" * 64)},
                        {**mapping, release["bundle_url"]: bundle.replace("release-attestation", "other")}):
            with self.subTest(delivery=invalid), self.assertRaises(registry.RegistryError):
                bootstrap.render_installer({**release, "delivery": invalid})

    def test_invalid_selected_bootstrap_bytes_cannot_advertise_an_installer(self):
        record = first_party_record()
        payloads = first_party_payloads()
        for kind in ("wrong-hash", "wrong-size", "wrong-container", "late-corrupt", "network"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                stage = Path(temp)
                (stage / "index.html").write_text("<main><h1>Packages</h1></main>")
                changed = deepcopy(record)
                if kind == "wrong-container":
                    changed["artifacts"][0]["sha256"] = hashlib.sha256(b"x" * 120).hexdigest()
                def reader(url, limit, *, expected_size):
                    target = url.rsplit("asm-0.6.0-", 1)[1]
                    data = payloads[target]
                    if kind == "network": raise OSError("Controlled upstream failure")
                    if kind == "late-corrupt" and target != "aarch64-linux": return data
                    return data[:-1] if kind == "wrong-size" else b"x" * len(data)
                try:
                    with self.assertRaises((registry.RegistryError, OSError)):
                        bootstrap.write_bootstrap(stage, [changed], {("stubbi/asm", "0.6.0")},
                            bundle_reader=lambda url, limit: BUNDLE, artifact_reader=reader)
                except TypeError as error:
                    self.fail("Checked bytes must gate first-party staging: " + str(error))
                self.assertFalse((stage / "install.sh").exists())
                self.assertFalse((stage / "bootstrap").exists())

    def test_first_party_namespace_collision_preserves_existing_paths(self):
        for kind in ("directory", "file", "symlink"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                stage = root / "site"
                stage.mkdir()
                (stage / "index.html").write_text("<main><h1>Packages</h1></main>")
                outside = root / "outside"
                outside.mkdir()
                (outside / "keep").write_bytes(b"Existing unrelated bytes")
                path = stage / "bootstrap"
                if kind == "directory": path.mkdir()
                elif kind == "file": path.write_bytes(b"Keep this file")
                else: path.symlink_to(outside, target_is_directory=True)
                def forbidden(*args, **kwargs): self.fail("An occupied namespace must stop before artifact reads")
                with self.assertRaises(registry.RegistryError):
                    bootstrap.write_bootstrap(stage, [first_party_record()], {("stubbi/asm", "0.6.0")},
                        bundle_reader=lambda url, limit: BUNDLE, artifact_reader=forbidden)
                self.assertEqual((outside / "keep").read_bytes(), b"Existing unrelated bytes")
                self.assertFalse((stage / "install.sh").exists())

    def test_checked_installer_binds_recovery_for_each_artifact_and_the_checked_bundle(self):
        with tempfile.TemporaryDirectory() as temp:
            stage = Path(temp)
            (stage / "index.html").write_text("<main><h1>Packages</h1></main>")
            calls = []
            def resolve(url, limit, *, expected_size):
                calls.append((url, limit, expected_size))
                return "https://api.github.com/repos/stubbi/asm/releases/assets/" + ("123" if url.endswith("-linux") else "456")
            try:
                selected = bootstrap.write_bootstrap(stage, [release_record()], {("stubbi/asm", "0.2.0")},
                                                     bundle_reader=lambda url, limit: BUNDLE, asset_resolver=resolve)
            except TypeError as error:
                self.fail("The checked installer cannot bind its official recovery endpoints: " + str(error))
            self.assertEqual(selected["recovery"], {
                "https://github.com/stubbi/asm/releases/download/v0.2.0/asm-0.2.0-x86_64-linux":
                    "https://api.github.com/repos/stubbi/asm/releases/assets/123",
                "https://github.com/stubbi/asm/releases/download/v0.2.0/release-attestation.sigstore.json":
                    "https://api.github.com/repos/stubbi/asm/releases/assets/456"})
            self.assertEqual([item[2] for item in calls], [8192, len(BUNDLE)])
            script = (stage / "install.sh").read_bytes()
            result = subprocess.run(["/bin/sh", "-n"], input=script, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_recovery_bindings_cannot_add_urls_or_inject_a_different_origin(self):
        good = bootstrap.installer_release([release_record()], {("stubbi/asm", "0.2.0")})
        urls = [good["artifacts"][0]["url"], good["bundle_url"]]
        mapping = dict(zip(urls, ["https://api.github.com/repos/stubbi/asm/releases/assets/123",
                                  "https://api.github.com/repos/stubbi/asm/releases/assets/456"]))
        try:
            bootstrap.render_installer({**good, "recovery": mapping})
        except registry.RegistryError as error:
            self.fail("Valid exact recovery bindings must render: " + str(error))
        for bad in (None, {}, {urls[0]: mapping[urls[0]]}, {**mapping, "https://example.invalid": mapping[urls[0]]},
                    dict.fromkeys(urls, mapping[urls[0]]),
                    {**mapping, urls[0]: "https://api.github.com/repos/other/asm/releases/assets/123"},
                    {**mapping, urls[0]: "https://api.github.com/repos/stubbi/asm/releases/assets/0"},
                    {**mapping, urls[0]: "https://api.github.com/repos/stubbi/asm/releases/assets/123?token=x"},
                    {**mapping, urls[0]: "https://api.github.com/repos/stubbi/asm/releases/assets/123';exit"}):
            with self.subTest(mapping=bad), self.assertRaises(registry.RegistryError):
                bootstrap.render_installer({**good, "recovery": bad})

    def test_only_the_latest_checked_active_cli_can_produce_an_installer(self):
        old, new = release_record("0.1.0"), release_record("0.2.0")
        self.assertIsNone(bootstrap.installer_release([], set()))
        self.assertIsNone(bootstrap.installer_release([old, new], {("stubbi/asm", "0.1.0")}))
        selected = bootstrap.installer_release([old, new], {("stubbi/asm", "0.2.0")})
        self.assertEqual(selected["version"], "0.2.0")
        new.update(yanked=True, yank_reason="Fixture withdrawal")
        selected = bootstrap.installer_release([old, new], {("stubbi/asm", "0.1.0")})
        self.assertIsNone(selected)
        self.assertIsNone(bootstrap.installer_release([old], {("stubbi/asm", "0.1.0")}))

    def test_metadata_cannot_inject_shell_or_change_the_trusted_release_location(self):
        good = bootstrap.installer_release([release_record()], {("stubbi/asm", "0.2.0")})
        changes = [
            {"version": "0.2.0';touch /tmp/unsafe"}, {"version": "9999999999.0.0"},
            {"source_commit": "0" * 40}, {"source_commit": "a" * 39 + "'"},
            {"repository_id": 1},
            {"bundle_url": "https://example.invalid/bundle"},
            {"version": "0.1.0",
             "bundle_url": "https://github.com/stubbi/asm/releases/download/v0.1.0/release-attestation.sigstore.json"},
            {"artifacts": []}, {"artifacts": None},
            {"artifacts": good["artifacts"] * 2},
        ]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(registry.RegistryError):
                bootstrap.render_installer({**good, **change})
        for change in ({"sha256": "A" * 64}, {"bytes": True}, {"bytes": 0},
                       {"bytes": registry.MAX_ARTIFACT_BYTES + 1},
                       {"url": good["artifacts"][0]["url"] + "?extra=1"},
                       {"target": "aarch64-linux"}, {"target": "x86_64;exit"},
                       {"target": "riscv64-linux"}, {"extra": "ignored"}):
            candidate = deepcopy(good)
            candidate["artifacts"][0].update(change)
            with self.subTest(artifact_change=change), self.assertRaises(registry.RegistryError):
                bootstrap.render_installer(candidate)
        for mutation in ("repository", "path", "url"):
            record = release_record()
            if mutation == "repository":
                record["source"][mutation] = "https://github.com/another/asm"
            elif mutation == "path":
                record["source"][mutation] = "cli"
            else:
                record["artifacts"][0][mutation] = "https://github.com/another/asm/releases/download/v0.2.0/asm"
            with self.subTest(mutation=mutation), self.assertRaises(registry.RegistryError):
                bootstrap.installer_release([record], {("stubbi/asm", "0.2.0")})

    def test_unchecked_site_cannot_publish_a_stale_installer(self):
        with tempfile.TemporaryDirectory() as temp:
            stage = Path(temp)
            shutil.copyfile(ROOT / "site/index.html", stage / "index.html")
            (stage / "install.sh").write_text("Stale installer")
            self.assertIsNone(bootstrap.write_bootstrap(stage, [release_record()], set()))
            self.assertFalse((stage / "install.sh").exists())
            self.assertNotIn('id="bootstrap-commands"', (stage / "index.html").read_text())

    def test_checked_site_contains_exact_reviewable_installer_and_static_instructions(self):
        with tempfile.TemporaryDirectory() as temp:
            stage = Path(temp)
            (stage / "index.html").write_text(installer_page_fixture(), encoding="utf-8")
            requests = []
            def read_bundle(url, limit):
                requests.append((url, limit))
                return BUNDLE
            selected = bootstrap.write_bootstrap(stage, [release_record()], {("stubbi/asm", "0.2.0")},
                                                  bundle_reader=read_bundle)
            script = (stage / "install.sh").read_text()
            self.assertIn("readonly asm_version='0.2.0'", script)
            self.assertIn(selected["artifacts"][0]["sha256"], script)
            self.assertIn(selected["source_commit"], script)
            self.assertNotIn("@@", script)
            page = (stage / "index.html").read_text()
            self.assertIn('id="bootstrap-commands"', page)
            self.assertIn('href="install.sh"', page)
            self.assertIn('class="source-fallback">', page)
            self.assertNotIn('class="source-fallback" open', page)
            self.assertEqual(requests, [(selected["bundle_url"], 1024 * 1024)])

    def test_checked_installer_is_generated_without_a_homepage_installation_section(self):
        with tempfile.TemporaryDirectory() as temp:
            stage = Path(temp)
            homepage = b'<!doctype html><main><h1>Find assembly packages</h1></main>\n'
            (stage / "index.html").write_bytes(homepage)
            requests = []
            def read_bundle(url, limit):
                requests.append((url, limit))
                return BUNDLE
            selected = bootstrap.write_bootstrap(stage, [release_record()], {("stubbi/asm", "0.2.0")}, bundle_reader=read_bundle)
            self.assertEqual((stage / "install.sh").read_bytes(), bootstrap.render_installer(selected))
            self.assertEqual((stage / "index.html").read_bytes(), homepage)
            self.assertEqual(requests, [(selected["bundle_url"], 1024 * 1024)])

    def test_unchecked_homepage_without_installation_section_removes_a_stale_installer(self):
        with tempfile.TemporaryDirectory() as temp:
            stage = Path(temp)
            homepage = b'<main><h1>Find assembly packages</h1></main>\n'
            (stage / "index.html").write_bytes(homepage)
            (stage / "install.sh").write_bytes(b"stale checked build")
            self.assertIsNone(bootstrap.write_bootstrap(stage, [release_record()], set()))
            self.assertFalse((stage / "install.sh").exists())
            self.assertEqual((stage / "index.html").read_bytes(), homepage)

    def test_no_homepage_installation_section_does_not_bypass_bundle_checks(self):
        with tempfile.TemporaryDirectory() as temp:
            stage = Path(temp)
            homepage = b'<main><h1>Find assembly packages</h1></main>\n'
            (stage / "index.html").write_bytes(homepage)
            for bundle in (None, b"{}", BUNDLE + b"\n" + BUNDLE):
                requests = []
                def reader(url, limit):
                    requests.append(url)
                    return bundle
                with self.subTest(bundle=bundle), self.assertRaises(registry.RegistryError):
                    bootstrap.write_bootstrap(stage, [release_record()], {("stubbi/asm", "0.2.0")},
                                              bundle_reader=None if bundle is None else reader)
                self.assertEqual(len(requests), 0 if bundle is None else 1)
                self.assertFalse((stage / "install.sh").exists())
                self.assertEqual((stage / "index.html").read_bytes(), homepage)

    def test_partial_duplicate_and_reversed_optional_markers_are_rejected(self):
        for content in (bootstrap.START, bootstrap.END, bootstrap.START * 2 + bootstrap.END,
                        bootstrap.START + bootstrap.END * 2, bootstrap.END + bootstrap.START):
            with self.subTest(content=content), tempfile.TemporaryDirectory() as temp:
                stage = Path(temp)
                (stage / "index.html").write_text(content, encoding="utf-8")
                with self.assertRaises(registry.RegistryError):
                    bootstrap.write_bootstrap(stage, [release_record()], set())
                self.assertEqual((stage / "index.html").read_text(), content)

    def test_missing_or_invalid_bundle_cannot_publish_an_installer(self):
        for bundle in (None, b"", b"{}", b"[]", BUNDLE + b"\n" + BUNDLE, b"x" * (1024 * 1024 + 1)):
            with self.subTest(bundle_size=len(bundle) if bundle is not None else None), tempfile.TemporaryDirectory() as temp:
                stage = Path(temp)
                shutil.copyfile(ROOT / "site/index.html", stage / "index.html")
                reader = None if bundle is None else lambda url, limit: bundle
                with self.assertRaises(registry.RegistryError):
                    bootstrap.write_bootstrap(stage, [release_record()], {("stubbi/asm", "0.2.0")},
                                              bundle_reader=reader)
                self.assertFalse((stage / "install.sh").exists())
                self.assertNotIn('id="bootstrap-commands"', (stage / "index.html").read_text())

    def test_installer_host_description_matches_available_artifacts(self):
        record = release_record("0.3.0")
        selected = bootstrap.installer_release([record], {("stubbi/asm", "0.3.0")})
        markup = bootstrap.installer_markup(selected)
        self.assertIn("The installer supports Linux x86_64.", markup)
        self.assertNotIn("Linux ARM64", markup)
        arm = {**record["artifacts"][0], "target": "aarch64-linux",
               "url": "https://github.com/stubbi/asm/releases/download/v0.3.0/asm-0.3.0-aarch64-linux"}
        record["artifacts"].append(arm)
        selected = bootstrap.installer_release([record], {("stubbi/asm", "0.3.0")})
        markup = bootstrap.installer_markup(selected)
        self.assertIn("The installer supports Linux ARM64 and Linux x86_64.", markup)

    def test_complete_download_instructions_stop_before_execution_on_failure(self):
        release = bootstrap.installer_release([release_record()], {("stubbi/asm", "0.2.0")})
        markup = bootstrap.installer_markup(release)
        commands = unescape(markup.split('<code id="bootstrap-ci-commands">', 1)[1].split('</code>', 1)[0])
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            tools = base / "tools"
            tools.mkdir()
            curl = tools / "curl"
            asm = tools / "asm"
            asm.write_text('#!/bin/sh\nprintf "must not run\\n" > "$HOME/unexpected-asm"\n')
            asm.chmod(0o755)
            for curl_body in (
                'exit 22\n',
                'while [ "$1" != -o ]; do shift; done\nprintf \'printf executed > "$HOME/unexpected-installer"\\n\' > "$2"\nexit 22\n',
                'while [ "$1" != -o ]; do shift; done\nprintf "exit 1\\n" > "$2"\n',
            ):
                with self.subTest(curl_body=curl_body):
                    curl.write_text('#!/bin/sh\n' + curl_body)
                    curl.chmod(0o755)
                    result = subprocess.run(['/bin/sh', '-c', commands], env={"PATH": f"{tools}:/usr/bin:/bin", "HOME": str(base)},
                                            capture_output=True, timeout=5)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse((base / "unexpected-asm").exists())
                    self.assertFalse((base / "unexpected-installer").exists())

    def test_interactive_pipeline_reports_failure_without_running_asm(self):
        release = bootstrap.installer_release([release_record()], {("stubbi/asm", "0.2.0")})
        markup = bootstrap.installer_markup(release)
        commands = unescape(markup.split('<code id="bootstrap-commands">', 1)[1].split('</code>', 1)[0])
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            tools = base / "tools"
            tools.mkdir()
            asm = tools / "asm"
            asm.write_text('#!/bin/sh\nprintf "must not run\\n" > "$HOME/unexpected-asm"\n')
            asm.chmod(0o755)
            cases = (
                # POSIX pipelines return the shell status. An empty script is a
                # no-op, even when curl failed. Keep that limitation explicit.
                ('printf "fixture download failed\\n" >&2\nexit 22\n', 0),
                ('printf \'printf "fixture install failed\\n" >&2; exit 1\\n\'\n', 1),
            )
            for curl_body, expected_status in cases:
                with self.subTest(curl_body=curl_body):
                    curl = tools / "curl"
                    curl.write_text('#!/bin/sh\n' + curl_body)
                    curl.chmod(0o755)
                    result = subprocess.run(['/bin/sh', '-c', commands], env={"PATH": f"{tools}:/usr/bin:/bin", "HOME": str(base)},
                                            capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, expected_status)
                    self.assertIn(b"failed", result.stderr)
                    self.assertFalse((base / "unexpected-asm").exists())


@unittest.skipUnless(platform.system() == "Linux" and all(Path("/usr/bin/" + tool).is_file()
                     for tool in ("stat", "id", "mktemp", "mkdir", "chmod", "ln", "rm", "sha256sum", "env", "timeout")),
                     "installer tests require Linux and GNU system tools")
class BootstrapUserFlowTests(unittest.TestCase):
    def setUp(self):
        base = Path("/tmp") if Path("/tmp").is_dir() else ROOT / "build"
        base.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="asm-bootstrap-test-", dir=base)
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.home = self.base / "home"
        self.home.mkdir(mode=0o700)
        self.tools = self.base / "tools"
        self.tools.mkdir(mode=0o700)
        (self.tools / "logs").mkdir()
        for name in ("curl", "gh", "uname", "ln"):
            tool = self.tools / name
            tool.write_text(TOOL_DOUBLE)
            tool.chmod(0o755)
        self.payload = self.base / "payload"
        self.payload.write_bytes(PAYLOAD)
        self.release = bootstrap.installer_release([release_record()], {("stubbi/asm", "0.2.0")})
        self.config = {**self.release, "commit": COMMIT, "payload_path": str(self.payload),
                       "artifact_url": self.release["artifacts"][0]["url"],
                       "interrupt_marker": str(self.base / "interrupt")}
        self.script = self.base / "install.sh"
        self.write_script()
        self.env = {"PATH": "/usr/bin:/bin", "HOME": str(self.home), "LANG": "C",
                    "https_proxy": "http://proxy.example:8080", "GH_TOKEN": "must-not-pass",
                    "GITHUB_TOKEN": "must-not-pass", "GH_HOST": "untrusted.invalid",
                    "GH_CONFIG_DIR": str(self.base / "untrusted-config"), "SSL_CERT_FILE": "must-not-pass",
                    "CURL_CA_BUNDLE": "must-not-pass", "SIGSTORE_ROOT_FILE": "must-not-pass",
                    "TUF_ROOT": "must-not-pass"}

    def write_script(self):
        script = bootstrap.render_installer(self.release).decode()
        for name in ("curl", "gh", "uname", "ln"):
            script = script.replace("/usr/bin/" + name, str(self.tools / name))
        # The prerequisite loop constructs its tool paths. Only its four test
        # doubles are redirected; all filesystem and hash tools stay real.
        script = script.replace('for asm_tool in curl gh stat id mktemp mkdir chmod ln rm sha256sum env timeout; do',
                                'for asm_tool in stat id mktemp mkdir chmod rm sha256sum env timeout; do')
        checks = '\n'.join(f'[ -x "{self.tools / name}" ] || asm_fail "Missing controlled {name} fixture."' for name in ("curl", "gh", "ln"))
        script = script.replace('    # Preserve only bounded proxy-routing settings.', checks + '\n    # Preserve only bounded proxy-routing settings.')
        self.script.write_text(script)

    @property
    def destination(self):
        return self.home / ".local/bin/asm"

    def save_config(self):
        (self.tools / "config.json").write_text(json.dumps(self.config))

    def run_installer(self, *, timeout=15, streamed=False, **changes):
        self.config.update(changes)
        self.save_config()
        command = ["/bin/sh"] if streamed else ["/bin/sh", str(self.script)]
        script_input = self.script.read_bytes() if streamed else None
        return subprocess.run(command, input=script_input, env=self.env, cwd=self.base,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)

    def calls(self, name):
        result = [json.loads(path.read_text()) for path in (self.tools / "logs").glob(name + "-*.json")]
        return sorted(result, key=lambda item: item["time"])

    def assert_no_install(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.home.glob(".asm-bootstrap.*")), [])
        self.assertEqual(list((self.home / ".local").glob(".asm-bootstrap.*")), [])
        self.assertEqual(list((self.home / ".local/bin").glob(".asm-bootstrap.*")), [])

    def test_install_verifies_then_creates_one_owned_executable_without_running_it(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(self.destination.read_bytes(), PAYLOAD)
        info = self.destination.stat()
        self.assertEqual(info.st_nlink, 1)
        self.assertEqual(info.st_uid, os.geteuid())
        self.assertEqual(info.st_gid, os.getegid())
        self.assertEqual(info.st_mode & 0o7777, 0o755)
        self.assertIn(b'export PATH="$HOME/.local/bin:$PATH"', result.stdout)
        self.assertIn(b"asm self update", result.stdout)
        self.assertEqual(list((self.home / ".local/bin").glob(".asm-bootstrap.*")), [])
        verify = self.calls("gh")[-1]
        self.assertEqual(verify["args"][:2], ["attestation", "verify"])
        self.assertTrue(verify["home"].startswith(str(self.home / ".local/bin/.asm-bootstrap.")))
        self.assertNotEqual(verify["home"], str(self.home))
        self.assertEqual(verify["proxy"], "http://proxy.example:8080")
        for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "SSL_CERT_FILE", "CURL_CA_BUNDLE", "SIGSTORE_ROOT_FILE", "TUF_ROOT"):
            self.assertNotIn(name, verify["env_keys"])

    def recovery_fixture(self):
        self.config["artifact_api_url"] = "https://api.github.com/repos/stubbi/asm/releases/assets/123"
        self.config["bundle_api_url"] = "https://api.github.com/repos/stubbi/asm/releases/assets/456"
        self.release["recovery"] = {self.config["artifact_url"]: self.config["artifact_api_url"],
                                     self.config["bundle_url"]: self.config["bundle_api_url"]}
        try:
            self.write_script()
        except registry.RegistryError as error:
            self.fail("Valid recovery-bound installer cannot be exercised: " + str(error))

    def delivery_fixture(self):
        self.recovery_fixture()
        artifact = self.release["artifacts"][0]
        self.config["artifact_delivery_url"] = "https://asm.build/bootstrap/sha256/" + artifact["sha256"] + "/" + artifact["url"].rsplit("/", 1)[1]
        self.config["bundle_delivery_url"] = "https://asm.build/bootstrap/sha256/" + "a" * 64 + "/release-attestation.sigstore.json"
        self.release["delivery"] = {self.config["artifact_url"]: self.config["artifact_delivery_url"],
                                     self.config["bundle_url"]: self.config["bundle_delivery_url"]}
        try:
            self.write_script()
        except registry.RegistryError as error:
            self.fail("A checked first-party installer must be executable: " + str(error))

    def test_first_party_primary_still_verifies_signed_exact_bytes(self):
        self.delivery_fixture()
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.destination.read_bytes(), PAYLOAD)
        self.assertEqual([call["args"][call["args"].index("--url") + 1] for call in self.calls("curl")],
                         [self.config["artifact_delivery_url"], self.config["bundle_delivery_url"]])
        self.assertEqual(self.calls("gh")[-1]["args"][:2], ["attestation", "verify"])

    def test_retired_first_party_copy_recovers_through_the_same_signed_api_asset(self):
        self.delivery_fixture()
        for key, connect in (("artifact_delivery_url", "000"), ("bundle_delivery_url", "000"),
                             ("artifact_delivery_url", 200), ("bundle_delivery_url", 200)):
            with self.subTest(asset=key, connect=connect):
                for log in (self.tools / "logs").iterdir(): log.unlink()
                result = self.run_installer(responses={self.config[key]: {"exit_code": 22, "status": 404, "connect": connect}})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.destination.read_bytes(), PAYLOAD)
                urls = [call["args"][call["args"].index("--url") + 1] for call in self.calls("curl")]
                expected_api = self.config["artifact_api_url" if key.startswith("artifact") else "bundle_api_url"]
                self.assertEqual(urls.count(expected_api), 1)
                self.assertEqual(self.calls("gh")[-1]["args"][:2], ["attestation", "verify"])
                self.destination.unlink()

    def test_first_party_permission_errors_and_missing_api_asset_do_not_install(self):
        self.delivery_fixture()
        cases = (
            ({self.config["artifact_delivery_url"]: {"exit_code": 22, "status": 403}}, 1, False),
            ({self.config["artifact_delivery_url"]: {"exit_code": 22, "status": 404, "connect": 404}}, 1, False),
            ({self.config["artifact_delivery_url"]: {"exit_code": 22, "status": 404, "connect": 201}}, 1, False),
            ({self.config["artifact_delivery_url"]: {"exit_code": 22, "status": 404},
              self.config["artifact_api_url"]: {"exit_code": 22, "status": 404}}, 2, False),
            ({}, 2, True))
        for responses, count, bad_signature in cases:
            with self.subTest(responses=responses, bad_signature=bad_signature):
                for log in (self.tools / "logs").iterdir(): log.unlink()
                self.assert_no_install(self.run_installer(responses=responses, verification_error=bad_signature))
                self.assertEqual(len(self.calls("curl")), count)

    def test_healthy_downloads_never_use_recovery(self):
        self.recovery_fixture()
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls("curl")
        self.assertEqual([call["args"][call["args"].index("--url") + 1] for call in calls],
                         [self.config["artifact_url"], self.config["bundle_url"]])
        self.assertEqual(self.destination.read_bytes(), PAYLOAD)

    def test_gateway_timeout_and_network_failure_recover_exact_artifact_and_bundle(self):
        self.recovery_fixture()
        for url in (self.config["artifact_url"], self.config["bundle_url"]):
            for code, status, connect in ((22, 502, "000"), (22, 503, "000"), (22, 504, "000"),
                                           (28, "000", "000"), (6, "000", "000"),
                                           (7, "000", "000"), (56, "000", 503)):
                with self.subTest(url=url, exit_code=code, status=status):
                    for log in (self.tools / "logs").iterdir(): log.unlink()
                    result = self.run_installer(responses={url: {"exit_code": code, "status": status, "connect": connect}})
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.destination.read_bytes(), PAYLOAD)
                    calls = self.calls("curl")
                    api_calls = [call for call in calls if "/releases/assets/" in " ".join(call["args"])]
                    self.assertEqual(len(api_calls), 1)
                    budgets = [int(call["args"][call["args"].index("--max-time") + 1]) for call in calls]
                    self.assertEqual(budgets, [60, 60, 60])
                    self.assertNotIn("GH_TOKEN", api_calls[0]["env_keys"])
                    self.assertEqual(self.calls("gh")[-1]["args"][:2], ["attestation", "verify"])
                    self.destination.unlink()

    def test_permission_missing_and_certificate_failures_never_use_recovery(self):
        self.recovery_fixture()
        for code, status, connect in ((22, 403, "000"), (22, 404, "000"), (60, "000", "000"),
                                     (51, "000", "000"), (35, "000", "000"), (56, 403, "000"),
                                     (56, 401, "000"), (56, 429, "000"), (56, "000", 407)):
            with self.subTest(exit_code=code, status=status, connect=connect):
                self.destination.unlink(missing_ok=True)
                for log in (self.tools / "logs").iterdir(): log.unlink()
                result = self.run_installer(responses={self.config["artifact_url"]: {"exit_code": code, "status": status,
                                                                                   "connect": connect}})
                self.assert_no_install(result)
                self.assertEqual(len(self.calls("curl")), 1)

    def test_failed_or_corrupt_recovery_and_bad_signature_leave_no_installation(self):
        self.recovery_fixture()
        for api_response, verification_error in (({"exit_code": 22, "status": 403}, False),
                                                  ({"exit_code": 28, "status": "000"}, False),
                                                  ({"corrupt": True}, False), ({}, True)):
            with self.subTest(api_response=api_response, verification_error=verification_error):
                for log in (self.tools / "logs").iterdir(): log.unlink()
                result = self.run_installer(responses={self.config["artifact_url"]: {"exit_code": 22, "status": 504},
                                                       self.config["artifact_api_url"]: api_response},
                                            verification_error=verification_error)
                self.assert_no_install(result)
                self.assertEqual(len([call for call in self.calls("curl") if "/releases/assets/" in " ".join(call["args"])]), 1)

    def test_same_stream_selects_and_verifies_each_host_without_executing_it(self):
        record = release_record("0.3.0")
        arm_payload = b"ARM64 fixture; this must never execute.\n".ljust(9216, b"!")
        arm = {"kind": "executable", "target": "aarch64-linux", "bytes": len(arm_payload),
               "sha256": hashlib.sha256(arm_payload).hexdigest(),
               "url": "https://github.com/stubbi/asm/releases/download/v0.3.0/asm-0.3.0-aarch64-linux"}
        record["artifacts"].append(arm)
        self.release = bootstrap.installer_release([record], {("stubbi/asm", "0.3.0")})
        self.config["bundle_url"] = self.release["bundle_url"]
        self.write_script()
        original_script = self.script.read_bytes()
        for machine, artifact, payload in (("x86_64", record["artifacts"][0], PAYLOAD),
                                           ("amd64", record["artifacts"][0], PAYLOAD),
                                           ("aarch64", arm, arm_payload), ("arm64", arm, arm_payload)):
            with self.subTest(machine=machine):
                self.payload.write_bytes(payload)
                result = self.run_installer(streamed=True, machine=machine, artifact_url=artifact["url"])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.script.read_bytes(), original_script)
                self.assertEqual(self.destination.read_bytes(), payload)
                self.assertIn(artifact["target"].encode(), result.stdout)
                self.assertEqual(self.calls("gh")[-1]["args"][:2], ["attestation", "verify"])
                self.destination.unlink()

    def test_unpublished_host_stops_before_network_or_installation(self):
        for machine, system in (("aarch64", "Linux"), ("riscv64", "Linux"),
                                ("i686", "Linux"), ("arm64", "Darwin"),
                                ("x86_64;echo unsafe", "Linux")):
            with self.subTest(machine=machine, system=system):
                result = self.run_installer(machine=machine, system=system)
                self.assert_no_install(result)
                self.assertEqual(self.calls("curl"), [])
                self.assertEqual(self.calls("gh"), [])
                self.assertEqual(list(self.home.iterdir()), [])

    def test_wrong_target_payload_cannot_replace_the_selected_arm_artifact(self):
        record = release_record("0.3.0")
        arm_payload = b"ARM64 fixture".ljust(len(PAYLOAD), b"!")
        record["artifacts"].append({"kind": "executable", "target": "aarch64-linux", "bytes": len(arm_payload),
                                    "sha256": hashlib.sha256(arm_payload).hexdigest(),
                                    "url": "https://github.com/stubbi/asm/releases/download/v0.3.0/asm-0.3.0-aarch64-linux"})
        self.release = bootstrap.installer_release([record], {("stubbi/asm", "0.3.0")})
        self.config["bundle_url"] = self.release["bundle_url"]
        self.write_script()
        result = self.run_installer(streamed=True, machine="aarch64", artifact_url=record["artifacts"][1]["url"])
        self.assert_no_install(result)
        self.assertIn(b"checksum", result.stderr)
        self.assertEqual(len([call for call in self.calls("gh") if call["args"][:2] == ["attestation", "verify"]]), 0)

    def test_exact_rerun_preserves_inode_and_does_not_download_again(self):
        first = self.run_installer()
        self.assertEqual(first.returncode, 0, first.stderr)
        inode = self.destination.stat().st_ino
        downloads = len(self.calls("curl"))
        second = self.run_installer()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn(b"already installed", second.stdout)
        self.assertEqual(self.destination.stat().st_ino, inode)
        self.assertEqual(self.destination.stat().st_nlink, 1)
        self.assertEqual(len(self.calls("curl")), downloads)

    def test_streamed_install_and_rerun_preserve_the_verification_contract(self):
        first = self.run_installer(streamed=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.destination.read_bytes(), PAYLOAD)
        self.assertEqual(self.destination.stat().st_mode & 0o7777, 0o755)
        self.assertEqual(self.destination.stat().st_nlink, 1)
        self.assertEqual(len(self.calls("curl")), 2)
        self.assertEqual(self.calls("gh")[-1]["args"][:2], ["attestation", "verify"])
        self.assertIn(b"asm self update", first.stdout)
        inode = self.destination.stat().st_ino
        calls = sorted(path.name for path in (self.tools / "logs").iterdir())

        second = self.run_installer(streamed=True)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn(b"already installed", second.stdout)
        self.assertEqual(self.destination.stat().st_ino, inode)
        # Host detection may run again. No download, verifier, or link may run.
        new_calls = [path for path in (self.tools / "logs").iterdir() if path.name not in calls]
        self.assertTrue(all(path.name.startswith("uname-") for path in new_calls))
        self.assertEqual(list(self.destination.parent.glob(".asm-bootstrap.*")), [])

    def test_incomplete_stream_never_starts_installation(self):
        script = self.script.read_bytes()
        entry = script.rindex(b'    asm_bootstrap_main "$@"')
        cuts = (script.index(b"set -eu") + 4, script.index(b"Downloading Asm") + 7,
                script.index(b"Cannot set executable permissions.") + 8,
                entry, entry + len(b"    asm_bootstrap_main"),
                entry + len(b'    asm_bootstrap_main "$@"'), script.rindex(b"}"))
        self.save_config()
        for cut in cuts:
            with self.subTest(bytes_received=cut):
                result = subprocess.run(["/bin/sh"], input=script[:cut], env=self.env, cwd=self.base,
                                        capture_output=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(self.home.iterdir()), [])
                self.assertEqual(list((self.tools / "logs").iterdir()), [])

    def test_streamed_install_rejects_corrupt_or_unattested_artifacts(self):
        for changes in ({"corrupt": True}, {"verification_error": True}):
            with self.subTest(changes=changes):
                self.config.update(corrupt=False, verification_error=False)
                result = self.run_installer(streamed=True, **changes)
                self.assert_no_install(result)

    def test_streamed_install_preserves_a_different_existing_command(self):
        self.destination.parent.mkdir(parents=True, mode=0o700)
        original = b"An unrelated command.\n"
        self.destination.write_bytes(original)
        before = self.destination.stat()
        result = self.run_installer(streamed=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.destination.read_bytes(), original)
        self.assertEqual(self.destination.stat().st_ino, before.st_ino)
        self.assertEqual(self.calls("curl"), [])
        self.assertEqual(self.calls("gh"), [])

    def test_version_probe_has_a_private_home_before_creating_install_directories(self):
        result = self.run_installer(inspect_version_home=True, expected_install_home=str(self.home))
        self.assertEqual(result.returncode, 0, result.stderr)
        version, verification = self.calls("gh")
        self.assertEqual(version["args"], ["--version"])
        self.assertTrue(version["private_config_checked"])
        self.assertFalse(version["install_directory_existed"])
        self.assertNotEqual(version["home"], verification["home"])
        self.assertNotEqual(version["home"], str(self.home))
        self.assertNotEqual(version["config"], self.env["GH_CONFIG_DIR"])
        self.assertFalse(Path(version["home"]).parent.exists())
        self.assertEqual(list(self.home.glob(".asm-bootstrap.*")), [])
        for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "SSL_CERT_FILE", "CURL_CA_BUNDLE", "SIGSTORE_ROOT_FILE", "TUF_ROOT"):
            self.assertNotIn(name, version["env_keys"])

    def test_verifier_startup_failure_cleans_probe_without_creating_install_directories(self):
        result = self.run_installer(version_error=True, inspect_version_home=True,
                                    expected_install_home=str(self.home))
        self.assert_no_install(result)
        self.assertIn(b"Cannot read the GitHub CLI version", result.stderr)
        self.assertFalse((self.home / ".local").exists())
        self.assertEqual(self.calls("curl"), [])

    def test_stalled_version_probe_reaches_deadline_and_cleans_home(self):
        result = self.run_installer(timeout=30, stall_version=True, inspect_version_home=True,
                                    expected_install_home=str(self.home))
        self.assert_no_install(result)
        self.assertIn(b"Cannot read the GitHub CLI version", result.stderr)
        self.assertFalse((self.home / ".local").exists())
        self.assertEqual(self.calls("curl"), [])

    def test_old_or_prerelease_verifier_fails_before_creating_install_directories(self):
        for version in ("2.92.9", "1.99.0", "2.93.0-pre", "2.93", "999999999.0.0"):
            with self.subTest(version=version):
                self.assert_no_install(self.run_installer(gh_version=version))
                self.assertFalse((self.home / ".local").exists())

    def test_unsupported_host_fails_before_network_or_file_changes(self):
        for changes in ({"system": "Darwin"}, {"system": "Linux", "machine": "aarch64"}):
            with self.subTest(changes=changes):
                self.assert_no_install(self.run_installer(**changes))
                self.assertFalse((self.home / ".local").exists())
                self.assertEqual(self.calls("curl"), [])

    def test_missing_verifier_fails_before_install_directories(self):
        (self.tools / "gh").unlink()
        self.assert_no_install(self.run_installer())
        self.assertFalse((self.home / ".local").exists())

    def test_network_checksum_and_size_failures_leave_no_command(self):
        for key in ("network_error", "corrupt", "truncated", "oversized_bundle"):
            with self.subTest(key=key):
                self.config.update(network_error=False, corrupt=False, truncated=False, oversized_bundle=False)
                self.assert_no_install(self.run_installer(**{key: True}))
        self.assertFalse(any(call["args"][:2] == ["attestation", "verify"] for call in self.calls("gh")))

    def test_failed_signature_or_ambiguous_repository_identity_never_installs(self):
        self.assert_no_install(self.run_installer(verification_error=True))
        self.config["verification_error"] = False
        for output in ("", "1441332955", "1441332955\n\n", "1441332955\n1441332955\n", "1441332956\n"):
            with self.subTest(output=output):
                self.assert_no_install(self.run_installer(verifier_output=output))

    def test_existing_files_and_symlinks_are_preserved(self):
        self.destination.parent.mkdir(parents=True)
        self.destination.write_bytes(b"Existing user command")
        self.destination.chmod(0o755)
        before = self.destination.stat().st_ino
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.destination.read_bytes(), b"Existing user command")
        self.assertEqual(self.destination.stat().st_ino, before)
        self.destination.unlink()
        target = self.base / "keep"
        target.write_bytes(PAYLOAD)
        target.chmod(0o755)
        self.destination.symlink_to(target)
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.destination.is_symlink())
        self.assertEqual(target.read_bytes(), PAYLOAD)

    def test_hardlinked_or_writable_existing_exact_bytes_are_not_accepted(self):
        self.destination.parent.mkdir(parents=True)
        self.destination.write_bytes(PAYLOAD)
        for mode in (0o775, 0o757, 0o4755, 0o2755, 0o644):
            with self.subTest(mode=oct(mode)):
                self.destination.chmod(mode)
                self.assertNotEqual(self.run_installer().returncode, 0)
                self.assertEqual(self.destination.stat().st_mode & 0o7777, mode)
        self.destination.chmod(0o755)
        os.link(self.destination, self.base / "other-link")
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(self.destination.stat().st_nlink, 2)

    def test_symlink_or_writable_install_directories_are_rejected(self):
        outside = self.base / "outside"
        outside.mkdir()
        (self.home / ".local").symlink_to(outside, target_is_directory=True)
        self.assert_no_install(self.run_installer())
        self.assertEqual(list(outside.iterdir()), [])
        (self.home / ".local").unlink()
        self.home.chmod(0o777)
        self.assert_no_install(self.run_installer())
        self.assertFalse((self.home / ".local").exists())

    def test_symlink_in_home_path_is_rejected(self):
        alias = self.base / "alias"
        alias.symlink_to(self.home, target_is_directory=True)
        self.env["HOME"] = str(alias)
        self.assert_no_install(self.run_installer())
        self.assertFalse((self.home / ".local").exists())

    def test_writable_ancestor_is_rejected_even_when_home_itself_is_private(self):
        parent = self.base / "writable-parent"
        parent.mkdir()
        parent.chmod(0o777)
        self.home = parent / "home"
        self.home.mkdir(mode=0o700)
        self.env["HOME"] = str(self.home)
        result = self.run_installer()
        self.assert_no_install(result)
        self.assertIn(b"HOME ancestor", result.stderr)
        self.assertEqual(self.calls("curl"), [])

    @unittest.skipUnless(Path("/tmp").is_dir(), "requires the normal system /tmp directory")
    def test_root_owned_sticky_tmp_with_owned_private_child_is_supported(self):
        if os.stat("/tmp").st_uid != 0 or not os.stat("/tmp").st_mode & 0o1000:
            self.skipTest("system /tmp is not a root-owned sticky directory")
        with tempfile.TemporaryDirectory(prefix="asm-bootstrap-home-", dir="/tmp") as temp:
            self.home = Path(temp) / "home"
            self.home.mkdir(mode=0o700)
            self.env["HOME"] = str(self.home)
            result = self.run_installer()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.destination.read_bytes(), PAYLOAD)
            self.assertEqual(self.destination.stat().st_nlink, 1)

    def test_changed_absolute_installation_path_is_detected_before_verification(self):
        result = self.run_installer(move_install_dir=True)
        self.assert_no_install(result)
        self.assertIn(b"moved or changed", result.stderr)
        self.assertFalse(any(call["args"][:2] == ["attestation", "verify"] for call in self.calls("gh")))
        self.assertEqual(list((self.home / ".local/bin-moved").glob(".asm-bootstrap.*")), [])

    @unittest.skipUnless(os.geteuid() == 0 and Path("/tmp").is_dir(), "real cross-UID check requires a root test process and /tmp")
    def test_other_uid_can_rename_unsafe_home_but_installer_rejects_that_ancestor(self):
        victim, attacker = 65532, 65533
        with tempfile.TemporaryDirectory(prefix="asm-bootstrap-cross-uid-", dir="/tmp") as temp:
            base = Path(temp)
            os.chown(base, victim, victim)
            base.chmod(0o755)
            tools = base / "tools"
            shutil.copytree(self.tools, tools)
            for path in [tools, *tools.rglob("*")]:
                os.chown(path, victim, victim)
            parent = base / "unsafe-parent"
            parent.mkdir()
            os.chown(parent, attacker, attacker)
            parent.chmod(0o777)
            home = parent / "home"
            home.mkdir(mode=0o700)
            os.chown(home, victim, victim)
            marker = home / "keep"
            marker.write_bytes(b"Existing victim data.\n")
            os.chown(marker, victim, victim)
            original_inode = home.stat().st_ino
            # Demonstrate the actual different-UID rename permission, then put
            # the original home back before checking the installer boundary.
            attack = subprocess.run(["/usr/bin/python3", "-c",
                "from pathlib import Path; import sys; h=Path(sys.argv[1]); m=h.with_name('moved'); h.rename(m); h.mkdir(); h.rmdir(); m.rename(h)",
                str(home)], user=attacker, group=attacker, extra_groups=[], capture_output=True, timeout=5)
            self.assertEqual(attack.returncode, 0, attack.stderr)
            self.assertEqual(home.stat().st_ino, original_inode)
            payload = base / "payload"
            payload.write_bytes(PAYLOAD)
            payload.chmod(0o644)
            config = {**self.config, "payload_path": str(payload)}
            (tools / "config.json").write_text(json.dumps(config))
            script = base / "install.sh"
            script.write_text(self.script.read_text().replace(str(self.tools), str(tools)))
            script.chmod(0o644)
            env = {**self.env, "HOME": str(home)}
            result = subprocess.run(["/bin/sh", str(script)], env=env, cwd=base, user=victim,
                                    group=victim, extra_groups=[], capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"HOME ancestor", result.stderr)
            self.assertFalse((home / ".local").exists())
            self.assertEqual(marker.read_bytes(), b"Existing victim data.\n")
            self.assertEqual(home.stat().st_ino, original_inode)
            self.assertEqual(list((tools / "logs").glob("curl-*.json")), [])
            evidence = {"victim_uid": victim, "attacker_uid": attacker, "ancestor_owner": parent.stat().st_uid,
                        "ancestor_mode": oct(parent.stat().st_mode & 0o7777), "cross_uid_rename_succeeded": True,
                        "installer_returncode": result.returncode, "stderr": result.stderr.decode(),
                        "home_inode_preserved": home.stat().st_ino == original_inode,
                        "user_marker_preserved": marker.read_bytes() == b"Existing victim data.\n",
                        "download_was_not_started": True}
            (ROOT / "build/bootstrap-cross-uid-result.json").write_text(json.dumps(evidence, indent=2) + "\n")

    @unittest.skipUnless(os.geteuid() == 0 and Path("/tmp").is_dir(), "real non-root permission check requires a root test process and /tmp")
    def test_readonly_home_allows_non_root_install_and_exact_rerun(self):
        uid = 65532
        evidence = []
        for existing_bin in (False, True):
            with self.subTest(existing_bin=existing_bin), tempfile.TemporaryDirectory(prefix="asm-bootstrap-readonly-", dir="/tmp") as temp:
                base = Path(temp)
                os.chown(base, uid, uid)
                base.chmod(0o755)
                tools = base / "tools"
                shutil.copytree(self.tools, tools)
                for path in [tools, *tools.rglob("*")]:
                    os.chown(path, uid, uid)
                home = base / "home"
                local = home / ".local"
                bin_path = local / "bin"
                local.mkdir(parents=True)
                directories = [home, local]
                if existing_bin:
                    bin_path.mkdir()
                    directories.append(bin_path)
                for directory in directories:
                    os.chown(directory, uid, uid)
                    directory.chmod(0o500 if directory == home or (existing_bin and directory == local) else 0o700)
                original_modes = {str(path): path.stat().st_mode & 0o7777 for path in directories}
                payload = base / "payload"
                payload.write_bytes(PAYLOAD)
                payload.chmod(0o644)
                config = {**self.config, "payload_path": str(payload), "inspect_version_home": True,
                          "expected_install_home": str(home), "gh_version": "2.92.9"}
                config_path = tools / "config.json"
                config_path.write_text(json.dumps(config))
                config_path.chmod(0o644)
                script = base / "install.sh"
                script.write_text(self.script.read_text().replace(str(self.tools), str(tools)))
                script.chmod(0o644)
                env = {**self.env, "HOME": str(home)}

                def run():
                    return subprocess.run(["/bin/sh", str(script)], env=env, cwd=base, user=uid,
                                          group=uid, extra_groups=[], capture_output=True, timeout=15)

                def assert_clean_stages():
                    for directory in (home, local, bin_path):
                        self.assertEqual(list(directory.glob(".asm-bootstrap.*")), [])

                rejected = run()
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(b"Update GitHub CLI", rejected.stderr)
                self.assertEqual(bin_path.exists(), existing_bin)
                self.assertEqual(original_modes, {str(path): path.stat().st_mode & 0o7777 for path in directories})
                self.assertEqual(list((tools / "logs").glob("curl-*.json")), [])
                assert_clean_stages()
                probe = json.loads(next((tools / "logs").glob("gh-*.json")).read_text())
                expected_parent = bin_path if existing_bin else local
                self.assertEqual(Path(probe["home"]).parent.parent, expected_parent)
                self.assertEqual(probe["bin_directory_existed"], existing_bin)

                config["gh_version"] = "2.93.0"
                config_path.write_text(json.dumps(config))
                installed = run()
                self.assertEqual(installed.returncode, 0, installed.stderr)
                command = bin_path / "asm"
                self.assertEqual(command.read_bytes(), PAYLOAD)
                self.assertEqual(command.stat().st_uid, uid)
                self.assertEqual(command.stat().st_nlink, 1)
                self.assertEqual(original_modes, {str(path): path.stat().st_mode & 0o7777 for path in directories})
                assert_clean_stages()

                for directory in (home, local, bin_path):
                    directory.chmod(0o500)
                inode = command.stat().st_ino
                calls = sorted(path.name for name in ("gh", "curl") for path in (tools / "logs").glob(name + "-*.json"))
                rerun = run()
                self.assertEqual(rerun.returncode, 0, rerun.stderr)
                self.assertIn(b"already installed", rerun.stdout)
                self.assertEqual(command.stat().st_ino, inode)
                self.assertEqual(command.read_bytes(), PAYLOAD)
                self.assertEqual(calls, sorted(path.name for name in ("gh", "curl") for path in (tools / "logs").glob(name + "-*.json")))
                self.assertTrue(all(path.stat().st_mode & 0o7777 == 0o500 for path in (home, local, bin_path)))
                assert_clean_stages()

                changed_bytes = PAYLOAD[:-1] + b"!"
                command.write_bytes(changed_bytes)
                refused = run()
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn(b"An existing asm file differs", refused.stderr)
                self.assertEqual(command.stat().st_ino, inode)
                self.assertEqual(command.read_bytes(), changed_bytes)
                self.assertEqual(calls, sorted(path.name for name in ("gh", "curl") for path in (tools / "logs").glob(name + "-*.json")))
                assert_clean_stages()
                evidence.append({"uid": uid, "initial_modes": original_modes, "bin_existed": existing_bin,
                                 "probe_parent": str(expected_parent), "old_verifier_rejected_before_creation": True,
                                 "installation_passed": True, "readonly_rerun_preserved_inode": True,
                                 "readonly_rerun_called_no_verifier_or_network_tool": True,
                                 "different_bytes_preserved_and_rejected": True})
        (ROOT / "build/bootstrap-readonly-home-result.json").write_text(json.dumps(evidence, indent=2) + "\n")

    def test_destination_created_after_validation_is_not_overwritten(self):
        result = self.run_installer(destination_race=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.destination.read_bytes(), b"Keep the concurrently created command.\n")
        self.assertEqual(list(self.destination.parent.glob(".asm-bootstrap.*")), [])

    def test_link_failure_cleans_verified_temporary_files(self):
        self.assert_no_install(self.run_installer(link_error=True))

    def test_invalid_proxy_settings_fail_without_exposing_the_setting(self):
        self.env["https_proxy"] = "http://proxy.example/\nprivate-value"
        result = self.run_installer()
        self.assert_no_install(result)
        self.assertNotIn(b"private-value", result.stderr)
        self.assertFalse((self.home / ".local").exists())

    def test_interrupted_download_cleans_the_private_stage(self):
        self.config["interrupt"] = True
        self.save_config()
        process = subprocess.Popen(["/bin/sh", str(self.script)], cwd=self.base, env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            marker = Path(self.config["interrupt_marker"])
            while not marker.exists() and time.monotonic() < deadline and process.poll() is None:
                time.sleep(0.01)
            self.assertTrue(marker.exists(), "Installer did not reach controlled download")
            os.killpg(process.pid, signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=5)
            self.assert_no_install(subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr))
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()

    def test_interrupted_version_probe_cleans_home_without_creating_install_directories(self):
        self.config.update(interrupt_version=True, inspect_version_home=True,
                           expected_install_home=str(self.home))
        self.save_config()
        process = subprocess.Popen(["/bin/sh", str(self.script)], cwd=self.base, env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            marker = Path(self.config["interrupt_marker"])
            while not marker.exists() and time.monotonic() < deadline and process.poll() is None:
                time.sleep(0.01)
            self.assertTrue(marker.exists(), "Installer did not reach the controlled version probe")
            os.killpg(process.pid, signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=5)
            self.assert_no_install(subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr))
            self.assertFalse((self.home / ".local").exists())
            self.assertEqual(self.calls("curl"), [])
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()


if __name__ == "__main__":
    unittest.main()
