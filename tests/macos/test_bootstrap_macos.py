"""Run the generated installer with real macOS filesystem and hash tools.

SPDX-License-Identifier: AGPL-3.0-or-later

Only host detection, HTTPS transport, verifier, and a race-injecting link
wrapper are replaced in a disposable script. The wrapper executes /bin/link.
No production override or test mode is added to the installer.

The test script exports a caller-controlled loader setting after its shell has
started. dyld(1) processes these settings before a program's entry point. An
invalid inserted library can prevent the shell from starting on hosts without
SIP protection; that process-start failure is outside the installer's boundary.
The installer cannot constrain a same-account caller's pre-launch loader setup.
Use an existing system library so the installer and its clean child environments
are exercised on both protected developer Macs and hosted macOS runners.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "tests"))
import bootstrap
import test_bootstrap as common


MAC_PAYLOAD = b"macOS ARM64 installer fixture; never execute.\n".ljust(9216, b"!")


def mac_release(*, linux=False):
    release = bootstrap.installer_release([common.release_record("0.3.0")], {("stubbi/asm", "0.3.0")})
    artifact = {"target": "aarch64-macos", "bytes": len(MAC_PAYLOAD),
                "sha256": hashlib.sha256(MAC_PAYLOAD).hexdigest(),
                "url": "https://github.com/stubbi/asm/releases/download/v0.3.0/asm-0.3.0-aarch64-macos"}
    linux_arm = {**release["artifacts"][0], "target": "aarch64-linux",
                 "url": "https://github.com/stubbi/asm/releases/download/v0.3.0/asm-0.3.0-aarch64-linux"}
    release["artifacts"] = ([*release["artifacts"], linux_arm, artifact] if linux else [artifact])
    return release


MAC_TOOL_DOUBLE = common.TOOL_DOUBLE.replace("#!/usr/bin/python3", "#!" + sys.executable, 1)
MAC_TOOL_DOUBLE = MAC_TOOL_DOUBLE.replace('import json, os, pathlib, signal, stat, sys, time',
                                          'import json, os, pathlib, signal, stat, subprocess, sys, time')
MAC_TOOL_DOUBLE = MAC_TOOL_DOUBLE.replace('        output.write_bytes(data)', '''        output.write_bytes(data)
        if cfg.get("staged_acl_allow"):
            subprocess.run(["/bin/chmod", "+a", "everyone allow write", str(output)], check=True)''')
MAC_TOOL_DOUBLE = MAC_TOOL_DOUBLE.replace('elif tool == "gh":', '''elif tool == "sw_vers":
    assert args == ["-productVersion"]
    print(cfg.get("macos_version", "15.6.1"))
elif tool == "gh":''')
MAC_TOOL_DOUBLE = MAC_TOOL_DOUBLE.replace('        print("gh version "', '''        if cfg.get("oversized_version"):
            sys.stdout.buffer.write(b"x" * 1048576)
            sys.exit(0)
        print("gh version "''')
MAC_TOOL_DOUBLE = MAC_TOOL_DOUBLE.replace('        if cfg.get("stall_version"):', '''        if cfg.get("stall_version"):
            pathlib.Path(cfg["interrupt_marker"]).write_text(str(os.getpid()))''')
MAC_TOOL_DOUBLE = MAC_TOOL_DOUBLE.replace('    if cfg.get("verification_error"):', '''    if cfg.get("stall_verifier"):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        pathlib.Path(cfg["interrupt_marker"]).write_text(str(os.getpid()))
        time.sleep(60)
    if cfg.get("oversized_verification"):
        sys.stdout.buffer.write(b"x" * 1048576)
        sys.exit(0)
    if cfg.get("verification_error"):''')
MAC_TOOL_DOUBLE = MAC_TOOL_DOUBLE.replace('elif tool == "ln":', 'elif tool == "link":')
MAC_TOOL_DOUBLE = MAC_TOOL_DOUBLE.replace('    if cfg.get("link_error"):', '''    if cfg.get("destination_directory_race"):
        pathlib.Path("asm").mkdir()
    if cfg.get("destination_symlink_race"):
        pathlib.Path("asm").symlink_to(cfg["outside_directory"], target_is_directory=True)
    if cfg.get("link_error"):''')
MAC_TOOL_DOUBLE = MAC_TOOL_DOUBLE.replace('os.execv("/usr/bin/ln", ["/usr/bin/ln"] + args)',
                                          'os.execv("/bin/link", ["/bin/link"] + args)')


class MacOSBootstrapGenerationTests(unittest.TestCase):
    def test_markup_lists_only_hosts_in_the_selected_release(self):
        old = bootstrap.installer_release([common.release_record()], {("stubbi/asm", "0.2.0")})
        self.assertNotIn("macOS", bootstrap.installer_markup(old))
        release = mac_release()
        try:
            markup = bootstrap.installer_markup(release)
        except common.registry.RegistryError as error:
            self.fail(f"A selected macOS artifact cannot produce installation instructions: {error}")
        self.assertIn("macOS 15 or later on ARM64", markup)
        self.assertNotIn("Linux", bootstrap.installer_markup(release))
        self.assertIn("/opt/homebrew/bin/gh", bootstrap.installer_markup(release))


@unittest.skipUnless(platform.system() == "Darwin", "requires native macOS BSD utilities")
class MacOSBootstrapUserFlowTests(unittest.TestCase):
    destination = common.BootstrapUserFlowTests.destination
    save_config = common.BootstrapUserFlowTests.save_config
    run_installer = common.BootstrapUserFlowTests.run_installer
    calls = common.BootstrapUserFlowTests.calls
    assert_no_install = common.BootstrapUserFlowTests.assert_no_install

    # These contracts are shared; run them through the native Darwin branch.
    test_install_verifies_then_creates_one_owned_executable_without_running_it = common.BootstrapUserFlowTests.test_install_verifies_then_creates_one_owned_executable_without_running_it
    test_old_or_prerelease_verifier_fails_before_creating_install_directories = common.BootstrapUserFlowTests.test_old_or_prerelease_verifier_fails_before_creating_install_directories
    test_network_checksum_and_size_failures_leave_no_command = common.BootstrapUserFlowTests.test_network_checksum_and_size_failures_leave_no_command
    test_failed_signature_or_ambiguous_repository_identity_never_installs = common.BootstrapUserFlowTests.test_failed_signature_or_ambiguous_repository_identity_never_installs
    test_existing_files_and_symlinks_are_preserved = common.BootstrapUserFlowTests.test_existing_files_and_symlinks_are_preserved
    test_hardlinked_or_writable_existing_exact_bytes_are_not_accepted = common.BootstrapUserFlowTests.test_hardlinked_or_writable_existing_exact_bytes_are_not_accepted
    test_symlink_or_writable_install_directories_are_rejected = common.BootstrapUserFlowTests.test_symlink_or_writable_install_directories_are_rejected
    test_symlink_in_home_path_is_rejected = common.BootstrapUserFlowTests.test_symlink_in_home_path_is_rejected
    test_writable_ancestor_is_rejected_even_when_home_itself_is_private = common.BootstrapUserFlowTests.test_writable_ancestor_is_rejected_even_when_home_itself_is_private
    test_changed_absolute_installation_path_is_detected_before_verification = common.BootstrapUserFlowTests.test_changed_absolute_installation_path_is_detected_before_verification
    test_destination_created_after_validation_is_not_overwritten = common.BootstrapUserFlowTests.test_destination_created_after_validation_is_not_overwritten
    test_link_failure_cleans_verified_temporary_files = common.BootstrapUserFlowTests.test_link_failure_cleans_verified_temporary_files
    test_invalid_proxy_settings_fail_without_exposing_the_setting = common.BootstrapUserFlowTests.test_invalid_proxy_settings_fail_without_exposing_the_setting
    test_interrupted_download_cleans_the_private_stage = common.BootstrapUserFlowTests.test_interrupted_download_cleans_the_private_stage
    test_interrupted_version_probe_cleans_home_without_creating_install_directories = common.BootstrapUserFlowTests.test_interrupted_version_probe_cleans_home_without_creating_install_directories
    test_version_probe_has_a_private_home_before_creating_install_directories = common.BootstrapUserFlowTests.test_version_probe_has_a_private_home_before_creating_install_directories
    test_verifier_startup_failure_cleans_probe_without_creating_install_directories = common.BootstrapUserFlowTests.test_verifier_startup_failure_cleans_probe_without_creating_install_directories
    test_incomplete_stream_never_starts_installation = common.BootstrapUserFlowTests.test_incomplete_stream_never_starts_installation
    test_streamed_install_rejects_corrupt_or_unattested_artifacts = common.BootstrapUserFlowTests.test_streamed_install_rejects_corrupt_or_unattested_artifacts
    test_streamed_install_preserves_a_different_existing_command = common.BootstrapUserFlowTests.test_streamed_install_preserves_a_different_existing_command

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="asm-bootstrap-macos-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        # Darwin inherits the parent's group for new files. Use the caller's
        # group so the shared set-ID fixture can actually set its group bit.
        os.chown(self.base, -1, os.getegid())
        self.home = self.base / "home"
        self.home.mkdir(mode=0o700)
        self.tools = self.base / "tools"
        self.tools.mkdir(mode=0o700)
        (self.tools / "logs").mkdir()
        for name in ("curl", "gh", "uname", "sw_vers", "link"):
            tool = self.tools / name
            tool.write_text(MAC_TOOL_DOUBLE)
            tool.chmod(0o755)
        self.payload = self.base / "payload"
        # Shared assertions use this byte fixture; macOS target identity and
        # download binding stay separate from executable-format site checks.
        self.payload.write_bytes(common.PAYLOAD)
        self.release = mac_release()
        self.release["artifacts"][0].update(bytes=len(common.PAYLOAD), sha256=hashlib.sha256(common.PAYLOAD).hexdigest())
        self.config = {**self.release, "system": "Darwin", "machine": "arm64",
                       "commit": common.COMMIT, "payload_path": str(self.payload),
                       "artifact_url": self.release["artifacts"][0]["url"],
                       "interrupt_marker": str(self.base / "interrupt")}
        self.script = self.base / "install.sh"
        self.write_script()
        self.env = {"PATH": "/usr/bin:/bin", "HOME": str(self.home), "LANG": "C",
                    "https_proxy": "http://proxy.example:8080", "GH_TOKEN": "must-not-pass",
                    "GITHUB_TOKEN": "must-not-pass", "GH_HOST": "untrusted.invalid",
                    "GH_CONFIG_DIR": str(self.base / "untrusted-config"), "SSL_CERT_FILE": "must-not-pass",
                    "CURL_CA_BUNDLE": "must-not-pass", "SIGSTORE_ROOT_FILE": "must-not-pass",
                    "TUF_ROOT": "must-not-pass", "PERL5OPT": "must-not-pass",
                    "PERL5LIB": "must-not-pass"}

    def write_script(self):
        script = bootstrap.render_installer(self.release).decode()
        for original, name in (("/usr/bin/curl", "curl"), ("/opt/homebrew/bin/gh", "gh"),
                               ("/usr/bin/uname", "uname"), ("/usr/bin/sw_vers", "sw_vers"),
                               ("/bin/link", "link")):
            script = script.replace(original, str(self.tools / name))
        # Export after /bin/sh has launched. A missing library at process
        # launch aborts dyld before the shell can execute any installer code.
        self.script.write_text("export DYLD_INSERT_LIBRARIES=/usr/lib/libSystem.B.dylib\n" + script)

    def test_os_and_architecture_choose_the_exact_record_asset(self):
        release = mac_release(linux=True)
        self.release = release
        self.write_script()
        self.payload.write_bytes(MAC_PAYLOAD)
        result = self.run_installer(streamed=True, artifact_url=release["artifacts"][-1]["url"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.destination.read_bytes(), MAC_PAYLOAD)
        self.assertIn(b"aarch64-macos", result.stdout)
        self.assertNotIn(b"x86_64-linux", result.stdout)

    def test_real_host_detection_installs_the_native_target(self):
        if platform.machine() != "arm64" or int(platform.mac_ver()[0].split(".")[0]) < 15:
            self.skipTest("requires macOS 15 or later on ARM64")
        script = self.script.read_text()
        script = script.replace(str(self.tools / "uname"), "/usr/bin/uname")
        script = script.replace(str(self.tools / "sw_vers"), "/usr/bin/sw_vers")
        self.script.write_text(script)
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.destination.read_bytes(), common.PAYLOAD)
        self.assertIn(b"aarch64-macos", result.stdout)

    def test_unpublished_or_unsupported_host_has_no_network_or_file_effects(self):
        for changes in ({"machine": "x86_64"}, {"machine": "riscv64"}, {"system": "FreeBSD"},
                        {"macos_version": "14.7.0"}, {"macos_version": "garbage"}):
            with self.subTest(changes=changes):
                self.config.update(system="Darwin", machine="arm64", macos_version="15.6.1")
                self.assert_no_install(self.run_installer(**changes))
                self.assertFalse((self.home / ".local").exists())
                self.assertEqual(self.calls("curl"), [])
                self.assertEqual(self.calls("gh"), [])
        old = bootstrap.installer_release([common.release_record()], {("stubbi/asm", "0.2.0")})
        self.release = old
        self.write_script()
        self.assert_no_install(self.run_installer())
        self.assertFalse((self.home / ".local").exists())
        self.assertEqual(self.calls("gh"), [])

    def test_exact_rerun_uses_no_verifier_or_network_and_preserves_inode(self):
        self.assertEqual(self.run_installer(streamed=True).returncode, 0)
        inode = self.destination.stat().st_ino
        calls = self.calls("curl") + self.calls("gh")
        self.destination.parent.chmod(0o500)
        self.addCleanup(self.destination.parent.chmod, 0o700)
        result = self.run_installer(streamed=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"already installed", result.stdout)
        self.assertEqual(self.destination.stat().st_ino, inode)
        self.assertEqual(self.calls("curl") + self.calls("gh"), calls)

    def test_native_link_refuses_a_concurrent_directory_or_directory_symlink(self):
        outside = self.base / "outside"
        outside.mkdir()
        for race in ("destination_directory_race", "destination_symlink_race"):
            with self.subTest(race=race):
                self.config.update(destination_directory_race=False, destination_symlink_race=False)
                result = self.run_installer(**{race: True, "outside_directory": str(outside)})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(outside.iterdir()), [])
                self.assertEqual(list(self.destination.iterdir()), [])
                self.assertEqual(list(self.destination.parent.glob(".asm-bootstrap.*")), [])
                if self.destination.is_symlink():
                    self.destination.unlink()
                else:
                    self.destination.rmdir()

    def test_missing_homebrew_verifier_stops_before_installation(self):
        (self.tools / "gh").unlink()
        self.assert_no_install(self.run_installer())
        self.assertFalse((self.home / ".local").exists())
        self.assertEqual(self.calls("curl"), [])

    def set_acl(self, path, entry):
        subprocess.run(["/bin/chmod", "+a", entry, str(path)], check=True, capture_output=True)
        self.addCleanup(self.clear_acl, path)

    @staticmethod
    def clear_acl(path):
        if path.exists():
            subprocess.run(["/bin/chmod", "-N", str(path)], check=True, capture_output=True)

    def test_acl_allow_on_an_ancestor_or_install_directory_is_rejected(self):
        self.destination.parent.mkdir(parents=True, mode=0o700)
        local = self.home / ".local"
        local.chmod(0o700)
        for path in (self.base, self.home, local, self.destination.parent):
            with self.subTest(path=path):
                path.chmod(0o700)
                self.set_acl(path, "everyone allow delete_child")
                self.assertEqual(path.stat().st_mode & 0o7777, 0o700)
                result = self.run_installer()
                try:
                    self.assert_no_install(result)
                    self.assertIn(b"ACL", result.stderr)
                    self.assertEqual(self.calls("curl"), [])
                    self.assertEqual(self.calls("gh"), [])
                finally:
                    self.clear_acl(path)
                    self.destination.unlink(missing_ok=True)

    def test_normal_deny_only_home_acl_allows_installation_and_exact_rerun(self):
        self.set_acl(self.home, "everyone deny delete")
        self.assertEqual(self.home.stat().st_mode & 0o7777, 0o700)
        first = self.run_installer()
        self.assertEqual(first.returncode, 0, first.stderr)
        inode = self.destination.stat().st_ino
        second = self.run_installer()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.destination.stat().st_ino, inode)

    def test_acl_allow_on_an_existing_exact_executable_is_rejected(self):
        self.destination.parent.mkdir(parents=True, mode=0o700)
        self.destination.write_bytes(common.PAYLOAD)
        self.destination.chmod(0o755)
        self.set_acl(self.destination, "everyone allow write")
        self.assertEqual(self.destination.stat().st_mode & 0o7777, 0o755)
        inode = self.destination.stat().st_ino
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"ACL", result.stderr)
        self.assertEqual(self.destination.read_bytes(), common.PAYLOAD)
        self.assertEqual(self.destination.stat().st_ino, inode)
        self.assertEqual(self.calls("curl"), [])
        self.assertEqual(self.calls("gh"), [])

    def test_acl_allow_on_the_staged_executable_prevents_finalization(self):
        self.assert_no_install(self.run_installer(staged_acl_allow=True))

    def test_failed_or_oversized_acl_inspection_fails_closed(self):
        fixture = self.tools / "ls"
        self.script.write_text(self.script.read_text().replace("/bin/ls", str(fixture)))
        for body in ("sys.exit(1)", "sys.stdout.buffer.write(b'x' * 1048576)"):
            with self.subTest(body=body):
                fixture.write_text("#!" + sys.executable + "\nimport os, sys\n"
                                   "assert not any(key in os.environ for key in ('GH_TOKEN', 'GH_CONFIG_DIR', 'PERL5OPT'))\n"
                                   + body + "\n")
                fixture.chmod(0o755)
                self.assert_no_install(self.run_installer())
                self.assertFalse((self.home / ".local").exists())
                self.assertEqual(self.calls("curl"), [])
                self.assertEqual(self.calls("gh"), [])

    def test_unsupported_or_ownership_disabled_volume_is_rejected_before_changes(self):
        device = subprocess.run(["/usr/bin/stat", "-f", "%Sd", str(self.home)], check=True,
                                capture_output=True, text=True).stdout.strip()
        fixture = self.tools / "diskutil"
        self.script.write_text(self.script.read_text().replace("/usr/sbin/diskutil", str(fixture)))
        good = {"DeviceIdentifier": device, "FilesystemType": "apfs", "GlobalPermissionsEnabled": True}
        for changes in ({"GlobalPermissionsEnabled": False}, {"FilesystemType": "hfs"},
                        {"GlobalPermissionsEnabled": "true"}, {"DeviceIdentifier": "disk999s1"}):
            with self.subTest(changes=changes):
                fixture.write_text("#!" + sys.executable + "\nimport plistlib, sys\n"
                                   + f"assert sys.argv[1:] == ['info', '-plist', '/dev/{device}']\n"
                                   + f"sys.stdout.buffer.write(plistlib.dumps({{**{good!r}, **{changes!r}}}))\n")
                fixture.chmod(0o755)
                result = self.run_installer()
                try:
                    self.assert_no_install(result)
                    self.assertFalse((self.home / ".local").exists())
                    self.assertEqual(self.calls("curl"), [])
                    self.assertEqual(self.calls("gh"), [])
                finally:
                    if self.destination.exists():
                        self.destination.unlink()
                    if self.destination.parent.exists():
                        self.destination.parent.rmdir()
                        self.destination.parent.parent.rmdir()

    def test_volume_inspection_failure_or_malformed_output_fails_closed(self):
        fixture = self.tools / "diskutil"
        self.script.write_text(self.script.read_text().replace("/usr/sbin/diskutil", str(fixture)))
        for body in ("sys.exit(1)", "sys.stdout.write('not a plist')", "sys.stdout.buffer.write(b'x' * 1048576)"):
            with self.subTest(body=body):
                fixture.write_text("#!" + sys.executable + "\nimport sys\n" + body + "\n")
                fixture.chmod(0o755)
                self.assert_no_install(self.run_installer())
                self.assertFalse((self.home / ".local").exists())

    def test_verifier_output_is_bounded_before_installation(self):
        for changes in ({"oversized_version": True}, {"oversized_verification": True}):
            with self.subTest(changes=changes):
                self.config.update(oversized_version=False, oversized_verification=False)
                self.assert_no_install(self.run_installer(**changes))

    def test_deadline_kills_a_stalled_verifier_and_cleans_the_stage(self):
        # Reduce only this disposable script's production deadline. The same
        # fixed native watchdog still performs process termination and cleanup.
        self.script.write_text(self.script.read_text().replace("asm_deadline 120 11", "asm_deadline 1 11"))
        started = time.monotonic()
        self.assert_no_install(self.run_installer(stall_verifier=True))
        self.assertLess(time.monotonic() - started, 10)
        pid = int(Path(self.config["interrupt_marker"]).read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_deadline_stops_a_stalled_version_probe_before_install_directories(self):
        self.script.write_text(self.script.read_text().replace("asm_deadline 15 4096", "asm_deadline 1 4096"))
        result = self.run_installer(stall_version=True, inspect_version_home=True,
                                    expected_install_home=str(self.home))
        self.assert_no_install(result)
        self.assertIn(b"Cannot read the GitHub CLI version", result.stderr)
        self.assertFalse((self.home / ".local").exists())
        self.assertEqual(self.calls("curl"), [])

    def test_deadline_does_not_inherit_a_blocked_or_ignored_alarm(self):
        self.script.write_text(self.script.read_text().replace("asm_deadline 15 4096", "asm_deadline 1 4096"))
        self.config["stall_version"] = True
        self.save_config()

        def block_alarm():
            signal.signal(signal.SIGALRM, signal.SIG_IGN)
            signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})

        process = subprocess.Popen(["/bin/sh", str(self.script)], cwd=self.base, env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True, preexec_fn=block_alarm)
        try:
            try:
                stdout, stderr = process.communicate(timeout=6)
            except subprocess.TimeoutExpired:
                self.fail("The native watchdog inherited a blocked alarm and missed its deadline")
            self.assert_no_install(subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr))
            self.assertFalse((self.home / ".local").exists())
        finally:
            marker = Path(self.config["interrupt_marker"])
            if marker.exists():
                try:
                    os.killpg(int(marker.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate()

    def test_verifier_receives_no_perl_or_dynamic_loader_configuration(self):
        self.assertEqual(self.run_installer().returncode, 0)
        # Prove that the installer entered with the untrusted loader setting.
        # A SIP-protected shell can otherwise remove it before the test starts.
        self.assertIn("DYLD_INSERT_LIBRARIES", self.calls("uname")[0]["env_keys"])
        for call in self.calls("gh") + self.calls("curl"):
            for key in ("PERL5OPT", "PERL5LIB", "DYLD_INSERT_LIBRARIES"):
                self.assertNotIn(key, call["env_keys"])


if __name__ == "__main__":
    unittest.main()
