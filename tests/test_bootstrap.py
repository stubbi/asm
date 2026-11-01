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


TOOL_DOUBLE = r'''#!/usr/bin/python3
import json, os, pathlib, signal, sys, time
base = pathlib.Path(__file__).parent
cfg = json.loads((base / "config.json").read_text())
tool = pathlib.Path(__file__).name
args = sys.argv[1:]
log = {"tool": tool, "args": args, "env_keys": sorted(os.environ),
       "home": os.environ.get("HOME"), "config": os.environ.get("GH_CONFIG_DIR"),
       "proxy": os.environ.get("https_proxy"), "time": time.monotonic_ns()}
(base / "logs" / (tool + "-" + str(os.getpid()) + ".json")).write_text(json.dumps(log))
if tool == "uname":
    print(cfg.get("system", "Linux") if args == ["-s"] else cfg.get("machine", "x86_64"))
elif tool == "gh":
    if args == ["--version"]:
        print("gh version " + cfg.get("gh_version", "2.93.0") + " (fixture)")
        sys.exit(0)
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
    assert url in (cfg["artifact_url"], cfg["bundle_url"])
    if cfg.get("network_error"):
        sys.exit(22)
    if url == cfg["artifact_url"]:
        data = pathlib.Path(cfg["payload_path"]).read_bytes()
        if cfg.get("corrupt"):
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
            {"sha256": "A" * 64}, {"source_commit": "0" * 40},
            {"source_commit": "a" * 39 + "'"}, {"bytes": True}, {"bytes": 0},
            {"bytes": registry.MAX_ARTIFACT_BYTES + 1}, {"repository_id": 1},
            {"artifact_url": good["artifact_url"] + "?extra=1"},
            {"bundle_url": "https://example.invalid/bundle"},
            {"version": "0.1.0", "artifact_url": "https://github.com/stubbi/asm/releases/download/v0.1.0/asm-0.1.0-x86_64-linux",
             "bundle_url": "https://github.com/stubbi/asm/releases/download/v0.1.0/release-attestation.sigstore.json"},
        ]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(registry.RegistryError):
                bootstrap.render_installer({**good, **change})
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
            shutil.copyfile(ROOT / "site/index.html", stage / "index.html")
            requests = []
            def read_bundle(url, limit):
                requests.append((url, limit))
                return BUNDLE
            selected = bootstrap.write_bootstrap(stage, [release_record()], {("stubbi/asm", "0.2.0")},
                                                  bundle_reader=read_bundle)
            script = (stage / "install.sh").read_text()
            self.assertIn("readonly asm_version='0.2.0'", script)
            self.assertIn(selected["sha256"], script)
            self.assertIn(selected["source_commit"], script)
            self.assertNotIn("@@", script)
            page = (stage / "index.html").read_text()
            self.assertIn('id="bootstrap-commands"', page)
            self.assertIn('href="install.sh"', page)
            self.assertIn('class="source-fallback">', page)
            self.assertNotIn('class="source-fallback" open', page)
            self.assertEqual(requests, [(selected["bundle_url"], 1024 * 1024)])

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

    def test_website_instructions_stop_before_running_asm_when_installation_fails(self):
        release = bootstrap.installer_release([release_record()], {("stubbi/asm", "0.2.0")})
        markup = bootstrap.installer_markup(release)
        commands = unescape(markup.split('<code id="bootstrap-commands">', 1)[1].split('</code>', 1)[0])
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            tools = base / "tools"
            tools.mkdir()
            curl = tools / "curl"
            asm = tools / "asm"
            asm.write_text('#!/bin/sh\nprintf "must not run\\n" > "$HOME/unexpected-asm"\n')
            asm.chmod(0o755)
            for curl_body in ('exit 22\n', 'while [ "$1" != -o ]; do shift; done\nprintf "exit 1\\n" > "$2"\n'):
                with self.subTest(curl_body=curl_body):
                    curl.write_text('#!/bin/sh\n' + curl_body)
                    curl.chmod(0o755)
                    result = subprocess.run(['/bin/sh', '-c', commands], env={"PATH": f"{tools}:/usr/bin:/bin", "HOME": str(base)},
                                            capture_output=True, timeout=5)
                    self.assertNotEqual(result.returncode, 0)
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
                       "interrupt_marker": str(self.base / "interrupt")}
        self.script = self.base / "install.sh"
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
        self.env = {"PATH": "/usr/bin:/bin", "HOME": str(self.home), "LANG": "C",
                    "https_proxy": "http://proxy.example:8080", "GH_TOKEN": "must-not-pass",
                    "GITHUB_TOKEN": "must-not-pass", "GH_HOST": "untrusted.invalid",
                    "GH_CONFIG_DIR": str(self.base / "untrusted-config"), "SSL_CERT_FILE": "must-not-pass",
                    "CURL_CA_BUNDLE": "must-not-pass", "SIGSTORE_ROOT_FILE": "must-not-pass",
                    "TUF_ROOT": "must-not-pass"}

    @property
    def destination(self):
        return self.home / ".local/bin/asm"

    def save_config(self):
        (self.tools / "config.json").write_text(json.dumps(self.config))

    def run_installer(self, **changes):
        self.config.update(changes)
        self.save_config()
        return subprocess.run(["/bin/sh", str(self.script)], env=self.env, cwd=self.base,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)

    def calls(self, name):
        result = [json.loads(path.read_text()) for path in (self.tools / "logs").glob(name + "-*.json")]
        return sorted(result, key=lambda item: item["time"])

    def assert_no_install(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.destination.exists())
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


if __name__ == "__main__":
    unittest.main()
