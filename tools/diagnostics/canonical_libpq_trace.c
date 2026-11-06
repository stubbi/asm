/* SPDX-License-Identifier: AGPL-3.0-or-later
 * UNQUALIFIED qualification-only observer. Preload only the application child.
 * Adapted from the typed forwarding in reference_libpq_trace.c at 881208f.
 * No SQL, parameters, callback text, URLs, paths, pointers, or provider messages
 * are inspected or emitted. Query phases are fixed send ordinals, not SQL.
 * Each worker owns one PGconn through PQfinish. Provider-internal public API
 * calls are forwarded but excluded, including libpq16.15 constructor calls.
 * Observation errors make evidence inconclusive; provider results stay intact.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <libpq-fe.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define PREFIX "ASM_CANONICAL_TRACE="
#define ERROR_PREFIX "ASM_CANONICAL_TRACE_ERROR="
#define RECORD_BYTES 4096
#define RECORD_LIMIT 256
#define SYMBOLS(X) X(PQconnectStartParams) X(PQconnectPoll) X(PQsetNoticeProcessor) \
    X(PQsetnonblocking) X(PQsocket) X(PQsendQueryParams) X(PQflush) X(PQconsumeInput) \
    X(PQisBusy) X(PQgetResult) X(PQresultStatus) X(PQntuples) X(PQnfields) \
    X(PQgetisnull) X(PQgetlength) X(PQgetvalue) X(PQresultErrorField) X(PQfinish) X(poll)
#define DECLARE(name) static __typeof__(&name) real_##name;
SYMBOLS(DECLARE)
static pthread_once_t once = PTHREAD_ONCE_INIT;
static pthread_mutex_t output_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic unsigned int sequence, errors;
enum error_kind { SYMBOL_ERROR, OWNER_ERROR, PHASE_ERROR, BOUND_ERROR,
                  COUNT_ERROR, CLOCK_ERROR, WRITE_ERROR };
enum api { NONE, CONNECT, CONNECT_POLL, NONBLOCK, SOCKET, SEND, FLUSH, CONSUME,
           BUSY, POLL, STATUS, ROWS, FIELDS, NULL_CELL, LENGTH, GUARD, EXTRA_RESULT };
struct phase {
    uint64_t send_ns, send_cpu_ns, result_ns, result_cpu_ns, drain_ns, drain_cpu_ns;
    int send_return, results, status, rows, fields, null_cell, bytes, guard;
    char sqlstate[6];
};
struct trace {
    PGconn *owner;
    int active, invalid, finish_called, connect_return, connect_poll, nonblocking, socket;
    int sends, active_phase, first_api, first_return, first_errno;
    int poll_calls, poll_return, poll_errno, poll_events, poll_revents, poll_timeout;
    int poll_eintr, poll_timeouts, poll_errors;
    unsigned int id;
    uint64_t start_ns, start_cpu_ns, created_ns, created_cpu_ns, connect_ns, connect_cpu_ns;
    uint64_t finish_ns, finish_cpu_ns, end_ns, end_cpu_ns, poll_ns, poll_cpu_ns;
    struct phase phases[3];
};
static _Thread_local struct trace current;
static _Thread_local int provider_depth, resolving;

static void error_marker(enum error_kind kind)
{
    int saved = errno;
    static const char *const messages[] = {
        ERROR_PREFIX "symbol\n", ERROR_PREFIX "ownership\n", ERROR_PREFIX "phase\n",
        ERROR_PREFIX "record_bound\n", ERROR_PREFIX "record_count\n", ERROR_PREFIX "clock\n",
        ERROR_PREFIX "write\n" };
    unsigned int mask = 1u << (unsigned int)kind;
    if (!(atomic_fetch_or(&errors, mask) & mask)) {
        const char *message = messages[kind];
        size_t size = strlen(message), position = 0;
        for (int attempt = 0; position < size && attempt < 4; ++attempt) {
            ssize_t count = write(2, message + position, size - position);
            if (count > 0) position += (size_t)count;
            else if (count < 0 && errno == EINTR) continue;
            else break;
        }
    }
    errno = saved;
}

static uint64_t clock_ns(clockid_t clock)
{
    struct timespec value;
    if (clock_gettime(clock, &value) != 0 || value.tv_sec < 0 || value.tv_nsec < 0 ||
        value.tv_nsec >= 1000000000 || (uint64_t)value.tv_sec > INT64_MAX / 1000000000ULL ||
        ((uint64_t)value.tv_sec == INT64_MAX / 1000000000ULL &&
         (uint64_t)value.tv_nsec > INT64_MAX % 1000000000ULL)) {
        current.invalid = 1;
        error_marker(CLOCK_ERROR);
        return 0;
    }
    return (uint64_t)value.tv_sec * 1000000000ULL + (uint64_t)value.tv_nsec;
}

static void stamp(uint64_t *wall, uint64_t *cpu)
{
    *wall = clock_ns(CLOCK_MONOTONIC);
    *cpu = clock_ns(CLOCK_THREAD_CPUTIME_ID);
}

static void resolve(void)
{
    resolving = 1;
#define LOAD(name) do { real_##name = (__typeof__(&name))dlsym(RTLD_NEXT, #name); \
    if (!real_##name) { error_marker(SYMBOL_ERROR); _exit(125); } } while (0);
    SYMBOLS(LOAD)
#undef LOAD
    resolving = 0;
}

static void ready(void)
{
    if (resolving) { error_marker(SYMBOL_ERROR); _exit(125); }
    if (pthread_once(&once, resolve) != 0) { error_marker(SYMBOL_ERROR); _exit(125); }
}

static int owner(PGconn *connection)
{
    if (provider_depth) return 0;
    if (!current.active || connection != current.owner) {
        current.invalid = 1;
        error_marker(OWNER_ERROR);
        return 0;
    }
    return 1;
}

static void bump(int *counter)
{
    if (*counter == INT_MAX) { current.invalid = 1; error_marker(BOUND_ERROR); }
    else ++*counter;
}

static void adverse(enum api api, int result, int saved_errno)
{
    if (!current.first_api) {
        current.first_api = api;
        current.first_return = result;
        current.first_errno = saved_errno;
    }
}

static struct phase *phase(void)
{
    if (current.active_phase < 1 || current.active_phase > 3) {
        current.invalid = 1;
        error_marker(PHASE_ERROR);
        return NULL;
    }
    return &current.phases[current.active_phase - 1];
}

static void emit(void)
{
    int saved = errno;
    char out[RECORD_BYTES];
    if (current.invalid || current.id > RECORD_LIMIT) { errno = saved; return; }
    int used = snprintf(out, sizeof out, PREFIX
        "{\"schema\":1,\"id\":%u,\"route\":0,\"start_ns\":%" PRIu64 ",\"start_cpu_ns\":%" PRIu64
        ",\"created_ns\":%" PRIu64 ",\"created_cpu_ns\":%" PRIu64 ",\"connect_ns\":%" PRIu64 ",\"connect_cpu_ns\":%" PRIu64
        ",\"finish_ns\":%" PRIu64 ",\"finish_cpu_ns\":%" PRIu64 ",\"end_ns\":%" PRIu64 ",\"end_cpu_ns\":%" PRIu64
        ",\"finish_called\":%d,\"connect_return\":%d,\"connect_poll\":%d,\"nonblocking\":%d,\"socket\":%d,\"sends\":%d,\"active_phase\":%d"
        ",\"first_api\":%d,\"first_return\":%d,\"first_errno\":%d,\"poll_calls\":%d,\"poll_ns\":%" PRIu64 ",\"poll_cpu_ns\":%" PRIu64
        ",\"poll_return\":%d,\"poll_errno\":%d,\"poll_events\":%d,\"poll_revents\":%d,\"poll_timeout\":%d"
        ",\"poll_eintr\":%d,\"poll_timeouts\":%d,\"poll_errors\":%d,\"phases\":[",
        current.id, current.start_ns, current.start_cpu_ns, current.created_ns, current.created_cpu_ns,
        current.connect_ns, current.connect_cpu_ns, current.finish_ns, current.finish_cpu_ns,
        current.end_ns, current.end_cpu_ns, current.finish_called, current.connect_return,
        current.connect_poll, current.nonblocking, current.socket, current.sends, current.active_phase,
        current.first_api, current.first_return, current.first_errno, current.poll_calls, current.poll_ns,
        current.poll_cpu_ns, current.poll_return, current.poll_errno, current.poll_events,
        current.poll_revents, current.poll_timeout, current.poll_eintr, current.poll_timeouts, current.poll_errors);
    if (used <= 0 || (size_t)used >= sizeof out) goto bound;
    for (int i = 0; i < 3; ++i) {
        struct phase *p = &current.phases[i];
        int count = snprintf(out + used, sizeof out - (size_t)used,
            "%s{\"ordinal\":%d,\"send_ns\":%" PRIu64 ",\"send_cpu_ns\":%" PRIu64
            ",\"result_ns\":%" PRIu64 ",\"result_cpu_ns\":%" PRIu64 ",\"drain_ns\":%" PRIu64 ",\"drain_cpu_ns\":%" PRIu64
            ",\"send_return\":%d,\"results\":%d,\"status\":%d,\"rows\":%d,\"fields\":%d,\"null_cell\":%d"
            ",\"bytes\":%d,\"guard\":%d,\"sqlstate\":\"%s\"}",
            i ? "," : "", i + 1, p->send_ns, p->send_cpu_ns, p->result_ns, p->result_cpu_ns,
            p->drain_ns, p->drain_cpu_ns, p->send_return, p->results, p->status, p->rows,
            p->fields, p->null_cell, p->bytes, p->guard, p->sqlstate);
        if (count <= 0 || (size_t)count >= sizeof out - (size_t)used) goto bound;
        used += count;
    }
    if (sizeof out - (size_t)used <= 3) goto bound;
    memcpy(out + used, "]}\n", 3);
    used += 3;
    int failed = 0;
    if (pthread_mutex_lock(&output_lock) != 0) failed = 1;
    else {
        size_t position = 0;
        for (int attempt = 0; position < (size_t)used && attempt < 4; ++attempt) {
            ssize_t count = write(2, out + position, (size_t)used - position);
            if (count > 0) position += (size_t)count;
            else if (count < 0 && errno == EINTR) continue;
            else break;
        }
        failed = position != (size_t)used;
        if (pthread_mutex_unlock(&output_lock) != 0) failed = 1;
    }
    if (failed) error_marker(WRITE_ERROR);
    errno = saved;
    return;
bound:
    error_marker(BOUND_ERROR);
    errno = saved;
}

PGconn *PQconnectStartParams(const char *const *keys, const char *const *values, int expand)
{
    int incoming = errno; ready();
    if (provider_depth) {
        errno = incoming; ++provider_depth;
        PGconn *result = real_PQconnectStartParams(keys, values, expand); int saved = errno;
        --provider_depth; errno = saved; return result;
    }
    if (current.active) error_marker(OWNER_ERROR);
    memset(&current, 0, sizeof current);
    current.active = 1;
    current.id = atomic_fetch_add(&sequence, 1) + 1;
    current.connect_poll = -1;
    current.nonblocking = current.socket = current.poll_return = current.poll_timeout = -2;
    for (int i = 0; i < 3; ++i) {
        struct phase *p = &current.phases[i];
        p->send_return = p->status = p->rows = p->fields = p->null_cell = p->bytes = p->guard = -1;
    }
    if (current.id > RECORD_LIMIT) { current.invalid = 1; error_marker(COUNT_ERROR); }
    stamp(&current.start_ns, &current.start_cpu_ns);
    errno = incoming; ++provider_depth;
    PGconn *result = real_PQconnectStartParams(keys, values, expand); int saved = errno;
    --provider_depth;
    current.owner = result;
    current.connect_return = result != NULL;
    stamp(&current.created_ns, &current.created_cpu_ns);
    if (!result) {
        adverse(CONNECT, 0, saved);
        stamp(&current.end_ns, &current.end_cpu_ns);
        emit(); current.active = 0;
    }
    errno = saved; return result;
}

PostgresPollingStatusType PQconnectPoll(PGconn *connection)
{
    int incoming = errno; ready(); int observed = owner(connection); errno = incoming;
    ++provider_depth;
    PostgresPollingStatusType result = real_PQconnectPoll(connection); int saved = errno;
    --provider_depth;
    if (observed) {
        current.connect_poll = result;
        if (result == PGRES_POLLING_OK) stamp(&current.connect_ns, &current.connect_cpu_ns);
        else if (result == PGRES_POLLING_FAILED) adverse(CONNECT_POLL, result, saved);
    }
    errno = saved; return result;
}

PQnoticeProcessor PQsetNoticeProcessor(PGconn *connection, PQnoticeProcessor processor, void *closure)
{
    int incoming = errno; ready(); (void)owner(connection); errno = incoming;
    ++provider_depth;
    PQnoticeProcessor result = real_PQsetNoticeProcessor(connection, processor, closure); int saved = errno;
    --provider_depth; errno = saved; return result;
}

int PQsetnonblocking(PGconn *connection, int enabled)
{
    int incoming = errno; ready(); int observed = owner(connection); errno = incoming;
    ++provider_depth; int result = real_PQsetnonblocking(connection, enabled); int saved = errno;
    --provider_depth;
    if (observed) { current.nonblocking = result; if (result) adverse(NONBLOCK, result, saved); }
    errno = saved; return result;
}

int PQsocket(const PGconn *connection)
{
    int incoming = errno; ready(); int observed = owner((PGconn *)connection); errno = incoming;
    ++provider_depth; int result = real_PQsocket(connection); int saved = errno;
    --provider_depth;
    if (observed) { current.socket = result; if (result < 0) adverse(SOCKET, result, saved); }
    errno = saved; return result;
}

int PQsendQueryParams(PGconn *connection, const char *sql, int count, const Oid *types,
    const char *const *values, const int *lengths, const int *formats, int result_format)
{
    int incoming = errno; ready(); int observed = owner(connection);
    struct phase *p = NULL;
    if (observed) {
        if (current.sends >= 3 || (current.sends && !current.phases[current.sends - 1].drain_ns)) {
            current.invalid = 1; error_marker(PHASE_ERROR);
        } else {
            ++current.sends; current.active_phase = current.sends;
            p = phase(); stamp(&p->send_ns, &p->send_cpu_ns);
        }
    }
    errno = incoming; ++provider_depth;
    int result = real_PQsendQueryParams(connection, sql, count, types, values, lengths, formats, result_format); int saved = errno;
    --provider_depth;
    if (p) { p->send_return = result; if (result != 1) adverse(SEND, result, saved); }
    errno = saved; return result;
}

int PQflush(PGconn *connection)
{
    int incoming = errno; ready(); int observed = owner(connection); errno = incoming;
    ++provider_depth; int result = real_PQflush(connection); int saved = errno; --provider_depth;
    if (observed && result < 0) adverse(FLUSH, result, saved);
    errno = saved; return result;
}

int PQconsumeInput(PGconn *connection)
{
    int incoming = errno; ready(); int observed = owner(connection); errno = incoming;
    ++provider_depth; int result = real_PQconsumeInput(connection); int saved = errno; --provider_depth;
    if (observed && result != 1) adverse(CONSUME, result, saved);
    errno = saved; return result;
}

int PQisBusy(PGconn *connection)
{
    int incoming = errno; ready(); int observed = owner(connection); errno = incoming;
    ++provider_depth; int result = real_PQisBusy(connection); int saved = errno; --provider_depth;
    if (observed && result != 0 && result != 1) adverse(BUSY, result, saved);
    errno = saved; return result;
}

PGresult *PQgetResult(PGconn *connection)
{
    int incoming = errno; ready(); int observed = owner(connection); errno = incoming;
    ++provider_depth; PGresult *result = real_PQgetResult(connection); int saved = errno; --provider_depth;
    if (observed) {
        struct phase *p = phase();
        if (p && !result) stamp(&p->drain_ns, &p->drain_cpu_ns);
        else if (p) {
            bump(&p->results);
            if (p->results > 1) adverse(EXTRA_RESULT, p->results, saved);
            else {
                stamp(&p->result_ns, &p->result_cpu_ns);
                p->status = real_PQresultStatus(result);
                p->rows = real_PQntuples(result);
                p->fields = real_PQnfields(result);
                int expected = current.active_phase == 1 ? PGRES_COMMAND_OK : PGRES_TUPLES_OK;
                if (p->status != expected) adverse(STATUS, p->status, saved);
                else if (current.active_phase != 1 && p->rows != 1) adverse(ROWS, p->rows, saved);
                else if (current.active_phase != 1 && p->fields != 1) adverse(FIELDS, p->fields, saved);
                const char *state = real_PQresultErrorField(result, PG_DIAG_SQLSTATE);
                if (state && strnlen(state, 6) == 5) {
                    int valid = 1;
                    for (int i = 0; i < 5; ++i)
                        if (!((state[i] >= '0' && state[i] <= '9') || (state[i] >= 'A' && state[i] <= 'Z'))) valid = 0;
                    if (valid) memcpy(p->sqlstate, state, 5);
                }
                if (p->status == PGRES_TUPLES_OK && p->rows == 1 && p->fields == 1) {
                    p->null_cell = real_PQgetisnull(result, 0, 0);
                    p->bytes = real_PQgetlength(result, 0, 0);
                    if (p->null_cell) adverse(NULL_CELL, p->null_cell, saved);
                    else if (p->bytes <= 0 || p->bytes > 4194304) adverse(LENGTH, p->bytes, saved);
                    else if (current.active_phase == 2) {
                        if (p->bytes == 1) {
                            const char *value = real_PQgetvalue(result, 0, 0);
                            if (value && value[1] == '\0' && (value[0] == '0' || value[0] == '1')) p->guard = value[0] - '0';
                        }
                        if (p->guard != 1) adverse(GUARD, p->guard, saved);
                    }
                }
            }
        }
    }
    errno = saved; return result;
}

void PQfinish(PGconn *connection)
{
    int incoming = errno; ready(); int observed = owner(connection);
    if (observed) { current.finish_called = 1; stamp(&current.finish_ns, &current.finish_cpu_ns); }
    errno = incoming; ++provider_depth; real_PQfinish(connection); int saved = errno; --provider_depth;
    if (observed) { stamp(&current.end_ns, &current.end_cpu_ns); emit(); current.active = 0; current.owner = NULL; }
    errno = saved;
}

int poll(struct pollfd *fds, nfds_t count, int timeout)
{
    int incoming = errno; ready(); int observed = current.active && !provider_depth;
    uint64_t start = 0, cpu = 0;
    if (observed) stamp(&start, &cpu);
    errno = incoming; ++provider_depth; int result = real_poll(fds, count, timeout); int saved = errno; --provider_depth;
    if (observed) {
        uint64_t end, end_cpu; stamp(&end, &end_cpu); bump(&current.poll_calls);
        if (end >= start && current.poll_ns <= INT64_MAX - (end - start) && end_cpu >= cpu && current.poll_cpu_ns <= INT64_MAX - (end_cpu - cpu)) {
            current.poll_ns += end - start;
            current.poll_cpu_ns += end_cpu - cpu;
        } else { current.invalid = 1; error_marker(CLOCK_ERROR); }
        current.poll_return = result;
        current.poll_errno = result < 0 ? saved : 0;
        current.poll_timeout = timeout;
        current.poll_events = count == 1 && fds ? (unsigned short)fds[0].events : 0;
        current.poll_revents = count == 1 && fds ? (unsigned short)fds[0].revents : 0;
        if (result < 0) { bump(&current.poll_errors); if (saved == EINTR) bump(&current.poll_eintr); }
        if (result == 0) bump(&current.poll_timeouts);
        if (result <= 0 || (current.poll_revents & (POLLERR | POLLHUP | POLLNVAL))) adverse(POLL, result, saved);
    }
    errno = saved; return result;
}
