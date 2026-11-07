/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Test-only snapshot synchronization and fault-boundary observations.
 * This object is linked only into named test variants, never the CLI.
 */
typedef unsigned int DWORD;
typedef unsigned short WCHAR;
typedef void *HANDLE;
#define API __declspec(dllimport)
API DWORD GetEnvironmentVariableW(const WCHAR *, WCHAR *, DWORD);
API HANDLE OpenEventW(DWORD, int, const WCHAR *);
API int SetEvent(HANDLE);
API DWORD WaitForSingleObject(HANDLE, DWORD);
API int CloseHandle(HANDLE);
API HANDLE CreateFileW(const WCHAR *, DWORD, DWORD, void *, DWORD, DWORD, HANDLE);
API int WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
API int FlushFileBuffers(HANDLE);
API __declspec(noreturn) void ExitProcess(DWORD);
static WCHAR ready_name[128], release_name[128];
static WCHAR fault_path[4096];

/* stage=1 payload flush, 2 record write, 3 record flush, 4 activation rename.
 * The injection wrapper preserves live arguments, volatile registers and flags.
 * ASM_TEST_FAULT_MARKER names one absent file inside the caller's private test
 * directory. CREATE_NEW refuses an existing file. Any observation failure
 * terminates the test variant with125 before the intended fault can execute.
 * This routine never opens, runs, or changes a CLI candidate or selection.
 */
void asm_test_fault_reached(DWORD stage) {
    static const char payload[] = "# asm-test-fault-v1\npayload_flush\n";
    static const char write[] = "# asm-test-fault-v1\nrecord_write\n";
    static const char flush[] = "# asm-test-fault-v1\nrecord_flush\n";
    static const char activation[] = "# asm-test-fault-v1\nactivation_rename\n";
    const char *bytes;
    DWORD count, length, offset = 0, written;
    HANDLE marker;
    int success = 1;
    switch (stage) {
        case 1: bytes = payload; count = sizeof(payload) - 1; break;
        case 2: bytes = write; count = sizeof(write) - 1; break;
        case 3: bytes = flush; count = sizeof(flush) - 1; break;
        case 4: bytes = activation; count = sizeof(activation) - 1; break;
        default: ExitProcess(125);
    }
    length = GetEnvironmentVariableW((const WCHAR *)L"ASM_TEST_FAULT_MARKER", fault_path, 4096);
    if (!length || length >= 4096) ExitProcess(125);
    marker = CreateFileW(fault_path, 0x40000000, 0, 0, 1, 0x200080, 0);
    if (marker == (HANDLE)(long long)-1) ExitProcess(125);
    while (offset < count) {
        written = 0;
        if (!WriteFile(marker, bytes + offset, count - offset, &written, 0)
                || !written || written > count - offset) {
            success = 0;
            break;
        }
        offset += written;
    }
    if (success) success = FlushFileBuffers(marker);
    success = CloseHandle(marker) && success;
    if (!success) ExitProcess(125);
}

/* No arguments. The injection site has no live volatile registers or flags.
 * Standard Windows callee-saved registers and stack conventions apply.
 * Event names belong to this test's two existing uniquely named events.
 */
void asm_test_snapshot_barrier(void) {
    DWORD length = GetEnvironmentVariableW((const WCHAR *)L"ASM_TEST_SNAPSHOT_READY", ready_name, 128);
    HANDLE ready, release;
    int success;
    if (!length) return;
    if (length >= 128) ExitProcess(124);
    length = GetEnvironmentVariableW((const WCHAR *)L"ASM_TEST_SNAPSHOT_RELEASE", release_name, 128);
    if (!length || length >= 128) ExitProcess(124);
    ready = OpenEventW(2, 0, ready_name);
    if (!ready) ExitProcess(124);
    release = OpenEventW(0x100000, 0, release_name);
    if (!release) { CloseHandle(ready); ExitProcess(124); }
    success = SetEvent(ready) && WaitForSingleObject(release, 45000) == 0;
    success = CloseHandle(release) && success;
    success = CloseHandle(ready) && success;
    if (!success) ExitProcess(124);
}
