/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Diagnostic interposer only. Never linked into or copied into the runtime.
 * Forward arguments/results unchanged; emit one bounded numeric connection
 * summary at PQfinish. Do not print SQL, parameters, libpq errors, or paths.
 * Timings include this interposer's overhead and are not qualification.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <libpq-fe.h>

#define SYMBOLS(X) X(PQconnectStartParams) X(PQconnectPoll) X(PQsslInUse) \
    X(PQsetnonblocking) X(PQsendQueryParams) X(PQflush) X(PQconsumeInput) \
    X(PQgetResult) X(PQresultStatus) X(PQntuples) X(PQnfields) X(PQgetisnull) \
    X(PQgetlength) X(PQgetvalue) X(PQresultErrorField) X(PQfinish) X(poll)
#define DECLARE(name) static __typeof__(&name) real_##name;
SYMBOLS(DECLARE)
static pthread_once_t once = PTHREAD_ONCE_INIT;
static _Atomic uint64_t sequence;

struct phase {
    uint64_t sent, received, drained;
    int send_result, results, status, rows, fields, null_cell, bytes, guard_one;
    char sqlstate[6];
};
struct trace {
    int active, phase, sends, route, connect_poll, tls, nonblocking;
    int flush_result, consume_result, poll_result, poll_errno, poll_revents, poll_timeout;
    uint64_t id, start, connected, before_finish, after_finish, polls, poll_ns;
    struct phase phases[3];
};
static _Thread_local struct trace current;

static uint64_t now_ns(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * 1000000000 + (uint64_t)value.tv_nsec;
}
static void resolve(void) {
#define LOAD(name) do { real_##name = (__typeof__(&name))dlsym(RTLD_NEXT, #name); \
    if (!real_##name) { const char msg[] = "ASM_LIBPQ_TRACE_ERROR=symbol_resolution\n"; \
        (void)write(2, msg, sizeof(msg)-1); _exit(125); } } while (0);
    SYMBOLS(LOAD)
#undef LOAD
}
static void ready(void) { pthread_once(&once, resolve); }
static uint64_t elapsed(uint64_t end) {
    return end >= current.start ? (end-current.start)/1000 : 0;
}
static void emit(void) {
    int saved = errno;
    char out[3072];
    int used = snprintf(out, sizeof(out),
        "ASM_LIBPQ_TRACE={\"id\":%" PRIu64 ",\"start_ns\":%" PRIu64
        ",\"connected_us\":%" PRIu64 ",\"before_finish_us\":%" PRIu64
        ",\"after_finish_us\":%" PRIu64 ",\"connect_poll\":%d,\"tls\":%d,"
        "\"nonblocking\":%d,\"sends\":%d,\"route\":%d,\"flush_result\":%d,"
        "\"consume_result\":%d,\"polls\":%" PRIu64 ",\"poll_us\":%" PRIu64
        ",\"poll_result\":%d,\"poll_errno\":%d,\"poll_revents\":%d,\"poll_timeout_ms\":%d,\"phases\":[",
        current.id, current.start, elapsed(current.connected), elapsed(current.before_finish),
        elapsed(current.after_finish), current.connect_poll, current.tls, current.nonblocking,
        current.sends, current.route, current.flush_result, current.consume_result, current.polls,
        current.poll_ns/1000, current.poll_result, current.poll_errno, current.poll_revents, current.poll_timeout);
    for (int i=0; i<3 && used>0 && (size_t)used<sizeof(out); ++i) {
        struct phase *p = &current.phases[i];
        int n = snprintf(out+used, sizeof(out)-(size_t)used,
            "%s{\"phase\":%d,\"sent_us\":%" PRIu64 ",\"received_us\":%" PRIu64 ",\"drained_us\":%" PRIu64
            ",\"send_result\":%d,\"results\":%d,\"status\":%d,\"rows\":%d,"
            "\"fields\":%d,\"null_cell\":%d,\"bytes\":%d,\"guard_one\":%d,\"sqlstate\":\"%s\"}",
            i ? "," : "", i, elapsed(p->sent), elapsed(p->received), elapsed(p->drained), p->send_result,
            p->results, p->status, p->rows, p->fields, p->null_cell, p->bytes, p->guard_one, p->sqlstate);
        if (n<0 || (size_t)n>=sizeof(out)-(size_t)used) { used=-1; break; }
        used += n;
    }
    if (used>0 && (size_t)used+3<sizeof(out)) {
        memcpy(out+used, "]}\n", 3);
        (void)write(2, out, (size_t)used+3);
    } else {
        const char msg[] = "ASM_LIBPQ_TRACE_ERROR=record_bound\n";
        (void)write(2, msg, sizeof(msg)-1);
    }
    errno = saved;
}

PGconn *PQconnectStartParams(const char *const *keys, const char *const *values, int expand) {
    ready(); memset(&current, 0, sizeof(current)); current.active=1; current.phase=-1;
    current.id=atomic_fetch_add(&sequence, 1)+1; current.start=now_ns();
    PGconn *result=real_PQconnectStartParams(keys, values, expand);
    int saved=errno;
    if (!result) { current.before_finish=current.after_finish=now_ns(); emit(); current.active=0; }
    errno=saved; return result;
}
PostgresPollingStatusType PQconnectPoll(PGconn *conn) {
    ready(); PostgresPollingStatusType result=real_PQconnectPoll(conn); int saved=errno;
    current.connect_poll=(int)result;
    if (result==PGRES_POLLING_OK) current.connected=now_ns();
    errno=saved; return result;
}
int PQsslInUse(PGconn *conn) {
    ready(); int result=real_PQsslInUse(conn); current.tls=result; return result;
}
int PQsetnonblocking(PGconn *conn, int enabled) {
    ready(); int result=real_PQsetnonblocking(conn, enabled); current.nonblocking=result; return result;
}
int PQsendQueryParams(PGconn *conn, const char *sql, int count, const Oid *types,
                     const char *const *values, const int *lengths, const int *formats, int result_format) {
    ready(); current.phase=current.sends++;
    if (current.phase==2 && count==1 && values && values[0]) {
        static const char *routes[]={"/registry/v1/index.tsv", "/registry/v1/index-macos.tsv",
                                    "/registry/v1/index-all.tsv", "/registry/v1/index.json"};
        for (int i=0; i<4; ++i) if (strcmp(values[0], routes[i])==0) current.route=i+1;
    }
    struct phase *p=current.phase<3 ? &current.phases[current.phase] : NULL;
    if (p) p->sent=now_ns();
    int result=real_PQsendQueryParams(conn, sql, count, types, values, lengths, formats, result_format);
    if (p) p->send_result=result;
    return result;
}
int PQflush(PGconn *conn) {
    ready(); int result=real_PQflush(conn); current.flush_result=result; return result;
}
int PQconsumeInput(PGconn *conn) {
    ready(); int result=real_PQconsumeInput(conn); current.consume_result=result; return result;
}
PGresult *PQgetResult(PGconn *conn) {
    ready(); PGresult *result=real_PQgetResult(conn); int saved=errno;
    if (current.phase>=0 && current.phase<3) {
        struct phase *p=&current.phases[current.phase];
        if (!result) p->drained=now_ns();
        else {
            if (!p->results) p->received=now_ns();
            ++p->results; p->status=(int)real_PQresultStatus(result);
            p->rows=real_PQntuples(result); p->fields=real_PQnfields(result);
            const char *state=real_PQresultErrorField(result, PG_DIAG_SQLSTATE);
            if (state && strnlen(state, 6)==5) {
                int valid=1;
                for (int i=0; i<5; ++i) if (!((state[i]>='0' && state[i]<='9') ||
                                             (state[i]>='A' && state[i]<='Z'))) valid=0;
                if (valid) memcpy(p->sqlstate, state, 5);
            }
            if (p->rows==1 && p->fields==1) {
                p->null_cell=real_PQgetisnull(result, 0, 0); p->bytes=real_PQgetlength(result, 0, 0);
                if (current.phase==1 && !p->null_cell && p->bytes==1)
                    p->guard_one=real_PQgetvalue(result, 0, 0)[0]=='1';
            }
        }
    }
    errno=saved; return result;
}
void PQfinish(PGconn *conn) {
    ready(); current.before_finish=now_ns(); real_PQfinish(conn); int saved=errno;
    current.after_finish=now_ns(); if (current.active) emit(); current.active=0; errno=saved;
}
int poll(struct pollfd *fds, nfds_t count, int timeout) {
    ready(); uint64_t start=current.active ? now_ns() : 0;
    int result=real_poll(fds, count, timeout); int saved=errno;
    if (current.active) {
        ++current.polls; current.poll_ns+=now_ns()-start; current.poll_result=result;
        current.poll_errno=result<0 ? saved : 0;
        current.poll_timeout=timeout;
        current.poll_revents=count==1 && fds ? fds[0].revents : 0;
    }
    errno=saved; return result;
}
