/* Exercise the verifier fixture's byte and transcript decisions on a Unix host.
 * This adapter does not test Windows APIs or qualify a Windows executable.
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define __declspec(value)
#include "update_tool_fixture.c"

static char narrow[4096];

static const char *ascii(const W *value) {
    unsigned int i = 0;
    while (value[i] && i < sizeof(narrow) - 1) {
        if (value[i] > 127) exit(98);
        narrow[i] = (char)value[i];
        ++i;
    }
    narrow[i] = 0;
    return narrow;
}

static W *wide(const char *value) {
    size_t i, length = strlen(value);
    W *result = calloc(length + 1, sizeof(W));
    if (!result) exit(98);
    for (i = 0; i < length; ++i) {
        if ((unsigned char)value[i] > 127) exit(98);
        result[i] = (unsigned char)value[i];
    }
    return result;
}

H CreateFileW(const W *name, D access, D share, void *security, D creation, D attributes, H template) {
    (void)share; (void)security; (void)creation; (void)attributes; (void)template;
    FILE *handle = fopen(ascii(name), access == 4 ? "ab" : "rb");
    return handle ? handle : (H)-1;
}

int ReadFile(H handle, void *data, D capacity, D *length, void *overlapped) {
    (void)overlapped;
    *length = (D)fread(data, 1, capacity, (FILE *)handle);
    return !ferror((FILE *)handle);
}

int WriteFile(H handle, const void *data, D size, D *length, void *overlapped) {
    (void)overlapped;
    *length = (D)fwrite(data, 1, size, (FILE *)handle);
    return *length == size;
}

int CloseHandle(H handle) { return fclose((FILE *)handle) == 0; }
H GetStdHandle(D number) { (void)number; return stdout; }
void ExitProcess(D code) { exit((int)code); }

D GetFileAttributesW(const W *name) {
    FILE *handle = fopen(ascii(name), "rb");
    if (!handle) return (D)-1;
    fclose(handle);
    return 128;
}

D GetEnvironmentVariableW(const W *name, W *output, D capacity) {
    const char *value = getenv(ascii(name));
    size_t i, length;
    if (!value) return 0;
    length = strlen(value);
    if (length + 1 > capacity) return (D)(length + 1);
    for (i = 0; i <= length; ++i) output[i] = (unsigned char)value[i];
    return (D)length;
}

W *GetCommandLineW(void) { exit(99); }
W **CommandLineToArgvW(const W *value, int *count) { (void)value; (void)count; exit(99); }
D GetModuleFileNameW(H module, W *output, D capacity) {
    (void)module; (void)output; (void)capacity; exit(99);
}

int main(int count, char **arguments) {
    int i;
    W *directory;
    size_t length;
    if (count < 4) return 98;
    directory = wide(arguments[1]);
    length = strlen(arguments[1]);
    if (length + 2 > sizeof(base) / sizeof(base[0])) return 98;
    for (i = 0; i < (int)length; ++i) base[i] = directory[i];
    base[length] = '/';
    base[length + 1] = 0;
    argc = count - 2;
    argv = calloc((size_t)argc + 1, sizeof(W *));
    if (!argv) return 98;
    for (i = 0; i < argc; ++i) argv[i] = wide(arguments[i + 2]);
    if (contains(argv[0], L"gh.exe")) verify();
    else download();
    return 99;
}
