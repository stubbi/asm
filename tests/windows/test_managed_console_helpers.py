"""Host checks for fixture logic; these do not qualify Windows APIs.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from managed_console import parse_receipt


class ConsoleReceiptTests(unittest.TestCase):
    def test_stdio_copy_preserves_binary_bytes_and_rejects_io_failures(self):
        # Missing output, partial writes, premature success, and overflow must fail.
        # Compile the actual fixture routine against bounded host I/O adapters.
        compiler = shutil.which('cc') or shutil.which('clang')
        target_arguments = []
        if os.name == 'nt':
            compiler = shutil.which('clang.exe')
            fixed_clang = Path('C:/Program Files/LLVM/bin/clang.exe')
            if fixed_clang.is_file():
                compiler = str(fixed_clang)
            targets = {'x86_64-windows': 'x86_64-pc-windows-msvc',
                       'aarch64-windows': 'aarch64-pc-windows-msvc'}
            host_target = {'amd64': 'x86_64-windows', 'x86_64': 'x86_64-windows',
                           'arm64': 'aarch64-windows', 'aarch64': 'aarch64-windows'}
            target = os.environ.get('ASM_WINDOWS_TARGET') or host_target.get(platform.machine().lower())
            self.assertIn(target, targets, 'The stdio checker requires a supported host target.')
            target_arguments = ['--target=' + targets[target]]
        self.assertIsNotNone(compiler, 'The stdio checker regression requires a C compiler.')
        fixture = Path(__file__).with_name('managed_console.c').read_text(encoding='utf-8')
        start = fixture.index('static D output_used;') + len('static D output_used;')
        body = fixture[start:fixture.index('/* All input is private test argv.')]
        harness = r'''
#include <stdio.h>
#include <stdlib.h>
#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
#endif
typedef unsigned int D;
typedef void *H;
#define INVALID ((H)(long long)-1)
H GetStdHandle(D);
int ReadFile(H, void *, D, D *, void *);
int WriteFile(H, const void *, D, D *, void *);
D GetLastError(void);
''' + body + r'''
static char mode;
static D last_error, read_calls;
H GetStdHandle(D stream) {
    if (mode == 'i' && stream == (D)-10) return INVALID;
    if (stream == (D)-10) return (H)1;
    if (stream == (D)-11) return (H)2;
    if (stream == (D)-12) return (H)3;
    abort();
}
int ReadFile(H stream, void *buffer, D count, D *read, void *overlapped) {
    if (stream != (H)1 || overlapped || !count) abort();
    *read = 0;
    if (mode == 'r' && read_calls++) { last_error = 5; return 0; }
    if (mode == 'R') { *read = count + 1; return 1; }
    if (count > 7) count = 7;
    *read = (D)fread(buffer, 1, count, stdin);
    if (!*read && mode == 'p') { last_error = 109; return 0; }
    return !ferror(stdin);
}
int WriteFile(H stream, const void *buffer, D count, D *written, void *overlapped) {
    if ((stream != (H)2 && stream != (H)3) || overlapped || !count) abort();
    *written = 0;
    if ((mode == 'o' && stream == (H)2) || (mode == 'e' && stream == (H)3)) return 0;
    if (mode == 'z') return 1;
    if (mode == 'W') { *written = count + 1; return 1; }
    if (count > 5) count = 5;
    *written = (D)fwrite(buffer, 1, count, stream == (H)2 ? stdout : stderr);
    return *written == count;
}
D GetLastError(void) { return last_error; }
int main(int argc, char **argv) {
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    _setmode(_fileno(stderr), _O_BINARY);
#endif
    if (argc != 2) return 99;
    mode = argv[1][0];
    return stdio_copy();
}
'''
        data = b'\x00\xffGr\xc3\xbc\xc3\x9fe \xe4\xb8\x96\xe7\x95\x8c\xf0\x9f\x99\x82\r\nend\x00'
        with tempfile.TemporaryDirectory(prefix='asm-console-stdio-') as temporary:
            source = Path(temporary) / 'stdio-host.c'
            binary = Path(temporary) / 'stdio-host.exe'
            source.write_text(harness, encoding='utf-8')
            built = subprocess.run([compiler, *target_arguments, '-std=c11', '-O0', str(source),
                                    '-o', str(binary)], capture_output=True, timeout=30)
            self.assertEqual(built.returncode, 0, built.stderr.decode(errors='replace'))
            cases = [('s', data, 37, data, data), ('p', data, 37, data, data),
                     ('s', b'', 37, b'', b''), ('p', b'x' * 4096, 37, b'x' * 4096, b'x' * 4096),
                     ('p', b'x' * 4097, 98, b'', b''), ('r', data, 98, b'', b''),
                     ('o', data, 98, b'', b''), ('e', data, 98, data, b''),
                     ('z', data, 98, b'', b''), ('i', data, 98, b'', b''),
                     ('R', data, 98, b'', b''), ('W', data, 98, b'', b'')]
            for mode, payload, code, out, err in cases:
                with self.subTest(mode=mode, size=len(payload)):
                    result = subprocess.run([str(binary), mode], input=payload,
                                            capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, code, result.stderr)
                    self.assertEqual(result.stdout, out)
                    self.assertEqual(result.stderr, err)

    def test_argument_checker_preserves_literal_utf16_tokens_and_count_limits(self):
        # A checker that accepts the wrong count or one altered token must fail.
        # Compile its actual C body; no Windows API behavior is simulated here.
        compiler = shutil.which('cc') or shutil.which('clang')
        target_arguments = []
        if os.name == 'nt':
            compiler = shutil.which('clang.exe')
            fixed_clang = Path('C:/Program Files/LLVM/bin/clang.exe')
            if fixed_clang.is_file():
                compiler = str(fixed_clang)
            targets = {'x86_64-windows': 'x86_64-pc-windows-msvc',
                       'aarch64-windows': 'aarch64-pc-windows-msvc'}
            host_target = {'amd64': 'x86_64-windows', 'x86_64': 'x86_64-windows',
                           'arm64': 'aarch64-windows', 'aarch64': 'aarch64-windows'}
            target = os.environ.get('ASM_WINDOWS_TARGET') or host_target.get(platform.machine().lower())
            self.assertIn(target, targets, 'The argument checker requires a supported host target.')
            target_arguments = ['--target=' + targets[target]]
        self.assertIsNotNone(compiler, 'The argument checker regression requires a C compiler.')
        fixture = Path(__file__).with_name('managed_console.c').read_text(encoding='utf-8')
        body = fixture[fixture.index('static int number('):fixture.index('static int append(')]
        harness = r'''
typedef unsigned short W;
typedef unsigned int D;
''' + body + r'''
int main(int argc, char **argv) {
    static W *args[1025];
    static const W *tokens[] = {u"space token", u"double\"quote", u"", u"back\\slash\\",
                               u"Gr\u00fc\u00dfe \u4e16\u754c\U0001f642"};
    int count = 257, i;
    if (argc < 2) return 99;
    args[0] = (W *)u"fixture"; args[1] = (W *)u"--check-args"; args[2] = (W *)u"257";
    if (argv[1][0] == 'b') { count = 1023; args[2] = (W *)u"1023"; }
    if (argv[1][0] == 'c') args[2] = (W *)u"256";
    if (argv[1][0] == 'e') { count = 1024; args[2] = (W *)u"1024"; }
    if (argv[1][0] == 'f') args[2] = (W *)u"0257";
    if (argv[1][0] == 'g') count = 2;
    if (argv[1][0] == 'h') { count = 3; args[2] = (W *)u"3"; }
    for (i = 3; i < count; ++i) args[i] = (W *)tokens[(i - 3) % 5];
    if (argv[1][0] == 'd' && argc == 3 && argv[2][0] >= '0' && argv[2][0] <= '4')
        args[3 + argv[2][0] - '0'] = (W *)u"altered";
    return check_args(count, args) ? 0 : 98;
}
'''
        with tempfile.TemporaryDirectory(prefix='asm-console-argv-') as temporary:
            source = Path(temporary) / 'argv-host.c'
            binary = Path(temporary) / 'argv-host.exe'
            source.write_text(harness, encoding='utf-8')
            built = subprocess.run([compiler, *target_arguments, '-std=c11', '-O0', str(source),
                                    '-o', str(binary)], capture_output=True, timeout=30)
            self.assertEqual(built.returncode, 0, built.stderr.decode(errors='replace'))
            cases = [(['a'], 0), (['b'], 0), (['c'], 98), (['e'], 98), (['f'], 98),
                     (['g'], 98), (['h'], 0)] + [(['d', str(i)], 98) for i in range(5)]
            for arguments, expected in cases:
                with self.subTest(arguments=arguments):
                    result = subprocess.run([str(binary), *arguments], capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual(result.stdout, b'')
                    self.assertEqual(result.stderr, b'')

    def receipt(self, **changes):
        row = {'status': 'complete', 'event': 0, 'requested_exit_code': 0xc000013a,
               'exit_code': 0xc000013a, 'payload_exit_code': 0xc000013a, 'ready': True, 'event_sent': True,
               'launcher_reaped': True, 'payload_reaped': True, 'error': 0, 'elapsed_ms': 42}
        row.update(changes)
        return json.dumps(row).encode('ascii')

    def test_full_dword_and_failed_native_outcome_are_retained(self):
        self.assertEqual(parse_receipt(self.receipt())['exit_code'], 0xc000013a)
        failed = parse_receipt(self.receipt(status='launcher-timeout', exit_code=None,
                                          launcher_reaped=False))
        self.assertIsNone(failed['exit_code'])
        self.assertFalse(failed['launcher_reaped'])
        self.assertEqual(failed['status'], 'launcher-timeout')
        self.check_no_readiness_controller_branch()

    def check_no_readiness_controller_branch(self):
        # Execute the actual controller branch with simulated APIs and clock.
        # This establishes receipt honesty only, never Windows kernel behavior.
        target_arguments = []
        if os.name == 'nt':
            compiler = shutil.which('clang.exe')
            fixed_clang = Path('C:/Program Files/LLVM/bin/clang.exe')
            if fixed_clang.is_file():
                compiler = str(fixed_clang)
            targets = {'x86_64-windows': 'x86_64-pc-windows-msvc',
                       'aarch64-windows': 'aarch64-pc-windows-msvc'}
            host_target = {'amd64': 'x86_64-windows', 'x86_64': 'x86_64-windows',
                           'arm64': 'aarch64-windows', 'aarch64': 'aarch64-windows'}
            target = os.environ.get('ASM_WINDOWS_TARGET') or host_target.get(platform.machine().lower())
            self.assertIn(target, targets, 'The Windows harness requires an explicit supported native target.')
            target_arguments = ['--target=' + targets[target]]
        else:
            compiler = shutil.which('cc') or shutil.which('clang')
        self.assertIsNotNone(compiler, 'The controller branch regression requires a C compiler.')
        fixture = Path(__file__).with_name('managed_console.c').resolve()
        harness = r"""
#include <stdio.h>
#include <stdlib.h>
#define API
#define __declspec(value) __attribute__((value))
#include "managed_console.c"
static Q ticks;
static int terminated, job_closed, signal_calls;
W *GetCommandLineW(void) { abort(); }
W **CommandLineToArgvW(const W *a, int *b) { abort(); }
H LocalFree(H a) { return 0; }
int SetConsoleCtrlHandler(int (*a)(D), int b) { return 1; }
int GenerateConsoleCtrlEvent(D a, D b) { ++signal_calls; return 1; }
int CreateProcessW(const W *a, W *b, SECURITY *c, SECURITY *d, int e, D f,
                   void *g, const W *h, STARTUP *i, PROCESS *j) {
    j->process = (H)1; j->thread = (H)2; return 1;
}
H GetStdHandle(D a) { return (H)4; }
H CreateJobObjectW(SECURITY *a, const W *b) { return (H)3; }
int SetInformationJobObject(H a, D b, void *c, D d) { return 1; }
int AssignProcessToJobObject(H a, H b) { return 1; }
D ResumeThread(H a) { return 1; }
H GetCurrentProcess(void) { abort(); }
D GetCurrentProcessId(void) { return 123; }
D GetProcessId(H a) { abort(); }
H OpenProcess(D a, int b, D c) { abort(); }
int DuplicateHandle(H a, H b, H c, H *d, D e, int f, D g) { abort(); }
H CreateFileW(const W *a, D b, D c, SECURITY *d, D e, D f, H g) { return INVALID; }
int WriteFile(H a, const void *b, D c, D *d, void *e) {
    *d = (D)fwrite(b, 1, c, stdout); return *d == c;
}
int ReadFile(H a, void *b, D c, D *d, void *e) { abort(); }
int FlushFileBuffers(H a) { abort(); }
int CloseHandle(H a) { if (a == (H)3) job_closed = 1; return 1; }
D WaitForSingleObject(H a, D b) {
    if (a != (H)1) abort();
    return terminated ? 0 : 258;
}
int GetExitCodeProcess(H a, D *b) { abort(); }
int TerminateProcess(H a, D b) { terminated = 1; return 1; }
Q GetTickCount64(void) { return ticks; }
D GetLastError(void) { return 0; }
void Sleep(D a) { ticks += a; }
void ExitProcess(D code) {
    fprintf(stderr, "launcher_terminated=%d job_closed=%d signal_calls=%d\n",
            terminated, job_closed, signal_calls);
    exit((int)code);
}
int main(void) {
    W *args[] = {(W *)u"fixture", (W *)u"--controller", (W *)u"launcher",
                 (W *)u"ready", (W *)u"0", (W *)u"123"};
    controller(6, args);
    return 99;
}
"""
        with tempfile.TemporaryDirectory(prefix='asm-console-no-readiness-') as temporary:
            source = Path(temporary) / 'controller-host.c'
            binary = Path(temporary) / 'controller-host.exe'
            source.write_text(harness, encoding='utf-8')
            built = subprocess.run([compiler, *target_arguments, '-std=c11', '-O0', '-I', str(fixture.parent),
                                    str(source), '-o', str(binary)], capture_output=True, timeout=30)
            self.assertEqual(built.returncode, 0, built.stderr.decode(errors='replace'))
            observed = subprocess.run([str(binary)], capture_output=True, timeout=5)
        self.assertEqual(observed.returncode, 1, observed.stderr)
        row = parse_receipt(observed.stdout)
        self.assertEqual(row['status'], 'readiness-timeout')
        self.assertFalse(row['ready'])
        self.assertFalse(row['event_sent'])
        self.assertIsNone(row['payload_exit_code'])
        self.assertTrue(row['launcher_reaped'])
        self.assertFalse(row['payload_reaped'])
        self.assertEqual(row['elapsed_ms'], 10000)
        self.assertEqual(observed.stderr.splitlines(),
                         [b'launcher_terminated=1 job_closed=1 signal_calls=0'])

    def test_malformed_or_ambiguous_receipts_are_rejected(self):
        cases = [b'', b'{}', b'x' * 4097, self.receipt() + b'{}',
                 self.receipt().replace(b'"event": 0', b'"event": 0, "event": 1'),
                 self.receipt(exit_code=-1), self.receipt(exit_code=0x100000000),
                 self.receipt(exit_code=True), self.receipt(event=2),
                 self.receipt(elapsed_ms=20001), self.receipt(ready=1),
                 self.receipt(status='invented-pass'), self.receipt(status=[]),
                 self.receipt(exit_code=None), self.receipt(payload_exit_code=None),
                 self.receipt(ready=False)]
        for raw in cases:
            with self.subTest(receipt=raw[:80]):
                with self.assertRaises(ValueError):
                    parse_receipt(raw)


if __name__ == '__main__':
    unittest.main()
