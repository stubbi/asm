/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Native test executable only. Never link this file into the HTTP runtime.
 * Link the reviewed metrics assembly with ASM_METRICS_TEST and --wrap for
 * clock_gettime and pthread_mutex_init/lock/unlock. No fixture runs a compiler.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

struct request {
    uint64_t start_ns;
    uint32_t route;
    uint32_t clock_valid;
};
_Static_assert(sizeof(struct request) == 16 && offsetof(struct request, route) == 8 &&
               offsetof(struct request, clock_valid) == 12, "request test ABI");

extern int asm_metrics_init(void);
extern void asm_metrics_destroy(void);
extern uint32_t asm_metrics_route(const char *);
extern void asm_metrics_begin(struct request *);
extern int asm_metrics_finish(struct request *, uint32_t, int);
extern ssize_t asm_metrics_render(char *, size_t);
extern void asm_metrics_test_seed(const uint64_t *);
extern void asm_metrics_test_snapshot(uint64_t *);

extern int __real_clock_gettime(clockid_t, struct timespec *);
extern int __real_pthread_mutex_init(pthread_mutex_t *, const pthread_mutexattr_t *);
extern int __real_pthread_mutex_lock(pthread_mutex_t *);
extern int __real_pthread_mutex_unlock(pthread_mutex_t *);

enum { ROUTES = 6, ROW = 13, WORDS = 79, CAPACITY = 16384, WORKERS = 16, EVENTS = 150 };
static const char *const route_names[] = {"live", "ready", "about", "index", "metrics", "other"};
static const char *const classes[] = {"2xx", "4xx", "5xx"};
static const char *const bucket_names[] = {"0.005", "0.01", "0.05", "0.1", "0.5", "1", "2", "+Inf"};
static const uint64_t bucket_ns[] = {5000000, 10000000, 50000000, 100000000,
                                   500000000, 1000000000, 2000000000, UINT64_MAX};
static const char *current_case;
static _Thread_local int scripted, clock_index, clock_fail_at;
static _Thread_local struct timespec clock_pair[2];
static int fail_init, fail_lock, fail_unlock;

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "metrics test %s: %s:%d: %s\n", current_case, __FILE__, __LINE__, #condition); \
    exit(1); } } while (0)

int __wrap_clock_gettime(clockid_t id, struct timespec *out)
{
    CHECK(id == CLOCK_MONOTONIC);
    if (!scripted)
        return __real_clock_gettime(id, out);
    int index = clock_index++;
    CHECK(index < 2);
    if (index == clock_fail_at) {
        errno = EIO;
        return -1;
    }
    *out = clock_pair[index];
    return 0;
}

int __wrap_pthread_mutex_init(pthread_mutex_t *mutex, const pthread_mutexattr_t *attr)
{
    return fail_init ? EAGAIN : __real_pthread_mutex_init(mutex, attr);
}

int __wrap_pthread_mutex_lock(pthread_mutex_t *mutex)
{
    return fail_lock ? EINVAL : __real_pthread_mutex_lock(mutex);
}

int __wrap_pthread_mutex_unlock(pthread_mutex_t *mutex)
{
    return fail_unlock ? EINVAL : __real_pthread_mutex_unlock(mutex);
}

static void script(uint64_t start, uint64_t end)
{
    scripted = 1;
    clock_index = 0;
    clock_fail_at = -1;
    clock_pair[0] = (struct timespec){(time_t)(start / 1000000000), (long)(start % 1000000000)};
    clock_pair[1] = (struct timespec){(time_t)(end / 1000000000), (long)(end % 1000000000)};
}

static void reset(void)
{
    uint64_t empty[WORDS] = {0};
    scripted = 0;
    asm_metrics_test_seed(empty);
}

static void event(uint32_t route, uint32_t status, int queued, uint64_t elapsed)
{
    struct request request;
    script(0, elapsed);
    asm_metrics_begin(&request);
    CHECK(request.clock_valid == 1 && request.start_ns == 0 && request.route == 5);
    request.route = route;
    CHECK(asm_metrics_finish(&request, status, queued) == queued);
    scripted = 0;
}

static void render(char buffer[CAPACITY + 1])
{
    ssize_t size = asm_metrics_render(buffer, CAPACITY);
    CHECK(size > 0 && size <= CAPACITY);
    buffer[size] = '\0';
    CHECK(buffer[size - 1] == '\n');
}

static const char *sample(const char *body, const char *name, const char *route,
                          const char *label, const char *value)
{
    char key[192];
    int size;
    if (!route)
        size = snprintf(key, sizeof key, "%s ", name);
    else if (!label)
        size = snprintf(key, sizeof key, "%s{route=\"%s\"} ", name, route);
    else
        size = snprintf(key, sizeof key, "%s{route=\"%s\",%s=\"%s\"} ", name, route, label, value);
    CHECK(size > 0 && (size_t)size < sizeof key);
    const char *found = strstr(body, key);
    CHECK(found && (found == body || found[-1] == '\n'));
    CHECK(!strstr(found + size, key));
    return found + size;
}

static uint64_t integer_sample(const char *body, const char *name, const char *route,
                               const char *label, const char *value)
{
    const char *start = sample(body, name, route, label, value);
    char *end;
    errno = 0;
    unsigned long long number = strtoull(start, &end, 10);
    CHECK(start[0] >= '0' && start[0] <= '9' && errno == 0 && *end == '\n');
    return (uint64_t)number;
}

/* Independent fixed-schema check. It does not read the aggregate test hook. */
static void coherent(const char *body)
{
    size_t lines = 0;
    for (const char *line = body; *line;) {
        if (*line != '#')
            ++lines;
        const char *next = strchr(line, '\n');
        CHECK(next);
        line = next + 1;
    }
    CHECK(lines == 79);
    for (size_t route = 0; route < ROUTES; ++route) {
        uint64_t count = integer_sample(body, "asm_http_request_duration_seconds_count", route_names[route], NULL, NULL);
        uint64_t total = 0, previous = 0;
        for (size_t status = 0; status < 3; ++status) {
            uint64_t value = integer_sample(body, "asm_http_requests_total", route_names[route], "status_class", classes[status]);
            CHECK(UINT64_MAX - total >= value);
            total += value;
        }
        CHECK(total == count);
        for (size_t bucket = 0; bucket < 8; ++bucket) {
            uint64_t value = integer_sample(body, "asm_http_request_duration_seconds_bucket", route_names[route], "le", bucket_names[bucket]);
            CHECK(previous <= value && value <= count);
            previous = value;
        }
        CHECK(previous == count);
        const char *sum = sample(body, "asm_http_request_duration_seconds_sum", route_names[route], NULL, NULL);
        char *end;
        errno = 0;
        long double value = strtold(sum, &end);
        CHECK(errno == 0 && value >= 0 && *end == '\n');
        if (count == 0)
            CHECK(value == 0);
    }
    (void)integer_sample(body, "asm_http_connection_failures_total", NULL, NULL, NULL);
}

static void zero_exposition(void)
{
    reset();
    char body[CAPACITY + 1];
    render(body);
    coherent(body);
    CHECK(strstr(body, "# TYPE asm_http_requests_total counter\n"));
    CHECK(strstr(body, "# TYPE asm_http_request_duration_seconds histogram\n"));
    CHECK(strstr(body, "# TYPE asm_http_connection_failures_total counter\n"));
    uint64_t actual[WORDS];
    asm_metrics_test_snapshot(actual);
    for (size_t index = 0; index < WORDS; ++index)
        CHECK(actual[index] == 0);
    for (size_t route = 0; route < ROUTES; ++route)
        CHECK(integer_sample(body, "asm_http_request_duration_seconds_count", route_names[route], NULL, NULL) == 0);
}

static void route_classification(void)
{
    static const struct { const char *path; uint32_t route; } cases[] = {
        {"/health/live", 0}, {"/health/ready", 1}, {"/api/v2/status", 2},
        {"/registry/v1/index.tsv", 3}, {"/registry/v1/index-macos.tsv", 3},
        {"/registry/v1/index-all.tsv", 3}, {"/registry/v1/index.json", 3},
        {"/metrics", 4}, {"", 5}, {"/metrics/", 5}, {"/METRICS", 5},
        {"/registry/v1/index.json/untrusted-account", 5}, {"/untrusted-package", 5}
    };
    for (size_t index = 0; index < sizeof cases / sizeof cases[0]; ++index)
        CHECK(asm_metrics_route(cases[index].path) == cases[index].route);
}

static void bucket_boundaries(void)
{
    for (size_t boundary = 0; boundary < 7; ++boundary) {
        for (int delta = -1; delta <= 1; ++delta) {
            reset();
            uint64_t elapsed = bucket_ns[boundary] + (uint64_t)delta;
            event(3, 503, 1, elapsed);
            uint64_t actual[WORDS];
            asm_metrics_test_snapshot(actual);
            for (size_t bucket = 0; bucket < 8; ++bucket)
                CHECK(actual[3 * ROW + 3 + bucket] == (elapsed <= bucket_ns[bucket]));
            CHECK(actual[3 * ROW + 2] == 1 && actual[3 * ROW + 11] == elapsed && actual[3 * ROW + 12] == 1);
        }
    }
}

static void decimal_sum_and_capacity(void)
{
    reset();
    event(2, 200, 1, UINT64_C(1234567890));
    char body[CAPACITY + 1];
    render(body);
    CHECK(strncmp(sample(body, "asm_http_request_duration_seconds_sum", "about", NULL, NULL), "1.234567890\n", 12) == 0);
    reset();
    uint64_t maximum[WORDS];
    for (size_t index = 0; index < WORDS; ++index)
        maximum[index] = UINT64_MAX;
    asm_metrics_test_seed(maximum);
    render(body);
    CHECK(strlen(body) < CAPACITY);
    CHECK(strncmp(sample(body, "asm_http_request_duration_seconds_sum", "about", NULL, NULL),
                  "18446744073.709551615\n", 22) == 0);
    unsigned char guarded[66];
    memset(guarded, 0xa5, sizeof guarded);
    CHECK(asm_metrics_render((char *)guarded + 1, 64) == -1);
    CHECK(guarded[0] == 0xa5 && guarded[65] == 0xa5);
    reset();
}

static void queue_failure(void)
{
    reset();
    event(3, 200, 0, 1);
    uint64_t actual[WORDS];
    asm_metrics_test_snapshot(actual);
    for (size_t index = 0; index < WORDS - 1; ++index)
        CHECK(actual[index] == 0);
    CHECK(actual[WORDS - 1] == 1);
    char body[CAPACITY + 1];
    render(body);
    coherent(body);
}

static atomic_uint ready, go, completed, midpoint, sampled_midpoint, snapshots;

static void *writer(void *argument)
{
    size_t worker = (size_t)(uintptr_t)argument;
    atomic_fetch_add(&ready, 1);
    while (!atomic_load(&go))
        sched_yield();
    for (size_t index = 0; index < EVENTS; ++index) {
        event(3, (uint32_t[]){200, 404, 503}[index % 3], 1, 1000000);
        if (worker == 0 && index == EVENTS / 2) {
            atomic_store(&midpoint, 1);
            while (!atomic_load(&sampled_midpoint))
                sched_yield();
        }
    }
    atomic_fetch_add(&completed, 1);
    return NULL;
}

static void *reader(void *argument)
{
    (void)argument;
    char body[CAPACITY + 1];
    atomic_fetch_add(&ready, 1);
    while (!atomic_load(&go))
        sched_yield();
    while (atomic_load(&completed) != WORKERS) {
        render(body);
        coherent(body);
        atomic_fetch_add(&snapshots, 1);
        if (atomic_load(&midpoint))
            atomic_store(&sampled_midpoint, 1);
    }
    return NULL;
}

static void parallel_snapshot(void)
{
    reset();
    atomic_store(&ready, 0); atomic_store(&go, 0); atomic_store(&completed, 0);
    atomic_store(&midpoint, 0); atomic_store(&sampled_midpoint, 0); atomic_store(&snapshots, 0);
    pthread_t workers[WORKERS], observer;
    CHECK(pthread_create(&observer, NULL, reader, NULL) == 0);
    for (size_t index = 0; index < WORKERS; ++index)
        CHECK(pthread_create(&workers[index], NULL, writer, (void *)(uintptr_t)index) == 0);
    while (atomic_load(&ready) != WORKERS + 1)
        sched_yield();
    atomic_store(&go, 1);
    for (size_t index = 0; index < WORKERS; ++index)
        CHECK(pthread_join(workers[index], NULL) == 0);
    CHECK(pthread_join(observer, NULL) == 0);
    CHECK(atomic_load(&snapshots) > 0 && atomic_load(&sampled_midpoint) == 1);
    uint64_t actual[WORDS];
    asm_metrics_test_snapshot(actual);
    for (size_t index = 0; index < 3; ++index)
        CHECK(actual[3 * ROW + index] == WORKERS * EVENTS / 3);
    CHECK(actual[3 * ROW + 12] == WORKERS * EVENTS);
    CHECK(actual[3 * ROW + 11] == UINT64_C(1000000) * WORKERS * EVENTS);
    char body[CAPACITY + 1];
    render(body);
    coherent(body);
}

static void unavailable_unchanged(const uint64_t before[WORDS])
{
    char body[CAPACITY + 1];
    CHECK(asm_metrics_render(body, CAPACITY) == -1);
    uint64_t after[WORDS];
    asm_metrics_test_snapshot(after);
    CHECK(memcmp(before, after, sizeof after) == 0);
    /* A later valid event cannot repair a lost observation silently. */
    event(0, 200, 1, 1);
    CHECK(asm_metrics_render(body, CAPACITY) == -1);
    asm_metrics_test_snapshot(after);
    CHECK(memcmp(before, after, sizeof after) == 0);
}

static void clock_fault(int fail_at, int invalid)
{
    reset();
    uint64_t before[WORDS] = {0};
    struct request request;
    script(10, 20);
    clock_fail_at = fail_at;
    int endpoint = invalid >= 10;
    int kind = invalid % 10;
    if (kind == 1) clock_pair[endpoint].tv_sec = -1;
    if (kind == 2) clock_pair[endpoint].tv_nsec = -1;
    if (kind == 3) clock_pair[endpoint].tv_nsec = 1000000000;
    if (kind == 4) clock_pair[endpoint].tv_sec = (time_t)INT64_MAX;
    if (kind == 5) clock_pair[1].tv_nsec = 9;
    if (kind == 6) {
        clock_pair[endpoint].tv_sec = (time_t)UINT64_C(18446744073);
        clock_pair[endpoint].tv_nsec = 709551616;
    }
    asm_metrics_begin(&request);
    request.route = 3;
    CHECK(asm_metrics_finish(&request, 200, 1) == 1);
    scripted = 0;
    unavailable_unchanged(before);
}

static void clock_failure_begin(void) { clock_fault(0, 0); }
static void clock_failure_finish(void) { clock_fault(1, 0); }
static void clock_invalid_timespec(void)
{
    for (int kind = 1; kind <= 3; ++kind) {
        clock_fault(-1, kind);
        clock_fault(-1, kind + 10);
    }
}
static void clock_conversion_overflow(void)
{
    clock_fault(-1, 4);
    clock_fault(-1, 14);
    clock_fault(-1, 6);
    clock_fault(-1, 16);
}
static void clock_backwards(void) { clock_fault(-1, 5); }

static void overflow_at(size_t field, int queued)
{
    reset();
    uint64_t before[WORDS] = {0};
    before[field] = UINT64_MAX;
    asm_metrics_test_seed(before);
    event(3, 200, queued, 1);
    unavailable_unchanged(before);
}
static void overflow_count(void) { overflow_at(3 * ROW + 12, 1); }
static void overflow_request_counter(void) { overflow_at(3 * ROW, 1); }
static void overflow_bucket(void) { overflow_at(3 * ROW + 3, 1); }
static void overflow_sum(void) { overflow_at(3 * ROW + 11, 1); }
static void overflow_queue_failure(void) { overflow_at(WORDS - 1, 0); }

static void mutex_init_failure(void)
{
    asm_metrics_destroy();
    fail_init = 1;
    CHECK(asm_metrics_init() == 0);
    fail_init = 0;
    CHECK(asm_metrics_init() == 1);
}

static void fatal_mutex(int unlock)
{
    int descriptors[2];
    CHECK(pipe(descriptors) == 0);
    pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        close(descriptors[0]);
        if (dup2(descriptors[1], STDERR_FILENO) < 0)
            _exit(99);
        close(descriptors[1]);
        alarm(3);
        fail_lock = !unlock;
        fail_unlock = unlock;
        char body[CAPACITY + 1];
        (void)asm_metrics_render(body, CAPACITY);
        _exit(98);
    }
    close(descriptors[1]);
    char output[256];
    size_t size = 0;
    for (;;) {
        ssize_t count = read(descriptors[0], output + size, sizeof output - size);
        if (count < 0 && errno == EINTR) continue;
        CHECK(count >= 0);
        if (!count) break;
        size += (size_t)count;
        CHECK(size < sizeof output);
    }
    close(descriptors[0]);
    int status;
    pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    CHECK(waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 71);
    static const char expected[] = "asm-hub: request metrics synchronization failed.\n";
    CHECK(size == sizeof expected - 1 && memcmp(output, expected, size) == 0);
}
static void mutex_lock_failure(void) { fatal_mutex(0); }
static void mutex_unlock_failure(void) { fatal_mutex(1); }

int main(void)
{
    static const struct { const char *name; void (*run)(void); } cases[] = {
        {"zero_exposition", zero_exposition}, {"route_classification", route_classification},
        {"bucket_boundaries", bucket_boundaries}, {"decimal_sum_and_capacity", decimal_sum_and_capacity},
        {"queue_failure", queue_failure}, {"parallel_snapshot", parallel_snapshot},
        {"clock_failure_begin", clock_failure_begin}, {"clock_failure_finish", clock_failure_finish},
        {"clock_invalid_timespec", clock_invalid_timespec}, {"clock_conversion_overflow", clock_conversion_overflow},
        {"clock_backwards", clock_backwards}, {"overflow_count", overflow_count},
        {"overflow_request_counter", overflow_request_counter},
        {"overflow_bucket", overflow_bucket}, {"overflow_sum", overflow_sum},
        {"overflow_queue_failure", overflow_queue_failure}, {"mutex_init_failure", mutex_init_failure},
        {"mutex_lock_failure", mutex_lock_failure}, {"mutex_unlock_failure", mutex_unlock_failure}
    };
    alarm(30);
    current_case = "initialization";
    CHECK(asm_metrics_init() == 1);
    for (size_t index = 0; index < sizeof cases / sizeof cases[0]; ++index) {
        current_case = cases[index].name;
        cases[index].run();
    }
    asm_metrics_destroy();
    fputs("{\"schema\":1,\"status\":\"pass\",\"scope\":\"assembly-metrics-unit\",\"checks\":[", stdout);
    for (size_t index = 0; index < sizeof cases / sizeof cases[0]; ++index)
        printf("%s\"%s\"", index ? "," : "", cases[index].name);
    puts("]}");
    return 0;
}
