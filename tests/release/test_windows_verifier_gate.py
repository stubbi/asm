"""Refuse incomplete Windows verifier evidence and bound child capture.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib.util
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))


class WindowsVerifierGateTests(unittest.TestCase):
    def setUp(self):
        path = ROOT / "tools/windows_verifier_test.py"
        self.assertTrue(path.is_file(), "The independent Windows verifier gate is absent")
        spec = importlib.util.spec_from_file_location("windows_verifier_gate", path)
        self.gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.gate)
        self.temporary = tempfile.TemporaryDirectory(prefix="asm-verifier-gate-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)

    def events(self):
        records = []
        packages = {package for package, _ in self.gate.REQUIRED | self.gate.PRIVILEGE_SKIPS}
        for package in sorted(packages):
            records.append({"Action": "start", "Package": package})
            for selected, name in sorted(self.gate.REQUIRED | self.gate.PRIVILEGE_SKIPS):
                if selected == package:
                    records.extend(({"Action": "run", "Package": package, "Test": name},
                                    {"Action": "pass", "Package": package, "Test": name}))
            records.append({"Action": "pass", "Package": package})
        return records

    def summarize(self, records, code=0):
        return self.gate.summarize(b"".join(json.dumps(event).encode() + b"\n" for event in records), code)

    def test_complete_native_case_set_is_required(self):
        records = self.events()
        report = self.summarize(records)
        self.assertEqual(report["outcome"], "pass")
        self.assertTrue(report["declared_windows_cases_executed"])
        required = next(iter(self.gate.REQUIRED))
        records = [event for event in records if (event["Package"], event.get("Test")) != required]
        self.assertFalse(self.summarize(records)["required_cases_passed"])
        self.assertFalse(self.summarize(self.events(), code=1)["required_cases_passed"])

    def test_missing_privilege_case_cannot_claim_complete_coverage(self):
        missing = next(iter(self.gate.PRIVILEGE_SKIPS))
        records = [event for event in self.events() if (event["Package"], event.get("Test")) != missing]
        report = self.summarize(records)
        self.assertFalse(report["required_cases_passed"])
        self.assertFalse(report["declared_windows_cases_executed"])

    def test_privilege_skip_is_visible_and_does_not_qualify_that_path(self):
        skipped = next(iter(self.gate.PRIVILEGE_SKIPS))
        records = self.events()
        for event in records:
            if (event["Package"], event.get("Test")) == skipped and event["Action"] == "pass":
                event["Action"] = "skip"
        report = self.summarize(records)
        self.assertEqual(report["outcome"], "pass-with-unqualified-paths")
        self.assertFalse(report["declared_windows_cases_executed"])
        self.assertEqual(len(report["unqualified_privilege_paths"]), 1)

    def test_required_skip_and_unfinished_test_fail_the_gate(self):
        required = next(iter(self.gate.REQUIRED))
        for action in ("skip", None):
            records = self.events()
            for event in records:
                if (event["Package"], event.get("Test")) == required and event["Action"] == "pass":
                    event["Action"] = action
            records = [event for event in records if event["Action"] is not None]
            self.assertFalse(self.summarize(records)["required_cases_passed"])

    def test_ambiguous_json_and_duplicate_or_unstarted_terminal_events_are_rejected(self):
        with self.assertRaises(ValueError):
            self.gate.summarize(b'{"Action":"fail","Action":"pass","Package":"p"}\n', 0)
        records = self.events()
        for extra in (records[-1], records[2]):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                self.summarize([*records, extra])
        with self.assertRaises(ValueError):
            self.summarize([event for event in records if event["Action"] != "run"])
        with self.assertRaises(ValueError):
            self.gate.summarize(b" " * (self.gate.MAX_OUTPUT + 1), 0)

    def test_nonfinite_numbers_are_not_valid_go_json(self):
        records = self.events()
        records[-1]["Elapsed"] = float("nan")
        with self.assertRaises(ValueError):
            self.summarize(records)

    def capture(self, program, **options):
        return self.gate.capture([sys.executable, "-I", "-c", program], self.base,
                                 dict(os.environ), self.base / "raw.jsonl", **options)

    def test_failed_capture_retains_the_exact_bounded_output(self):
        code = self.capture("import sys; sys.stdout.buffer.write(b'failure detail\\n'); "
                            "sys.stdout.buffer.flush(); sys.exit(7)")
        self.assertEqual(code, 7)
        self.assertEqual((self.base / "raw.jsonl").read_bytes(), b"failure detail\n")
        with self.assertRaisesRegex(RuntimeError, "byte limit"):
            self.capture("import sys; sys.stdout.buffer.write(b'x' * 4096); sys.stdout.buffer.flush()", limit=128)
        self.assertEqual((self.base / "raw.jsonl").read_bytes(), b"x" * 128)

    def test_go_diagnostics_do_not_corrupt_the_json_stream(self):
        diagnostics = self.base / "stderr.log"
        code = self.capture("import sys; sys.stdout.buffer.write(b'{}\\n'); sys.stdout.buffer.flush(); "
                            "sys.stderr.buffer.write(b'go: downloading fixture\\n'); sys.stderr.buffer.flush()",
                            stderr_path=diagnostics)
        self.assertEqual(code, 0)
        self.assertEqual((self.base / "raw.jsonl").read_bytes(), b"{}\n")
        self.assertEqual(diagnostics.read_bytes(), b"go: downloading fixture\n")

    def test_stalled_child_and_descendant_held_pipe_cannot_hang_capture(self):
        with self.assertRaisesRegex(RuntimeError, "time limit"):
            self.capture("import sys,time; sys.stdout.buffer.write(b'before stall\\n'); "
                         "sys.stdout.buffer.flush(); time.sleep(30)", timeout=2)
        self.assertEqual((self.base / "raw.jsonl").read_bytes(), b"before stall\n")
        code = self.capture("import subprocess,sys; subprocess.Popen([sys.executable,'-I','-c',"
                            "'import time; time.sleep(30)'], stdout=sys.stdout, stderr=sys.stderr); "
                            "sys.stdout.buffer.write(b'completed parent\\n'); sys.stdout.buffer.flush()", timeout=2)
        self.assertEqual(code, 0)
        self.assertEqual((self.base / "raw.jsonl").read_bytes(), b"completed parent\n")

    def repository(self, files=None):
        repo = self.base / "repo"
        repo.mkdir()
        (repo / "verifier").mkdir()
        (repo / "verifier/example.go").write_bytes(b"package main\n")
        for name, data in (files or {}).items():
            (repo / name).write_bytes(data)
        def git(*args):
            return subprocess.check_output(["git", "-C", str(repo), "-c", "core.hooksPath=/dev/null",
                "-c", "user.name=Gate fixture", "-c", "user.email=fixture@example.invalid",
                "-c", "commit.gpgsign=false", *args], stderr=subprocess.PIPE, timeout=10).decode().strip()
        git("init", "-q")
        git("add", ".")
        git("commit", "-qm", "Create original source fixture")
        return repo, git

    def test_source_identity_binds_original_commit_tree_and_clean_files(self):
        repo, git = self.repository()
        commit, tree = git("rev-parse", "HEAD"), git("rev-parse", "HEAD^{tree}")
        identity = self.gate.source_identity(commit, root=repo)
        self.assertEqual(identity["source_commit"], commit)
        self.assertEqual(identity["source_tree"], tree)
        self.assertEqual(identity["inputs_sha256"], {
            "verifier/example.go": hashlib.sha256(b"package main\n").hexdigest()})
        with self.assertRaises(RuntimeError):
            self.gate.source_identity("a" * 40, root=repo)
        (repo / "verifier/example.go").write_text("package changed\n")
        with self.assertRaises(RuntimeError):
            self.gate.source_identity(commit, root=repo)

    def test_clean_crlf_checkout_cannot_replace_original_verifier_bytes(self):
        repo, git = self.repository({".gitattributes": b"verifier/example.go text eol=crlf\n"})
        commit = git("rev-parse", "HEAD")
        source = repo / "verifier/example.go"
        source.write_bytes(b"package main\r\n")
        # Refresh the stat cache after Git's clean conversion. The staged blob
        # remains identical to HEAD while the working file retains CRLF.
        git("add", "verifier/example.go")
        self.assertEqual(git("diff", "--cached", "--exit-code"), "")
        self.assertEqual(git("status", "--porcelain"), "", "The transformed checkout must appear clean")
        self.assertNotEqual(source.read_bytes(), git("show", "HEAD:verifier/example.go").encode() + b"\n")
        with self.assertRaisesRegex(RuntimeError, "original.*blob|blob.*bytes"):
            self.gate.source_identity(commit, root=repo)

    def test_ignored_extra_go_file_cannot_enter_qualified_inputs(self):
        repo, git = self.repository({".gitignore": b"verifier/ignored.go\n"})
        commit = git("rev-parse", "HEAD")
        (repo / "verifier/ignored.go").write_bytes(b"package main\nfunc hidden() {}\n")
        self.assertEqual(git("status", "--porcelain"), "", "The extra Go file must be hidden from status")
        self.assertEqual(git("check-ignore", "verifier/ignored.go"), "verifier/ignored.go")
        with self.assertRaisesRegex(RuntimeError, "file set|extra verifier"):
            self.gate.source_identity(commit, root=repo)

    def test_existing_evidence_is_preserved(self):
        evidence = self.base / "existing"
        evidence.mkdir()
        marker = evidence / "results.json"
        marker.write_bytes(b"prior evidence\n")
        error = io.StringIO()
        with contextlib.redirect_stderr(error), self.assertRaises(SystemExit) as stopped:
            self.gate.main(["--target", "x86_64-windows", "--source-commit", "a" * 40,
                            "--evidence", str(evidence)])
        self.assertEqual(stopped.exception.code, 2)
        self.assertIn("Select a new evidence directory", error.getvalue())
        self.assertEqual(marker.read_bytes(), b"prior evidence\n")


if __name__ == "__main__":
    unittest.main()
