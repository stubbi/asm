/* Owned-console launcher qualification fixture. This is test infrastructure.
 * No result from a cross-build qualifies Windows control-event behavior.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
typedef unsigned short W;
typedef unsigned int D;
typedef unsigned long long Q;
typedef void *H;
typedef struct { D length; void *descriptor; int inherit; } SECURITY;
typedef struct {
    D cb; W *reserved, *desktop, *title; D x, y, width, height, chars_x, chars_y;
    D fill, flags; unsigned short show, reserved_size; unsigned char *reserved_data;
    H input, output, error;
} STARTUP;
typedef struct { H process, thread; D process_id, thread_id; } PROCESS;
typedef struct {
    Q process_time, job_time; D flags; Q minimum_working_set, maximum_working_set;
    D active_processes; Q affinity; D priority, scheduling;
} BASIC_LIMITS;
typedef struct { BASIC_LIMITS basic; Q io[6], process_memory, job_memory, peak_process, peak_job; } JOB_LIMITS;
_Static_assert(sizeof(D) == 4 && sizeof(W) == 2 && sizeof(H) == 8, "Win64 ABI required");
_Static_assert(sizeof(BASIC_LIMITS) == 64 && sizeof(JOB_LIMITS) == 144, "Win64 job limits ABI required");
#ifndef API
#define API __declspec(dllimport)
#endif
API W *GetCommandLineW(void);
API W **CommandLineToArgvW(const W *, int *);
API H LocalFree(H);
API int SetConsoleCtrlHandler(int (*)(D), int);
API int GenerateConsoleCtrlEvent(D, D);
API int CreateProcessW(const W *, W *, SECURITY *, SECURITY *, int, D, void *, const W *, STARTUP *, PROCESS *);
API H GetStdHandle(D);
API H CreateJobObjectW(SECURITY *, const W *);
API int SetInformationJobObject(H, D, void *, D);
API int AssignProcessToJobObject(H, H);
API D ResumeThread(H);
API H GetCurrentProcess(void);
API D GetCurrentProcessId(void);
API D GetProcessId(H);
API H OpenProcess(D, int, D);
API int DuplicateHandle(H, H, H, H *, D, int, D);
API H CreateFileW(const W *, D, D, SECURITY *, D, D, H);
API int WriteFile(H, const void *, D, D *, void *);
API int ReadFile(H, void *, D, D *, void *);
API int FlushFileBuffers(H);
API int CloseHandle(H);
API D WaitForSingleObject(H, D);
API int GetExitCodeProcess(H, D *);
API int TerminateProcess(H, D);
API Q GetTickCount64(void);
API D GetLastError(void);
API void Sleep(D);
API __declspec(noreturn) void ExitProcess(D);
#define INVALID ((H)(long long)-1)
#define PAYLOAD_RIGHTS 0x101001
static W command[32768];
static char output[1024];
static D wanted_exit;
static D output_used;

/* Read at most 4096 binary bytes from inherited synchronous stdin, then
 * write all bytes to each inherited output. A closed anonymous pipe is EOF.
 * Input overflow and any other I/O failure return98; complete copies return37.
 * Borrow all three handles without closing them. Own the static data buffer. */
static int stdio_copy(void) {
    static unsigned char data[4096];
    unsigned char extra;
    H input = GetStdHandle((D)-10), streams[2];
    D used = 0, read = 0, capacity, index, offset, written;
    streams[0] = GetStdHandle((D)-11); streams[1] = GetStdHandle((D)-12);
    if (!input || input == INVALID || !streams[0] || streams[0] == INVALID
        || !streams[1] || streams[1] == INVALID) return 98;
    for (;;) {
        capacity = used < sizeof(data) ? (D)sizeof(data) - used : 1;
        read = 0;
        if (!ReadFile(input, used < sizeof(data) ? data + used : &extra, capacity, &read, 0)) {
            if (GetLastError() == 109 && !read) break; /* ERROR_BROKEN_PIPE */
            return 98;
        }
        if (read > capacity) return 98;
        if (!read) break;
        if (used == sizeof(data)) return 98;
        used += read;
    }
    for (index = 0; index < 2; ++index) {
        offset = 0;
        while (offset < used) {
            written = 0;
            if (!WriteFile(streams[index], data + offset, used - offset, &written, 0)
                || !written || written > used - offset) return 98;
            offset += written;
        }
    }
    return 37;
}

/* All input is private test argv. Reject overflow before constructing a command. */
static int equal(const W *value, const char *text) {
    D i = 0;
    while (text[i] && value[i] == (unsigned char)text[i]) ++i;
    return !text[i] && !value[i];
}
static int number(const W *value, D *result) {
    D i = 0, n = 0;
    if (!value[0] || (value[0] == '0' && value[1])) return 0;
    while (value[i]) {
        D digit = value[i++] - '0';
        if (digit > 9 || n > (0xffffffffUL - digit) / 10) return 0;
        n = n * 10 + digit;
    }
    *result = n;
    return 1;
}
/* EXPECTED_COUNT includes the executable, mode, and count arguments.
 * Compare a fixed five-token cycle as exact UTF-16 code units. The final
 * Unicode token contains a surrogate pair. All fixture input is private.
 * Return one only for 3..1023 arguments and the canonical declared count. */
static int check_args(int count, W **args) {
    static const W spaces[] = {'s','p','a','c','e',' ','t','o','k','e','n',0};
    static const W quotes[] = {'d','o','u','b','l','e','"','q','u','o','t','e',0};
    static const W empty[] = {0};
    static const W slashes[] = {'b','a','c','k','\\','s','l','a','s','h','\\',0};
    static const W unicode[] = {'G','r',0x00fc,0x00df,'e',' ',0x4e16,0x754c,0xd83d,0xde42,0};
    static const W *tokens[] = {spaces, quotes, empty, slashes, unicode};
    D expected, i;
    if (count < 3 || count > 1023 || !number(args[2], &expected) || expected != (D)count) return 0;
    for (i = 3; i < (D)count; ++i) {
        const W *token = tokens[(i - 3) % 5];
        D j = 0;
        while (token[j] && args[i][j] == token[j]) ++j;
        if (args[i][j] != token[j]) return 0;
    }
    return 1;
}
static int append(W value, D *used) {
    if (*used >= 32767) return 0;
    command[(*used)++] = value;
    return 1;
}
static int quote(const W *arg, D *used) {
    D slashes = 0;
    if (!append('"', used)) return 0;
    for (;;) {
        W ch = *arg++;
        if (ch == '\\') { ++slashes; continue; }
        if (!ch || ch == '"') {
            D copies = slashes * 2 + (ch == '"');
            while (copies--) if (!append('\\', used)) return 0;
        } else {
            while (slashes--) if (!append('\\', used)) return 0;
        }
        slashes = 0;
        if (!ch) break;
        if (!append(ch, used)) return 0;
    }
    return append('"', used);
}
static void decimal_w(D value, W *buffer) {
    W reverse[10];
    D n = 0, i = 0;
    do { reverse[n++] = '0' + value % 10; value /= 10; } while (value);
    while (n) buffer[i++] = reverse[--n];
    buffer[i] = 0;
}
static int ignore_event(D event) { return event == 0 || event == 1; }
static int payload_event(D event) {
    if (event == 0 || event == 1) {
        ExitProcess(wanted_exit);
    }
    return 0;
}
static void character(char value) {
    if (output_used >= sizeof(output)) ExitProcess(98);
    output[output_used++] = value;
}
static void text(const char *value) { while (*value) character(*value++); }
static void decimal(Q value) {
    char reverse[20];
    D n = 0;
    do { reverse[n++] = '0' + (char)(value % 10); value /= 10; } while (value);
    while (n) character(reverse[--n]);
}
static int reaped(H process) { return process && WaitForSingleObject(process, 0) == 0; }
static int stop(H process) {
    if (!process) return 1;
    if (WaitForSingleObject(process, 0) != 0) TerminateProcess(process, 97);
    return WaitForSingleObject(process, 1000) == 0;
}
static void payload(int count, W **args) {
    D parent_id, written;
    H parent, remote = 0, marker;
    Q handshake[2];
    if (count != 5 || !number(args[3], &wanted_exit) || !number(args[4], &parent_id)) ExitProcess(98);
    if (!SetConsoleCtrlHandler(payload_event, 1)) ExitProcess(98);
    parent = OpenProcess(0x100040, 0, parent_id); /* SYNCHRONIZE | PROCESS_DUP_HANDLE */
    if (!parent) ExitProcess(98);
    if (!DuplicateHandle(GetCurrentProcess(), GetCurrentProcess(), parent, &remote,
                         PAYLOAD_RIGHTS, 0, 0)) { CloseHandle(parent); ExitProcess(98); }
    handshake[0] = (Q)remote;
    handshake[1] = GetCurrentProcessId();
    marker = CreateFileW(args[2], 0x40000000, 0, 0, 1, 0x80, 0); /* CREATE_NEW */
    if (marker == INVALID) { CloseHandle(parent); ExitProcess(98); }
    if (!WriteFile(marker, handshake, sizeof(handshake), &written, 0) || written != sizeof(handshake)
        || !FlushFileBuffers(marker)) { CloseHandle(marker); CloseHandle(parent); ExitProcess(98); }
    CloseHandle(marker);
    LocalFree(args);
    /* Wait indefinitely for a real control event. Parent death is the failure escape. */
    WaitForSingleObject(parent, 0xffffffffUL);
    CloseHandle(parent);
    ExitProcess(98);
}
static void controller(int count, W **args) {
    static STARTUP startup;
    static PROCESS child;
    static JOB_LIMITS limits;
    W controller_id[11];
    static const W payload_option[] = {'-','-','c','o','n','s','o','l','e','-','p','a','y','l','o','a','d',0};
    const W *parts[5];
    D event = 0, requested = 0, used = 0, actual = 0, payload_actual = 0, error = 0, i, length;
    int ready = 0, sent = 0, got_exit = 0, got_payload_exit = 0, child_reaped = 0, payload_reaped = 0;
    H marker = INVALID, selected = 0, job = 0;
    Q handshake[2], started = GetTickCount64();
    const char *status = "invalid-arguments";
    if (count != 6 || !number(args[4], &event) || event > 1 || !number(args[5], &requested)) goto finish;
    status = "handler-failed";
    if (!SetConsoleCtrlHandler(ignore_event, 1)) { error = GetLastError(); goto finish; }
    decimal_w(GetCurrentProcessId(), controller_id);
    parts[0] = args[2]; parts[1] = payload_option; parts[2] = args[3]; parts[3] = args[5]; parts[4] = controller_id;
    status = "command-too-long";
    for (i = 0; i < 5; ++i) {
        if (i && !append(' ', &used)) goto finish;
        if (!quote(parts[i], &used)) goto finish;
    }
    command[used] = 0;
    startup.cb = sizeof(startup);
    startup.flags = 0x100; /* STARTF_USESTDHANDLES; keep the owned inherited pipes. */
    startup.input = GetStdHandle((D)-10); startup.output = GetStdHandle((D)-11); startup.error = GetStdHandle((D)-12);
    status = "job-failed";
    job = CreateJobObjectW(0, 0);
    if (!job) { error = GetLastError(); goto finish; }
    limits.basic.flags = 0x2000; /* KILL_ON_JOB_CLOSE is fixture isolation only. */
    if (!SetInformationJobObject(job, 9, &limits, sizeof(limits))) { error = GetLastError(); goto finish; }
    status = "create-failed";
    if (!CreateProcessW(args[2], command, 0, 0, 1, 4, 0, 0, &startup, &child)) { error = GetLastError(); goto finish; }
    status = "job-assignment-failed";
    if (!AssignProcessToJobObject(job, child.process)) { error = GetLastError(); goto finish; }
    status = "resume-failed";
    if (ResumeThread(child.thread) == (D)-1) { error = GetLastError(); goto finish; }
    CloseHandle(child.thread); child.thread = 0;
    status = "readiness-timeout";
    while (GetTickCount64() - started < 10000) {
        marker = CreateFileW(args[3], 0x80000000, 1, 0, 3, 0x80, 0);
        if (marker != INVALID) {
            if (ReadFile(marker, handshake, sizeof(handshake), &length, 0) && length == sizeof(handshake)) {
                selected = (H)handshake[0];
                ready = selected && GetProcessId(selected) == handshake[1];
            }
            CloseHandle(marker); marker = INVALID;
            if (ready) break;
            selected = 0; /* A partial marker can become complete before close. */
        }
        if (WaitForSingleObject(child.process, 0) == 0) { status = "launcher-exited-before-ready"; break; }
        Sleep(10);
    }
    if (!ready) goto finish;
    status = "signal-failed";
    sent = GenerateConsoleCtrlEvent(event, 0); /* Group zero is only this controller's new console. */
    if (!sent) { error = GetLastError(); goto finish; }
    status = "launcher-timeout";
    if (WaitForSingleObject(child.process, 5000) != 0) goto finish;
    status = "exit-query-failed";
    got_exit = GetExitCodeProcess(child.process, &actual);
    if (!got_exit) { error = GetLastError(); goto finish; }
    status = "payload-timeout";
    if (WaitForSingleObject(selected, 1000) != 0) goto finish;
    status = "payload-exit-query-failed";
    got_payload_exit = GetExitCodeProcess(selected, &payload_actual);
    if (!got_payload_exit) { error = GetLastError(); goto finish; }
    status = "complete";
finish:
    /* A missing readiness handshake leaves payload termination unobserved.
     * Report false even though closing the fixture job contains descendants. */
    if (selected) payload_reaped = stop(selected);
    if (child.process) child_reaped = stop(child.process);
    text("{\"status\":\""); text(status); text("\",\"event\":"); decimal(event);
    text(",\"requested_exit_code\":"); decimal(requested);
    text(",\"exit_code\":"); if (got_exit) decimal(actual); else text("null");
    text(",\"payload_exit_code\":"); if (got_payload_exit) decimal(payload_actual); else text("null");
    text(",\"ready\":"); text(ready ? "true" : "false");
    text(",\"event_sent\":"); text(sent ? "true" : "false");
    text(",\"launcher_reaped\":"); text(child_reaped && reaped(child.process) ? "true" : "false");
    text(",\"payload_reaped\":"); text(payload_reaped && reaped(selected) ? "true" : "false");
    text(",\"error\":"); decimal(error); text(",\"elapsed_ms\":"); decimal(GetTickCount64() - started); text("}\n");
    if (selected) CloseHandle(selected);
    if (child.process) CloseHandle(child.process);
    if (child.thread) CloseHandle(child.thread);
    if (job) CloseHandle(job);
    LocalFree(args);
    used = 0;
    while (used < output_used) {
        if (!WriteFile(GetStdHandle((D)-11), output + used, output_used - used, &length, 0)
            || !length) ExitProcess(98);
        used += length;
    }
    ExitProcess(got_exit && got_payload_exit && ready && sent && child_reaped && payload_reaped ? 0 : 1);
}
void fixture_entry(void) {
    int count = 0;
    W **args = CommandLineToArgvW(GetCommandLineW(), &count);
    D code;
    if (!args || count < 2) ExitProcess(98);
    if (equal(args[1], "--exit") && count == 3 && number(args[2], &code)) {
        LocalFree(args); ExitProcess(code);
    }
    if (equal(args[1], "--check-args")) {
        code = check_args(count, args) ? 0 : 98;
        LocalFree(args); ExitProcess(code);
    }
    if (equal(args[1], "--stdio") && count == 2) {
        LocalFree(args); ExitProcess((D)stdio_copy());
    }
    if (equal(args[1], "--console-payload")) payload(count, args);
    if (equal(args[1], "--controller")) controller(count, args);
    LocalFree(args);
    ExitProcess(98);
}
