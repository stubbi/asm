/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Qualification-only interposer for the actual assembly executable. This file
 * is never linked into, copied into, or compiled by a runtime image.
 * Fixed fault modes target a known fixture response; no production target,
 * credential argument, arbitrary command, or request-derived instruction.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <microhttpd.h>
#include <libpq-fe.h>

enum fault { CREATE = 1, HEADER, QUEUE, CLOCK, MUTEX_INIT };
static enum fault mode;
static int index_target;
static atomic_int fired;
static _Thread_local struct MHD_Response *tracked;
static _Thread_local int clear_result, clock_armed;
static struct MHD_Response *(*real_create)(size_t, void *, enum MHD_ResponseMemoryMode);
static enum MHD_Result (*real_header)(struct MHD_Response *, const char *, const char *);
static enum MHD_Result (*real_queue)(struct MHD_Connection *, unsigned, struct MHD_Response *);
static void (*real_destroy)(struct MHD_Response *);
static void (*real_clear)(PGresult *);
static int (*real_clock)(clockid_t, struct timespec *);
static int (*real_mutex_init)(pthread_mutex_t *, const pthread_mutexattr_t *);
#define ENSURE(slot, name) do { if (!(slot)) { (slot) = (void *)dlsym(RTLD_NEXT, (name)); \
    if (!(slot)) _exit(97); } } while (0)

static void trace(const char *text)
{
    size_t size = strlen(text);
    while (size) {
        ssize_t count = write(STDERR_FILENO, text, size);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) _exit(96);
        text += count;
        size -= (size_t)count;
    }
}

__attribute__((constructor)) static void initialize(void)
{
    const char *name = getenv("ASM_METRICS_TEST_FAULT");
    const char *target = getenv("ASM_METRICS_TEST_TARGET");
    if (!name || !target) _exit(97);
    if (strcmp(name, "create") == 0) mode = CREATE;
    else if (strcmp(name, "header") == 0) mode = HEADER;
    else if (strcmp(name, "queue") == 0) mode = QUEUE;
    else if (strcmp(name, "clock") == 0) mode = CLOCK;
    else if (strcmp(name, "mutex-init") == 0) mode = MUTEX_INIT;
    else _exit(97);
    if (strcmp(target, "index") == 0) index_target = 1;
    else if (strcmp(target, "about") != 0) _exit(97);
    real_create = (void *)dlsym(RTLD_NEXT, "MHD_create_response_from_buffer");
    real_header = (void *)dlsym(RTLD_NEXT, "MHD_add_response_header");
    real_queue = (void *)dlsym(RTLD_NEXT, "MHD_queue_response");
    real_destroy = (void *)dlsym(RTLD_NEXT, "MHD_destroy_response");
    real_clear = (void *)dlsym(RTLD_NEXT, "PQclear");
    real_clock = (void *)dlsym(RTLD_NEXT, "clock_gettime");
    real_mutex_init = (void *)dlsym(RTLD_NEXT, "pthread_mutex_init");
    if (!real_create || !real_header || !real_queue || !real_destroy || !real_clear ||
        !real_clock || !real_mutex_init) _exit(97);
}

static int target_response(size_t size, const void *body)
{
    static const char prefix[] = "{\"service\":\"asm-hub\"";
    if (index_target)
        return size > 16384; /* Existing owned JSON fixture is larger than16KiB. */
    return size >= sizeof prefix - 1 && memcmp(body, prefix, sizeof prefix - 1) == 0;
}

struct MHD_Response *MHD_create_response_from_buffer(size_t size, void *body,
                                                    enum MHD_ResponseMemoryMode memory)
{
    ENSURE(real_create, "MHD_create_response_from_buffer");
    int target = mode != MUTEX_INIT && !atomic_load(&fired) && target_response(size, body);
    if (target && mode == CREATE && !atomic_exchange(&fired, 1)) {
        clear_result = index_target;
        trace("asm-metrics-test: create failure\n");
        return NULL;
    }
    struct MHD_Response *response = real_create(size, body, memory);
    if (target && response)
        tracked = response;
    return response;
}

enum MHD_Result MHD_add_response_header(struct MHD_Response *response,
                                        const char *name, const char *value)
{
    ENSURE(real_header, "MHD_add_response_header");
    if (response == tracked && mode == HEADER && !atomic_exchange(&fired, 1)) {
        clear_result = index_target;
        trace("asm-metrics-test: header failure\n");
        return MHD_NO;
    }
    return real_header(response, name, value);
}

enum MHD_Result MHD_queue_response(struct MHD_Connection *connection, unsigned status,
                                   struct MHD_Response *response)
{
    ENSURE(real_queue, "MHD_queue_response");
    if (response == tracked && mode == QUEUE && !atomic_exchange(&fired, 1)) {
        clear_result = index_target;
        trace("asm-metrics-test: queue failure\n");
        return MHD_NO;
    }
    enum MHD_Result result = real_queue(connection, status, response);
    if (response == tracked && mode == CLOCK && result == MHD_YES)
        clock_armed = 1;
    return result;
}

void MHD_destroy_response(struct MHD_Response *response)
{
    ENSURE(real_destroy, "MHD_destroy_response");
    int ours = response == tracked;
    real_destroy(response);
    if (ours) {
        tracked = NULL;
        trace("asm-metrics-test: destroyed owned response\n");
        /* Arm only after the application's reference is released. The next
         * clock call belongs to asm_metrics_finish, after its queue helper. */
        if (clock_armed)
            clock_armed = 2;
    }
}

void PQclear(PGresult *result)
{
    ENSURE(real_clear, "PQclear");
    real_clear(result);
    if (clear_result) {
        clear_result = 0;
        trace("asm-metrics-test: cleared owned result\n");
    }
}

int clock_gettime(clockid_t id, struct timespec *out)
{
    ENSURE(real_clock, "clock_gettime");
    if (clock_armed == 2 && id == CLOCK_MONOTONIC && !atomic_exchange(&fired, 1)) {
        clock_armed = 0;
        errno = EIO;
        trace("asm-metrics-test: clock failure\n");
        return -1;
    }
    return real_clock(id, out);
}

int pthread_mutex_init(pthread_mutex_t *mutex, const pthread_mutexattr_t *attributes)
{
    ENSURE(real_mutex_init, "pthread_mutex_init");
    /* Only the main ELF's call is eligible. libpq/OpenSSL/MHD initialization
     * keeps its real behavior before and after asm_metrics_init. */
    if (mode == MUTEX_INIT && !atomic_load(&fired)) {
        Dl_info info;
        const char *binary = getenv("ASM_SERVER_BINARY");
        if (binary && dladdr(__builtin_return_address(0), &info) && info.dli_fname &&
            strcmp(binary, info.dli_fname) == 0 && !atomic_exchange(&fired, 1))
            return EAGAIN;
    }
    return real_mutex_init(mutex, attributes);
}
