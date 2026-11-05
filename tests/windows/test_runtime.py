"""Observe the public PE CLI on its declared native Windows target.

Run through tools/windows_test.py. No source-string assertions qualify a port.
SPDX-License-Identifier: AGPL-3.0-or-later
"""

import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import shutil
import tarfile
import tempfile
import time
import unittest

from runtime_helpers import absolute_archive_cases, assert_complete_provenance, final_replacement_failure, capture_deadline_source, displaced_running_image
from fixture_security import own_directory, own_home_directories, own_path

ROOT = Path(__file__).resolve().parents[2]
ASM = Path(os.environ["ASM_WINDOWS_EXE"])
TARGET = os.environ["ASM_WINDOWS_TARGET"]
ARM64 = TARGET == "aarch64-windows"
OTHER_TARGET = "x86_64-windows" if ARM64 else "aarch64-windows"
VERSION = json.loads((ROOT / "cli/commands.json").read_text())["version"]
HEADER = "# asm-registry-v1\n"
PACKAGE = "fixture/hello"
COMMANDS = []
TEST_ARTIFACTS = []
TOOLCHAIN_BIN = Path("C:/Program Files/LLVM/bin")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def program(body):
    syntax = "" if ARM64 else ".intel_syntax noprefix\n"
    return syntax + ".text\n.global _start\n.extern ExitProcess\n_start:\n" + body + "\n"


def exit_source(code):
    return program(f"mov w0, #{code}\nbl ExitProcess" if ARM64 else
                   f"sub rsp, 40\nmov ecx, {code}\ncall ExitProcess")


def marker_source(code):
    # A deliberately observable package. Management must never create this file.
    if ARM64:
        return program("sub sp, sp, #64\nadrp x0, marker\nadd x0, x0, :lo12:marker\n"
                       "mov w1, #0x40000000\nmov w2, #0\nmov x3, #0\n"
                       "mov w4, #2\nmov w5, #128\nmov x6, #0\nbl CreateFileA\n"
                       f"mov w0, #{code}\nbl ExitProcess\n"
                       '.data\nmarker: .asciz "PACKAGE_EXECUTED"\n.extern CreateFileA')
    return program("sub rsp, 72\nlea rcx, [rip + marker]\nmov edx, 0x40000000\n"
                   "xor r8d, r8d\nxor r9d, r9d\nmov qword ptr [rsp+32], 2\n"
                   "mov qword ptr [rsp+40], 128\nmov qword ptr [rsp+48], 0\ncall CreateFileA\n"
                   f"mov ecx, {code}\ncall ExitProcess\n"
                   '.data\nmarker: .asciz "PACKAGE_EXECUTED"\n.extern CreateFileA')


def archive_bytes(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, kind, data in entries:
            member = tarfile.TarInfo(name)
            member.type = kind
            member.mode = 0o755 if kind == tarfile.DIRTYPE else 0o644
            member.uid = member.gid = member.mtime = 0
            member.size = len(data) if kind == tarfile.REGTYPE else 0
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                member.linkname = "../../outside"
            archive.addfile(member, io.BytesIO(data) if member.size else None)
    return gzip.compress(stream.getvalue(), mtime=0)


class WindowsRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="asm-windows-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name).resolve()
        self.home = self.work / "home with spaces"
        self.home.mkdir()
        own_directory(self.home, self.work)
        self.environment = dict(os.environ, HOME=str(self.home), USERPROFILE=str(self.home))
        self.index = self.work / "index.tsv"
        self.artifact = self.work / "payload"
        self.inventory = self.home / ".local/state/asm/installed.tsv"

    def cli(self, *args, cwd=None, code=0, env=None, binary=ASM, timeout=30):
        argv = [str(binary), *map(str, args)]
        started = time.monotonic()
        result = subprocess.run(argv, cwd=cwd or self.work, env=env or self.environment,
                                capture_output=True, text=True, encoding="utf-8",
                                errors="strict", timeout=timeout)
        COMMANDS.append({"test": self.id(), "argv": argv, "cwd": str(cwd or self.work),
                         "exit_code": result.returncode, "stdout": result.stdout[:65536],
                         "stderr": result.stderr[:65536],
                         "seconds": round(time.monotonic() - started, 6)})
        self.assertEqual(result.returncode, code, (argv, result.stdout, result.stderr))
        if code == 0:
            self.assertEqual(result.stderr, "")
        elif code in (1, 2, 69):
            self.assertNotEqual(result.stderr, "")
        self.assertFalse(((cwd or self.work) / "PACKAGE_EXECUTED").exists(),
                         "Package management executed package code")
        self.assertEqual(list((cwd or self.work).glob(".asm-registry-*")), [], "A private stage remains")
        return result

    def project(self, name="hello"):
        project = self.work / name
        self.cli("new", project)
        return project

    def metadata(self, data, *, package=PACKAGE, version="0.1.0", target=TARGET,
                 kind="source", digest=None, size=None):
        return "\t".join((package, version, target, kind, digest or sha256(data),
                          f"https://github.com/stubbi/asm/releases/download/v{version}/payload.tar.gz",
                          str(len(data) if size is None else size), "A runtime test fixture")) + "\n"

    def write_index(self, *rows):
        self.index.write_bytes((HEADER + "".join(rows)).encode())

    def payload(self, data, **metadata):
        self.artifact.write_bytes(data)
        self.write_index(self.metadata(data, **metadata))

    def installed(self):
        return json.loads(self.cli("installed", "--json").stdout)["installed"]

    def executable_fixture(self, project_name="payload-source", code=73):
        project = self.project(project_name)
        (project / "src/main.s").write_text(marker_source(code), encoding="utf-8")
        self.cli("build", cwd=project)
        return (project / "build/app.exe").read_bytes()

    def source_fixture(self, *, version="0.1.0", entries=None):
        manifest = (f'[package]\nname = "hello"\nversion = "{version}"\n\n'
                    f'[build]\nsource = "src/main.s"\ntarget = "{TARGET}"\n').encode()
        routine = (".text\n.global asm_u64_min\nasm_u64_min:\ncmp x0, x1\n"
                   "csel x0, x0, x1, ls\nret\n" if ARM64 else
                   ".intel_syntax noprefix\n.text\n.global asm_u64_min\nasm_u64_min:\n"
                   "mov rax, rcx\ncmp rcx, rdx\ncmova rax, rdx\nret\n").encode()
        return archive_bytes(entries if entries is not None else [
            ("asm.toml", tarfile.REGTYPE, manifest),
            ("LICENSE", tarfile.REGTYPE, b"A deterministic test fixture.\n"),
            ("README.md", tarfile.REGTYPE, b"Deterministic Windows source-package fixture.\n"),
            ("src/main.s", tarfile.REGTYPE, exit_source(0).encode()),
            ("src/min.s", tarfile.REGTYPE, routine),
        ])

    def consumer(self, project, version="0.1.0"):
        if ARM64:
            body = ("sub sp, sp, #32\nmov x0, #12\nmov x1, #37\nbl asm_u64_min\n"
                    "cmp x0, #12\ncset w0, ne\nbl ExitProcess")
        else:
            body = ("sub rsp, 40\nmov ecx, 12\nmov edx, 37\ncall asm_u64_min\n"
                    "cmp rax, 12\nmov ecx, 0\nje success\nmov ecx, 99\nsuccess:\ncall ExitProcess")
        include = f'.include "fixture/hello/{version}/{TARGET}/src/min.s"\n'
        (project / "src/main.s").write_text(include + program(body), encoding="utf-8")

    def add(self, project, *, version="0.1.0", code=0):
        return self.cli("add", f"{PACKAGE}@{version}", "--index", self.index,
                        "--artifact", self.artifact, "--json", cwd=project, code=code)

    def junction(self, link, target):
        # mklink is a fixed Windows command. Both paths come from this test's temp directory.
        shell = str(Path(os.environ["SystemRoot"]) / "System32/cmd.exe")
        result = subprocess.run([shell, "/d", "/c", "mklink", "/J", str(link), str(target)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertTrue(link.lstat().st_file_attributes & 0x400, "The fixture is not a reparse point")

    def test_version_help_license_doctor_and_target(self):
        self.assertEqual(self.cli("version").stdout, f"asm {VERSION} ({TARGET})\n")
        self.assertIn("Usage:", self.cli().stdout)
        self.assertEqual(json.loads(self.cli("version", "--json").stdout)["version"], VERSION)
        self.assertTrue(json.loads(self.cli("doctor", "--json").stdout)["ok"])
        self.assertEqual(json.loads(self.cli("targets", "--json").stdout),
                         {"host": TARGET, "targets": [TARGET]})
        license_ = json.loads(self.cli("license", "--json").stdout)
        self.assertEqual(license_["license"], "AGPL-3.0-or-later")
        self.assertEqual(license_["template_license"], "MIT")
        self.assertFalse(license_["warranty"])
        status = json.loads(self.cli("status").stdout)
        for command in ("build", "fetch", "install", "upgrade", "uninstall", "add", "sync", "self"):
            self.assertIn(command, status["implemented"])

    def test_new_init_build_run_test_clean(self):
        project = self.project()
        self.assertIn(f'target = "{TARGET}"', (project / "asm.toml").read_text())
        self.assertEqual(self.cli("run", cwd=project).stdout, "Hello from asm!\n")
        self.assertTrue((project / "build/app.exe").is_file())
        self.assertTrue(json.loads(self.cli("test", "--json", cwd=project).stdout)["ok"])
        keep = project / "build/keep.txt"
        keep.write_bytes(b"user data")
        self.cli("clean", cwd=project)
        self.assertEqual(keep.read_bytes(), b"user data")
        self.assertFalse((project / "build/app.exe").exists())
        self.cli("clean", cwd=project)
        self.assertTrue((project / "src/main.s").is_file())
        blank = self.work / "blank"
        blank.mkdir()
        self.cli("init", cwd=blank)
        self.assertTrue((blank / "asm.toml").is_file())

    def test_starter_preserves_the_mit_grant(self):
        project = self.project()
        notice = (ROOT / "LICENSES/MIT.txt").read_text().strip()
        for path in (project / "src/main.s", project / "tests/main.s"):
            source = path.read_text()
            self.assertIn("SPDX-License-Identifier: MIT", source)
            self.assertIn(notice, "\n".join(line[2:] if line.startswith("# ") else ""
                                           for line in source.splitlines()))

    def test_named_native_target_uses_its_source_and_test_paths(self):
        project = self.project()
        # Parse all seven real declarations while executing only this native target.
        shutil.copytree(ROOT / "examples/hello/targets", project / "targets")
        shutil.copyfile(ROOT / "examples/hello/asm.toml", project / "asm.toml")
        manifest = project / "asm.toml"
        source = project / "selected.s"
        test = project / "selected-test.s"
        source.write_bytes((project / f"targets/{TARGET}/src/main.s").read_bytes())
        test.write_bytes((project / f"targets/{TARGET}/tests/main.s").read_bytes())
        (project / "src/main.s").write_text("invalid inactive default source\n")
        (project / "tests/main.s").write_text("invalid inactive default test\n")
        manifest.write_text(manifest.read_text().replace(f'targets/{TARGET}/src/main.s', 'selected.s')
                            .replace(f'targets/{TARGET}/tests/main.s', 'selected-test.s'))
        self.assertEqual(self.cli("run", "--target", TARGET, cwd=project).stdout, "Hello from asm!\n")
        self.assertTrue(json.loads(self.cli("test", "--target", TARGET, "--json", cwd=project).stdout)["ok"])
        self.assertTrue((project / "build/app.exe").is_file())
        self.assertTrue((project / "build/test.exe").is_file())

    def test_native_no_run_builds_the_test_without_execution(self):
        project = self.project()
        (project / "tests/main.s").write_text(marker_source(73))
        report = json.loads(self.cli("test", "--no-run", "--json", cwd=project).stdout)
        self.assertEqual(report, {"ok": True, "artifact": "build/test.exe", "executed": False})
        self.assertTrue((project / "build/test.exe").is_file())
        self.assertFalse((project / "PACKAGE_EXECUTED").exists())

    def test_invalid_inactive_target_preserves_the_native_output(self):
        project = self.project()
        self.cli("build", cwd=project)
        previous = (project / "build/app.exe").read_bytes()
        native = (f'[package]\nname="hello"\nversion="0.1.0"\n'
                  f'[target.{TARGET}]\nsource="src/main.s"\n')
        inactive = f'[target.{OTHER_TARGET}]\n'
        for recipe in ('source="../outside.s"\n', 'source="@options.s"\n',
                       'source="C:/outside.s"\n', 'source="src/NUL.s"\n',
                       'source="src/trailing./main.s"\n', 'source="source.s:stream"\n',
                       'source="src/main.s"\ntest="C:/outside.s"\n',
                       'source="src/main.s"\nlink="c"\ncheck="C:/outside.c"\n',
                       'source="src/main.s"\nunknown="value"\n'):
            with self.subTest(recipe=recipe):
                (project / "asm.toml").write_text(native + inactive + recipe)
                result = self.cli("build", cwd=project, code=1)
                self.assertIn("invalid or missing asm.toml", result.stderr)
                self.assertEqual((project / "build/app.exe").read_bytes(), previous)
                self.assertFalse(list((project / "build").glob(".asm-stage-*")))

    def test_v2_lock_preserves_an_inactive_target_without_its_cache(self):
        project = self.project()
        (project / "asm.toml").write_text(
            f'[package]\nname="hello"\nversion="0.1.0"\n'
            f'[target.{TARGET}]\nsource="src/main.s"\n'
            f'[target.{OTHER_TARGET}]\nsource="src/main.s"\n')
        self.payload(self.source_fixture())
        self.add(project)
        lock = project / "asm.lock"
        self.assertTrue(lock.read_bytes().startswith(b"# asm-lock-v2\n"))
        foreign = self.metadata(b"inactive cache is deliberately absent", target=OTHER_TARGET, version="0.2.0")
        lock.write_bytes(lock.read_bytes() + foreign.encode())
        self.consumer(project)
        self.cli("run", "--locked", cwd=project)
        self.assertEqual(json.loads(self.cli("lock", "--json", cwd=project).stdout)["dependencies"], 1)
        self.assertFalse((project / f".asm/packages/{PACKAGE}/0.2.0/{OTHER_TARGET}").exists())
        self.cli("remove", PACKAGE, cwd=project)
        self.assertIn(foreign.encode(), lock.read_bytes())
        self.assertEqual(json.loads(self.cli("lock", "--json", cwd=project).stdout)["dependencies"], 0)

    def test_fixed_tools_work_with_an_empty_path(self):
        project = self.project()
        env = dict(self.environment, PATH="")
        self.assertEqual(self.cli("run", cwd=project, env=env).stdout, "Hello from asm!\n")

    def test_closed_stdout_reports_output_failure_in_plain_and_json_modes(self):
        for options in ([], ["--json"]):
            with self.subTest(options=options):
                read_fd, write_fd = os.pipe()
                os.close(read_fd)
                try:
                    result = subprocess.run([str(ASM), "version", *options], cwd=self.work,
                                            env=self.environment, stdout=write_fd, stderr=subprocess.PIPE,
                                            text=True, timeout=10)
                finally:
                    os.close(write_fd)
                COMMANDS.append({"test": self.id(), "argv": result.args, "exit_code": result.returncode,
                                 "stdout": "closed pipe", "stderr": result.stderr})
                self.assertEqual(result.returncode, 1, result.stderr)
                if options:
                    self.assertFalse(json.loads(result.stderr)["ok"])
                else:
                    self.assertIn("cannot write command output", result.stderr)

    def test_continuously_available_capture_checks_deadline_before_the_byte_limit(self):
        source = self.work / "capture-deadline.s"
        obj = source.with_suffix(".obj")
        binary = source.with_suffix(".exe")
        source.write_text(capture_deadline_source(ROOT, ARM64), encoding="utf-8")
        triple = "aarch64-pc-windows-msvc" if ARM64 else "x86_64-pc-windows-msvc"
        commands = [[str(TOOLCHAIN_BIN / "clang.exe"), "--target=" + triple, "-c", str(source), "-o", str(obj)],
                    [str(TOOLCHAIN_BIN / "lld-link.exe"), "/machine:" + ("arm64" if ARM64 else "x64"),
                     "/entry:_start", "/subsystem:console", "/nodefaultlib", "/nxcompat", "/dynamicbase",
                     "/out:" + str(binary), str(obj), "kernel32.lib"]]
        for argv in commands:
            result = subprocess.run(argv, capture_output=True, text=True, timeout=30)
            COMMANDS.append({"test": self.id(), "argv": argv, "exit_code": result.returncode,
                             "stdout": result.stdout, "stderr": result.stderr})
            self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        result = subprocess.run([str(binary)], capture_output=True, timeout=5)
        self.assertEqual((result.returncode, result.stderr, len(result.stdout)), (0, b"", 16))
        clocks, reads = struct.unpack("<QQ", result.stdout)
        self.assertGreater(clocks, 1)
        self.assertGreater(reads, 0)
        self.assertLess(reads, 256, "A full capture buffer hid the missing deadline check")
        TEST_ARTIFACTS.append({"role": "capture-deadline-private-shim", "target": TARGET,
                               "sha256": sha256(binary.read_bytes()), "source_sha256": sha256(source.read_bytes()),
                               "clock_calls": clocks, "read_calls": reads,
                               "scope": "Exact native capture loop with simulated pipe and clock APIs"})

    def test_unicode_spaces_and_shell_metacharacters_are_literal(self):
        project = self.project("hello world & echo INJECTION")
        self.assertEqual(self.cli("run", "--", "quoted argument", "& echo INJECTION", cwd=project).stdout,
                         "Hello from asm!\n")
        self.assertFalse((self.work / "INJECTION").exists())
        unicode_project = self.project("hello-é-日本")
        self.assertEqual(self.cli("run", cwd=unicode_project).stdout, "Hello from asm!\n")

    def test_child_exit_and_failed_build_preserve_previous_output(self):
        project = self.project()
        (project / "src/main.s").write_text(exit_source(37))
        self.cli("run", cwd=project, code=37)
        # Child failures can be quiet. The CLI owns the test failure diagnostic.
        (project / "tests/main.s").write_text(exit_source(9))
        self.cli("test", cwd=project, code=9)
        previous = (project / "build/app.exe").read_bytes()
        (project / "src/main.s").write_text("this is not assembly\n")
        self.cli("build", cwd=project, code=1)
        self.assertEqual((project / "build/app.exe").read_bytes(), previous)
        self.assertEqual(list((project / "build").glob(".asm-*")), [])

    def test_deliberate_application_runs_beyond_two_minutes(self):
        project = self.project("long-running-application")
        body = ("sub sp, sp, #32\nmov w0, #125\nmov w1, #1000\nmul w0, w0, w1\n"
                "bl Sleep\nmov w0, #37\nbl ExitProcess\n.extern Sleep" if ARM64 else
                "sub rsp, 40\nmov ecx, 125000\ncall Sleep\nmov ecx, 37\n"
                "call ExitProcess\n.extern Sleep")
        (project / "src/main.s").write_text(program(body), encoding="utf-8")
        started = time.monotonic()
        result = self.cli("run", cwd=project, code=37, timeout=160)
        self.assertGreaterEqual(time.monotonic() - started, 120)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")

    def test_existing_project_and_partial_init_preserve_files(self):
        project = self.project()
        manifest = (project / "asm.toml").read_bytes()
        for command in ("new", "init"):
            self.cli(command, project, code=1)
            self.assertEqual((project / "asm.toml").read_bytes(), manifest)
        partial = self.work / "partial"
        (partial / "src").mkdir(parents=True)
        (partial / "src/main.s").write_bytes(b"precious source")
        self.cli("init", partial, code=1)
        self.assertFalse((partial / "asm.toml").exists())
        self.assertEqual((partial / "src/main.s").read_bytes(), b"precious source")

    def test_clean_preserves_an_empty_directory_at_the_application_path(self):
        project = self.project()
        obstruction = project / "build/app.exe"
        obstruction.mkdir(parents=True)
        self.cli("clean", cwd=project, code=1)
        self.assertTrue(obstruction.is_dir())
        self.assertEqual(list(obstruction.iterdir()), [])

    def test_arguments_unsupported_target_and_missing_manifest_fail(self):
        for args in (("nosuchcommand",), ("new",), ("new", ""), ("build", "--mystery"),
                     ("build", "--target", "riscv64-windows")):
            with self.subTest(args=args):
                self.cli(*args, code=2)
        for command in ("build", "run", "test", "clean"):
            self.cli(command, code=1)
        self.cli("build", "--target", OTHER_TARGET, code=1)
        project = self.project()
        manifest = project / "asm.toml"
        manifest.write_text(manifest.read_text().replace(TARGET, OTHER_TARGET))
        self.cli("build", cwd=project, code=2)
        self.assertFalse((project / "build/app.exe").exists())

    def test_manifest_parser_rejects_duplicates_ambiguity_and_bounds(self):
        project = self.project()
        manifest = project / "asm.toml"
        original = manifest.read_text()
        mutations = [original + 'source = "src/other.s"\n', original + '[build]\n',
                     original + 'unknown = "value"\n', original + "\0hidden",
                     original.replace('source = "src/main.s"', 'source = "../outside.s"'),
                     original.replace('source = "src/main.s"', 'source = "src\\main.s"'),
                     original.replace('source = "src/main.s"', 'source = "src/main.s:stream"'),
                     original.replace('version = "0.1.0"', 'version = "01.0.0"'),
                     "x" * 8192]
        for data in mutations:
            with self.subTest(data=data[:100]):
                manifest.write_bytes(data.encode())
                self.cli("build", cwd=project, code=1)
                self.assertFalse((project / "build/app.exe").exists())

    def test_reparse_project_paths_fail_without_outside_changes(self):
        outside = self.work / "outside"
        outside.mkdir()
        sentinel = outside / "app.exe"
        sentinel.write_bytes(b"keep")
        project = self.project()
        self.junction(project / "build", outside)
        self.cli("build", cwd=project, code=1)
        self.cli("clean", cwd=project, code=1)
        self.assertEqual(sentinel.read_bytes(), b"keep")
        partial = self.work / "partial"
        partial.mkdir()
        self.junction(partial / "src", outside)
        self.cli("init", partial, code=1)
        self.assertFalse((partial / "asm.toml").exists())
        self.assertEqual(sorted(path.name for path in outside.iterdir()), ["app.exe"])

    def test_registry_search_info_versions_and_empty_results(self):
        self.payload(b"fixture\n")
        result = json.loads(self.cli("search", "runtime", "--index", self.index, "--json").stdout)
        self.assertEqual(result["results"][0]["package"], PACKAGE)
        self.assertEqual(json.loads(self.cli("info", PACKAGE, "--index", self.index, "--json").stdout)
                         ["results"][0]["sha256"], sha256(b"fixture\n"))
        self.assertEqual(json.loads(self.cli("versions", PACKAGE, "--index", self.index, "--json").stdout)
                         ["versions"], ["0.1.0"])
        self.write_index()
        self.assertEqual(json.loads(self.cli("search", "--index", self.index, "--json").stdout),
                         {"results": []})

    def test_registry_parser_rejects_malformed_records_before_output(self):
        row = self.metadata(b"fixture")
        malformed = [b"", b"# asm-registry-v2\n", HEADER.encode() + row.rstrip("\n").encode(),
                     (HEADER + row + row).encode(), (HEADER + row).replace("fixture", "fixture\0").encode(),
                     (HEADER + row).replace("source\t", "script\t").encode(),
                     (HEADER + row).replace(TARGET, "riscv64-windows").encode(),
                     HEADER.encode() + b"x" * 1048576]
        for data in malformed:
            with self.subTest(bytes=len(data), prefix=data[:40]):
                self.index.write_bytes(data)
                result = self.cli("search", "--index", self.index, "--json", code=1)
                self.assertEqual(result.stdout, "")
                self.assertFalse(json.loads(result.stderr)["ok"])

    def test_fetch_bytes_corruption_existing_destination_and_no_execution(self):
        data = self.executable_fixture()
        self.payload(data, kind="executable")
        output = self.work / "download.exe"
        result = json.loads(self.cli("fetch", f"{PACKAGE}@0.1.0", "--kind", "executable",
                                    "--index", self.index, "--artifact", self.artifact,
                                    "--output", output, "--json").stdout)
        self.assertTrue(result["verified"])
        self.assertEqual(output.read_bytes(), data)
        self.cli("fetch", PACKAGE, "--kind", "executable", "--index", self.index,
                 "--artifact", self.artifact, "--output", output, code=1)
        self.assertEqual(output.read_bytes(), data)
        for changes in ({"digest": "0" * 64}, {"size": 1}):
            with self.subTest(changes=changes):
                self.write_index(self.metadata(data, **changes))
                destination = self.work / "rejected"
                self.cli("fetch", PACKAGE, "--index", self.index, "--artifact", self.artifact,
                         "--output", destination, code=1)
                self.assertFalse(destination.exists())

    def test_network_failure_preserves_existing_files(self):
        self.payload(b"never downloaded")
        # Reserve a loopback TCP port without listening. The proxy fails locally.
        with socket.socket() as endpoint:
            endpoint.bind(("127.0.0.1", 0))
            proxy = f"http://127.0.0.1:{endpoint.getsockname()[1]}"
            env = dict(self.environment, HTTPS_PROXY=proxy, https_proxy=proxy, ALL_PROXY=proxy,
                       all_proxy=proxy, NO_PROXY="", no_proxy="")
            destination = self.work / "download"
            self.cli("fetch", PACKAGE, "--index", self.index, "--output", destination, env=env, code=1)
        self.assertFalse(destination.exists())
        self.assertEqual(self.artifact.read_bytes(), b"never downloaded")

    def test_dependency_add_lock_build_update_remove_and_sync(self):
        project = self.project()
        first = self.source_fixture()
        self.payload(first)
        self.add(project)
        lock = (project / "asm.lock").read_bytes()
        self.assertIn(sha256(first).encode(), lock)
        self.consumer(project)
        self.cli("run", "--locked", cwd=project)
        self.assertEqual(json.loads(self.cli("lock", "--json", cwd=project).stdout)["dependencies"], 1)
        clone = self.project("clone")
        (clone / "asm.lock").write_bytes(lock)
        self.consumer(clone)
        self.cli("build", "--locked", cwd=clone, code=1)
        self.cli("sync", "--artifact", self.artifact, cwd=clone)
        self.cli("run", "--locked", cwd=clone)
        second = self.source_fixture(version="0.2.0")
        self.payload(second, version="0.2.0")
        self.cli("update", f"{PACKAGE}@0.2.0", "--index", self.index,
                 "--artifact", self.artifact, cwd=project)
        self.consumer(project, "0.2.0")
        self.cli("run", "--locked", cwd=project)
        self.cli("remove", PACKAGE, cwd=project)
        self.assertEqual(json.loads(self.cli("lock", "--json", cwd=project).stdout)["dependencies"], 0)

    def test_dependency_cache_edits_and_corrupt_update_preserve_lock_and_output(self):
        project = self.project()
        self.payload(self.source_fixture())
        self.add(project)
        self.consumer(project)
        self.cli("build", cwd=project)
        previous = (project / "build/app.exe").read_bytes()
        lock = (project / "asm.lock").read_bytes()
        source = project / f".asm/packages/{PACKAGE}/0.1.0/{TARGET}/src/min.s"
        source.write_bytes(source.read_bytes() + b"\n# user edit\n")
        edited = source.read_bytes()
        self.cli("build", cwd=project, code=1)
        self.cli("sync", "--artifact", self.artifact, cwd=project, code=1)
        self.assertEqual(source.read_bytes(), edited)
        self.payload(self.source_fixture(version="0.2.0"), version="0.2.0", digest="0" * 64)
        self.cli("update", f"{PACKAGE}@0.2.0", "--index", self.index,
                 "--artifact", self.artifact, cwd=project, code=1)
        self.assertEqual((project / "asm.lock").read_bytes(), lock)
        self.assertEqual((project / "build/app.exe").read_bytes(), previous)

    def test_archive_hostile_members_are_rejected_before_cache_or_lock_commit(self):
        project = self.project()
        absolute_temp = tempfile.TemporaryDirectory(prefix="asm-archive-absolute-")
        self.addCleanup(absolute_temp.cleanup)
        absolute_root = Path(absolute_temp.name).resolve()
        self.assertEqual(absolute_root.drive.lower(), project.drive.lower())
        absolute_cases = absolute_archive_cases(absolute_root)
        sentinels = {path: b"owned absolute-path sentinel\n" for _, path in absolute_cases}
        for path, data in sentinels.items():
            path.write_bytes(data)
        cases = [[(path, tarfile.REGTYPE, b"must not appear")] for path in
                 ("../outside", "src\\escape.s", "src/file:stream",
                  "src/trailing.", "src/trailing ", "CON", "NUL.txt", "src/../outside")]
        cases += [[(name, tarfile.REGTYPE, b"must not replace the sentinel")] for name, _ in absolute_cases]
        cases += [[("same", tarfile.REGTYPE, b"one"), ("same", tarfile.REGTYPE, b"two")],
                  [("src", tarfile.SYMTYPE, b"")], [("src", tarfile.LNKTYPE, b"")],
                  [("src", tarfile.FIFOTYPE, b"")]]
        for entries in cases:
            with self.subTest(entries=entries):
                self.payload(self.source_fixture(entries=entries))
                self.add(project, code=1)
                self.assertFalse((project / "asm.lock").exists())
                self.assertFalse((project / f".asm/packages/{PACKAGE}/0.1.0/{TARGET}").exists())
                self.assertFalse((self.work / "outside").exists())
                for path, expected in sentinels.items():
                    self.assertEqual(path.read_bytes(), expected)
                self.assertEqual(set(absolute_root.iterdir()), set(sentinels))

    def test_archive_corrupt_gzip_and_tar_headers_fail(self):
        project = self.project()
        valid = self.source_fixture()
        bad_crc = valid[:-8] + bytes([valid[-8] ^ 1]) + valid[-7:]
        raw = bytearray(gzip.decompress(valid))
        raw[148] ^= 1
        for data in (b"not gzip", valid[:-1], bad_crc, gzip.compress(bytes(raw), mtime=0)):
            with self.subTest(digest=sha256(data)):
                self.payload(data)
                self.add(project, code=1)
                self.assertFalse((project / "asm.lock").exists())

    def test_install_inventory_upgrade_uninstall_and_no_implicit_execution(self):
        first = self.executable_fixture("first", 73)
        second = self.executable_fixture("second", 74)
        self.assertNotEqual(first, second)
        self.payload(first, kind="executable")
        self.assertEqual(self.installed(), [])
        result = json.loads(self.cli("install", f"{PACKAGE}@0.1.0", "--index", self.index,
                                    "--artifact", self.artifact, "--json").stdout)
        destination = Path(result["artifact"])
        if not destination.is_absolute():
            destination = self.work / destination
        self.assertEqual(destination.read_bytes(), first)
        self.assertEqual(self.installed()[0]["version"], "0.1.0")
        self.payload(second, kind="executable", version="0.2.0")
        self.assertEqual(self.cli("upgrade", PACKAGE, "--index", self.index,
                                 "--artifact", self.artifact).stdout, "")
        self.assertEqual(destination.read_bytes(), second)
        self.assertEqual(self.installed()[0]["version"], "0.2.0")
        # Deliberate execution is separate from package management.
        ran = subprocess.run([str(destination)], cwd=self.work, capture_output=True, timeout=10)
        self.assertEqual((ran.returncode, ran.stdout, ran.stderr), (74, b"", b""))
        self.assertTrue((self.work / "PACKAGE_EXECUTED").is_file())
        (self.work / "PACKAGE_EXECUTED").unlink()
        self.assertEqual(self.cli("uninstall", PACKAGE).stdout, "")
        self.assertFalse(destination.exists())
        self.assertEqual(self.installed(), [])

    def test_install_refuses_corrupt_or_wrong_machine_pe_and_preserves_existing_destination(self):
        valid = ASM.read_bytes()
        offset = struct.unpack_from("<I", valid, 60)[0]
        wrong = bytearray(valid)
        struct.pack_into("<H", wrong, offset + 4, 0x8664 if ARM64 else 0xAA64)
        for data in (b"#!/bin/sh\necho must-not-run\n", b"MZ", bytes(wrong), valid[:offset + 24]):
            with self.subTest(digest=sha256(data)):
                self.payload(data, kind="executable")
                output = self.work / "rejected.exe"
                self.cli("install", PACKAGE, "--index", self.index, "--artifact", self.artifact,
                         "--output", output, code=1)
                self.assertFalse(output.exists())
                self.assertEqual(self.installed(), [])
        output = self.work / "existing.exe"
        output.write_bytes(b"user data")
        self.payload(valid, kind="executable")
        self.cli("install", PACKAGE, "--index", self.index, "--artifact", self.artifact,
                 "--output", output, code=1)
        self.assertEqual(output.read_bytes(), b"user data")

    def test_install_rejects_overlapping_pe_sections_and_headers_without_file_effects(self):
        original = ASM.read_bytes()
        pe = struct.unpack_from("<I", original, 60)[0]
        optional = pe + 24
        sections = optional + struct.unpack_from("<H", original, pe + 20)[0]
        count = struct.unpack_from("<H", original, pe + 6)[0]
        file_backed = [sections + number * 40 for number in range(count)
                       if struct.unpack_from("<I", original, sections + number * 40 + 16)[0]]
        self.assertGreaterEqual(len(file_backed), 2)
        first, second = file_backed[:2]
        first_rva = struct.unpack_from("<I", original, first + 12)[0]
        first_raw = struct.unpack_from("<I", original, first + 20)[0]
        entry = struct.unpack_from("<I", original, optional + 16)[0]
        mutations = [("virtual-section-overlap", [(second + 12, first_rva)]),
                     ("raw-section-overlap", [(second + 20, first_raw)]),
                     ("virtual-header-overlap", [(first + 12, 0), (optional + 16, entry - first_rva)]),
                     ("raw-header-overlap", [(first + 20, 0)])]
        for name, changes in mutations:
            with self.subTest(name=name):
                data = bytearray(original)
                for offset, value in changes:
                    struct.pack_into("<I", data, offset, value)
                self.payload(bytes(data), kind="executable")
                output = self.work / "rejected.exe"
                self.cli("install", PACKAGE, "--index", self.index, "--artifact", self.artifact,
                         "--output", output, code=1)
                self.assertFalse(output.exists())
                self.assertFalse(self.inventory.exists())
                self.assertEqual(self.installed(), [])
                TEST_ARTIFACTS.append({"role": "rejected-pe-" + name, "target": TARGET,
                                       "sha256": sha256(data), "bytes": len(data)})

    def test_drive_absolute_install_output_is_literal_and_ambiguous_roots_are_rejected(self):
        self.payload(ASM.read_bytes(), kind="executable")
        output = self.work / "literal path & name.exe"
        self.cli("install", PACKAGE, "--index", self.index, "--artifact", self.artifact,
                 "--output", output.as_posix())
        self.assertEqual(output.read_bytes(), ASM.read_bytes())
        self.cli("uninstall", PACKAGE)
        self.assertFalse(output.exists())
        unc_target = self.work / "unc-output.exe"
        unc = "//localhost/" + self.work.drive.rstrip(":") + "$" + unc_target.as_posix()[2:]
        for destination in (self.work.drive + "drive-relative.exe", unc):
            with self.subTest(destination=destination):
                self.cli("install", PACKAGE, "--index", self.index, "--artifact", self.artifact,
                         "--output", destination, code=1)
                self.assertFalse((self.work / "drive-relative.exe").exists())
                self.assertFalse(unc_target.exists())
                self.assertEqual(self.installed(), [])

    def test_management_preserves_modified_and_hardlinked_destinations(self):
        data = self.executable_fixture()
        self.payload(data, kind="executable")
        output = self.work / "installed.exe"
        self.cli("install", PACKAGE, "--index", self.index, "--artifact", self.artifact,
                 "--output", output)
        inventory = self.inventory.read_bytes()
        output.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
        modified = output.read_bytes()
        self.cli("upgrade", PACKAGE, "--index", self.index, "--artifact", self.artifact, code=1)
        self.cli("uninstall", PACKAGE, code=1)
        self.assertEqual(output.read_bytes(), modified)
        self.assertEqual(self.inventory.read_bytes(), inventory)
        output.write_bytes(data)
        link = self.work / "hardlink.exe"
        os.link(output, link)
        self.cli("uninstall", PACKAGE, code=1)
        self.assertEqual(output.read_bytes(), data)
        self.assertEqual(link.read_bytes(), data)
        self.assertEqual(self.inventory.read_bytes(), inventory)

    def test_reparse_install_parent_and_state_are_rejected(self):
        self.payload(ASM.read_bytes(), kind="executable")
        outside = self.work / "outside"
        outside.mkdir()
        link = self.work / "linked"
        self.junction(link, outside)
        self.cli("install", PACKAGE, "--index", self.index, "--artifact", self.artifact,
                 "--output", link / "program.exe", code=1)
        self.assertEqual(list(outside.iterdir()), [])
        # Use fresh state; the failed destination check may create private state.
        self.home = self.work / "state home"
        self.home.mkdir()
        own_directory(self.home, self.work)
        self.environment.update(HOME=str(self.home), USERPROFILE=str(self.home))
        state_parent = self.home / ".local/state"
        state_parent.mkdir(parents=True, exist_ok=True)
        own_home_directories(self.home, self.work)
        self.junction(state_parent / "asm", outside)
        self.cli("installed", code=1)
        self.assertEqual(list(outside.iterdir()), [])

    def test_writable_dacl_state_and_destination_parent_are_rejected(self):
        # This modifies only disposable test directories. The SID is Everyone.
        tool = str(Path(os.environ["SystemRoot"]) / "System32/icacls.exe")
        state = self.inventory.parent
        state.mkdir(parents=True)
        own_home_directories(self.home, self.work)
        own_directory(state, self.work)

        def acl(path, *args):
            result = subprocess.run([tool, str(path), *args], capture_output=True, text=True, timeout=10)
            COMMANDS.append({"test": self.id(), "argv": result.args, "exit_code": result.returncode,
                             "stdout": result.stdout, "stderr": result.stderr})
            self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))

        acl(state, "/grant", "*S-1-1-0:(OI)(CI)(M)")
        self.cli("installed", code=1)
        self.assertFalse(self.inventory.exists())
        acl(state, "/remove:g", "*S-1-1-0")
        self.payload(ASM.read_bytes(), kind="executable")
        output_dir = self.work / "programs"
        output_dir.mkdir()
        own_directory(output_dir, self.work)
        output = output_dir / "installed.exe"
        self.cli("install", PACKAGE, "--index", self.index, "--artifact", self.artifact,
                 "--output", output)
        inventory = self.inventory.read_bytes()
        acl(output_dir, "/grant", "*S-1-1-0:(OI)(CI)(M)")
        self.cli("upgrade", PACKAGE, "--index", self.index, "--artifact", self.artifact, code=1)
        self.cli("uninstall", PACKAGE, code=1)
        self.assertEqual(output.read_bytes(), ASM.read_bytes())
        self.assertEqual(self.inventory.read_bytes(), inventory)

    def test_windows_path_aliases_cannot_overwrite_reserved_or_other_files(self):
        self.payload(ASM.read_bytes(), kind="executable")
        reserved = self.home / ".local/bin"
        reserved.mkdir(parents=True)
        own_home_directories(self.home, self.work)
        devices = tuple(prefix + digit + suffix for prefix in ("COM", "LPT")
                        for digit in "¹²³" for suffix in ("", ".exe"))
        inventory_before = self.inventory.read_bytes() if self.inventory.exists() else None
        for basename in ("asm.exe", "AsM.ExE", "asm.exe.", "asm.exe ", "CON", "NUL.exe", "hello.exe:stream") + devices:
            with self.subTest(basename=basename):
                self.cli("install", PACKAGE, "--index", self.index, "--artifact", self.artifact,
                         "--output", reserved / basename, code=1)
                self.assertEqual(list(reserved.iterdir()), [])
                self.assertEqual(self.installed(), [])
                inventory_after = self.inventory.read_bytes() if self.inventory.exists() else None
                self.assertEqual(inventory_after, inventory_before)

    def test_inventory_parser_rejects_duplicate_changed_origin_and_oversized_records(self):
        self.payload(ASM.read_bytes(), kind="executable")
        output = self.work / "installed.exe"
        self.cli("install", PACKAGE, "--index", self.index, "--artifact", self.artifact,
                 "--output", output)
        original = self.inventory.read_bytes()
        row = original.split(b"\n", 1)[1]
        malformed = [b"", b"# asm-installed-v2\n", original[:-1], original + row,
                     original.replace(b"\tlocal\n", b"\tlocal\textra\n"),
                     original + b"x" * 1048576]
        for data in malformed:
            with self.subTest(bytes=len(data)):
                self.inventory.write_bytes(data)
                result = self.cli("installed", "--json", code=1)
                self.assertEqual(result.stdout, "")
                self.assertFalse(json.loads(result.stderr)["ok"])
                self.cli("uninstall", PACKAGE, code=1)
                self.assertEqual(output.read_bytes(), ASM.read_bytes())
                self.assertEqual(self.inventory.read_bytes(), data)
        self.inventory.write_bytes(original.replace(b"\tlocal\n", b"\thttps://example.test/index.tsv\n"))
        changed = self.inventory.read_bytes()
        self.cli("upgrade", PACKAGE, "--index", self.index, "--artifact", self.artifact, code=1)
        self.assertEqual(self.inventory.read_bytes(), changed)
        self.assertEqual(output.read_bytes(), ASM.read_bytes())

    def test_self_update_invalid_install_and_network_failure_preserve_executable(self):
        installed = self.home / ".local/bin/asm.exe"
        installed.parent.mkdir(parents=True)
        own_home_directories(self.home, self.work)
        installed.write_bytes(ASM.read_bytes())
        self.cli("self", "update", code=1)  # An unmanaged checkout path cannot replace itself.
        with socket.socket() as endpoint:
            endpoint.bind(("127.0.0.1", 0))
            proxy = f"http://127.0.0.1:{endpoint.getsockname()[1]}"
            env = dict(self.environment, HTTPS_PROXY=proxy, https_proxy=proxy,
                       ALL_PROXY=proxy, all_proxy=proxy, NO_PROXY="", no_proxy="")
            self.cli("self", "update", binary=installed, env=env, code=1)
        self.assertEqual(installed.read_bytes(), ASM.read_bytes())
        self.assertEqual(list(installed.parent.glob(".asm-*")), [])

    def publication_args(self, artifact, kind, output, **overrides):
        fields = {"name": PACKAGE, "version": "0.1.0", "summary": "A runtime fixture",
                  "license": "MIT", "repository": "https://github.com/fixture/hello",
                  "commit": "a" * 40, "source-path": ".", "output": str(output)}
        fields.update(overrides)
        args = ["publish"]
        for name, value in fields.items():
            args += ["--" + name, str(value)]
        args += ["--artifact", TARGET, kind, artifact,
                 f"https://github.com/fixture/hello/releases/download/v0.1.0/{Path(artifact).name}", "--json"]
        return args

    def test_publish_prepares_source_and_executable_records_with_exact_digests(self):
        source = self.work / "hello.tar.gz"
        entries = [("asm.toml", tarfile.REGTYPE,
                    f'[package]\nname = "hello"\nversion = "0.1.0"\n[build]\nsource = "src/main.s"\ntarget = "{TARGET}"\n'.encode()),
                   ("LICENSE", tarfile.REGTYPE, b"MIT test fixture.\n"),
                   ("README.md", tarfile.REGTYPE, b"Runtime publication fixture.\n"),
                   ("src/main.s", tarfile.REGTYPE, exit_source(0).encode())]
        source.write_bytes(archive_bytes(entries))
        executable = self.work / "hello.exe"
        executable.write_bytes(ASM.read_bytes())
        for artifact, kind in ((source, "source"), (executable, "executable")):
            with self.subTest(kind=kind):
                output = self.work / (kind + ".json")
                result = json.loads(self.cli(*self.publication_args(artifact, kind, output)).stdout)
                self.assertTrue(result["prepared"])
                self.assertFalse(result["uploaded"])
                record = json.loads(output.read_bytes())
                self.assertEqual(record["source"]["commit"], "a" * 40)
                self.assertEqual(record["artifacts"][0]["target"], TARGET)
                self.assertEqual(record["artifacts"][0]["sha256"], sha256(artifact.read_bytes()))
                self.assertEqual(record["artifacts"][0]["bytes"], artifact.stat().st_size)
        preserved = self.work / "preserved.json"
        preserved.write_bytes(b"user record")
        self.cli(*self.publication_args(executable, "executable", preserved), code=1)
        self.assertEqual(preserved.read_bytes(), b"user record")

    def test_publish_rejects_wrong_target_missing_source_or_bad_abi_check(self):
        output = self.work / "rejected.json"
        base = (f'[package]\nname = "hello"\nversion = "0.1.0"\n[build]\n'
                f'source = "src/main.s"\ntarget = "{TARGET}"\n')
        manifests = [base.replace(TARGET, OTHER_TARGET), base.replace("src/main.s", "missing.s"),
                     base + 'link = "c"\ncheck = "missing-check.c"\n',
                     base + 'link = "c"\ncheck = "../abi-check.c"\n',
                     base + 'link = "c"\nlibraries = "kernel32  ucrt"\n']
        for manifest in manifests:
            with self.subTest(manifest=manifest):
                artifact = self.work / "invalid.tar.gz"
                artifact.write_bytes(archive_bytes([
                    ("asm.toml", tarfile.REGTYPE, manifest.encode()),
                    ("LICENSE", tarfile.REGTYPE, b"MIT fixture\n"),
                    ("README.md", tarfile.REGTYPE, b"Runtime fixture\n"),
                    ("src/main.s", tarfile.REGTYPE, exit_source(0).encode())]))
                self.cli(*self.publication_args(artifact, "source", output), code=1)
                self.assertFalse(output.exists())
        executable = self.work / "invalid.exe"
        executable.write_bytes(b"MZ invalid executable")
        self.cli(*self.publication_args(executable, "executable", output), code=1)
        self.assertFalse(output.exists())
        # Use the established Linux container fixture as a positive dispatch control.
        header = bytearray(64)
        header[:7] = b"\x7fELF\x02\x01\x01"
        struct.pack_into("<HHI", header, 16, 2, 62, 1)
        struct.pack_into("<Q", header, 32, 64)
        struct.pack_into("<HHH", header, 52, 64, 56, 1)
        linux = bytes(header) + struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 120, 120, 4096)
        executable.write_bytes(linux)
        control = self.work / "linux-container.json"
        arguments = self.publication_args(executable, "executable", control)
        target_index = arguments.index("--artifact") + 1
        arguments[target_index] = "x86_64-linux"
        self.cli(*arguments)
        self.assertEqual(json.loads(control.read_bytes())["artifacts"][0]["target"], "x86_64-linux")
        for target in ("x86_64-windows", "aarch64-windows", "x86_64-macos", "aarch64-macos"):
            with self.subTest(wrong_os=target):
                arguments = self.publication_args(executable, "executable", output)
                arguments[target_index] = target
                self.cli(*arguments, code=1)
                self.assertFalse(output.exists())
                self.assertEqual(executable.read_bytes(), linux)

    def native_main(self):
        if ARM64:
            return ('.text\n.global main\nmain:\nstp x29, x30, [sp, #-16]!\nmov x29, sp\n'
                    'bl GetCurrentProcessId\nadrp x0, message\nadd x0, x0, :lo12:message\nbl puts\n'
                    'mov w0, #0\nldp x29, x30, [sp], #16\nret\n'
                    '.section .rdata,"dr"\nmessage: .asciz "native linked"\n')
        return ('.intel_syntax noprefix\n.text\n.global main\nmain:\nsub rsp, 40\n'
                'call GetCurrentProcessId\nlea rcx, [rip + message]\ncall puts\nxor eax, eax\n'
                'add rsp, 40\nret\n.section .rdata,"dr"\nmessage: .asciz "native linked"\n')

    def native_project(self):
        project = self.project()
        manifest = project / "asm.toml"
        base = manifest.read_text()
        manifest.write_text(base + 'link = "c"\nlibraries = "kernel32"\ncheck = "abi-check.c"\n')
        (project / "abi-check.c").write_text('_Static_assert(sizeof(void *) == 8, "64-bit pointers");\n'
                                            '_Static_assert(sizeof(long) == 4, "Windows LLP64");\n')
        (project / "src/main.s").write_text(self.native_main())
        (project / "tests/main.s").write_text(self.native_main())
        return project, base

    def test_c_abi_project_links_kernel32_and_ucrt_with_hardened_pe_output(self):
        project, base = self.native_project()
        self.assertEqual(self.cli("run", cwd=project).stdout, "native linked\n")
        data = (project / "build/app.exe").read_bytes()
        offset = struct.unpack_from("<I", data, 60)[0]
        self.assertEqual(data[offset:offset + 4], b"PE\0\0")
        characteristics = struct.unpack_from("<H", data, offset + 24 + 70)[0]
        self.assertTrue(characteristics & 0x100, "The executable lacks NX_COMPAT")
        self.assertTrue(characteristics & 0x40, "The executable lacks DYNAMIC_BASE")
        self.assertIn("native linked\n", self.cli("test", cwd=project).stdout)
        self.assertFalse((project / "checker-executed").exists())

        include = self.work / "private header files"
        library = self.work / "private library files"
        wrong_library = self.work / "wrong library files"
        for directory in (include, library, wrong_library):
            directory.mkdir()
        header = include / "asm_private_abi.h"
        header.write_text('#define ASM_PRIVATE_VALUE 37\n'
                          'struct asm_private_layout { unsigned int value; unsigned char tag; };\n'
                          'int asm_private_value(unsigned int value);\n', encoding="utf-8")
        check = project / "abi-check.c"
        check.write_text('#include <asm_private_abi.h>\n'
                         '_Static_assert(ASM_PRIVATE_VALUE == 37, "private header value");\n'
                         '_Static_assert(sizeof(struct asm_private_layout) == 8, "private layout size");\n'
                         '_Static_assert(__builtin_offsetof(struct asm_private_layout, tag) == 4, "private field offset");\n'
                         'int main(void) { return 97; }\n', encoding="utf-8")
        clang, linker = TOOLCHAIN_BIN / "clang.exe", TOOLCHAIN_BIN / "lld-link.exe"
        triple = "aarch64-pc-windows-msvc" if ARM64 else "x86_64-pc-windows-msvc"
        machine = "arm64" if ARM64 else "x64"
        for directory, body in ((library, 'int asm_private_value(unsigned int value) { return value + ASM_PRIVATE_VALUE; }\n'),
                                (wrong_library, 'int asm_wrong_value(void) { return 42; }\n')):
            source, obj = directory / "fixture.c", directory / "fixture.obj"
            archive = directory / "asmprivatefixture.lib"
            source.write_text('#include <asm_private_abi.h>\n' + body, encoding="utf-8")
            commands = ([clang, "--no-default-config", "--target=" + triple, "-fms-runtime-lib=dll", "-O2", "-ffreestanding",
                         "-fno-builtin", "-fno-stack-protector", "-I", include, "-c", source, "-o", obj],
                        [linker, "/lib", "/machine:" + machine, "/out:" + str(archive), obj])
            for command in commands:
                argv = list(map(str, command))
                result = subprocess.run(argv, cwd=project, env=self.environment, capture_output=True,
                                        text=True, encoding="utf-8", errors="strict", timeout=30)
                COMMANDS.append({"test": self.id(), "argv": argv, "cwd": str(project),
                                 "exit_code": result.returncode, "stdout": result.stdout[:65536],
                                 "stderr": result.stderr[:65536]})
                self.assertEqual(result.returncode, 0, (argv, result.stdout, result.stderr))
            for role, path in (("source", source), ("coff", obj), ("archive", archive)):
                artifact = path.read_bytes()
                TEST_ARTIFACTS.append({"role": "native-c-abi-" + directory.name + "-" + role,
                                       "target": TARGET, "bytes": len(artifact), "sha256": sha256(artifact)})
        # The assembly checks the actual C return value in the target ABI return register.
        assembly = self.native_main().replace('"native linked"', '"private library linked"')
        assembly = (assembly.replace('mov w0, #0\n', 'mov w0, #5\nbl asm_private_value\n'
                                     'cmp w0, #42\ncset w0, ne\n') if ARM64 else
                    assembly.replace('xor eax, eax\n', 'mov ecx, 5\ncall asm_private_value\n'
                                     'cmp eax, 42\nsetne al\nmovzx eax, al\n'))
        for path in (project / "src/main.s", project / "tests/main.s"):
            path.write_text(assembly, encoding="utf-8")
        (project / "asm.toml").write_text(base + 'link = "c"\nlibraries = "kernel32 ucrt asmprivatefixture"\n'
                                         'check = "abi-check.c"\n', encoding="utf-8")
        for role, artifact in (("header", header.read_bytes()), ("check", check.read_bytes()),
                               ("assembly", assembly.encode())):
            TEST_ARTIFACTS.append({"role": "native-c-abi-private-" + role, "target": TARGET,
                                   "bytes": len(artifact), "sha256": sha256(artifact)})
        options = ("--include-dir", include.as_posix(), "--library-dir", library.as_posix())
        self.cli("build", *options, cwd=project)
        self.assertEqual(self.cli("run", *options, cwd=project).stdout, "private library linked\n")
        self.assertIn("private library linked\n", self.cli("test", *options, cwd=project).stdout)
        outputs = {path: path.read_bytes() for path in (project / "build/app.exe", project / "build/test.exe")}
        for path, artifact in outputs.items():
            TEST_ARTIFACTS.append({"role": "native-c-abi-private-" + path.name, "target": TARGET,
                                   "bytes": len(artifact), "sha256": sha256(artifact)})
        failures = (("--library-dir", library.as_posix()), ("--include-dir", include.as_posix()),
                    ("--include-dir", (self.work / "absent header files").as_posix(),
                     "--library-dir", library.as_posix()),
                    ("--include-dir", include.as_posix(),
                     "--library-dir", (self.work / "absent library files").as_posix()),
                    ("--include-dir", include.as_posix(), "--library-dir", wrong_library.as_posix()))
        for command in ("build", "run", "test"):
            for arguments in failures:
                with self.subTest(command=command, arguments=arguments):
                    self.assertEqual(self.cli(command, *arguments, cwd=project, code=1).stdout, "")
                    for path, content in outputs.items():
                        self.assertEqual(path.read_bytes(), content)
                    self.assertEqual(list((project / "build").glob(".asm-*")), [])
        self.assertFalse((project / "checker-executed").exists())

    def test_c_abi_failures_preserve_output_and_compile_checker_without_execution(self):
        project, base = self.native_project()
        self.cli("build", cwd=project)
        output = project / "build/app.exe"
        previous = output.read_bytes()
        check = project / "abi-check.c"
        check.write_text('_Static_assert(0, "must reject");\n')
        self.cli("build", cwd=project, code=1)
        self.assertEqual(output.read_bytes(), previous)
        check.write_text('int main(void) { return 97; }\n')
        self.cli("build", cwd=project)
        self.assertEqual(self.cli("run", cwd=project).stdout, "native linked\n")
        previous = output.read_bytes()
        for fields in ('link = "c"\nlibraries = "asmdoesnotexist"\n',
                       'link = "c"\nlibraries = "kernel32  ucrt"\n',
                       'link = "c"\ncheck = "../abi-check.c"\n'):
            with self.subTest(fields=fields):
                (project / "asm.toml").write_text(base + fields)
                self.cli("build", cwd=project, code=1)
                self.assertEqual(output.read_bytes(), previous)
        (project / "asm.toml").write_text(base + 'link = "c"\nlibraries = "kernel32"\n')
        (project / "src/main.s").write_text("invalid native assembly\n")
        self.cli("build", cwd=project, code=1)
        self.assertEqual(output.read_bytes(), previous)
        self.assertEqual(list((project / "build").glob(".asm-*")), [])


class SelfUpdateRuntimeTests(unittest.TestCase):
    """Use a separate native build with two fixed test-tool paths.

    The fixture enforces provenance argv. It does not validate a real signature.
    Production bytes remain covered by the other runtime tests.
    """

    cli = WindowsRuntimeTests.cli
    metadata = WindowsRuntimeTests.metadata

    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="asm-windows-update-fixtures-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.fixture = Path(cls.temporary.name).resolve()
        cls.next_version = f"{int(VERSION.split('.')[0]) + 1}.10.0"
        cls.triple = "aarch64-pc-windows-msvc" if ARM64 else "x86_64-pc-windows-msvc"
        cls.clang = TOOLCHAIN_BIN / "clang.exe"
        cls.linker = TOOLCHAIN_BIN / "lld-link.exe"
        if not cls.clang.is_file() or not cls.linker.is_file():
            raise RuntimeError("Native update fixtures require clang.exe and lld-link.exe.")
        fixture_obj = cls.fixture / "update-tool.obj"
        cls.build_command([cls.clang, "--target=" + cls.triple, "-Oz", "-ffreestanding", "-fno-builtin",
                           "-fno-stack-protector", "-c", ROOT / "tests/windows/update_tool_fixture.c",
                           "-o", fixture_obj])
        cls.build_command([cls.linker, "/machine:" + ("arm64" if ARM64 else "x64"),
                           "/entry:fixture_entry", "/subsystem:console", "/nodefaultlib", "/nxcompat",
                           "/dynamicbase", "/Brepro", "/out:" + str(cls.fixture / "curl.exe"),
                           fixture_obj, "kernel32.lib", "shell32.lib"])
        tool_bytes = (cls.fixture / "curl.exe").read_bytes()
        TEST_ARTIFACTS.append({"role": "self-update-transport-verifier-test-tool", "target": TARGET,
                               "bytes": len(tool_bytes), "sha256": sha256(tool_bytes),
                               "source_sha256": sha256((ROOT / "tests/windows/update_tool_fixture.c").read_bytes())})
        shutil.copyfile(cls.fixture / "curl.exe", cls.fixture / "gh.exe")
        module_path = ROOT / ("tools/windows_arm64.py" if ARM64 else "tools/windows_x64.py")
        spec = importlib.util.spec_from_file_location("windows_update_source", module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        source = module.prepare(ROOT / ("cli/aarch64/asm.s" if ARM64 else "cli/asm.s"))
        paths = {"C:/Windows/System32/curl.exe": (cls.fixture / "curl.exe").as_posix(),
                 "C:/Program Files/GitHub CLI/gh.exe": (cls.fixture / "gh.exe").as_posix()}
        for original, fixture in paths.items():
            if original not in source:
                raise RuntimeError(f"The fixed update tool path is absent from the prepared source: {original}")
            source = source.replace(original, fixture)
        cls.current = cls.build_cli(source, "current")
        cls.next_bytes = cls.build_cli(source.replace(VERSION, cls.next_version), "next")
        # Fault only the final replacement. The parser, verifier, staging,
        # identity checks, and cleanup execute with their real native code.
        cls.finalization_failure = cls.build_cli(final_replacement_failure(source, ARM64), "finalization-failure")

    @classmethod
    def build_command(cls, argv):
        result = subprocess.run(list(map(str, argv)), cwd=ROOT, capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=120)
        COMMANDS.append({"test": "SelfUpdateRuntimeTests.setUpClass", "argv": list(map(str, argv)),
                         "exit_code": result.returncode, "stdout": result.stdout[:65536],
                         "stderr": result.stderr[:65536]})
        if result.returncode:
            raise RuntimeError((argv, result.stdout, result.stderr))

    @classmethod
    def build_cli(cls, source, name):
        path = cls.fixture / (name + ".s")
        obj = path.with_suffix(".obj")
        binary = path.with_suffix(".exe")
        path.write_text(source, encoding="utf-8")
        cls.build_command([cls.clang, "--target=" + cls.triple, "-c", path, "-o", obj])
        cls.build_command([cls.linker, "/machine:" + ("arm64" if ARM64 else "x64"), "/entry:_start",
                           "/subsystem:console", "/nodefaultlib", "/nxcompat", "/dynamicbase", "/Brepro",
                           "/out:" + str(binary), obj, "kernel32.lib", "ntdll.lib", "advapi32.lib",
                           "bcrypt.lib", "shell32.lib"])
        data = binary.read_bytes()
        TEST_ARTIFACTS.append({"role": "self-update-test-only-" + name, "target": TARGET,
                               "bytes": len(data), "sha256": sha256(data),
                               "source_sha256": sha256(source.encode())})
        return data

    def setUp(self):
        self.case_temp = tempfile.TemporaryDirectory(prefix="asm-windows-update-case-")
        self.addCleanup(self.case_temp.cleanup)
        self.work = Path(self.case_temp.name).resolve()
        self.home = self.work / "home with spaces"
        self.bin_dir = self.home / ".local/bin"
        self.bin_dir.mkdir(parents=True)
        own_home_directories(self.home, self.work)
        self.installed = self.bin_dir / "asm.exe"
        self.installed.write_bytes(self.current)
        self.environment = dict(os.environ, HOME=str(self.home), USERPROFILE=str(self.home),
                                GH_TOKEN="test-token", GITHUB_TOKEN="test-token",
                                GH_HOST="untrusted.invalid", CURL_CA_BUNDLE="untrusted.pem",
                                SSL_CERT_FILE="untrusted.pem")
        for name in ("calls.tsv", "network-failure", "reject-signature", "reject-source", "wrong-repository"):
            (self.fixture / name).unlink(missing_ok=True)
        filename = f"asm-{self.next_version}-{TARGET}.exe"
        (self.fixture / "artifact").write_bytes(self.next_bytes)
        (self.fixture / "bundle").write_bytes(b"test-only signed bundle fixture\n")
        row = self.metadata(self.next_bytes, package="stubbi/asm", version=self.next_version,
                            kind="executable")
        row = row.replace("/payload.tar.gz", "/" + filename)
        (self.fixture / "index.tsv").write_bytes((HEADER + row).encode())
        self.manifest = {"schema": 1, "project": "asm", "version": self.next_version,
                         "tag": "v" + self.next_version, "repository": "https://github.com/stubbi/asm",
                         "source_commit": "a" * 40, "license": "AGPL-3.0-or-later", "template_license": "MIT",
                         "assets": [{"file": filename, "bytes": len(self.next_bytes), "sha256": sha256(self.next_bytes)}],
                         "tool_versions": {"clang": "test fixture"}, "builds": {"asm": {"target": TARGET}}}
        self.save_manifest()

    def save_manifest(self):
        (self.fixture / "release.json").write_text(json.dumps(self.manifest) + "\n", encoding="utf-8")

    def calls(self):
        path = self.fixture / "calls.tsv"
        return path.read_text().splitlines() if path.exists() else []

    def update(self, code=0):
        return self.cli("self", "update", "--json", binary=self.installed, code=code)

    def unchanged(self, original=None):
        self.assertEqual(self.installed.read_bytes(), original or self.current)
        self.assertEqual(list(self.bin_dir.glob(".asm-*")), [])

    def test_update_replaces_exact_bytes_after_three_provenance_bindings(self):
        result = json.loads(self.update().stdout)
        self.assertTrue(result["updated"])
        self.assertTrue(result["integrity_verified"])
        self.assertTrue(result["provenance_verified"])
        self.assertEqual(result["version"], self.next_version)
        self.assertEqual(self.installed.read_bytes(), self.next_bytes)
        assert_complete_provenance(self.calls())
        self.assertIn(f"asm {self.next_version}", self.cli("--version", binary=self.installed).stdout)
        self.assertEqual(list(self.bin_dir.glob(".asm-*")), [])

    def test_preexisting_running_image_displacement_is_rejected(self):
        # A failed ownership precondition must not masquerade as image binding.
        own_path(self.installed, self.work)
        control = json.loads(self.cli("self", "update", VERSION, "--json", binary=self.installed).stdout)
        self.assertFalse(control["updated"])
        self.assertEqual(self.calls(), [])
        report = displaced_running_image(self.installed, VERSION, self.environment, self.work,
                                         own_replacement=lambda path: own_path(path, self.work))
        COMMANDS.append({"test": self.id(), "argv": report.get("argv", []), "cwd": str(self.work),
                         "exit_code": report.get("exit_code"), "stdout": report.get("stdout", ""),
                         "stderr": report.get("stderr", ""), "native_image_fixture": report})
        self.assertEqual(report["fixture"], "complete", report)
        self.assertEqual(report["exit_code"], 1, report)
        self.assertFalse(json.loads(report["stderr"])["ok"])
        self.assertEqual(report["stdout"], "")
        self.assertEqual(self.calls(), [], "The rejected image reached transport or verification.")
        self.assertEqual(list(self.bin_dir.glob(".asm-*")), [])

    def test_update_rejects_signature_source_and_repository_substitution(self):
        for name in ("reject-signature", "reject-source", "wrong-repository"):
            with self.subTest(name=name):
                (self.fixture / name).write_bytes(b"fail")
                self.update(code=1)
                self.unchanged()
                (self.fixture / name).unlink()

    def test_update_rejects_manifest_source_and_artifact_binding_changes(self):
        original = json.dumps(self.manifest)
        changes = ({"source_commit": "b" * 40}, {"version": VERSION},
                   {"repository": "https://github.com/other/asm"},
                   {"assets": [{"file": self.manifest["assets"][0]["file"],
                                "bytes": len(self.next_bytes), "sha256": "0" * 64}]})
        for change in changes:
            with self.subTest(change=change):
                self.manifest = json.loads(original)
                self.manifest.update(change)
                self.save_manifest()
                self.update(code=1)
                self.unchanged()

    def test_update_corrupt_candidate_and_network_failure_preserve_original(self):
        (self.fixture / "artifact").write_bytes(self.next_bytes[:-1] + bytes([self.next_bytes[-1] ^ 1]))
        self.update(code=1)
        self.unchanged()
        (self.fixture / "artifact").write_bytes(self.next_bytes)
        (self.fixture / "network-failure").write_bytes(b"fail")
        self.update(code=1)
        self.unchanged()

    def test_final_replacement_failure_preserves_running_image_after_verification(self):
        self.installed.write_bytes(self.finalization_failure)
        self.update(code=1)
        self.unchanged(self.finalization_failure)
        assert_complete_provenance(self.calls())


if __name__ == "__main__":
    unittest.main()
