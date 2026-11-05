/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Test-only libpq failure boundary. No application logic is implemented here. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>

void *PQconnectStartParams(const char *const *keys, const char *const *values, int expand)
{
    const char *marker = getenv("ASM_TEST_CONNECT_NULL_FILE");
    if (marker != NULL && access(marker, F_OK) == 0)
        return NULL;
    void *(*real_connect)(const char *const *, const char *const *, int);
    *(void **)(&real_connect) = dlsym(RTLD_NEXT, "PQconnectStartParams");
    if (real_connect == NULL)
        _exit(86);
    return real_connect(keys, values, expand);
}
