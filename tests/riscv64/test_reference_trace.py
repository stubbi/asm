"""Reject ambiguous or unbounded reference-server trace evidence.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib.util
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PREFIX = b"ASM_REFERENCE_TRACE="


def record(**changes):
    value = dict.fromkeys(("schema id index kind start_ns connect_ns send_ns result_ns drain_ns finish_ns end_ns seen "
        "first_api first_return first_errno connect_return connect_poll nonblocking socket sends send_return "
        "flush_calls flush_return consume_calls consume_return busy_calls busy_return poll_calls poll_ns "
        "poll_return poll_errno poll_events poll_revents poll_timeout poll_eintr poll_timeouts poll_errors "
        "results status rows fields null_cell bytes").split(), 0)
    value.update(schema=1, id=1, index=1, kind=2, start_ns=100, connect_ns=110, send_ns=120,
        result_ns=130, drain_ns=140, finish_ns=150, end_ns=160, sqlstate="")
    value.update(changes)
    return value


def line(value=None):
    return PREFIX + json.dumps(record() if value is None else value, separators=(",", ":")).encode() + b"\n"


class ReferenceTraceParserTests(unittest.TestCase):
    def setUp(self):
        path = ROOT / "tools/riscv64_reference_trace.py"
        self.assertTrue(path.is_file(), "The bounded reference trace reader is absent")
        spec = importlib.util.spec_from_file_location("reference_trace", path)
        self.reader = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.reader)

    def read(self, data):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "server.log"
            path.write_bytes(data)
            return self.reader.read_records(path)

    def test_missing_or_empty_trace_is_rejected_without_log_text(self):
        private = b"private connection configuration"
        for data in (b"", private + b"\n", b"unrelated server output\n"):
            with self.subTest(data=data), self.assertRaises(ValueError) as caught:
                self.read(data)
            self.assertNotIn("private", str(caught.exception))
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError):
                self.reader.read_records(Path(temporary) / "missing")

    def test_any_producer_error_marker_is_rejected_without_error_text(self):
        for data in (b"ASM_REFERENCE_TRACE_ERROR=private\n" + line(), line() + b"prefix ASM_REFERENCE_TRACE_ERROR=private\n"):
            with self.subTest(data=data), self.assertRaises(ValueError) as caught:
                self.read(data)
            self.assertNotIn("private", str(caught.exception))

    def test_only_validated_records_are_returned(self):
        values = [record(), record(id=2, index=0, kind=0, sqlstate="42P01")]
        self.assertEqual(self.read(b"private server output\n\xff\n" + line(values[0]) + b"other output\n" + line(values[1])), values)

    def test_malformed_duplicate_missing_unknown_and_nested_fields_are_rejected(self):
        missing = record()
        missing.pop("socket")
        duplicate = line().replace(b'"schema":1', b'"schema":1,"schema":1')
        for data in (PREFIX + b"\n", line()[:-1], line()[:-2] + b"private\n", PREFIX + b"[]\n",
                     PREFIX + b"null\n", duplicate, line(missing), line(record(private="secret")),
                     line(record(socket={"private": 1})), line(record(socket=None)), line(record(socket="1")),
                     b"interleaved " + line() + line()):
            with self.subTest(data=data), self.assertRaises(ValueError) as caught:
                self.read(data)
            self.assertNotIn("secret", str(caught.exception))
            self.assertNotIn("private", str(caught.exception))
            self.assertIsNone(caught.exception.__context__)

    def test_booleans_floats_and_nonfinite_numbers_are_not_integers(self):
        for field in record().keys() - {"sqlstate"}:
            for value in (True, False, 1.0):
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    self.read(line(record(**{field: value})))
        for value in (float("nan"), float("inf"), -float("inf")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.read(line(record(poll_ns=value)))

    def test_exact_numeric_ranges_and_sentinels(self):
        maximum = (1 << 31) - 1
        ranges = {"schema": (1, 1), "id": (1, 256), "index": (0, 16), "seen": (0, 65535),
            "first_api": (0, 15), "first_return": (-1, maximum), "first_errno": (0, 4095),
            "connect_return": (0, 1), "connect_poll": (-1, 4), "socket": (-2, maximum), "sends": (0, 1),
            "send_return": (-1, 1), "flush_return": (-2, 1), "consume_return": (-1, 1),
            "busy_return": (-1, 1), "poll_return": (-2, maximum), "poll_errno": (0, 4095),
            "poll_events": (0, 65535), "poll_revents": (0, 65535), "poll_timeout": (-2, maximum),
            "results": (0, 2), "status": (-1, 12), "rows": (-1, maximum), "fields": (-1, maximum),
            "bytes": (-1, maximum), "null_cell": (-1, 1), "poll_ns": (0, (1 << 63) - 1)}
        ranges.update({key: (0, maximum) for key in ("flush_calls", "consume_calls", "busy_calls", "poll_calls",
                                                    "poll_eintr", "poll_timeouts", "poll_errors")})
        for field, (low, high) in ranges.items():
            for value in (low, high):
                with self.subTest(field=field, value=value):
                    self.assertEqual(self.read(line(record(**{field: value})))[0][field], value)
            for value in (low - 1, high + 1):
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    self.read(line(record(**{field: value})))
        for field, allowed in (("kind", (-1, 0, 2)), ("nonblocking", (-2, -1, 0))):
            for value in allowed:
                with self.subTest(field=field, value=value):
                    self.assertEqual(self.read(line(record(**{field: value})))[0][field], value)
            for value in (min(allowed) - 1, max(allowed) + 1, 1):
                if value not in allowed:
                    with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                        self.read(line(record(**{field: value})))

    def test_timestamps_are_bounded_by_the_observed_window(self):
        maximum = (1 << 63) - 1
        for field in ("connect_ns", "send_ns", "result_ns", "drain_ns", "finish_ns"):
            for value in (0, 100, 160):
                self.assertEqual(self.read(line(record(**{field: value})))[0][field], value)
            for value in (-1, 99, 161, maximum + 1):
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    self.read(line(record(**{field: value})))
        for changes in ({"start_ns": 0}, {"end_ns": 0}, {"start_ns": 161}, {"end_ns": 99},
                        {"start_ns": maximum + 1}, {"end_ns": maximum + 1}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.read(line(record(**changes)))
        self.assertEqual(self.read(line(record(start_ns=maximum, end_ns=maximum, connect_ns=0, send_ns=0,
                    result_ns=0, drain_ns=0, finish_ns=0)))[0]["end_ns"], maximum)

    def test_sqlstate_is_empty_or_five_uppercase_ascii_letters_and_digits(self):
        for value in ("", "00000", "42P01", "ABCDE", "12345"):
            self.assertEqual(self.read(line(record(sqlstate=value)))[0]["sqlstate"], value)
        for value in ("42p01", "private", "1234", "123456", "A_BCD", "\u00c4BCDE", "AAAA\n", None, 12345, True):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.read(line(record(sqlstate=value)))

    def test_whole_log_line_and_producer_record_limits(self):
        trace = line()
        complete = 1024 * 1024 - len(trace)
        count, rest = divmod(complete, 4096)
        exact = trace + (b"x" * 4095 + b"\n") * count + b"x" * rest
        self.assertEqual(len(exact), 1024 * 1024)
        self.assertEqual(len(self.read(exact)), 1)
        with self.assertRaises(ValueError):
            self.read(exact + b"x")
        self.assertEqual(len(self.read(trace + b"x" * 4095 + b"\n")), 1)
        with self.assertRaises(ValueError):
            self.read(trace + b"x" * 4096 + b"\n")
        exact_trace = trace[:-1] + b" " * (2048 - len(trace)) + b"\n"
        self.assertEqual(len(exact_trace), 2048)
        self.assertEqual(len(self.read(exact_trace)), 1)
        with self.assertRaises(ValueError):
            self.read(exact_trace[:-1] + b" \n")

    def test_connection_ids_are_unique_and_record_count_is_bounded(self):
        complete = b"".join(line(record(id=index)) for index in range(1, 257))
        self.assertEqual(len(self.read(complete)), 256)
        for data in (complete + line(record(id=1)), line() + line(), line(record(id=257))):
            with self.subTest(length=len(data)), self.assertRaises(ValueError):
                self.read(data)

    def test_links_directories_and_fifos_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            original = base / "original"
            original.write_bytes(line())
            link = base / "link"
            link.symlink_to(original)
            cases = [base, link]
            if hasattr(os, "mkfifo"):
                fifo = base / "fifo"
                os.mkfifo(fifo)
                cases.append(fifo)
            for path in cases:
                with self.subTest(path=path.name), self.assertRaises(ValueError):
                    self.reader.read_records(path)


PROVIDER = r'''
#define _GNU_SOURCE
#include <microhttpd.h>
#include <libpq-fe.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static _Thread_local int mode, delivered, token;
static _Thread_local const char *query="fixture 05";
static _Thread_local const char *expected_sql;
static _Thread_local int expected_count, expected_format;
static _Thread_local const Oid *expected_types;
static _Thread_local const char *const *expected_values;
static _Thread_local const int *expected_lengths, *expected_formats;
static _Thread_local void (*nested_callback)(PGconn *);
static _Atomic unsigned int clocks;
static void entry(void) { if(errno!=E2BIG) abort(); }
static int finish(int value) { errno=EAGAIN; return value; }
PGconn *fixture_connection(void) { return (PGconn *)(void *)&token; }
void fixture_mode(int value) { mode=value; delivered=0; }
void fixture_query(const char *value) { query=value; }
void fixture_nested(void (*value)(PGconn *)) { nested_callback=value; }
unsigned int fixture_clocks(void) { return atomic_load(&clocks); }
void fixture_expect(const char *s,int n,const Oid *t,const char *const *v,const int *l,const int *f,int r) {
 expected_sql=s;expected_count=n;expected_types=t;expected_values=v;
 expected_lengths=l;expected_formats=f;expected_format=r;
}
int clock_gettime(clockid_t which,struct timespec *value) {
 if(which!=CLOCK_MONOTONIC) abort();
 unsigned int tick=atomic_fetch_add(&clocks,1)+1;
 errno=ERANGE;
 if(mode==24) { errno=EIO;return -1; }
 if(mode==32) { value->tv_sec=INT64_MAX/1000000000ULL;value->tv_nsec=INT64_MAX%1000000000ULL+1;return 0; }
 value->tv_sec=1;value->tv_nsec=(long)tick*1000;return 0;
}
#ifndef OMIT_MHD
int MHD_get_connection_values_n(struct MHD_Connection *c,enum MHD_ValueKind k,MHD_KeyValueIteratorN it,void *cls) {
 entry();if(c!=(struct MHD_Connection *)(uintptr_t)0xbeef)abort();
 if(!it)return finish(3);
 const char *key=k==MHD_GET_ARGUMENT_KIND ? "q":"X-Test";
 const char *value=k==MHD_GET_ARGUMENT_KIND ? query:"opaque";
 int count=mode==20 && k==MHD_GET_ARGUMENT_KIND ? 2:1;
 for(int i=0;i<count;++i) {
  errno=E2BIG;
  enum MHD_Result r=it(cls,k,key,strlen(key),value,strlen(value));
  if(errno!=EAGAIN)abort();
  if(r==MHD_NO)return finish(i+1);
 }
 return finish(count);
}
#endif
PGconn *PQconnectStartParams(const char *const *keys,const char *const *values,int expand) {
 entry();if(!keys || !values || expand!=1)abort();
 if(mode==31) { errno=E2BIG;nested_callback(fixture_connection());if(errno!=EAGAIN)abort(); }
 errno=EAGAIN;return mode==1 ? NULL:fixture_connection();
}
PostgresPollingStatusType PQconnectPoll(PGconn *c) {
 entry();if(c!=fixture_connection())abort();
 errno=EAGAIN;return mode==2 ? PGRES_POLLING_FAILED:PGRES_POLLING_OK;
}
int PQsetnonblocking(PGconn *c,int enabled) {
 entry();if(c!=fixture_connection() || enabled!=1)abort();return finish(mode==3 ? -1:0);
}
int PQsocket(const PGconn *c) {
 entry();if(c!=fixture_connection())abort();return finish(mode==7 ? -1:19);
}
int PQsendQueryParams(PGconn *c,const char *s,int n,const Oid *t,const char *const *v,const int *l,const int *f,int r) {
 entry();if(c!=fixture_connection() || s!=expected_sql || n!=expected_count || t!=expected_types ||
 v!=expected_values || l!=expected_lengths || f!=expected_formats || r!=expected_format)abort();
 return finish(mode==4 ? 0:1);
}
int PQflush(PGconn *c) {
 entry();if(mode!=18 && c!=fixture_connection())abort();return finish(mode==5 || mode==18 ? -1:0);
}
int PQconsumeInput(PGconn *c) {
 entry();if(c!=fixture_connection())abort();return finish(mode==6 ? 0:1);
}
int PQisBusy(PGconn *c) {
 entry();if(c!=fixture_connection())abort();return finish(mode==8 ? 1:0);
}
PGresult *PQgetResult(PGconn *c) {
 entry();if(c!=fixture_connection())abort();errno=EAGAIN;
 return delivered++<(mode==17 ? 2:1) ? (PGresult *)(uintptr_t)0x5678:NULL;
}
ExecStatusType PQresultStatus(const PGresult *r) {
 if(r!=(PGresult *)(uintptr_t)0x5678) { abort(); }
 errno=EACCES;
 return mode==12 ? PGRES_FATAL_ERROR:PGRES_TUPLES_OK;
}
int PQntuples(const PGresult *r) { (void)r;errno=EACCES;return mode==13 ? 2:1; }
int PQnfields(const PGresult *r) { (void)r;errno=EACCES;return mode==14 ? 2:1; }
int PQgetisnull(const PGresult *r,int row,int col) { (void)r;if(row || col)abort();errno=EACCES;return mode==15; }
int PQgetlength(const PGresult *r,int row,int col) { (void)r;if(row || col)abort();errno=EACCES;return mode==16 ? 20000:12; }
char *PQresultErrorField(const PGresult *r,int field) {
 (void)r;if(field!=PG_DIAG_SQLSTATE)abort();errno=EACCES;
 return mode==12 ? "57014":mode==21 ? "private SQLSTATE text":NULL;
}
void PQfinish(PGconn *c) { entry();if(c!=fixture_connection())abort();errno=EAGAIN; }
int poll(struct pollfd *fds,nfds_t count,int timeout) {
 entry();if(count!=1 || timeout!=17 || fds[0].fd!=19 || fds[0].events!=POLLIN)abort();
 fds[0].revents=mode==11 ? POLLERR:POLLIN;
 errno=mode==9 ? EINTR:mode==11 ? EIO:EAGAIN;
 return mode==9 || mode==11 ? -1:mode==10 ? 0:1;
}
'''
DRIVER = r'''
#include <microhttpd.h>
#include <libpq-fe.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern PGconn *fixture_connection(void);
extern void fixture_mode(int);
extern void fixture_query(const char *);
extern void fixture_nested(void (*)(PGconn *));
extern void fixture_expect(const char *,int,const Oid *,const char *const *,const int *,const int *,int);
extern unsigned int fixture_clocks(void);
struct callback { int calls, stop; enum MHD_ValueKind kind; const char *query; };
static enum MHD_Result iterator(void *closure,enum MHD_ValueKind k,const char *key,size_t kn,const char *v,size_t vn) {
 struct callback *state=closure;
 if(errno!=E2BIG || !state || k!=state->kind || !key || !v)abort();
 if(k==MHD_GET_ARGUMENT_KIND && (kn!=1 || key[0]!='q' || strcmp(v,state->query) || vn!=strlen(v)))abort();
 if(k==MHD_HEADER_KIND && (kn!=6 || strcmp(key,"X-Test") || vn!=6 || strcmp(v,"opaque")))abort();
 ++state->calls;errno=EAGAIN;return state->stop ? MHD_NO:MHD_YES;
}
#define CHECK(expr) do { errno=E2BIG;if(!(expr) || errno!=EAGAIN)abort(); } while(0)
static void nested(PGconn *connection) {
 CHECK(PQconnectPoll(connection)==PGRES_POLLING_OK);
 CHECK(PQsocket(connection)==19);
 CHECK(PQisBusy(connection)==0);
}
static void identify(const char *query,int mode) {
 fixture_query(query);
 struct callback state={0,mode==27,MHD_GET_ARGUMENT_KIND,query};
 int expected=mode==20 ? 2:1;
 CHECK(MHD_get_connection_values_n((struct MHD_Connection *)(uintptr_t)0xbeef,MHD_GET_ARGUMENT_KIND,iterator,&state)==expected);
 if(state.calls!=expected)abort();
 state.kind=MHD_HEADER_KIND;state.calls=0;
 CHECK(MHD_get_connection_values_n((struct MHD_Connection *)(uintptr_t)0xbeef,MHD_HEADER_KIND,iterator,&state)==1);
 if(state.calls!=1)abort();
 CHECK(MHD_get_connection_values_n((struct MHD_Connection *)(uintptr_t)0xbeef,MHD_HEADER_KIND,NULL,&state)==3);
 CHECK(MHD_get_connection_values_n((struct MHD_Connection *)(uintptr_t)0xbeef,MHD_GET_ARGUMENT_KIND,NULL,&state)==3);
}
static void one(int mode,const char *query) {
 fixture_mode(mode);identify(query,mode);
 fixture_nested(nested);
 const char *keys[]={"dbname",NULL},*values[]={"private password URL",NULL};
 errno=E2BIG;PGconn *c=PQconnectStartParams(keys,values,1);
 if(errno!=EAGAIN || c!=(mode==1 ? NULL:fixture_connection()))abort();
 if(!c)return;
 if(mode==18) { CHECK(PQflush((PGconn *)(uintptr_t)0x7777)==-1);CHECK((PQfinish(c),1));return; }
 CHECK(PQconnectPoll(c)==(mode==2 ? PGRES_POLLING_FAILED:PGRES_POLLING_OK));
 if(mode==2) { CHECK((PQfinish(c),1));return; }
 CHECK(PQsetnonblocking(c,1)==(mode==3 ? -1:0));
 if(mode==3) { CHECK((PQfinish(c),1));return; }
 CHECK(PQsocket(c)==(mode==7 ? -1:19));
 if(mode==7) { CHECK((PQfinish(c),1));return; }
 const Oid types[]={25,25};const char *params[]={"private parameter",NULL};
 const int lengths[]={17,0},formats[]={0,0};const char *sql="private SQL must never be logged";
 fixture_expect(sql,2,types,params,lengths,formats,0);
 CHECK(PQsendQueryParams(c,sql,2,types,params,lengths,formats,0)==(mode==4 ? 0:1));
 if(mode==4) { CHECK((PQfinish(c),1));return; }
 CHECK(PQflush(c)==(mode==5 ? -1:0));
 if(mode==5) { CHECK((PQfinish(c),1));return; }
 CHECK(PQconsumeInput(c)==(mode==6 ? 0:1));
 if(mode==6) { CHECK((PQfinish(c),1));return; }
 CHECK(PQisBusy(c)==(mode==8 ? 1:0));
 struct pollfd p={.fd=19,.events=POLLIN,.revents=0};
 errno=E2BIG;int polled=poll(&p,1,17);
 if(polled!=(mode==9 || mode==11 ? -1:mode==10 ? 0:1) || errno!=(mode==9 ? EINTR:mode==11 ? EIO:EAGAIN)
    || p.revents!=(mode==11 ? POLLERR:POLLIN))abort();
 CHECK(PQgetResult(c)==(PGresult *)(uintptr_t)0x5678);
 if(mode==17) CHECK(PQgetResult(c)==(PGresult *)(uintptr_t)0x5678);
 CHECK(PQgetResult(c)==NULL);
 CHECK((PQfinish(c),1));
}
static void *thread_one(void *argument) {
 char query[11];snprintf(query,sizeof(query),"fixture %02d",(int)(uintptr_t)argument);
 one(0,query);return NULL;
}
int main(int argc,char **argv) {
 int mode=argc>1 ? atoi(argv[1]):0;
 const char *query=argc>2 ? argv[2]:"fixture 05";
 if(mode==30) {
  pthread_t threads[8];
  for(int i=0;i<8;++i)if(pthread_create(&threads[i],NULL,thread_one,(void *)(uintptr_t)(i+1)))abort();
  for(int i=0;i<8;++i)if(pthread_join(threads[i],NULL))abort();
 } else if(mode==23) {
  for(int i=0;i<257;++i)one(1,query);
 } else one(mode,query);
 if(!fixture_clocks())return 91;
 return 0;
}
'''


class NativeTraceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="asm-reference-trace-native-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.base = Path(cls.temporary.name)
        cls.source = ROOT / "tools/diagnostics/reference_libpq_trace.c"
        if not cls.source.is_file():
            raise AssertionError("The reference trace interposer source is absent")
        cls.headers = subprocess.check_output(["pkg-config", "--cflags", "libmicrohttpd", "libpq"], text=True).strip()
        cls.versions = subprocess.check_output(["pkg-config", "--modversion", "libmicrohttpd", "libpq"], text=True).splitlines()
        cls.compiler = subprocess.check_output(["cc", "--version"], text=True).splitlines()[0]
        cls.system = platform.system()
        if cls.system not in ("Linux", "Darwin"):
            raise RuntimeError("Native interposition checks require Linux or Darwin; no target test was skipped.")
        suffix = ".dylib" if cls.system == "Darwin" else ".so"
        shared = "-dynamiclib" if cls.system == "Darwin" else "-shared"
        flags = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC", "-pthread", *shlex.split(cls.headers)]
        cls.trace = cls.base / ("libreference_trace" + suffix)
        cls.provider = cls.base / ("libprovider" + suffix)
        (cls.base / "provider.c").write_text(PROVIDER)
        (cls.base / "driver.c").write_text(DRIVER)
        libraries = [] if cls.system == "Darwin" else ["-ldl"]
        subprocess.run([*flags, shared, str(cls.base / "provider.c"), "-o", str(cls.provider), *libraries],
                       capture_output=True, check=True, timeout=20)
        # Darwin RTLD_NEXT follows the calling image's dependency scope. Make
        # the fake provider an explicit dependency for these native checks.
        # Linux exercises the normal LD_PRELOAD/DT_NEEDED search arrangement.
        provider_dependency = ["-Wl,-needed_library," + str(cls.provider)] if cls.system == "Darwin" else []
        subprocess.run([*flags, shared, str(cls.source), "-o", str(cls.trace), *provider_dependency, *libraries],
                       capture_output=True, check=True, timeout=20)
        cls.executable = cls.base / "driver"
        subprocess.run([*flags, str(cls.base / "driver.c"), str(cls.trace), str(cls.provider),
                        "-Wl,-rpath," + str(cls.base), "-o", str(cls.executable)],
                       capture_output=True, check=True, timeout=20)
        path = ROOT / "tools/riscv64_reference_trace.py"
        spec = importlib.util.spec_from_file_location("reference_trace", path)
        cls.reader = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.reader)

    def run_case(self, mode=0, query="fixture 05", *, valid=True):
        env = {key: value for key, value in os.environ.items()
               if key not in {"LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "DYLD_FORCE_FLAT_NAMESPACE"}}
        if self.system == "Darwin":
            env.update(DYLD_INSERT_LIBRARIES=str(self.trace), DYLD_FORCE_FLAT_NAMESPACE="1")
        else:
            env["LD_PRELOAD"] = str(self.trace)
        result = subprocess.run([str(self.executable), str(mode), query], env=env,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stdout, b"")
        self.assertNotIn(b"private", result.stderr)
        self.assertTrue(all(len(item) <= 2048 for item in result.stderr.splitlines(keepends=True)))
        path = self.base / "result.log"
        path.write_bytes(result.stderr)
        if not valid:
            with self.assertRaises(ValueError):
                self.reader.read_records(path)
            return result.stderr
        return self.reader.read_records(path)

    def test_native_interposer_source_exists(self):
        self.assertTrue((ROOT / "tools/diagnostics/reference_libpq_trace.c").is_file(),
                        "The reference trace interposer source is absent")

    def test_native_evidence_declares_its_actual_host_headers_and_compiler(self):
        self.assertEqual(len(self.versions), 2)
        self.assertTrue(self.compiler)
        self.assertIn(self.system, ("Darwin", "Linux"))

    def test_all_eight_arguments_callbacks_results_and_errno_are_forwarded(self):
        found = self.run_case()[0]
        self.assertEqual((found["index"], found["kind"], found["sends"], found["results"]), (5, 2, 1, 1))
        self.assertEqual((found["first_api"], found["status"], found["rows"], found["fields"], found["bytes"]), (0, 2, 1, 1, 12))
        self.assertGreater(found["drain_ns"], found["result_ns"])

    def test_connect_failure_keeps_integer_identity_before_any_send(self):
        found = self.run_case(1, "fixture 08")[0]
        self.assertEqual((found["index"], found["kind"], found["sends"], found["connect_return"]), (8, -1, 0, 0))
        self.assertEqual((found["first_api"], found["first_return"]), (1, 0))

    def test_iterator_stop_return_and_null_get_iterator_are_forwarded(self):
        self.assertEqual(self.run_case(27)[0]["index"], 5)

    def test_library_internal_calls_before_constructor_return_are_not_misattributed(self):
        found = self.run_case(31)[0]
        self.assertEqual(found["first_api"], 0)
        self.assertEqual(found["busy_calls"], 1)

    def test_only_exact_fixture_values_produce_a_nonzero_index(self):
        for index in (1, 16):
            self.assertEqual(self.run_case(1, f"fixture {index:02d}")[0]["index"], index)
        for query in ("fixture 00", "fixture 17", "fixture 5", "fixture 005", "fixture 05x", "Fixture 05", "private query"):
            with self.subTest(query=query):
                self.assertEqual(self.run_case(1, query)[0]["index"], 0)

    def test_first_adverse_api_survives_later_calls_and_cleanup(self):
        for mode, api in ((2, 2), (3, 3), (4, 4), (5, 5), (6, 6), (7, 7),
                          (9, 9), (10, 9), (11, 9), (12, 10), (13, 11), (14, 12), (15, 13), (16, 14), (17, 15)):
            with self.subTest(mode=mode):
                found = self.run_case(mode)[0]
                self.assertEqual(found["first_api"], api)
        found = self.run_case(9)[0]
        self.assertEqual((found["poll_calls"], found["poll_eintr"], found["poll_errors"]), (1, 1, 1))
        found = self.run_case(10)[0]
        self.assertEqual(found["poll_timeouts"], 1)

    def test_sqlstate_is_bounded_without_query_or_provider_error_text(self):
        self.assertEqual(self.run_case(12)[0]["sqlstate"], "57014")
        self.assertEqual(self.run_case(21)[0]["sqlstate"], "")

    def test_ownership_and_conflicting_query_association_are_inconclusive(self):
        self.assertIn(b"ASM_REFERENCE_TRACE_ERROR=ownership", self.run_case(18, valid=False))
        self.assertIn(b"ASM_REFERENCE_TRACE_ERROR=association", self.run_case(20, valid=False))

    def test_clock_and_record_count_errors_are_inconclusive(self):
        self.assertIn(b"ASM_REFERENCE_TRACE_ERROR=clock", self.run_case(24, valid=False))
        self.assertIn(b"ASM_REFERENCE_TRACE_ERROR=clock", self.run_case(32, valid=False))
        raw = self.run_case(23, valid=False)
        self.assertEqual(raw.count(PREFIX), 256)
        self.assertIn(b"ASM_REFERENCE_TRACE_ERROR=record_count", raw)
        self.assertLess(len(raw), 1024 * 1024)

    def test_parallel_threads_keep_connection_identity_and_output_separate(self):
        found = self.run_case(30)
        self.assertEqual(len(found), 8)
        self.assertEqual(sorted(item["index"] for item in found), list(range(1, 9)))
        self.assertEqual(len({item["id"] for item in found}), 8)


if __name__ == "__main__":
    unittest.main()
