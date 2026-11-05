"""Exercise qualification refusals without claiming Windows runtime coverage.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import difflib
import importlib.util
import io
import json
import os
import platform
from pathlib import Path, PureWindowsPath
import struct
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from runtime_helpers import absolute_archive_cases, assert_complete_provenance, final_replacement_failure, preparation_failure, snapshot_source, fault_observation

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


class FaultObservationTests(unittest.TestCase):
    def test_observation_wrapper_preserves_live_registers_vectors_and_flags(self):
        # The callback deliberately changes every volatile integer/vector and
        # condition flag. An unprotected call is a required failing control.
        compiler = shutil.which('clang')
        target_arguments = []
        host = platform.machine().lower()
        if os.name == 'nt':
            compiler = shutil.which('clang.exe')
            fixed = Path('C:/Program Files/LLVM/bin/clang.exe')
            if fixed.is_file():
                compiler = str(fixed)
            target = os.environ.get('ASM_WINDOWS_TARGET')
            arm64 = target == 'aarch64-windows' if target else host in ('arm64', 'aarch64')
            cases = [(arm64, ['--target=' + ('aarch64-pc-windows-msvc' if arm64 else 'x86_64-pc-windows-msvc')])]
        elif platform.system() == 'Darwin':
            cases = [(False, ['--target=x86_64-apple-darwin'])]
            if host in ('arm64', 'aarch64'):
                cases.append((True, ['--target=arm64-apple-darwin']))
        else:
            self.assertIn(host, ('x86_64', 'amd64'), 'This host cannot execute a supported assembly adapter.')
            cases = [(False, [])]
        self.assertIsNotNone(compiler, 'The register observation check requires clang.')
        darwin = platform.system() == 'Darwin'
        prefix = '_' if darwin else ''
        with tempfile.TemporaryDirectory(prefix='asm-fault-registers-') as temporary:
            root = Path(temporary)
            driver_source = root / 'driver.c'
            driver_source.write_text('extern int test_probe(void); int main(void) { return test_probe(); }\n')
            for arm64, target_arguments in cases:
                if arm64:
                    address = ('    adrp x16, observed@PAGE\n    add x16, x16, observed@PAGEOFF\n'
                               if darwin else '    adrp x16, observed\n    add x16, x16, :lo12:observed\n')
                    setup = ('.text\n.global test_probe\ntest_probe:\n'
                             '    stp x29, x30, [sp, #-96]!\n    mov x29, sp\n'
                             '    stp x19, x20, [sp, #16]\n')
                    setup += ''.join(f'    stp d{i}, d{i + 1}, [sp, #{32 + (i - 8) * 8}]\n'
                                     for i in range(8, 16, 2))
                    setup += ''.join(f'    mov x{i}, #{256 + i}\n' for i in range(18))
                    vectors = list(range(32))
                    setup += ''.join(f'    movi v{i}.16b, #0x5a\n' for i in vectors)
                    setup += '    cmp x0, x0\n'
                    checks = '    b.ne failed\n    b.cc failed\n'
                    for i in range(18):
                        checks += f'    cmp x{i}, #{256 + i}\n    b.ne failed\n'
                    checks += ('    movz x20, #0x5a5a\n    movk x20, #0x5a5a, lsl #16\n'
                               '    movk x20, #0x5a5a, lsl #32\n    movk x20, #0x5a5a, lsl #48\n')
                    for i in vectors:
                        for lane in (0, 1):
                            checks += f'    umov x19, v{i}.d[{lane}]\n    cmp x19, x20\n    b.ne failed\n'
                    checks += address + '    ldr w16, [x16]\n    cmp w16, #2\n    b.ne failed\n'
                    checks += ('    mov w0, #0\n    b done\nfailed:\n    mov w0, #95\ndone:\n'
                               '    ldp x19, x20, [sp, #16]\n')
                    checks += ''.join(f'    ldp d{i}, d{i + 1}, [sp, #{32 + (i - 8) * 8}]\n'
                                      for i in range(8, 16, 2))
                    checks += '    ldp x29, x30, [sp], #96\n    ret\n'
                    callback = 'asm_test_fault_reached:\n' + address + '    str w0, [x16]\n'
                    callback += ''.join(f'    mov x{i}, #0\n' for i in range(18))
                    callback += ''.join(f'    movi v{i}.16b, #0\n' if i < 8 or i >= 16 else
                                        f'    ins v{i}.d[1], xzr\n' for i in vectors)
                    callback += '    cmp x0, #1\n    ret\n.data\n.p2align 2\nobserved: .long 0\n'
                    unsafe = '    mov x0, #2\n    bl asm_test_fault_reached\n'
                else:
                    registers = ['rax', 'rcx', 'rdx', 'r8', 'r9', 'r10', 'r11']
                    setup = ('.intel_syntax noprefix\n.text\n.global test_probe\ntest_probe:\n'
                             '    push rbp\n    mov rbp, rsp\n    push rbx\n    sub rsp, 24\n')
                    setup += ''.join(f'    mov {reg}, {256 + i}\n' for i, reg in enumerate(registers))
                    setup += '    lea rbx, [rip + vector_pattern]\n'
                    setup += ''.join(f'    movdqu xmm{i}, [rbx]\n' for i in range(6))
                    setup += '    cmp rax, rax\n'
                    checks = '    jne failed\n    jc failed\n'
                    for i, reg in enumerate(registers):
                        checks += f'    cmp {reg}, {256 + i}\n    jne failed\n'
                    checks += '    movabs rax, 0x5a5a5a5a5a5a5a5a\n'
                    for i in range(6):
                        checks += (f'    movdqu [rsp], xmm{i}\n    cmp [rsp], rax\n    jne failed\n'
                                   '    cmp [rsp + 8], rax\n    jne failed\n')
                    checks += ('    cmp dword ptr [rip + observed], 2\n    jne failed\n'
                               '    xor eax, eax\n    jmp done\nfailed:\n    mov eax, 95\ndone:\n'
                               '    lea rsp, [rbp - 8]\n    pop rbx\n    pop rbp\n    ret\n')
                    callback = 'asm_test_fault_reached:\n    mov [rip + observed], ecx\n'
                    callback += ''.join(f'    xor {reg}, {reg}\n' for reg in registers)
                    callback += ''.join(f'    pxor xmm{i}, xmm{i}\n' for i in range(6))
                    callback += ('    cmp eax, 1\n    ret\n.data\n.p2align 4\n'
                                 'vector_pattern: .quad 0x5a5a5a5a5a5a5a5a, 0x5a5a5a5a5a5a5a5a\nobserved: .long 0\n')
                    if platform.system() == 'Linux':
                        callback += '.section .note.GNU-stack,"",@progbits\n'
                    unsafe = '    sub rsp, 32\n    mov ecx, 2\n    call asm_test_fault_reached\n    add rsp, 32\n'
                for control in (False, True):
                    source, binary = root / 'registers.s', root / 'registers.exe'
                    hook = unsafe if control else fault_observation(arm64, 'record_write')
                    assembly = setup + hook + checks + callback
                    if prefix:
                        assembly = assembly.replace('test_probe', prefix + 'test_probe').replace(
                            'asm_test_fault_reached', prefix + 'asm_test_fault_reached')
                    source.write_text(assembly)
                    built = subprocess.run([compiler, *target_arguments, str(source), str(driver_source),
                                            '-o', str(binary)], capture_output=True, timeout=30)
                    self.assertEqual(built.returncode, 0, built.stderr.decode(errors='replace'))
                    ran = subprocess.run([str(binary)], capture_output=True, timeout=5)
                    self.assertEqual((ran.returncode, ran.stdout, ran.stderr),
                                     (95 if control else 0, b'', b''), (arm64, control))

    def test_fault_marker_function_writes_exact_stage_and_fails_closed(self):
        # The actual C function must leave a stage-specific file. A missing
        # write, short-write mishandling, or accepted failure breaks this test.
        compiler = shutil.which('cc') or shutil.which('clang')
        target_arguments = []
        if os.name == 'nt':
            compiler = shutil.which('clang.exe')
            fixed = Path('C:/Program Files/LLVM/bin/clang.exe')
            if fixed.is_file():
                compiler = str(fixed)
            target = os.environ.get('ASM_WINDOWS_TARGET')
            if not target:
                target = {'amd64': 'x86_64-windows', 'x86_64': 'x86_64-windows',
                          'arm64': 'aarch64-windows', 'aarch64': 'aarch64-windows'}.get(platform.machine().lower())
            triples = {'x86_64-windows': 'x86_64-pc-windows-msvc',
                       'aarch64-windows': 'aarch64-pc-windows-msvc'}
            self.assertIn(target, triples)
            target_arguments = ['--target=' + triples[target]]
        self.assertIsNotNone(compiler, 'The fault observation check requires a C compiler.')
        fixture = Path(__file__).with_name('snapshot_barrier.c').read_text()
        fixture = fixture.replace('#define API __declspec(dllimport)', '#define API')
        fixture = fixture.replace('__declspec(noreturn)', '__attribute__((noreturn))').replace('L"', 'u"')
        harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
''' + fixture + r'''
void asm_test_fault_reached(DWORD);
static FILE *marker;
static const char *marker_path;
static int mode, writes, flushes, closes;
DWORD GetEnvironmentVariableW(const WCHAR *name, WCHAR *value, DWORD capacity) {
    static const WCHAR expected[] = u"ASM_TEST_FAULT_MARKER";
    size_t n, i;
    for (i = 0; expected[i]; ++i) if (name[i] != expected[i]) abort();
    if (name[i]) abort();
    if (mode == 1) return 0;
    if (mode == 2) return capacity;
    n = strlen(marker_path);
    if (n >= capacity) abort();
    for (i = 0; i <= n; ++i) value[i] = (unsigned char)marker_path[i];
    return (DWORD)n;
}
HANDLE CreateFileW(const WCHAR *path, DWORD access, DWORD share, void *security,
                   DWORD creation, DWORD flags, HANDLE template_file) {
    if (!path[0] || access != 0x40000000 || share || security || creation != 1
            || flags != 0x200080 || template_file) abort();
    if (mode == 3) return (HANDLE)(long long)-1;
    marker = fopen(marker_path, "wbx");
    return marker ? (HANDLE)marker : (HANDLE)(long long)-1;
}
int WriteFile(HANDLE handle, const void *data, DWORD count, DWORD *written, void *overlap) {
    ++writes;
    if (handle != (HANDLE)marker || overlap) abort();
    *written = 0;
    if (mode == 4) return 0;
    if (mode == 5) return 1;
    if (count > 3) count = 3; /* Require the real function to handle short writes. */
    *written = (DWORD)fwrite(data, 1, count, marker);
    return *written == count;
}
int FlushFileBuffers(HANDLE handle) {
    ++flushes;
    if (handle != (HANDLE)marker) abort();
    return fflush(marker) == 0 && mode != 6;
}
int CloseHandle(HANDLE handle) {
    ++closes;
    if (handle != (HANDLE)marker) abort();
    return fclose(marker) == 0 && mode != 7;
}
HANDLE OpenEventW(DWORD a, int b, const WCHAR *c) { abort(); }
int SetEvent(HANDLE a) { abort(); }
DWORD WaitForSingleObject(HANDLE a, DWORD b) { abort(); }
void ExitProcess(DWORD code) {
    fprintf(stderr, "writes=%d flushes=%d closes=%d\n", writes, flushes, closes);
    exit((int)code);
}
int main(int argc, char **argv) {
    if (argc != 4) return 99;
    mode = atoi(argv[2]); marker_path = argv[3];
    asm_test_fault_reached((DWORD)atoi(argv[1]));
    fprintf(stderr, "writes=%d flushes=%d closes=%d\n", writes, flushes, closes);
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix='asm-fault-marker-') as temporary:
            root = Path(temporary)
            source, binary = root / 'marker.c', root / 'marker.exe'
            source.write_text(harness)
            built = subprocess.run([compiler, *target_arguments, '-std=c11', '-O0', str(source),
                                    '-o', str(binary)], capture_output=True, timeout=30)
            self.assertEqual(built.returncode, 0, built.stderr.decode(errors='replace'))
            stages = ((1, b'payload_flush'), (2, b'record_write'),
                      (3, b'record_flush'), (4, b'activation_rename'))
            for stage, name in stages:
                with self.subTest(stage=stage):
                    path = root / ('stage-' + str(stage))
                    ran = subprocess.run([str(binary), str(stage), '0', str(path)], capture_output=True, timeout=5)
                    self.assertEqual((ran.returncode, ran.stdout), (0, b''), ran.stderr)
                    self.assertEqual(path.read_bytes(), b'# asm-test-fault-v1\n' + name + b'\n')
                    self.assertIn(b'flushes=1 closes=1', ran.stderr)
                    self.assertNotIn(b'writes=1 ', ran.stderr)
                    again = subprocess.run([str(binary), str(stage), '0', str(path)], capture_output=True, timeout=5)
                    self.assertEqual(again.returncode, 125, again.stderr)
                    self.assertEqual(path.read_bytes(), b'# asm-test-fault-v1\n' + name + b'\n')
            for stage, mode, cleanup in ((0, 0, b'closes=0'), (1, 1, b'closes=0'),
                                          (1, 2, b'closes=0'), (1, 3, b'closes=0'),
                                          (1, 4, b'flushes=0 closes=1'), (1, 5, b'flushes=0 closes=1'),
                                          (1, 6, b'flushes=1 closes=1'), (1, 7, b'flushes=1 closes=1')):
                with self.subTest(stage=stage, mode=mode):
                    path = root / ('failure-' + str(stage) + '-' + str(mode))
                    ran = subprocess.run([str(binary), str(stage), str(mode), str(path)], capture_output=True, timeout=5)
                    self.assertEqual((ran.returncode, ran.stdout), (125, b''), ran.stderr)
                    self.assertIn(cleanup, ran.stderr)


class RuntimeHelperTests(unittest.TestCase):
    def test_snapshot_sync_preserves_source_except_one_explicit_test_hook(self):
        source = 'before\nwin_managed_snapshot_ready:\nafter\n'
        for arm64, hook in ((True, '    ARM_CALL asm_test_snapshot_barrier\n'),
                            (False, '    sub rsp, 32\n    call asm_test_snapshot_barrier\n    add rsp, 32\n')):
            with self.subTest(arm64=arm64):
                changed = snapshot_source(source, arm64)
                self.assertEqual(changed.replace(hook, '', 1), source)
                self.assertIn('win_managed_snapshot_ready:\n' + hook, changed)
        for source in ('missing', source + source):
            with self.subTest(source=source), self.assertRaises(ValueError):
                snapshot_source(source, False)

    def test_preparation_fault_targets_only_the_selected_native_boundary(self):
        for arm64 in (False, True):
            for stage, native in (('record_write', 'arm_write'), ('record_flush', 'arm_fsync'),
                                  ('payload_flush', 'arm_fsync')):
                label = 'win_managed_' + stage + ':\n'
                call = '    ARM_CALL ' + native + '\n' if arm64 else '    call win_syscall\n'
                source = 'unchanged before\n' + label + call + 'unchanged after\n'
                with self.subTest(arm64=arm64, stage=stage):
                    changed = preparation_failure(source, arm64, stage)
                    bad = '    mov x0, #-1\n' if arm64 else '    mov rdi, -1\n'
                    self.assertTrue(changed.startswith('unchanged before\n' + label))
                    self.assertTrue(changed.endswith(bad + call + 'unchanged after\n'))
                    self.assertEqual(changed.count('call asm_test_fault_reached' if not arm64 else
                                                   'bl asm_test_fault_reached'), 1)
                    number = {'payload_flush': 1, 'record_write': 2, 'record_flush': 3}[stage]
                    self.assertIn(('    mov x0, #' if arm64 else '    mov ecx, ') + str(number) + '\n', changed)

    def test_managed_fault_changes_only_final_record_activation(self):
        for arm64, call, bad in ((True, '    ARM_CALL win_managed_rename_fd\n', '    mov x1, #-1\n'),
                                 (False, '    call win_managed_rename_fd\n', '    mov rsi, -1\n')):
            source = ('before\nself_commit_update:\n    branch_to_managed_commit\n'
                      '\nself_update_cleanup:\nuntouched cleanup\n'
                      'win_managed_activation_rename:\n' + call + 'after\n')
            with self.subTest(arm64=arm64):
                changed = final_replacement_failure(source, arm64)
                self.assertTrue(changed.startswith(source[:source.index('    ' + ('ARM_CALL win_managed_rename_fd' if arm64 else 'call win_managed_rename_fd'))]))
                self.assertTrue(changed.endswith(bad + call + 'after\n'))
                self.assertEqual(changed.count('bl asm_test_fault_reached' if arm64 else
                                               'call asm_test_fault_reached'), 1)
                self.assertIn('    mov x0, #4\n' if arm64 else '    mov ecx, 4\n', changed)
                self.assertIn('untouched cleanup\n', changed)

    def test_prepared_fault_instrumentation_changes_only_one_named_boundary(self):
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
                managed = '\nwin_managed_activation_rename:\n' in source
                bad = ("    mov x1, #-1" if arm64 else "    mov rsi, -1") if managed else (
                    "    mov x2, #-1" if arm64 else "    mov rdx, -1")
                inserted = after[changed_start:changed_end]
                self.assertEqual(inserted[-1], bad)
                expected_call = ("    ARM_CALL win_managed_rename_fd" if arm64 else
                                 "    call win_managed_rename_fd") if managed else (
                    "    ARM_CALL arm_renameat" if arm64 else "    call win_syscall")
                self.assertEqual(before[start], expected_call)
                if managed:
                    self.assertEqual(before[start - 1], 'win_managed_activation_rename:')
                    self.assertIn('    bl asm_test_fault_reached' if arm64 else
                                  '    call asm_test_fault_reached', inserted)
                elif not arm64:
                    self.assertEqual(inserted, [bad])
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


class OutcomeGateTests(unittest.TestCase):
    def run_case(self, case):
        return unittest.TextTestRunner(stream=io.StringIO(), resultclass=driver.EvidenceResult).run(case)

    def test_expected_failure_is_recorded_and_cannot_qualify(self):
        class KnownFailure(unittest.TestCase):
            @unittest.expectedFailure
            def test_case(self):
                self.fail("expected fixture failure")

        result = self.run_case(KnownFailure("test_case"))
        self.assertTrue(result.wasSuccessful(), "This exercises unittest's expected-failure success behavior")
        self.assertEqual(len(result.expectedFailures), 1)
        self.assertEqual(result.records[0]["outcome"], "expected-failure")
        self.assertIn("expected fixture failure", result.records[0]["detail"])
        self.assertFalse(driver.qualifies_result(result))

    def test_skip_empty_suite_and_unexpected_success_cannot_qualify(self):
        class Skipped(unittest.TestCase):
            def test_case(self):
                self.skipTest("missing fixture capability")

        class UnexpectedSuccess(unittest.TestCase):
            @unittest.expectedFailure
            def test_case(self):
                pass

        skipped = self.run_case(Skipped("test_case"))
        self.assertEqual(skipped.records[0]["outcome"], "not-run")
        unexpected = self.run_case(UnexpectedSuccess("test_case"))
        self.assertEqual(unexpected.records[0]["outcome"], "unexpected-success")
        for result in (skipped, unexpected, self.run_case(unittest.TestSuite())):
            self.assertFalse(driver.qualifies_result(result))

    def test_only_an_executed_unittest_success_qualifies(self):
        class Cases(unittest.TestCase):
            def test_pass(self):
                self.assertEqual(2 + 2, 4)

            def test_failure(self):
                self.fail("real fixture failure")

            def test_error(self):
                raise RuntimeError("real fixture error")

        for name, expected in (("test_pass", True), ("test_failure", False), ("test_error", False)):
            with self.subTest(name=name):
                self.assertEqual(driver.qualifies_result(self.run_case(Cases(name))), expected)


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
