/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Test-only observer. Never link this object into a production CLI.
 * Inputs: borrowed suspended child HANDLE and real class-44 adapter result.
 * Returns 1 after transferring a duplicate to the Python controller, else 0.
 * Every error returns to the launcher's existing refusal/reaping branch.
 * Never closes, resumes, terminates, or waits on the borrowed child handle.
 * Windows x64/ARM64 C ABI preserves nonvolatile registers. No CRT is needed.
 */
typedef unsigned int DWORD;
typedef unsigned short WCHAR;
typedef unsigned long long U64;
typedef void *HANDLE;
#define API __declspec(dllimport)
#define INVALID_HANDLE ((HANDLE)(long long)-1)
#define PROCESS_DUP_HANDLE 0x40
#define CHILD_OBSERVER_ACCESS 0x101001 /* synchronize, query limited, terminate */
#define DUPLICATE_CLOSE_SOURCE 1
API DWORD GetEnvironmentVariableW(const WCHAR *, WCHAR *, DWORD);
API HANDLE GetCurrentProcess(void);
API DWORD GetCurrentProcessId(void);
API DWORD GetProcessId(HANDLE);
API HANDLE OpenProcess(DWORD, int, DWORD);
API int DuplicateHandle(HANDLE, HANDLE, HANDLE, HANDLE *, DWORD, int, DWORD);
API HANDLE CreateFileW(const WCHAR *, DWORD, DWORD, void *, DWORD, DWORD, HANDLE);
API int WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
API int FlushFileBuffers(HANDLE);
API int CloseHandle(HANDLE);
API int DeleteFileW(const WCHAR *);
static WCHAR controller_text[16], receipt_path[4096];

static void little_endian(unsigned char *out, U64 value, DWORD count) {
    DWORD index;
    for (index = 0; index < count; ++index) {
        out[index] = (unsigned char)value;
        value >>= 8;
    }
}

int asm_test_child_binding(HANDLE child, long long actual_match) {
    static const unsigned char magic[8] = {'A','S','M','C','B','1','\r','\n'};
    unsigned char receipt[40];
    DWORD length, index, digit, controller_pid = 0, child_pid, offset = 0, written;
    HANDLE controller = 0, marker = INVALID_HANDLE, remote = 0;
    int created = 0, closed;
    length = GetEnvironmentVariableW((const WCHAR *)L"ASM_TEST_CHILD_CONTROLLER_PID",
                                     controller_text, 16);
    if (!length || length > 10 || controller_text[0] == '0') return 0;
    for (index = 0; index < length; ++index) {
        digit = (DWORD)controller_text[index] - '0';
        if (digit > 9 || controller_pid > (0xffffffffU - digit) / 10) return 0;
        controller_pid = controller_pid * 10 + digit;
    }
    length = GetEnvironmentVariableW((const WCHAR *)L"ASM_TEST_CHILD_RECEIPT",
                                     receipt_path, 4096);
    if (!length || length >= 4096) return 0;
    child_pid = GetProcessId(child);
    if (!child_pid) return 0;
    controller = OpenProcess(PROCESS_DUP_HANDLE, 0, controller_pid);
    if (!controller) return 0;
    /* CREATE_NEW, no sharing, and OPEN_REPARSE_POINT: never overwrite a receipt. */
    marker = CreateFileW(receipt_path, 0x40000000, 0, 0, 1, 0x200080, 0);
    if (marker == INVALID_HANDLE) goto fail;
    created = 1;
    if (!DuplicateHandle(GetCurrentProcess(), child, controller, &remote,
                         CHILD_OBSERVER_ACCESS, 0, 0)) goto fail;
    for (index = 0; index < 8; ++index) receipt[index] = magic[index];
    little_endian(receipt + 8, (U64)remote, 8);
    little_endian(receipt + 16, child_pid, 4);
    little_endian(receipt + 20, controller_pid, 4);
    little_endian(receipt + 24, (U64)actual_match, 8);
    little_endian(receipt + 32, GetCurrentProcessId(), 4);
    little_endian(receipt + 36, 0, 4);
    while (offset < sizeof(receipt)) {
        written = 0;
        if (!WriteFile(marker, receipt + offset, (DWORD)sizeof(receipt) - offset, &written, 0)
                || !written || written > sizeof(receipt) - offset) goto fail;
        offset += written;
    }
    if (!FlushFileBuffers(marker)) goto fail;
    closed = CloseHandle(marker);
    marker = INVALID_HANDLE;
    if (!closed) goto fail;
    /* A complete closed receipt transfers the duplicate's ownership. */
    CloseHandle(controller);
    return 1;
fail:
    if (marker != INVALID_HANDLE) CloseHandle(marker);
    if (remote) {
        /* Remove only the duplicate in the controller, never the borrowed child. */
        DuplicateHandle(controller, remote, 0, 0, 0, 0, DUPLICATE_CLOSE_SOURCE);
    }
    if (created) DeleteFileW(receipt_path);
    CloseHandle(controller);
    return 0;
}
