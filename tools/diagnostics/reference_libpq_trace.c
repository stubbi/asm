/* SPDX-License-Identifier: AGPL-3.0-or-later
 * UNQUALIFIED diagnostic interposer for the exact single-query reference.
 * Preload only the server child, never its Python or PostgreSQL fixtures.
 * Forward every provider argument, result, and errno. Do not emit SQL, query
 * text, parameters, URLs, passwords, pointers, paths, or error messages.
 * One PGconn belongs to one worker until PQfinish. A scope violation emits a
 * fixed error marker and makes the diagnostic inconclusive.
 *
 * MHD_get_connection_values_n invokes its iterator synchronously. The bridge
 * lifetime is the enclosing call. Its original closure and six arguments are
 * forwarded unchanged. Header enumeration does not change query identity.
 * GNU MHD manual, Handling requests; target-source verification is a CI gate.
 * Local native header tests do not establish RISC-V or target-library ABI.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <microhttpd.h>
#include <libpq-fe.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define PREFIX "ASM_REFERENCE_TRACE="
#define ERROR_PREFIX "ASM_REFERENCE_TRACE_ERROR="
#define RECORD_BYTES 2048
#define RECORD_LIMIT 256
#define SYMBOLS(X) X(PQconnectStartParams) X(PQconnectPoll) X(PQsetnonblocking) \
    X(PQsocket) X(PQsendQueryParams) X(PQflush) X(PQconsumeInput) X(PQisBusy) \
    X(PQgetResult) X(PQresultStatus) X(PQntuples) X(PQnfields) X(PQgetisnull) \
    X(PQgetlength) X(PQresultErrorField) X(PQfinish) X(poll) X(MHD_get_connection_values_n)
#define DECLARE(name) static __typeof__(&name) real_##name;
SYMBOLS(DECLARE)
static pthread_once_t once = PTHREAD_ONCE_INIT;
static pthread_mutex_t output_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic unsigned int sequence;
static _Atomic unsigned int errors;

enum error_kind { SYMBOL_ERROR, OWNER_ERROR, ASSOCIATION_ERROR, BOUND_ERROR,
                  COUNT_ERROR, CLOCK_ERROR, WRITE_ERROR };
enum api { NONE, CONNECT, CONNECT_POLL, NONBLOCK, SEND, FLUSH, CONSUME,
           SOCKET, BUSY, POLL, STATUS, ROWS, FIELDS, NULL_CELL, LENGTH, EXTRA_RESULT };
enum seen_bit { S_CONNECT=1, S_CONNECT_POLL=2, S_NONBLOCK=4, S_SEND=8,
    S_FLUSH=16, S_CONSUME=32, S_SOCKET=64, S_BUSY=128, S_POLL=256,
    S_RESULT=512, S_STATUS=1024, S_ROWS=2048, S_FIELDS=4096, S_NULL=8192,
    S_LENGTH=16384, S_FINISH=32768 };
struct trace {
    PGconn *owner;
    int active, invalid, index, kind, seen, first_api, first_return, first_errno;
    int connect_return, connect_poll, nonblocking, socket, sends, send_return;
    int flush_calls, flush_return, consume_calls, consume_return, busy_calls, busy_return;
    int poll_calls, poll_return, poll_errno, poll_events, poll_revents, poll_timeout;
    int poll_eintr, poll_timeouts, poll_errors, results, status, rows, fields, null_cell, bytes;
    unsigned int id;
    uint64_t start_ns, connect_ns, send_ns, result_ns, drain_ns, finish_ns, end_ns, poll_ns;
    char sqlstate[6];
};
static _Thread_local struct trace current;
static _Thread_local int pending_index, pending_bad;
/* Observe application boundaries, not libpq's public-API self-calls. In
 * libpq16.15 connectDBStart calls PQconnectPoll before its constructor returns.
 * The connection owner is not available to this interposer until that return.
 */
static _Thread_local int provider_depth, resolving;

static void error_marker(enum error_kind kind) {
    int saved = errno;
    static const char *const messages[] = {
        ERROR_PREFIX "symbol\n", ERROR_PREFIX "ownership\n", ERROR_PREFIX "association\n",
        ERROR_PREFIX "record_bound\n", ERROR_PREFIX "record_count\n", ERROR_PREFIX "clock\n",
        ERROR_PREFIX "write\n" };
    unsigned int mask = 1u << (unsigned int)kind;
    if (!(atomic_fetch_or(&errors, mask) & mask)) {
        const char *message = messages[kind];
        (void)write(2, message, strlen(message));
    }
    errno = saved;
}
static uint64_t now_ns(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0 || value.tv_sec < 0 || value.tv_nsec < 0
        || value.tv_nsec >= 1000000000 || (uint64_t)value.tv_sec > INT64_MAX / 1000000000ULL
        || ((uint64_t)value.tv_sec == INT64_MAX / 1000000000ULL
            && (uint64_t)value.tv_nsec > INT64_MAX % 1000000000ULL)) {
        error_marker(CLOCK_ERROR); current.invalid=1; return 0;
    }
    return (uint64_t)value.tv_sec*1000000000ULL+(uint64_t)value.tv_nsec;
}
static void resolve(void) {
    resolving=1;
#define LOAD(name) do { real_##name=(__typeof__(&name))dlsym(RTLD_NEXT, #name); \
    if (!real_##name) { error_marker(SYMBOL_ERROR); _exit(125); } } while (0);
    SYMBOLS(LOAD)
#undef LOAD
    resolving=0;
}
static void ready(void) {
    if (resolving) { error_marker(SYMBOL_ERROR); _exit(125); }
    (void)pthread_once(&once, resolve);
}
static int owner(PGconn *connection) {
    if (provider_depth) return 0;
    if (!current.active || connection != current.owner) {
        current.invalid=1; error_marker(OWNER_ERROR); return 0;
    }
    return 1;
}
static void bump(int *counter) {
    if (*counter == INT_MAX) { current.invalid=1; error_marker(BOUND_ERROR); }
    else ++*counter;
}
static void adverse(enum api api, int result, int saved_errno) {
    if (!current.first_api) {
        current.first_api=(int)api; current.first_return=result; current.first_errno=saved_errno;
    }
}
static void emit(void) {
    int saved=errno;
    char out[RECORD_BYTES];
    if (current.invalid || current.id>RECORD_LIMIT) { errno=saved; return; }
    int used=snprintf(out, sizeof(out), PREFIX
        "{\"schema\":1,\"id\":%u,\"index\":%d,\"kind\":%d,"
        "\"start_ns\":%" PRIu64 ",\"connect_ns\":%" PRIu64 ",\"send_ns\":%" PRIu64
        ",\"result_ns\":%" PRIu64 ",\"drain_ns\":%" PRIu64 ",\"finish_ns\":%" PRIu64
        ",\"end_ns\":%" PRIu64 ",\"seen\":%d,\"first_api\":%d,\"first_return\":%d,\"first_errno\":%d,"
        "\"connect_return\":%d,\"connect_poll\":%d,\"nonblocking\":%d,\"socket\":%d,\"sends\":%d,\"send_return\":%d,"
        "\"flush_calls\":%d,\"flush_return\":%d,\"consume_calls\":%d,\"consume_return\":%d,"
        "\"busy_calls\":%d,\"busy_return\":%d,\"poll_calls\":%d,\"poll_ns\":%" PRIu64
        ",\"poll_return\":%d,\"poll_errno\":%d,\"poll_events\":%d,\"poll_revents\":%d,\"poll_timeout\":%d,"
        "\"poll_eintr\":%d,\"poll_timeouts\":%d,\"poll_errors\":%d,\"results\":%d,\"status\":%d,"
        "\"rows\":%d,\"fields\":%d,\"null_cell\":%d,\"bytes\":%d,\"sqlstate\":\"%s\"}\n",
        current.id,current.index,current.kind,current.start_ns,current.connect_ns,current.send_ns,
        current.result_ns,current.drain_ns,current.finish_ns,current.end_ns,current.seen,current.first_api,
        current.first_return,current.first_errno,current.connect_return,current.connect_poll,current.nonblocking,
        current.socket,current.sends,current.send_return,current.flush_calls,current.flush_return,current.consume_calls,
        current.consume_return,current.busy_calls,current.busy_return,current.poll_calls,current.poll_ns,
        current.poll_return,current.poll_errno,current.poll_events,current.poll_revents,current.poll_timeout,
        current.poll_eintr,current.poll_timeouts,current.poll_errors,current.results,current.status,current.rows,
        current.fields,current.null_cell,current.bytes,current.sqlstate);
    if (used<=0 || (size_t)used>=sizeof(out)) { error_marker(BOUND_ERROR); errno=saved; return; }
    int failed=0;
    if (pthread_mutex_lock(&output_lock)!=0) failed=1;
    else {
        size_t position=0;
        for (int attempt=0; position<(size_t)used && attempt<4; ++attempt) {
            ssize_t count=write(2,out+position,(size_t)used-position);
            if (count>0) position+=(size_t)count;
            else if (count<0 && errno==EINTR) continue;
            else break;
        }
        failed=position!=(size_t)used;
        (void)pthread_mutex_unlock(&output_lock);
    }
    if (failed) error_marker(WRITE_ERROR);
    errno=saved;
}

struct bridge { MHD_KeyValueIteratorN iterator; void *closure; int index, q_count, bad; };
static enum MHD_Result query_value(void *closure, enum MHD_ValueKind kind,
    const char *key, size_t key_size, const char *value, size_t value_size) {
    int incoming=errno;
    struct bridge *bridge=closure;
    if (kind==MHD_GET_ARGUMENT_KIND && key && key_size==1 && key[0]=='q') {
        ++bridge->q_count;
        if (bridge->q_count!=1) { bridge->bad=1; bridge->index=0; }
        else if (value && value_size==10 && memcmp(value,"fixture ",8)==0
                 && value[8]>='0' && value[8]<='9' && value[9]>='0' && value[9]<='9') {
            int index=(value[8]-'0')*10+value[9]-'0';
            if (index>=1 && index<=16) bridge->index=index;
        }
    }
    errno=incoming;
    enum MHD_Result result=bridge->iterator(bridge->closure,kind,key,key_size,value,value_size);
    int saved=errno;
    errno=saved; return result;
}
int MHD_get_connection_values_n(struct MHD_Connection *connection, enum MHD_ValueKind kind,
    MHD_KeyValueIteratorN iterator, void *closure) {
    int incoming=errno; ready();
    if (kind!=MHD_GET_ARGUMENT_KIND || !iterator || provider_depth) {
        errno=incoming;
        ++provider_depth;
        int result=real_MHD_get_connection_values_n(connection,kind,iterator,closure); int saved=errno;
        --provider_depth; errno=saved; return result;
    }
    struct bridge bridge={iterator,closure,0,0,0};
    if (current.active) bridge.bad=1;
    errno=incoming;
    ++provider_depth;
    int result=real_MHD_get_connection_values_n(connection,kind,query_value,&bridge); int saved=errno;
    --provider_depth;
    pending_index=bridge.bad ? 0 : bridge.index;
    pending_bad=bridge.bad;
    errno=saved; return result;
}

PGconn *PQconnectStartParams(const char *const *keys,const char *const *values,int expand) {
    int incoming=errno; ready();
    if (provider_depth) {
        errno=incoming; ++provider_depth;
        PGconn *result=real_PQconnectStartParams(keys,values,expand); int saved=errno;
        --provider_depth; errno=saved; return result;
    }
    if (current.active) error_marker(OWNER_ERROR);
    memset(&current,0,sizeof(current)); current.active=1;
    current.id=atomic_fetch_add(&sequence,1)+1; current.index=pending_index;
    current.kind=-1; current.connect_poll=-1; current.nonblocking=-2; current.socket=-2;
    current.send_return=-1; current.flush_return=-2; current.consume_return=-1; current.busy_return=-1;
    current.poll_return=-2; current.poll_timeout=-2; current.status=-1; current.rows=-1;
    current.fields=-1; current.null_cell=-1; current.bytes=-1;
    if (pending_bad) { current.invalid=1; error_marker(ASSOCIATION_ERROR); }
    pending_index=pending_bad=0;
    if (current.id>RECORD_LIMIT) { current.invalid=1; error_marker(COUNT_ERROR); }
    current.start_ns=now_ns(); current.seen|=S_CONNECT;
    errno=incoming;
    ++provider_depth;
    PGconn *result=real_PQconnectStartParams(keys,values,expand); int saved=errno;
    --provider_depth;
    current.owner=result; current.connect_return=result!=NULL;
    if (!result) {
        adverse(CONNECT,0,saved); current.finish_ns=current.end_ns=now_ns();
        emit(); current.active=0;
    }
    errno=saved; return result;
}
PostgresPollingStatusType PQconnectPoll(PGconn *connection) {
    int incoming=errno; ready(); int observed=owner(connection); errno=incoming;
    ++provider_depth;
    PostgresPollingStatusType result=real_PQconnectPoll(connection); int saved=errno;
    --provider_depth;
    if (observed) {
        current.seen|=S_CONNECT_POLL; current.connect_poll=(int)result;
        if (result==PGRES_POLLING_OK) current.connect_ns=now_ns();
        else if (result==PGRES_POLLING_FAILED) adverse(CONNECT_POLL,(int)result,saved);
    }
    errno=saved; return result;
}
int PQsetnonblocking(PGconn *connection,int enabled) {
    int incoming=errno; ready(); int observed=owner(connection); errno=incoming;
    ++provider_depth;
    int result=real_PQsetnonblocking(connection,enabled); int saved=errno;
    --provider_depth;
    if (observed) { current.seen|=S_NONBLOCK; current.nonblocking=result; if (result) adverse(NONBLOCK,result,saved); }
    errno=saved; return result;
}
int PQsocket(const PGconn *connection) {
    int incoming=errno; ready(); int observed=owner((PGconn *)connection); errno=incoming;
    ++provider_depth;
    int result=real_PQsocket(connection); int saved=errno;
    --provider_depth;
    if (observed) { current.seen|=S_SOCKET; current.socket=result; if (result<0) adverse(SOCKET,result,saved); }
    errno=saved; return result;
}
int PQsendQueryParams(PGconn *connection,const char *sql,int count,const Oid *types,
    const char *const *values,const int *lengths,const int *formats,int result_format) {
    int incoming=errno; ready(); int observed=owner(connection);
    if (observed) {
        current.seen|=S_SEND; bump(&current.sends); current.send_ns=now_ns();
        current.kind=count==0 || count==2 ? count : -1;
        if (current.sends!=1) { current.invalid=1; error_marker(OWNER_ERROR); }
    }
    errno=incoming;
    ++provider_depth;
    int result=real_PQsendQueryParams(connection,sql,count,types,values,lengths,formats,result_format); int saved=errno;
    --provider_depth;
    if (observed) { current.send_return=result; if (result!=1) adverse(SEND,result,saved); }
    errno=saved; return result;
}
int PQflush(PGconn *connection) {
    int incoming=errno; ready(); int observed=owner(connection); errno=incoming;
    ++provider_depth;
    int result=real_PQflush(connection); int saved=errno;
    --provider_depth;
    if (observed) { current.seen|=S_FLUSH; bump(&current.flush_calls); current.flush_return=result;
        if (result<0) adverse(FLUSH,result,saved); }
    errno=saved; return result;
}
int PQconsumeInput(PGconn *connection) {
    int incoming=errno; ready(); int observed=owner(connection); errno=incoming;
    ++provider_depth;
    int result=real_PQconsumeInput(connection); int saved=errno;
    --provider_depth;
    if (observed) { current.seen|=S_CONSUME; bump(&current.consume_calls); current.consume_return=result;
        if (result!=1) adverse(CONSUME,result,saved); }
    errno=saved; return result;
}
int PQisBusy(PGconn *connection) {
    int incoming=errno; ready(); int observed=owner(connection); errno=incoming;
    ++provider_depth;
    int result=real_PQisBusy(connection); int saved=errno;
    --provider_depth;
    if (observed) { current.seen|=S_BUSY; bump(&current.busy_calls); current.busy_return=result;
        if (result!=0 && result!=1) adverse(BUSY,result,saved); }
    errno=saved; return result;
}
PGresult *PQgetResult(PGconn *connection) {
    int incoming=errno; ready(); int observed=owner(connection); errno=incoming;
    ++provider_depth;
    PGresult *result=real_PQgetResult(connection); int saved=errno;
    --provider_depth;
    if (observed) {
        current.seen|=S_RESULT;
        if (!result) current.drain_ns=now_ns();
        else {
            bump(&current.results);
            if (current.results>1) adverse(EXTRA_RESULT,current.results,saved);
            else {
                current.result_ns=now_ns();
                current.status=(int)real_PQresultStatus(result); current.seen|=S_STATUS;
                current.rows=real_PQntuples(result); current.seen|=S_ROWS;
                current.fields=real_PQnfields(result); current.seen|=S_FIELDS;
                if (current.status!=PGRES_TUPLES_OK) adverse(STATUS,current.status,saved);
                else if (current.rows!=1) adverse(ROWS,current.rows,saved);
                else if (current.fields!=1) adverse(FIELDS,current.fields,saved);
                const char *state=real_PQresultErrorField(result,PG_DIAG_SQLSTATE);
                if (state && strnlen(state,6)==5) {
                    int valid=1;
                    for (int i=0;i<5;++i) if (!((state[i]>='0' && state[i]<='9') || (state[i]>='A' && state[i]<='Z'))) valid=0;
                    if (valid) memcpy(current.sqlstate,state,5);
                }
                if (current.rows==1 && current.fields==1) {
                    current.null_cell=real_PQgetisnull(result,0,0); current.seen|=S_NULL;
                    current.bytes=real_PQgetlength(result,0,0); current.seen|=S_LENGTH;
                    if (current.null_cell) adverse(NULL_CELL,current.null_cell,saved);
                    else if (current.bytes<=0 || current.bytes>16384) adverse(LENGTH,current.bytes,saved);
                }
            }
        }
    }
    errno=saved; return result;
}
void PQfinish(PGconn *connection) {
    int incoming=errno; ready(); int observed=owner(connection);
    if (observed) { current.seen|=S_FINISH; current.finish_ns=now_ns(); }
    errno=incoming; ++provider_depth; real_PQfinish(connection); int saved=errno;
    --provider_depth;
    if (observed) { current.end_ns=now_ns(); emit(); current.active=0; current.owner=NULL; }
    errno=saved;
}
int poll(struct pollfd *fds,nfds_t count,int timeout) {
    int incoming=errno; ready(); int observed=current.active && !provider_depth; uint64_t start=0;
    if (observed) start=now_ns();
    errno=incoming; ++provider_depth; int result=real_poll(fds,count,timeout); int saved=errno;
    --provider_depth;
    if (observed) {
        uint64_t end=now_ns(); current.seen|=S_POLL; bump(&current.poll_calls);
        if (end>=start && current.poll_ns<=INT64_MAX-(end-start)) current.poll_ns+=end-start;
        else { current.invalid=1; error_marker(CLOCK_ERROR); }
        current.poll_return=result; current.poll_errno=result<0 ? saved : 0;
        current.poll_timeout=timeout; current.poll_events=count==1 && fds ? (unsigned short)fds[0].events : 0;
        current.poll_revents=count==1 && fds ? (unsigned short)fds[0].revents : 0;
        if (result<0) { bump(&current.poll_errors); if (saved==EINTR) bump(&current.poll_eintr); }
        if (result==0) bump(&current.poll_timeouts);
        if (result<=0 || (current.poll_revents & (POLLERR|POLLHUP|POLLNVAL))) adverse(POLL,result,saved);
    }
    errno=saved; return result;
}
