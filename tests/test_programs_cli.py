"""Manage installed programs through the public native CLI.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import fcntl
import hashlib
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

from host import IS_ARM64, IS_MACOS, OTHER_TARGET, TARGET, program

ROOT = Path(__file__).resolve().parents[1]
ASM = ROOT / "build/asm"
PACKAGE = "stubbi/hello"


class InstalledProgramTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture_directory = tempfile.TemporaryDirectory(prefix="program-fixtures-", dir=ROOT / "build")
        cls.addClassCleanup(cls.fixture_directory.cleanup)
        fixtures = Path(cls.fixture_directory.name)
        cls.payloads = {}
        for number, version in enumerate(("0.1.0", "0.2.0")):
            project = fixtures / f"program-{number}"
            subprocess.run([str(ASM), "new", str(project)], cwd=fixtures, check=True,
                           capture_output=True, timeout=15)
            if IS_MACOS:
                body = ("stp x29, x30, [sp, #-16]!\n"
                        "adrp x0, marker@PAGE\nadd x0, x0, marker@PAGEOFF\n"
                        "mov x1, #1537\nsub sp, sp, #16\nmov x2, #384\nstr x2, [sp]\n"
                        "bl _open\nadd sp, sp, #16\n"
                        f"mov x0, #{73 + number}\nbl _exit\n"
                        '.data\nmarker: .asciz "PACKAGE_EXECUTED"')
            elif IS_ARM64:
                body = ("mov x0, #-100\nadrp x1, marker\nadd x1, x1, :lo12:marker\n"
                        "mov x2, #577\nmov x3, #384\nmov x8, #56\nsvc #0\n"
                        f"mov x0, #{73 + number}\nmov x8, #93\nsvc #0\n"
                        '.section .rodata\nmarker: .asciz "PACKAGE_EXECUTED"')
            else:
                body = ("lea rdi, [rip + marker]\nmov esi, 577\nmov edx, 384\n"
                        "mov eax, 2\nsyscall\n"
                        f"mov edi, {73 + number}\nmov eax, 60\nsyscall\n"
                        '.section .rodata\nmarker: .asciz "PACKAGE_EXECUTED"')
            (project / "src/main.s").write_text(program(body))
            subprocess.run([str(ASM), "build"], cwd=project, check=True,
                           capture_output=True, timeout=15)
            cls.payloads[version] = (project / "build/app").read_bytes()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="programs-cli-", dir=ROOT / "build")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name).resolve()
        self.home = self.work / "home"
        self.home.mkdir(mode=0o700)
        self.environment = dict(os.environ, HOME=str(self.home))
        self.index = self.work / "index.tsv"
        self.artifacts = {}
        for version, data in self.payloads.items():
            artifact = self.work / f"program-{version}"
            artifact.write_bytes(data)
            self.artifacts[version] = artifact
        self.inventory = self.home / ".local/state/asm/installed.tsv"
        self.destination = self.home / ".local/bin/hello"
        self.write_index(self.row("0.1.0"))

    def row(self, version, *, package=PACKAGE, target=TARGET, digest=None, size=None):
        data = self.payloads["0.1.0" if version == "0.1.0" else "0.2.0"]
        return "\t".join((package, version, target, "executable",
                          digest or hashlib.sha256(data).hexdigest(),
                          f"https://github.com/stubbi/asm/releases/download/v{version}/hello.tar.gz",
                          str(len(data) if size is None else size), "A test program")) + "\n"

    def write_index(self, *rows):
        self.index.write_text("# asm-registry-v1\n" + "".join(rows))

    def cli(self, *args, cwd=None, code=0, binary=ASM):
        working_directory = cwd or self.work
        result = subprocess.run([str(binary), *map(str, args)], cwd=working_directory,
                                env=self.environment, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, code, (result.args, result.stdout, result.stderr))
        self.assertFalse((working_directory / "PACKAGE_EXECUTED").exists(), "Management executed the package")
        self.assertEqual(list(working_directory.glob(".asm-registry-*")), [], "Download stage remains")
        if code == 0:
            self.assertEqual(result.stderr, "")
        else:
            self.assertNotEqual(result.stderr, "")
        return result

    def install(self, *, output=None, package=PACKAGE, version="0.1.0"):
        args = ["install", f"{package}@{version}", "--index", self.index,
                "--artifact", self.artifacts[version], "--json"]
        if output is not None:
            args += ["--output", output]
        return json.loads(self.cli(*args).stdout)

    def installed(self, *, cwd=None):
        return json.loads(self.cli("installed", "--json", cwd=cwd).stdout)["installed"]

    def upgrade(self, selector=PACKAGE, *, artifact=None, code=0, cwd=None):
        return self.cli("upgrade", selector, "--index", self.index,
                        "--artifact", artifact or self.artifacts["0.2.0"], "--json", code=code, cwd=cwd)

    def assert_preserved(self, before_bytes, before_inventory):
        self.assertEqual(self.destination.read_bytes(), before_bytes)
        self.assertEqual(self.inventory.read_bytes(), before_inventory)

    def inventory_failure_binary(self, fault="inventory"):
        """Compile one failure or stop into a specific transaction boundary.

        The real filesystem operations and cleanup still run. No production
        fault switch is introduced, and no operating-system permission is weakened.
        """
        if IS_MACOS:
            source = self.work / "inventory-failure.s"
            subprocess.run([sys.executable, str(ROOT / "tools/macos.py"), "--output", str(source)],
                           cwd=ROOT, check=True, capture_output=True, timeout=30)
            text = source.read_text()
        else:
            directory = "cli/aarch64" if IS_ARM64 else "cli"
            module = ROOT / directory / "programs.s"
            text = module.read_text()
        if fault == "inventory":
            start = text.index("program_commit_state:\n")
            end = text.index("\nprogram_list:", start)
            commit = text[start:end]
            if IS_ARM64:
                operation = "    ARM_CALL arm_renameat\n"
                replacement = "    mov x2, #-1\n" + operation
            else:
                operation = "    syscall\n"
                replacement = "    mov rdx, -1\n" + operation
            self.assertEqual(commit.count(operation), 1, "Fault must affect only the final inventory rename")
            text = text[:start] + commit.replace(operation, replacement) + text[end:]
        else:
            self.assertIn(fault, ("probe_error", "probe_stop"))
            if IS_ARM64:
                operation = "    P_SET 1, program_probe_active\n"
                if fault == "probe_error":
                    injected = "    b program_probe_error\n"
                else:
                    injected = ("    ARM_CALL arm_getpid\n    mov x0, x9\n"
                                f"    mov x1, #{int(signal.SIGSTOP)}\n    ARM_CALL arm_kill\n")
            else:
                operation = "    mov qword ptr [rip + program_probe_active], 1\n"
                if fault == "probe_error":
                    injected = "    jmp program_probe_error\n"
                else:
                    injected = ("    mov eax, 39\n    syscall\n    mov rdi, rax\n"
                                f"    mov esi, {int(signal.SIGSTOP)}\n    mov eax, 62\n    syscall\n")
            self.assertEqual(text.count(operation), 1, "Fault must occur after this invocation creates its probe")
            text = text.replace(operation, operation + injected)
        binary = self.work / "inventory-failure"
        if IS_MACOS:
            source.write_text(text)
            command = ["/usr/bin/clang", "-arch", "arm64", "-mmacosx-version-min=15.0",
                       "-Wl,-no_uuid", "-o", str(binary), str(source)]
        else:
            modified_module = self.work / "programs-failure.s"
            modified_module.write_text(text)
            source = self.work / "inventory-failure.s"
            main = (ROOT / directory / "asm.s").read_text()
            include = f'.include "{directory}/programs.s"'
            self.assertEqual(main.count(include), 1)
            source.write_text(main.replace(include, f'.include "{modified_module}"'))
            obj = self.work / "inventory-failure.o"
            subprocess.run(["/usr/bin/as", *([] if IS_ARM64 else ["--64"]), "--fatal-warnings",
                            "-o", str(obj), str(source)], cwd=ROOT, check=True,
                           capture_output=True, timeout=30)
            command = ["/usr/bin/ld", "-z", "noexecstack", "-o", str(binary), str(obj)]
        subprocess.run(command, cwd=ROOT, check=True, capture_output=True, timeout=30)
        return binary

    def test_empty_inventory_is_machine_readable_and_has_no_network_requirement(self):
        self.assertEqual(self.installed(), [])
        self.assertFalse(self.inventory.exists())

    def test_help_and_status_expose_the_same_management_commands(self):
        declared = json.loads((ROOT / "cli/commands.json").read_text())["implemented"]
        help_commands = json.loads(self.cli("help", "--json").stdout)["commands"]
        status_commands = json.loads(self.cli("status").stdout)["implemented"]
        self.assertEqual(set(help_commands), set(declared))
        self.assertEqual(set(status_commands), set(declared))
        help_text = self.cli("help").stdout
        for command in ("installed", "upgrade", "uninstall"):
            self.assertIn(command, declared)
            self.assertIn(command, help_text)

    def test_install_inventory_upgrade_and_uninstall_from_another_directory(self):
        self.install()
        record = self.installed()[0]
        self.assertEqual(record, {
            "package": PACKAGE, "version": "0.1.0", "target": TARGET,
            "sha256": hashlib.sha256(self.payloads["0.1.0"]).hexdigest(),
            "bytes": len(self.payloads["0.1.0"]), "path": str(self.destination), "registry": "local",
        })
        elsewhere = self.work / "another directory"
        elsewhere.mkdir()
        self.write_index(self.row("0.1.0"), self.row("0.2.0"))
        json.loads(self.upgrade(cwd=elsewhere).stdout)
        self.assertEqual(self.destination.read_bytes(), self.payloads["0.2.0"])
        self.assertEqual(self.installed(cwd=elsewhere)[0]["version"], "0.2.0")
        json.loads(self.cli("uninstall", PACKAGE, "--json", cwd=elsewhere).stdout)
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.installed(), [])

    def test_relative_custom_destination_is_recorded_as_an_absolute_path(self):
        output = 'program "quoted"; touch INJECTION'
        self.install(output=output)
        destination = self.work / output
        self.assertEqual(self.installed()[0]["path"], str(destination))
        elsewhere = self.work / "elsewhere"
        elsewhere.mkdir()
        self.write_index(self.row("0.2.0"))
        self.upgrade(cwd=elsewhere)
        self.assertEqual(destination.read_bytes(), self.payloads["0.2.0"])
        self.cli("uninstall", PACKAGE, cwd=elsewhere)
        self.assertFalse(destination.exists())
        self.assertFalse((self.work / "INJECTION").exists())

    def test_unicode_destination_round_trips_through_the_inventory(self):
        directory = self.work / "répertoire"
        directory.mkdir()
        destination = directory / "hello 世界"
        self.install(output=destination)
        self.assertEqual(self.installed()[0]["path"], str(destination))
        self.cli("uninstall", PACKAGE)
        self.assertFalse(destination.exists())

    def test_protected_home_below_the_system_temporary_directory(self):
        with tempfile.TemporaryDirectory(prefix="asm-program-home-", dir="/tmp") as temporary:
            self.home = Path(temporary).resolve()
            self.environment["HOME"] = str(self.home)
            self.inventory = self.home / ".local/state/asm/installed.tsv"
            self.destination = self.home / ".local/bin/hello"
            self.install()
            self.assertEqual(self.installed()[0]["path"], str(self.destination))
            self.cli("uninstall", PACKAGE)
            self.assertFalse(self.destination.exists())

    def test_latest_version_is_numeric_and_target_specific(self):
        self.install()
        self.write_index(self.row("2.9.9"), self.row("2.10.0"), self.row("3.0.0", target=OTHER_TARGET))
        self.upgrade()
        self.assertEqual(self.installed()[0]["version"], "2.10.0")

    def test_exact_upgrade_and_downgrade_refusal_preserve_records(self):
        self.install()
        self.write_index(self.row("0.1.0"), self.row("0.2.0"), self.row("0.3.0"))
        self.upgrade(f"{PACKAGE}@0.2.0")
        self.assertEqual(self.installed()[0]["version"], "0.2.0")
        before_bytes, before_inventory = self.destination.read_bytes(), self.inventory.read_bytes()
        self.upgrade(f"{PACKAGE}@0.1.0", artifact=self.artifacts["0.1.0"], code=1)
        self.assert_preserved(before_bytes, before_inventory)

    def test_equal_version_is_unchanged_and_changed_release_is_rejected(self):
        self.install()
        before_bytes, before_inventory = self.destination.read_bytes(), self.inventory.read_bytes()
        inode = self.destination.stat().st_ino
        self.upgrade(artifact=self.artifacts["0.1.0"])
        self.assert_preserved(before_bytes, before_inventory)
        self.assertEqual(self.destination.stat().st_ino, inode)
        self.write_index(self.row("0.1.0", digest=hashlib.sha256(self.payloads["0.2.0"]).hexdigest(),
                                  size=len(self.payloads["0.2.0"])))
        self.upgrade(code=1)
        self.assert_preserved(before_bytes, before_inventory)

    def test_corrupt_upgrade_and_network_failure_preserve_the_previous_install(self):
        self.install()
        before_bytes, before_inventory = self.destination.read_bytes(), self.inventory.read_bytes()
        self.write_index(self.row("0.2.0", digest="0" * 64))
        self.upgrade(code=1)
        self.assert_preserved(before_bytes, before_inventory)
        self.write_index(self.row("0.2.0"))
        # A closed proxy port fails transport without contacting the release host.
        self.environment.update(HTTPS_PROXY="http://127.0.0.1:9", https_proxy="http://127.0.0.1:9",
                                NO_PROXY="", no_proxy="", ALL_PROXY="", all_proxy="")
        result = self.cli("upgrade", PACKAGE, "--index", self.index, code=1)
        self.assertIn("download failed", result.stderr)
        self.assert_preserved(before_bytes, before_inventory)

    def test_inventory_commit_failure_rolls_back_install_upgrade_and_uninstall(self):
        binary = self.inventory_failure_binary()
        self.cli("install", PACKAGE, "--index", self.index, "--artifact", self.artifacts["0.1.0"],
                 code=1, binary=binary)
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.installed(), [])
        self.install()
        self.destination.chmod(0o1755)
        before_bytes, before_inventory = self.destination.read_bytes(), self.inventory.read_bytes()
        self.write_index(self.row("0.2.0"))
        self.cli("upgrade", PACKAGE, "--index", self.index, "--artifact", self.artifacts["0.2.0"],
                 code=1, binary=binary)
        self.assert_preserved(before_bytes, before_inventory)
        self.assertEqual(self.destination.stat().st_mode & 0o7777, 0o1755)
        self.cli("uninstall", PACKAGE, code=1, binary=binary)
        self.assert_preserved(before_bytes, before_inventory)
        self.assertEqual(self.destination.stat().st_mode & 0o7777, 0o1755)
        self.assertEqual(list(self.destination.parent.glob(".asm-program-*")), [])
        self.assertEqual(list(self.inventory.parent.glob(".installed-*")), [])

    def test_local_inventory_requires_an_explicit_local_index_for_upgrade(self):
        self.install()
        before_inventory = self.inventory.read_bytes()
        self.environment.update(HTTPS_PROXY="http://127.0.0.1:9", https_proxy="http://127.0.0.1:9",
                                NO_PROXY="", no_proxy="", ALL_PROXY="", all_proxy="")
        result = self.cli("upgrade", PACKAGE, "--artifact", self.artifacts["0.2.0"], code=1)
        self.assertIn("local index", result.stderr)
        self.assertNotIn("download failed", result.stderr)
        self.assert_preserved(self.payloads["0.1.0"], before_inventory)

    def test_install_refuses_existing_destination_without_recording_it(self):
        destination = self.work / "unrelated"
        destination.write_bytes(b"keep this unrelated file")
        self.cli("install", PACKAGE, "--index", self.index, "--artifact", self.artifacts["0.1.0"],
                 "--output", destination, code=1)
        self.assertEqual(destination.read_bytes(), b"keep this unrelated file")
        self.assertEqual(self.installed(), [])

    def test_inventory_path_is_reserved_before_the_first_install(self):
        for output in (self.inventory, self.inventory.with_name("Installed.tsv"),
                       self.inventory.with_name("another-program")):
            with self.subTest(output=output.name):
                self.cli("install", PACKAGE, "--index", self.index, "--artifact", self.artifacts["0.1.0"],
                         "--output", output, code=1)
                self.assertFalse(output.exists())
                self.assertFalse(self.inventory.exists())
                self.assertEqual(self.installed(), [])

    def test_cli_destination_and_case_variants_are_reserved(self):
        directory = self.home / ".local/bin"
        directory.mkdir(parents=True)
        for basename in ("asm", "AsM", "ASM"):
            destination = directory / basename
            with self.subTest(basename=basename):
                result = self.cli("install", PACKAGE, "--index", self.index,
                                  "--artifact", self.artifacts["0.1.0"], "--output", destination, code=1)
                self.assertIn("reserved", result.stderr)
                self.assertFalse(destination.exists())
                self.assertEqual(self.installed(), [])

    def test_cli_unicode_alias_reservation_obeys_the_filesystem(self):
        directory = self.home / ".local/bin"
        directory.mkdir(parents=True)
        reserved = directory / "asm"
        alternate = directory / "aſm"
        reserved.write_bytes(b"temporary name-comparison fixture")
        original = reserved.stat()
        try:
            other = alternate.stat()
            aliases = (original.st_dev, original.st_ino) == (other.st_dev, other.st_ino)
        except FileNotFoundError:
            aliases = False
        reserved.unlink()
        result = self.cli("install", PACKAGE, "--index", self.index,
                          "--artifact", self.artifacts["0.1.0"], "--output", alternate,
                          code=1 if aliases else 0)
        if aliases:
            self.assertIn("reserved", result.stderr)
            self.assertFalse(alternate.exists())
            self.assertEqual(self.installed(), [])
        else:
            self.assertEqual(self.installed()[0]["path"], str(alternate))
            self.cli("uninstall", PACKAGE)
        self.assertFalse(reserved.exists())

    def test_download_workspace_is_reserved_as_an_install_destination(self):
        # exec retains the wrapper's PID, making the private workspace name
        # deterministic without altering the CLI or guessing process IDs.
        wrapper = ("import os, sys\nfrom pathlib import Path\n"
                   "output = Path.cwd() / f'.asm-registry-{os.getpid()}' / 'index.tsv'\n"
                   "os.execv(sys.argv[1], [sys.argv[1], 'install', sys.argv[2], '--index', sys.argv[3], "
                   "'--artifact', sys.argv[4], '--output', str(output)])\n")
        self.cli("-c", wrapper, ASM, PACKAGE, self.index, self.artifacts["0.1.0"],
                 binary=sys.executable, code=1)
        self.assertEqual(self.installed(), [])

    def test_reinstall_refuses_a_second_destination_for_the_same_package(self):
        self.install()
        before_inventory = self.inventory.read_bytes()
        output = self.work / "second-install"
        self.cli("install", PACKAGE, "--index", self.index, "--artifact", self.artifacts["0.1.0"],
                 "--output", output, code=1)
        self.assertFalse(output.exists())
        self.assertEqual(self.inventory.read_bytes(), before_inventory)

    def test_missing_recorded_destination_cannot_be_reassigned_to_another_package(self):
        self.install()
        before_inventory = self.inventory.read_bytes()
        self.destination.unlink()
        self.write_index(self.row("0.1.0", package="other/hello"))
        self.cli("install", "other/hello@0.1.0", "--index", self.index,
                 "--artifact", self.artifacts["0.1.0"], "--output", self.destination, code=1)
        self.assertEqual(self.inventory.read_bytes(), before_inventory)
        self.assertFalse(self.destination.exists())

    def check_missing_destination_alias(self, recorded_name, alternate_name):
        recorded = self.work / recorded_name
        alternate = self.work / alternate_name
        self.install(output=recorded)
        original = recorded.stat()
        try:
            other = alternate.stat()
            aliases = (original.st_dev, original.st_ino) == (other.st_dev, other.st_ino)
        except FileNotFoundError:
            aliases = False
        before_inventory = self.inventory.read_bytes()
        recorded.unlink()
        self.write_index(self.row("0.1.0", package="other/hello"))
        self.cli("install", "other/hello@0.1.0", "--index", self.index,
                 "--artifact", self.artifacts["0.1.0"], "--output", alternate,
                 code=1 if aliases else 0)
        if aliases:
            self.assertEqual(self.inventory.read_bytes(), before_inventory)
            self.assertFalse(recorded.exists())
            self.assertFalse(alternate.exists())
        else:
            self.assertEqual(len(self.installed()), 2)
            self.assertEqual(alternate.read_bytes(), self.payloads["0.1.0"])
            self.cli("uninstall", "other/hello")
            self.assertEqual(self.inventory.read_bytes(), before_inventory)
            self.assertFalse(recorded.exists())

    def test_missing_destination_reservation_obeys_filesystem_case_rules(self):
        self.check_missing_destination_alias("hello", "HELLO")

    def test_missing_destination_reservation_obeys_unicode_case_rules(self):
        self.check_missing_destination_alias("café", "CAFÉ")

    def test_missing_destination_reservation_obeys_unicode_normalization_rules(self):
        self.check_missing_destination_alias("café", "cafe\u0301")

    def test_existing_alias_records_cannot_change_a_shared_file(self):
        self.install()
        alternate = self.destination.with_name("HELLO")
        original = self.destination.stat()
        try:
            other = alternate.stat()
            aliases = (original.st_dev, original.st_ino) == (other.st_dev, other.st_ino)
        except FileNotFoundError:
            aliases = False
        if not aliases:
            alternate.write_bytes(self.payloads["0.1.0"])
            alternate.chmod(0o755)
        first = self.inventory.read_bytes()
        _, row = first.split(b"\n", 1)
        other_row = row.replace(PACKAGE.encode(), b"other/hello").replace(
            str(self.destination).encode(), str(alternate).encode())
        self.inventory.write_bytes(first + other_row)
        before_inventory = self.inventory.read_bytes()
        if aliases:
            self.write_index(self.row("0.2.0"))
            self.upgrade(code=1)
            self.cli("uninstall", PACKAGE, code=1)
            self.assert_preserved(self.payloads["0.1.0"], before_inventory)
        else:
            self.cli("uninstall", PACKAGE)
            self.assertFalse(self.destination.exists())
            self.assertEqual(alternate.read_bytes(), self.payloads["0.1.0"])
            self.assertEqual([x["package"] for x in self.installed()], ["other/hello"])
            self.cli("uninstall", "other/hello")

    def test_probe_failure_restores_an_absent_destination(self):
        self.install()
        before_inventory = self.inventory.read_bytes()
        destination = self.destination.with_name("new-program")
        self.write_index(self.row("0.1.0", package="other/hello"))
        binary = self.inventory_failure_binary("probe_error")
        self.cli("install", "other/hello@0.1.0", "--index", self.index,
                 "--artifact", self.artifacts["0.1.0"], "--output", destination,
                 binary=binary, code=1)
        self.assertFalse(destination.exists())
        self.assert_preserved(self.payloads["0.1.0"], before_inventory)

    def test_interrupted_probe_leaves_only_an_empty_nonexecutable_new_file(self):
        self.install()
        before_inventory = self.inventory.read_bytes()
        destination = self.destination.with_name("new-program")
        self.write_index(self.row("0.1.0", package="other/hello"))
        binary = self.inventory_failure_binary("probe_stop")
        process = subprocess.Popen([str(binary), "install", "other/hello@0.1.0", "--index", str(self.index),
                                    "--artifact", str(self.artifacts["0.1.0"]), "--output", str(destination)],
                                   cwd=self.work, env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not destination.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(destination.exists(), "The instrumented command did not reach the filename check")
            metadata = destination.stat()
            self.assertEqual(metadata.st_size, 0)
            self.assertEqual(metadata.st_mode & 0o777, 0)
            process.kill()
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, -signal.SIGKILL, (stdout, stderr))
            self.assert_preserved(self.payloads["0.1.0"], before_inventory)
            self.assertEqual(destination.stat().st_size, 0)
            destination.unlink()
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

    def test_install_rejects_paths_that_cannot_be_recorded_without_changing_files(self):
        nested = self.work / "nested"
        nested.mkdir()
        for output in ("tab\tname", "line\nname", "../outside", "missing/../outside"):
            with self.subTest(output=output):
                self.cli("install", PACKAGE, "--index", self.index,
                         "--artifact", self.artifacts["0.1.0"], "--output", output, code=1, cwd=nested)
                self.assertEqual(self.installed(), [])
                self.assertFalse((nested / output).exists())

    def test_modified_destination_is_never_upgraded_or_uninstalled(self):
        self.install()
        self.destination.write_bytes(self.payloads["0.1.0"][:-1] + b"x")
        before_bytes, before_inventory = self.destination.read_bytes(), self.inventory.read_bytes()
        self.write_index(self.row("0.2.0"))
        self.upgrade(code=1)
        self.cli("uninstall", PACKAGE, code=1)
        self.assert_preserved(before_bytes, before_inventory)

    def test_symlink_destination_is_never_upgraded_or_uninstalled(self):
        self.install()
        target = self.work / "outside"
        self.destination.rename(target)
        self.destination.symlink_to(target)
        before_inventory = self.inventory.read_bytes()
        self.write_index(self.row("0.2.0"))
        self.upgrade(code=1)
        self.cli("uninstall", PACKAGE, code=1)
        self.assertTrue(self.destination.is_symlink())
        self.assertEqual(target.read_bytes(), self.payloads["0.1.0"])
        self.assertEqual(self.inventory.read_bytes(), before_inventory)

    def test_hardlinked_destination_is_never_upgraded_or_uninstalled(self):
        self.install()
        link = self.work / "hardlink"
        os.link(self.destination, link)
        before_inventory = self.inventory.read_bytes()
        self.write_index(self.row("0.2.0"))
        self.upgrade(code=1)
        self.cli("uninstall", PACKAGE, code=1)
        self.assertEqual(link.read_bytes(), self.payloads["0.1.0"])
        self.assert_preserved(self.payloads["0.1.0"], before_inventory)

    def test_writable_destination_is_never_upgraded_or_uninstalled(self):
        self.install()
        self.destination.chmod(0o777)
        before_inventory = self.inventory.read_bytes()
        self.write_index(self.row("0.2.0"))
        self.upgrade(code=1)
        self.cli("uninstall", PACKAGE, code=1)
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o777)
        self.assert_preserved(self.payloads["0.1.0"], before_inventory)

    def test_missing_destination_preserves_the_record_for_recovery(self):
        self.install()
        self.destination.unlink()
        before_inventory = self.inventory.read_bytes()
        self.write_index(self.row("0.2.0"))
        self.upgrade(code=1)
        self.cli("uninstall", PACKAGE, code=1)
        self.assertEqual(self.inventory.read_bytes(), before_inventory)
        self.assertFalse(self.destination.exists())

    def test_unmanaged_program_is_not_adopted_by_upgrade_or_uninstall(self):
        self.destination.parent.mkdir(parents=True)
        self.destination.write_bytes(self.payloads["0.1.0"])
        self.destination.chmod(0o755)
        self.write_index(self.row("0.2.0"))
        self.upgrade(code=1)
        self.cli("uninstall", PACKAGE, code=1)
        self.assertEqual(self.destination.read_bytes(), self.payloads["0.1.0"])
        self.assertEqual(self.installed(), [])

    def test_inventory_origin_change_is_rejected(self):
        self.install()
        self.inventory.write_bytes(self.inventory.read_bytes().replace(b"\tlocal\n", b"\thttps://example.test/index.tsv\n"))
        before_inventory = self.inventory.read_bytes()
        self.write_index(self.row("0.2.0"))
        self.upgrade(code=1)
        self.assert_preserved(self.payloads["0.1.0"], before_inventory)

    def test_inventory_is_bounded_and_strict_before_listing_or_mutating(self):
        self.install()
        original = self.inventory.read_bytes()
        first_line, row = original.split(b"\n", 1)
        malformed = [b"", b"# asm-installed-v2\n", original[:-1], original + row,
                     original + row.replace(PACKAGE.encode(), b"other/hello"),
                     original.replace(str(self.destination).encode(), b"/invalid-\xed\xa0\x80"),
                     original.replace(str(self.destination).encode(),
                                      (str(self.destination.parent) + "/../bin/hello").encode()),
                     original.replace(str(self.destination).encode(),
                                      (str(self.destination.parent) + "/./hello").encode()),
                     original.replace(str(self.destination).encode(),
                                      (str(self.destination.parent) + "//hello").encode()),
                     original.replace(str(self.destination).encode(),
                                      (str(self.destination) + "/").encode()),
                     original.replace(b"\tlocal\n", b"\tlocal\textra\n"),
                     original.replace(b"\tlocal\n", b"\tlocal\x00hidden\n"),
                     first_line + b"\n" + b"x" * 1048576]
        for data in malformed:
            with self.subTest(length=len(data)):
                self.inventory.write_bytes(data)
                result = self.cli("installed", "--json", code=1)
                self.assertEqual(result.stdout, "")
                self.assertFalse(json.loads(result.stderr)["ok"])
                self.cli("uninstall", PACKAGE, code=1)
                self.assertEqual(self.destination.read_bytes(), self.payloads["0.1.0"])
                self.assertEqual(self.inventory.read_bytes(), data)

    def test_symlink_inventory_and_state_directory_are_rejected(self):
        self.install()
        actual = self.work / "actual-inventory.tsv"
        self.inventory.rename(actual)
        self.inventory.symlink_to(actual)
        self.cli("installed", code=1)
        self.cli("uninstall", PACKAGE, code=1)
        self.assertTrue(self.inventory.is_symlink())
        self.inventory.unlink()
        self.inventory.write_bytes(actual.read_bytes())
        state = self.inventory.parent
        state.rename(state.with_name("actual-state"))
        state.symlink_to(state.with_name("actual-state"), target_is_directory=True)
        self.cli("installed", code=1)
        self.cli("uninstall", PACKAGE, code=1)
        self.assertTrue(state.is_symlink())
        self.assertEqual(self.destination.read_bytes(), self.payloads["0.1.0"])

    def test_inventory_lock_prevents_competing_mutations(self):
        self.install()
        before_inventory = self.inventory.read_bytes()
        descriptor = os.open(self.inventory.parent, os.O_RDONLY)
        self.addCleanup(os.close, descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.write_index(self.row("0.2.0"))
        self.upgrade(code=1)
        self.cli("uninstall", PACKAGE, code=1)
        self.assert_preserved(self.payloads["0.1.0"], before_inventory)

    def test_bad_management_arguments_do_not_change_installed_files(self):
        self.install()
        before_inventory = self.inventory.read_bytes()
        for args in (("installed", PACKAGE), ("uninstall",), ("uninstall", "hello"),
                     ("uninstall", f"{PACKAGE}@0.1.0"), ("upgrade",),
                     ("upgrade", PACKAGE, "--output", "somewhere"),
                     ("upgrade", PACKAGE, "--target", OTHER_TARGET)):
            with self.subTest(args=args):
                self.cli(*args, code=2)
                self.assert_preserved(self.payloads["0.1.0"], before_inventory)

    def test_ordinary_install_upgrade_and_uninstall_are_quiet(self):
        result = self.cli("install", f"{PACKAGE}@0.1.0", "--index", self.index,
                          "--artifact", self.artifacts["0.1.0"])
        self.assertEqual(result.stdout, "")
        self.write_index(self.row("0.2.0"))
        result = self.cli("upgrade", PACKAGE, "--index", self.index,
                          "--artifact", self.artifacts["0.2.0"])
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.cli("uninstall", PACKAGE).stdout, "")


if __name__ == "__main__":
    unittest.main()
