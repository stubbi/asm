"""Reject incomplete RISC-V combined qualification evidence.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CombinedQualificationTests(unittest.TestCase):
    def setUp(self):
        source = ROOT / "tools/riscv64_combined.py"
        self.assertTrue(source.is_file(), "The combined qualification runner is absent")
        spec = importlib.util.spec_from_file_location("combined_qualification", source)
        self.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.runner)

    def test_guest_tool_requires_a_riscv_elf_executable(self):
        data = bytearray(64)
        data[:7] = b"\x7fELF\x02\x01\x01"
        struct.pack_into("<HH", data, 16, 3, 243)
        self.assertEqual(self.runner.elf_machine(data), 243)
        for bad in (b"#!/bin/sh\n", data[:63]):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    self.runner.elf_machine(bad)
        for machine, kind in ((62, 3), (243, 1)):
            struct.pack_into("<HH", data, 16, kind, machine)
            with self.subTest(machine=machine, kind=kind):
                with self.assertRaises(ValueError):
                    self.runner.elf_machine(data)

    def test_all_nineteen_tests_must_pass_without_skips(self):
        good = "Ran 19 tests in 8.2s\n\nOK\n"
        self.assertEqual(self.runner.suite_contract(good, 19), 19)
        for bad in ("", good.replace("19", "18"), good.replace("19", "20"),
                    good.replace("OK", "FAILED (failures=1)"),
                    good.replace("OK", "OK (skipped=1)"),
                    "test_x (test_fixture.Tests.test_x) ... skipped 'host'\n" + good):
            with self.subTest(output=bad):
                with self.assertRaises(ValueError):
                    self.runner.suite_contract(bad, 19)

    def test_compiler_must_declare_the_guest_target(self):
        self.runner.compiler_contract("riscv64-linux-gnu")
        for target in ("x86_64-linux-gnu", "aarch64-linux-gnu", "riscv32-linux-gnu", ""):
            with self.subTest(target=target):
                with self.assertRaises(ValueError):
                    self.runner.compiler_contract(target)

    def test_collected_report_requires_nineteen_server_tests(self):
        self.assertTrue(hasattr(self.runner, "result_contract"), "Collected reports have no acceptance contract")
        report = {"outcome": "pass", "target": "riscv64-linux", "execution": "qemu-user",
                  "native_qualified": False, "release_qualified": False,
                  "checks": {"server_package": {"outcome": "pass", "tests_run": 19, "tests_skipped": 0}}}
        self.runner.result_contract(report)
        for changes in ({"tests_run": 18}, {"tests_skipped": 1}, {"outcome": "fail"}):
            with self.subTest(changes=changes):
                bad = json.loads(json.dumps(report))
                bad["checks"]["server_package"].update(changes)
                with self.assertRaises(ValueError):
                    self.runner.result_contract(bad)

    def test_source_receipt_rejects_legacy_mode_free_digest_schema(self):
        self.assertTrue(hasattr(self.runner, "input_contract"), "Runtime inputs have no versioned digest contract")
        inputs = {"schema": 2, "hosted_revision": self.runner.HOSTED_REVISION,
                  "package_revision": self.runner.PACKAGE_REVISION}
        self.runner.input_contract(inputs)
        for schema in (1, 2.0, "2", True, None):
            with self.subTest(schema=schema):
                with self.assertRaises(ValueError):
                    self.runner.input_contract({**inputs, "schema": schema})
        with self.assertRaises(ValueError):
            self.runner.input_contract({key: value for key, value in inputs.items() if key != "schema"})

    def test_failed_guest_setup_retains_failure_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "qualification.json"
            result = subprocess.run([sys.executable, str(ROOT / "tools/riscv64_combined.py"),
                                     "--inside", "--output", str(output)], capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            report = json.loads(output.read_text())
            self.assertEqual(report["outcome"], "fail")
            self.assertFalse(report["native_qualified"])
            self.assertFalse(report["release_qualified"])
            self.assertIn("error", report)


class CombinedResourceBoundsTests(unittest.TestCase):
    setUp = CombinedQualificationTests.setUp

    def _host_boundaries(self):
        from unittest import mock
        base = {"Id": "sha256:base", "Architecture": "riscv64", "Os": "linux",
                "RootFS": {"Layers": ["sha256:layer"]}, "Config": {}}
        derived = {**base, "Id": "sha256:derived", "Config": {"Labels": {
            "build.asm.hosted-build-id": base["Id"], "build.asm.candidate-revision": "a" * 40}}}
        def host_command(arguments, **kwargs):
            if arguments[1:3] == ["image", "inspect"]:
                image = base if arguments[3] == "base" else derived
                return subprocess.CompletedProcess(arguments, 0, stdout=json.dumps([image]).encode())
            return subprocess.CompletedProcess(arguments, 0, stdout=b"")
        return (mock.patch.object(self.runner, "command", side_effect=host_command),
                mock.patch.object(self.runner, "bounded_process", return_value={"outcome": "pass", "exit_code": 0}))

    def test_failed_collection_never_reads_an_oversized_prior_report(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            previous = output / "qualification.json"
            previous.write_bytes(b" " * (self.runner.EVIDENCE_LIMITS["qualification.json"] + 3))
            old_size = previous.stat().st_size
            original_read = Path.read_text
            def guarded_read(path, *arguments, **kwargs):
                self.assertNotEqual(path, previous, "Failed collection read the oversized prior report")
                return original_read(path, *arguments, **kwargs)
            host_command, runtime = self._host_boundaries()
            with host_command, runtime, mock.patch.object(self.runner, "collect_file", side_effect=ValueError("current collection failed")), mock.patch.object(Path, "read_text", new=guarded_read):
                self.assertEqual(self.runner.run_image("derived", "base", output), 1)
            self.assertEqual(previous.stat().st_size, old_size)
            report = json.loads((output / "combined-report.json").read_text())
            self.assertEqual(report["outcome"], "fail")
            self.assertIn("collection_error", report)

    def test_current_report_cannot_hash_an_uncollected_prior_artifact(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            previous = output / "asm-riscv64-linux"
            old_size = self.runner.EVIDENCE_LIMITS[previous.name] + 1
            with previous.open("wb") as stream:
                stream.truncate(old_size)
            result = {"outcome": "pass", "target": "riscv64-linux", "execution": "qemu-user",
                      "native_qualified": False, "release_qualified": False,
                      "checks": {"server_package": {"outcome": "pass", "tests_run": 19, "tests_skipped": 0}},
                      "inputs": {"candidate_revision": "a" * 40}}
            def current_collection(arguments, filename, destination, budget, **kwargs):
                if filename != "qualification.json":
                    raise ValueError("current artifact collection failed")
                (destination / filename).write_text(json.dumps(result))
                budget["files"] += 1
                budget["bytes"] += (destination / filename).stat().st_size
            host_command, runtime = self._host_boundaries()
            with host_command, runtime, mock.patch.object(self.runner, "collect_file", side_effect=current_collection), mock.patch.object(self.runner, "sha256", side_effect=AssertionError("Uncollected prior artifact reached hashing")):
                self.assertEqual(self.runner.run_image("derived", "base", output), 1)
            self.assertEqual(previous.stat().st_size, old_size)
            self.assertEqual(json.loads((output / "combined-report.json").read_text())["outcome"], "fail")

    def test_noisy_child_is_killed_at_the_log_byte_limit(self):
        self.assertTrue(hasattr(self.runner, "bounded_process"), "Commands have no streamed byte limit")
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "noisy.log"
            result = self.runner.bounded_process(
                [sys.executable, "-c", "import os\nwhile True: os.write(1, b'x' * 4096)"],
                log, timeout=3, max_bytes=8192)
            self.assertEqual(result["failure"], "byte-limit")
            self.assertEqual(log.stat().st_size, 8192)
            self.assertLess(result["seconds"], 2)
            self.assertNotEqual(result["exit_code"], 0)

    def test_deadline_kills_pipe_descendant_after_leader_exits(self):
        self.assertTrue(hasattr(self.runner, "bounded_process"), "Commands have no streamed deadline")
        import time
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "descendant-survived"
            log = Path(temporary) / "descendant.log"
            # A fresh Python interpreter can consume the entire 0.2-second
            # deadline under CPU emulation before this scenario even starts.
            # Shell builtins establish the fork/pipe state without Python startup.
            child = ('(printf "descendant holds stdout\\n"; sleep 0.8; '
                     'printf survived > "$1"; sleep 30) & exit 0')
            result = self.runner.bounded_process(["/bin/sh", "-c", child, "asm-deadline-test", str(marker)], log,
                                                 timeout=0.2, max_bytes=8192)
            self.assertEqual(result["failure"], "deadline")
            self.assertLess(result["seconds"], 2)
            self.assertIn(b"descendant holds stdout", log.read_bytes())
            time.sleep(0.9)
            self.assertFalse(marker.exists(), "The exited leader's descendant survived group termination")

    def test_one_allowlisted_tar_file_is_copied_and_counted(self):
        self.assertTrue(hasattr(self.runner, "collect_file"), "Host collection has no bounded file boundary")
        import io
        import tarfile
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            archive = base / "incoming.tar"
            with tarfile.open(archive, "w") as stream:
                member = tarfile.TarInfo("qualification.json")
                member.size = 2
                stream.addfile(member, io.BytesIO(b"{}"))
            destination = base / "evidence"
            destination.mkdir()
            budget = {"bytes": 0, "files": 0}
            emit = [sys.executable, "-c", "import pathlib,sys;sys.stdout.buffer.write(pathlib.Path(sys.argv[1]).read_bytes())", str(archive)]
            self.runner.collect_file(emit, "qualification.json", destination, budget, max_bytes=2)
            self.assertEqual((destination / "qualification.json").read_bytes(), b"{}")
            self.assertEqual(budget, {"bytes": 2, "files": 1})

    def test_collected_file_limits_preserve_existing_evidence(self):
        self.assertTrue(hasattr(self.runner, "collect_file"), "Host collection has no bounded file boundary")
        import io
        import tarfile
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            archive = base / "incoming.tar"
            with tarfile.open(archive, "w") as stream:
                member = tarfile.TarInfo("qualification.json")
                member.size = 9
                stream.addfile(member, io.BytesIO(b"new bytes"))
            destination = base / "evidence"
            destination.mkdir()
            previous = destination / "qualification.json"
            previous.write_bytes(b"previous evidence")
            emit = [sys.executable, "-c", "import pathlib,sys;sys.stdout.buffer.write(pathlib.Path(sys.argv[1]).read_bytes())", str(archive)]
            with self.assertRaises(ValueError):
                self.runner.collect_file(emit, "qualification.json", destination,
                                         {"bytes": 0, "files": 0}, max_bytes=8)
            self.assertEqual(previous.read_bytes(), b"previous evidence")
            with self.assertRaises(ValueError):
                self.runner.collect_file(emit, "qualification.json", destination,
                                         {"bytes": self.runner.EVIDENCE_TOTAL_LIMIT - 1, "files": 0}, max_bytes=16)
            self.assertEqual(previous.read_bytes(), b"previous evidence")
            with self.assertRaises(ValueError):
                self.runner.collect_file(emit, "qualification.json", destination,
                                         {"bytes": 0, "files": self.runner.EVIDENCE_FILE_LIMIT}, max_bytes=16)

    def test_collected_tar_rejects_links_directories_and_extra_members(self):
        self.assertTrue(hasattr(self.runner, "collect_file"), "Host collection has no allowlisted tar boundary")
        import io
        import tarfile
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            destination = base / "evidence"
            destination.mkdir()
            for kind in (tarfile.SYMTYPE, tarfile.DIRTYPE, tarfile.XHDTYPE, "extra"):
                archive = base / "incoming.tar"
                with tarfile.open(archive, "w") as stream:
                    member = tarfile.TarInfo("qualification.json")
                    if kind == "extra":
                        member.size = 2
                        stream.addfile(member, io.BytesIO(b"{}"))
                        other = tarfile.TarInfo("unrequested")
                        other.size = 1
                        stream.addfile(other, io.BytesIO(b"x"))
                    else:
                        member.type = kind
                        member.linkname = "/outside"
                        stream.addfile(member)
                emit = [sys.executable, "-c", "import pathlib,sys;sys.stdout.buffer.write(pathlib.Path(sys.argv[1]).read_bytes())", str(archive)]
                with self.subTest(kind=kind):
                    with self.assertRaises(ValueError):
                        self.runner.collect_file(emit, "qualification.json", destination,
                                                 {"bytes": 0, "files": 0}, max_bytes=16)
                    self.assertEqual(list(destination.iterdir()), [])


class CombinedSourceBindingTests(unittest.TestCase):
    def setUp(self):
        CombinedQualificationTests.setUp(self)
        self.temporary = tempfile.TemporaryDirectory(prefix="combined-source-binding-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.repo = self.work / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Source fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "core.filemode", "true")
        self.original = {"LICENSE": (b"fixture license\n", 0o644),
                         ".dockerignore": (b"fixture boundary\n", 0o644),
                         "containers/server.Dockerfile": (b"FROM fixture\n", 0o644),
                         "tools/registry.py": (b"# fixture registry\n", 0o644)}
        for prefix in ("", "server/", "experiments/assembly-server/"):
            self.original.update({prefix + "source.s": (b"original $Format:%H$\n", 0o644),
                                  prefix + "retained.s": (b"retained source\n", 0o644),
                                  prefix + "tool.sh": (b"#!/bin/sh\nexit 0\n", 0o755)})
        for name, (data, mode) in self.original.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(mode)
        self.git("add", ".")
        self.git("commit", "-qm", "original source")
        self.commit = self.git("rev-parse", "HEAD")
        for name in self.original:
            (self.repo / name).write_bytes(b"replacement source\n")
            (self.repo / name).chmod(0o644)
        self.git("add", ".")
        self.git("commit", "-qm", "replacement source")
        self.changed = self.git("rev-parse", "HEAD")
        # Deliberately leave changed worktree bytes outside the selected commit.
        self.git("update-ref", "HEAD", self.commit)

    def git(self, *arguments):
        return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", "-C", str(self.repo),
                                        *arguments], text=True, stderr=subprocess.STDOUT, timeout=10).strip()

    def assert_original_contexts(self):
        from unittest import mock
        import tarfile
        selections = {"hosted": ("containers/server.Dockerfile", ".dockerignore", "server", "LICENSE"),
                      "package-source": ("experiments/assembly-server", "tools/registry.py", "LICENSE"),
                      "candidate": ()}
        receipts = []
        with mock.patch.object(self.runner, "ROOT", self.repo), mock.patch.object(self.runner, "HOSTED_REVISION", self.commit), mock.patch.object(self.runner, "PACKAGE_REVISION", self.commit):
            for number in range(2):
                output = self.work / ("context-" + str(number))
                self.runner.prepare_context(output, self.commit)
                receipt = json.loads((output / "input-manifest.json").read_text())
                self.assertEqual(receipt["schema"], 2)
                self.runner.input_contract(receipt)
                receipts.append(receipt)
                for name, paths in selections.items():
                    expected = {path: value for path, value in self.original.items()
                                if not paths or any(path == prefix or path.startswith(prefix + "/") for prefix in paths)}
                    actual = {path.relative_to(output / name).as_posix():
                              (path.read_bytes(), path.stat().st_mode & 0o777)
                              for path in (output / name).rglob("*") if path.is_file()}
                    self.assertEqual(actual, expected, name + " did not use the original committed bytes and modes")
                    record = receipt["archives"][name]
                    self.assertEqual(record["commit"], self.commit)
                    self.assertEqual(record["sha256"], self.runner.sha256(output / (name + ".tar")))
                    self.assertEqual(record["tree_sha256"], self.runner.tree_digest(output / name))
                    with tarfile.open(output / (name + ".tar"), "r:") as archive:
                        archived = {item.name: (archive.extractfile(item).read(), item.mode)
                                    for item in archive if item.isfile()}
                    self.assertEqual(archived, expected)
                    tool = output / name / ("tool.sh" if name == "candidate" else
                                            "server/tool.sh" if name == "hosted" else
                                            "experiments/assembly-server/tool.sh")
                    tool.chmod(0o644)
                    self.assertNotEqual(self.runner.tree_digest(output / name), record["tree_sha256"],
                                        "The source receipt did not bind its executable mode")
                    tool.chmod(0o755)
        self.assertEqual(receipts[0], receipts[1], "Source tar receipts must be deterministic")

    def test_commit_replacements_cannot_change_any_context(self):
        self.git("replace", self.commit, self.changed)
        self.assert_original_contexts()

    def test_filtered_tracked_paths_cannot_silently_disappear_from_contexts(self):
        from unittest import mock
        original = self.commit
        for number, relative in enumerate(("build/hidden.s", "server/build/hidden.s",
                                            "experiments/assembly-server/build/hidden.s")):
            with self.subTest(path=relative):
                self.git("reset", "--hard", original)
                path = self.repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"committed source must not disappear\n")
                self.git("add", "-f", "--", relative)
                self.git("commit", "-qm", "Record unsupported tracked path")
                commit = self.git("rev-parse", "HEAD")
                output = self.work / ("unsupported-context-" + str(number))
                with mock.patch.object(self.runner, "ROOT", self.repo), \
                        mock.patch.object(self.runner, "HOSTED_REVISION", commit), \
                        mock.patch.object(self.runner, "PACKAGE_REVISION", commit):
                    with self.assertRaisesRegex(ValueError, "unsupported tracked"):
                        self.runner.prepare_context(output, commit)
                self.assertFalse((output / "input-manifest.json").exists())

    def test_tree_replacements_cannot_change_any_context(self):
        self.git("replace", self.git("--no-replace-objects", "rev-parse", self.commit + "^{tree}"),
                 self.git("--no-replace-objects", "rev-parse", self.changed + "^{tree}"))
        self.assert_original_contexts()

    def test_blob_replacements_cannot_change_any_context(self):
        self.git("replace", self.git("--no-replace-objects", "rev-parse", self.commit + ":source.s"),
                 self.git("--no-replace-objects", "rev-parse", self.changed + ":source.s"))
        self.assert_original_contexts()

    def test_committed_export_attributes_cannot_filter_or_expand_sources(self):
        self.git("reset", "--hard", self.commit)
        attributes = "**/retained.s export-ignore\nretained.s export-ignore\n**/source.s export-subst\nsource.s export-subst\n"
        (self.repo / ".gitattributes").write_text(attributes)
        self.git("add", ".gitattributes")
        self.git("commit", "-qm", "committed archive attributes")
        self.commit = self.git("rev-parse", "HEAD")
        self.original[".gitattributes"] = (attributes.encode(), 0o644)
        self.assert_original_contexts()

    def test_untracked_info_attributes_cannot_filter_or_expand_sources(self):
        (self.repo / ".git/info/attributes").write_text("**/retained.s export-ignore\nretained.s export-ignore\n**/source.s export-subst\nsource.s export-subst\n")
        self.assert_original_contexts()

    def test_untracked_worktree_attributes_cannot_change_sources(self):
        (self.repo / ".gitattributes").write_text("** export-ignore\n")
        self.assert_original_contexts()


if __name__ == "__main__":
    unittest.main(verbosity=2)
