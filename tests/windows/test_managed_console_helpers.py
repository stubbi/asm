"""Host checks for receipt parsing only; these do not qualify Windows APIs.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from managed_console import parse_receipt


class ConsoleReceiptTests(unittest.TestCase):
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
        compiler = shutil.which('cc') or shutil.which('clang') or shutil.which('clang.exe')
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
            built = subprocess.run([compiler, '-std=c11', '-O0', '-I', str(fixture.parent),
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
        self.assertEqual(observed.stderr,
                         b'launcher_terminated=1 job_closed=1 signal_calls=0\n')

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
