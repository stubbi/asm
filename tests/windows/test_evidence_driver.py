"""Exercise qualification refusals without claiming Windows runtime coverage.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import difflib
import importlib.util
import json
import os
from pathlib import Path, PureWindowsPath
import struct
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from runtime_helpers import absolute_archive_cases, assert_complete_provenance, final_replacement_failure

MODULE = Path(__file__).resolve().parents[2] / "tools/windows_test.py"
SPEC = importlib.util.spec_from_file_location("windows_test", MODULE)
driver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(driver)


class EvidenceDriverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="windows-evidence-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.patch_root = patch.object(driver, "ROOT", self.root)
        self.patch_root.start()
        self.addCleanup(self.patch_root.stop)
        self.git("init", "--quiet")
        (self.root / "source.s").write_text(".text\n")
        self.git("add", "source.s")
        self.git("-c", "user.name=Evidence test", "-c", "user.email=evidence@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Test fixture")
        self.commit = self.git("rev-parse", "HEAD")

    def git(self, *args):
        result = subprocess.run(["git", *args], cwd=self.root, capture_output=True,
                                text=True, timeout=10, check=True)
        return result.stdout.strip()

    def pe(self, machine=0x8664):
        data = bytearray(256)
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 60, 128)
        data[128:132] = b"PE\0\0"
        struct.pack_into("<H", data, 132, machine)
        struct.pack_into("<H", data, 152, 0x20B)
        return bytes(data)

    def test_source_identity_requires_exact_clean_commit(self):
        self.assertEqual(driver.source_identity(self.commit),
                         {"source_commit": self.commit, "source_dirty": False})
        with self.assertRaisesRegex(RuntimeError, "commit"):
            driver.source_identity("0" * 40)
        (self.root / "source.s").write_text("changed bytes\n")
        with self.assertRaisesRegex(RuntimeError, "clean source"):
            driver.source_identity(self.commit)
        result = driver.source_identity(self.commit, allow_dirty=True)
        self.assertTrue(result["source_dirty"])
        self.assertEqual(result["experimental_inputs"]["source.s"],
                         driver.digest(self.root / "source.s"))

    def test_missing_executable_retains_error_evidence(self):
        output = self.root / "missing.json"
        result = driver.main(["--asm", str(self.root / "absent.exe"), "--target", "x86_64-windows",
                              "--evidence", str(output), "--source-commit", self.commit])
        self.assertEqual(result, 2)
        evidence = json.loads(output.read_text())
        self.assertEqual(evidence["outcome"], "error")
        self.assertIn("absent", evidence["error"])
        self.assertEqual(evidence["tests"], [])

    def test_packages_only_reaches_native_gate_without_a_cli_executable(self):
        output = self.root / "packages-only.json"
        with patch.object(driver, "native_machine", side_effect=RuntimeError("Native package gate reached")):
            result = driver.main(["--packages-only", "--target", "x86_64-windows", "--evidence", str(output)])
        self.assertEqual(result, 2)
        evidence = json.loads(output.read_text())
        self.assertEqual(evidence["scope"], "packages")
        self.assertEqual(evidence["error"], "Native package gate reached")
        self.assertNotIn("artifact", evidence)

    def test_wrong_pe_target_fails_before_runtime(self):
        binary = self.root / "wrong.exe"
        binary.write_bytes(self.pe(0xAA64))
        self.git("add", "wrong.exe")
        self.git("-c", "user.name=Evidence test", "-c", "user.email=evidence@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Add PE fixture")
        output = self.root / "wrong.json"
        result = driver.main(["--asm", str(binary), "--target", "x86_64-windows",
                              "--evidence", str(output)])
        self.assertEqual(result, 2)
        evidence = json.loads(output.read_text())
        self.assertEqual(evidence["artifact"]["sha256"], driver.digest(binary))
        self.assertIn("PE architecture", evidence["error"])
        self.assertEqual(evidence["tests"], [])

    def test_malformed_pe_offsets_are_bounded(self):
        binary = self.root / "bad.exe"
        for data in (b"", b"MZ", self.pe()[:150], self.pe()[:60] + b"\xff" * 4 + b"\0" * 192):
            with self.subTest(length=len(data)):
                binary.write_bytes(data)
                with self.assertRaises(ValueError):
                    driver.pe_machine(binary)

    def test_non_windows_runtime_is_an_error(self):
        if os.name == "nt":
            self.assertIn(driver.native_machine(), driver.MACHINES.values())
        else:
            with self.assertRaisesRegex(RuntimeError, "No runtime test was executed"):
                driver.native_machine()

    def test_package_qualification_requires_bound_native_cases_for_matching_target(self):
        target = "x86_64-windows"
        cases = [("hello", "src/main.s", "stdout"), ("hello", "src/main.s", "read-only-stdout"),
                 ("hello", "tests/main.s", "writer-contract"), ("math", "src/main.s", "stdout"),
                 ("math", "src/main.s", "read-only-stdout"), ("math", "tests/main.s", "assembly-contract"),
                 ("math", "tests/io.s", "assembly-contract")]
        events = []
        for number, (package, source, case) in enumerate(cases):
            artifact = f"{number:064x}"
            events += [{"phase": "build", "package": package + "-" + target, "target": target,
                        "source": source, "artifact_sha256": artifact},
                       {"phase": "native-execution", "target": target, "source": source,
                        "case": case, "artifact_sha256": artifact}]
        driver.require_package_execution(events, target)
        with self.assertRaisesRegex(ValueError, "did not execute"):
            driver.require_package_execution([event for event in events if event["phase"] == "build"], target)
        with self.assertRaisesRegex(ValueError, "did not execute"):
            driver.require_package_execution(events[:-1], target)
        broken = [dict(event) for event in events]
        broken[1]["artifact_sha256"] = "f" * 64
        with self.assertRaisesRegex(ValueError, "build-artifact binding"):
            driver.require_package_execution(broken, target)
        with self.assertRaisesRegex(ValueError, "wrong native target"):
            driver.require_package_execution(events, "aarch64-windows")


class RuntimeHelperTests(unittest.TestCase):
    def test_prepared_fault_instrumentation_changes_one_instruction(self):
        root = Path(__file__).resolve().parents[2]
        for arm64, tool, entry in ((False, "windows_x64", "cli/asm.s"),
                                   (True, "windows_arm64", "cli/aarch64/asm.s")):
            with self.subTest(tool=tool):
                spec = importlib.util.spec_from_file_location(tool, root / ("tools/" + tool + ".py"))
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                source = module.prepare(root / entry)
                changed = final_replacement_failure(source, arm64)
                before, after = source.splitlines(), changed.splitlines()
                edits = [item for item in difflib.SequenceMatcher(None, before, after, autojunk=False).get_opcodes()
                         if item[0] != "equal"]
                self.assertEqual(len(edits), 1)
                kind, start, _, changed_start, changed_end = edits[0]
                self.assertEqual(kind, "insert")
                self.assertEqual(after[changed_start:changed_end],
                                 ["    mov x2, #-1" if arm64 else "    mov rdx, -1"])
                self.assertEqual(before[start], "    ARM_CALL arm_renameat" if arm64 else "    call win_syscall")
                if not arm64:
                    self.assertIn("    mov eax, 264", before[start - 5:start])

    def test_x64_fault_targets_rename_and_preserves_later_cleanup(self):
        rename = ("    mov eax, 264\n"
                  "    mov rdi, [rip + self_stage_fd]\n"
                  "    lea rsi, [rip + self_payload_name]\n"
                  "    mov rdx, [rip + self_parent_fd]\n"
                  "    lea r10, [rip + self_binary_name]\n"
                  "    call win_syscall\n")
        cleanup = ".Lself_commit_close_fail:\n    mov eax, 3\n    mov rdi, r12\n    call win_syscall\n"
        source = "before\nself_commit_update:\n" + rename + cleanup + "\nself_update_cleanup:\nafter\n"
        changed = final_replacement_failure(source, False)
        self.assertIn("    lea r10, [rip + self_binary_name]\n    mov rdx, -1\n    call win_syscall", changed)
        self.assertIn(cleanup, changed)
        self.assertEqual(changed.replace("    mov rdx, -1\n", "", 1), source)

    def test_arm64_fault_changes_only_the_unique_final_rename(self):
        source = ("before\nself_commit_update:\n    ARM_CALL arm_fsync\n    ARM_CALL arm_renameat\n"
                  "    ARM_CALL arm_close\n\nself_update_cleanup:\nafter\n")
        changed = final_replacement_failure(source, True)
        self.assertIn("    mov x2, #-1\n    ARM_CALL arm_renameat\n", changed)
        self.assertEqual(changed.replace("    mov x2, #-1\n", "", 1), source)

    def test_fault_refuses_missing_or_ambiguous_instrumentation(self):
        for source in ("", "\nself_commit_update:\n\nself_update_cleanup:\n",
                       "\nself_commit_update:\n    ARM_CALL arm_renameat\n    ARM_CALL arm_renameat\n\nself_update_cleanup:\n"):
            with self.subTest(source=source):
                with self.assertRaises(ValueError):
                    final_replacement_failure(source, True)

    def test_absolute_archive_names_stay_under_the_owned_windows_root(self):
        for drive in ("C", "D"):
            root = PureWindowsPath(f"{drive}:/Users/test/owned temporary root")
            for name, actual in absolute_archive_cases(root):
                parsed = PureWindowsPath(name)
                if not parsed.drive:
                    parsed = PureWindowsPath(root.drive + name)
                self.assertEqual(parsed, actual)
                self.assertEqual(actual.parent, root)
                self.assertTrue(parsed.is_absolute())
        with self.assertRaises(ValueError):
            absolute_archive_cases(PureWindowsPath("relative/root"))

    def test_provenance_requires_each_subject_in_the_required_order(self):
        assert_complete_provenance(["curl", "manifest-identity", "curl", "manifest-exact", "candidate-exact"])
        for calls in (["manifest-identity", "manifest-exact", "manifest-exact"],
                      ["manifest-identity", "candidate-exact", "manifest-exact"],
                      ["manifest-identity", "manifest-exact"],
                      ["manifest-identity", "manifest-exact", "candidate-exact", "candidate-exact"]):
            with self.subTest(calls=calls):
                with self.assertRaises(AssertionError):
                    assert_complete_provenance(calls)


class VerifierFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="asm-verifier-helper-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.fixture = Path(cls.temp.name).resolve()
        sources = Path(__file__).resolve().parent
        if os.name == "nt":
            llvm = Path("C:/Program Files/LLVM/bin")
            arch = "aarch64" if driver.native_machine() == 0xAA64 else "x86_64"
            obj = cls.fixture / "tool.obj"
            cls.binary = cls.fixture / "gh.exe"
            commands = [[str(llvm / "clang.exe"), f"--target={arch}-pc-windows-msvc", "-Oz", "-Werror",
                         "-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-c",
                         str(sources / "update_tool_fixture.c"), "-o", str(obj)],
                        [str(llvm / "lld-link.exe"), "/machine:" + ("arm64" if arch == "aarch64" else "x64"),
                         "/entry:fixture_entry", "/subsystem:console", "/nodefaultlib", "/nxcompat", "/dynamicbase",
                         "/out:" + str(cls.binary), str(obj), "kernel32.lib", "shell32.lib"]]
        else:
            cls.binary = cls.fixture / "verifier-host"
            commands = [["cc", "-std=c11", "-fshort-wchar", "-O0", "-Werror",
                         str(sources / "update_tool_fixture_host.c"), "-o", str(cls.binary)]]
        for argv in commands:
            result = subprocess.run(argv, capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise RuntimeError((argv, result.stdout, result.stderr))
        cls.curl_binary = cls.fixture / "curl.exe"
        shutil.copyfile(cls.binary, cls.curl_binary)

    def setUp(self):
        files = {"release.json": b"exact manifest\n", "artifact": b"exact candidate\n", "bundle": b"exact bundle\n",
                 "subject-manifest": b"exact manifest\n", "subject-candidate": b"exact candidate\n",
                 "subject-bundle": b"exact bundle\n"}
        for name, data in files.items():
            (self.fixture / name).write_bytes(data)
        for name in ("calls.tsv", "reject-signature", "reject-source", "wrong-repository"):
            (self.fixture / name).unlink(missing_ok=True)

    def verify(self, subject="subject-manifest", bundle="subject-bundle", exact=False, code=0):
        args = ["attestation", "verify", str(self.fixture / subject), "--repo", "stubbi/asm",
                "--cert-identity", "https://github.com/stubbi/asm/.github/workflows/release.yml@refs/heads/main",
                "--cert-oidc-issuer", "https://token.actions.githubusercontent.com", "--source-ref", "refs/heads/main",
                "--predicate-type", "https://slsa.dev/provenance/v1", "--hostname", "github.com", "--format", "json",
                "--jq", ".[].verificationResult.signature.certificate.sourceRepositoryIdentifier",
                "--deny-self-hosted-runners", "--bundle", str(self.fixture / bundle)]
        if exact:
            args += ["--source-digest", "a" * 40, "--signer-digest", "a" * 40]
        prefix = [str(self.binary)] if os.name == "nt" else [str(self.binary), str(self.fixture), "gh.exe"]
        environment = dict(os.environ)
        for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "CURL_CA_BUNDLE", "SSL_CERT_FILE"):
            environment.pop(name, None)
        result = subprocess.run(prefix + args, capture_output=True, text=True, env=environment, timeout=10)
        self.assertEqual(result.returncode, code, (result.args, result.stdout, result.stderr))
        if code == 0:
            self.assertEqual(result.stdout, "1441332955\n")
        return result

    def calls(self):
        path = self.fixture / "calls.tsv"
        return path.read_text().splitlines() if path.exists() else []

    def test_exact_subjects_and_bundle_have_distinct_provenance_bindings(self):
        self.verify()
        self.verify(exact=True)
        self.verify(subject="subject-candidate", exact=True)
        assert_complete_provenance(self.calls())

    def test_changed_subject_and_bundle_bytes_are_rejected(self):
        (self.fixture / "subject-manifest").write_bytes(b"changed manifest\n")
        self.verify(code=92)
        (self.fixture / "subject-candidate").write_bytes(b"changed candidate\n")
        self.verify(subject="subject-candidate", exact=True, code=92)
        (self.fixture / "subject-manifest").write_bytes(b"exact manifest\n")
        (self.fixture / "subject-bundle").write_bytes(b"changed bundle\n")
        self.verify(code=92)
        self.verify(bundle="missing-bundle", code=92)
        self.assertEqual(self.calls(), [])

    def test_duplicate_manifest_cannot_stand_in_for_candidate_verification(self):
        self.verify(subject="subject-candidate", code=92)
        self.verify()
        self.verify(exact=True)
        self.verify(exact=True)
        self.assertEqual(self.calls(), ["manifest-identity", "manifest-exact", "manifest-exact"])
        with self.assertRaises(AssertionError):
            assert_complete_provenance(self.calls())

    def test_subject_comparison_checks_tail_bytes_and_length_across_chunks(self):
        data = b"a" * 32768 + b"b" * 32768 + b"tail"
        (self.fixture / "artifact").write_bytes(data)
        subject = self.fixture / "subject-candidate"
        subject.write_bytes(data)
        self.verify(subject="subject-candidate", exact=True)
        for changed in (data[:-1] + b"x", data + b"x", data[:-1]):
            with self.subTest(length=len(changed)):
                subject.write_bytes(changed)
                self.verify(subject="subject-candidate", exact=True, code=92)

    def test_transport_returns_exact_binary_bytes_on_stdout_without_a_destination_file(self):
        data = b"exact transport bytes\n\x00\r\n"
        (self.fixture / "artifact").write_bytes(data)
        args = ["--disable", "--proto", "=https", "--proto-redir", "=https", "--max-filesize", str(len(data)),
                "--output", "-", "--", "https://github.com/stubbi/asm/releases/download/v1/payload"]
        prefix = [str(self.curl_binary)] if os.name == "nt" else [str(self.binary), str(self.fixture), "curl.exe"]
        environment = dict(os.environ)
        for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "CURL_CA_BUNDLE", "SSL_CERT_FILE"):
            environment.pop(name, None)
        result = subprocess.run(prefix + args, cwd=self.fixture, capture_output=True, env=environment, timeout=10)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, data, b""))
        self.assertFalse((self.fixture / "-").exists())


if __name__ == "__main__":
    unittest.main()
