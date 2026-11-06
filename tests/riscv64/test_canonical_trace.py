"""Typed mock-provider checks; no application or RISC-V code is executed.

SPDX-License-Identifier: AGPL-3.0-or-later
The actual host headers and compiler are reported. They do not qualify target ABI.
"""
import json
import importlib.util
import os
from pathlib import Path
import platform
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PREFIX = b"ASM_CANONICAL_TRACE="

PROVIDER = r'''
#define _GNU_SOURCE
#include <libpq-fe.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
static _Thread_local int mode, stage, delivered, token;
static _Thread_local const char *expected_sql;
static _Thread_local int expected_count, expected_format;
static _Thread_local const Oid *expected_types;
static _Thread_local const char *const *expected_values;
static _Thread_local const int *expected_lengths, *expected_formats;
static _Thread_local void (*nested_callback)(PGconn *);
static _Thread_local PQnoticeProcessor expected_notice;
static _Thread_local void *expected_closure;
static _Atomic unsigned int ticks;
static void entry(void) { if(errno!=E2BIG)abort(); }
static int done(int value) { errno=EAGAIN;return value; }
PGconn *fixture_connection(void) { return (PGconn *)(void *)&token; }
void fixture_mode(int value) { mode=value;stage=delivered=0; }
void fixture_nested(void (*value)(PGconn *)) { nested_callback=value; }
void fixture_expect(const char *s,int n,const Oid *t,const char *const *v,const int *l,const int *f,int r) {
 expected_sql=s;expected_count=n;expected_types=t;expected_values=v;
 expected_lengths=l;expected_formats=f;expected_format=r;
}
static void old_notice(void *context,const char *message) { (void)context;(void)message; }
PQnoticeProcessor fixture_old_notice(void) { return old_notice; }
void fixture_notice(PQnoticeProcessor processor,void *closure) { expected_notice=processor;expected_closure=closure; }
int clock_gettime(clockid_t which,struct timespec *value) {
 unsigned int tick=atomic_fetch_add(&ticks,1)+1;
 errno=ERANGE;
 if(mode==22) { errno=EIO;return -1; }
 if(mode==23) { value->tv_sec=INT64_MAX/1000000000ULL;value->tv_nsec=INT64_MAX%1000000000ULL+1;return 0; }
 if(which!=CLOCK_MONOTONIC && which!=CLOCK_THREAD_CPUTIME_ID)abort();
 value->tv_sec=which==CLOCK_MONOTONIC ? 1:0;
 value->tv_nsec=(long)tick*(which==CLOCK_MONOTONIC ? 1000:100);return 0;
}
PGconn *PQconnectStartParams(const char *const *keys,const char *const *values,int expand) {
 entry();if(keys!=(const char *const *)(uintptr_t)0x1111 || values!=(const char *const *)(uintptr_t)0x2222 || expand!=1)abort();
 if(mode==21) { errno=E2BIG;nested_callback(fixture_connection());if(errno!=EAGAIN)abort(); }
 errno=EAGAIN;return mode==1 ? NULL:fixture_connection();
}
PQnoticeProcessor PQsetNoticeProcessor(PGconn *c,PQnoticeProcessor processor,void *closure) {
 entry();if(c!=fixture_connection() || processor!=expected_notice || closure!=expected_closure)abort();
 errno=E2BIG;processor(closure,"private notice must not be logged");if(errno!=EAGAIN)abort();
 errno=EAGAIN;return old_notice;
}
PostgresPollingStatusType PQconnectPoll(PGconn *c) {
 entry();if(c!=fixture_connection())abort();errno=EAGAIN;return mode==2 ? PGRES_POLLING_FAILED:PGRES_POLLING_OK;
}
int PQsetnonblocking(PGconn *c,int enabled) {
 entry();if(c!=fixture_connection() || enabled!=1)abort();return done(mode==3 ? -1:0);
}
int PQsocket(const PGconn *c) { entry();if(c!=fixture_connection())abort();return done(mode==7 ? -1:19); }
int PQsendQueryParams(PGconn *c,const char *s,int n,const Oid *t,const char *const *v,const int *l,const int *f,int r) {
 entry();if(c!=fixture_connection() || s!=expected_sql || n!=expected_count || t!=expected_types ||
 v!=expected_values || l!=expected_lengths || f!=expected_formats || r!=expected_format)abort();
 ++stage;delivered=0;return done(mode==4 && stage==2 ? 0:1);
}
int PQflush(PGconn *c) { entry();if(mode!=18 && c!=fixture_connection())abort();return done(mode==5 && stage==2 ? -1:0); }
int PQconsumeInput(PGconn *c) { entry();if(c!=fixture_connection())abort();return done(mode==6 && stage==2 ? 0:1); }
int PQisBusy(PGconn *c) { entry();if(c!=fixture_connection())abort();return done(mode==8 ? 1:0); }
PGresult *PQgetResult(PGconn *c) {
 entry();if(c!=fixture_connection())abort();errno=EAGAIN;
 return delivered++<(mode==17 && stage==3 ? 2:1) ? (PGresult *)(uintptr_t)0x5678:NULL;
}
ExecStatusType PQresultStatus(const PGresult *r) {
 if(r!=(PGresult *)(uintptr_t)0x5678)abort();errno=EACCES;
 return mode==12 && stage==2 ? PGRES_FATAL_ERROR:mode==29 && stage==1 ? PGRES_TUPLES_OK:stage==1 ? PGRES_COMMAND_OK:PGRES_TUPLES_OK;
}
int PQntuples(const PGresult *r) { (void)r;errno=EACCES;return stage==1 ? 0:mode==14 && stage==2 ? 2:1; }
int PQnfields(const PGresult *r) { (void)r;errno=EACCES;return stage==1 ? 0:1; }
int PQgetisnull(const PGresult *r,int row,int col) { (void)r;if(row || col)abort();errno=EACCES;return mode==15 && stage==2; }
int PQgetlength(const PGresult *r,int row,int col) { (void)r;if(row || col)abort();errno=EACCES;return stage==2 ? 1:mode==30 ? 20000:mode==31 ? 4194305:12; }
char *PQgetvalue(const PGresult *r,int row,int col) {
 (void)r;if(stage!=2 || row || col)abort();errno=EACCES;
 return mode==13 ? "0":mode==16 ? "x":"1";
}
char *PQresultErrorField(const PGresult *r,int field) {
 (void)r;if(field!=PG_DIAG_SQLSTATE)abort();errno=EACCES;
 return mode==12 && stage==2 ? "57014":mode==20 ? "private error text":NULL;
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
#include <libpq-fe.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
extern PGconn *fixture_connection(void);
extern void fixture_mode(int);
extern void fixture_nested(void (*)(PGconn *));
extern void fixture_expect(const char *,int,const Oid *,const char *const *,const int *,const int *,int);
extern void fixture_notice(PQnoticeProcessor,void *);
extern PQnoticeProcessor fixture_old_notice(void);
#define CHECK(expr) do { errno=E2BIG;if(!(expr) || errno!=EAGAIN)abort(); } while(0)
static void nested(PGconn *c) { CHECK(PQconnectPoll(c)==PGRES_POLLING_OK);CHECK(PQsocket(c)==19);CHECK(PQisBusy(c)==0); }
static void notice(void *closure,const char *message) {
 if(errno!=E2BIG || closure!=(void *)(uintptr_t)0xcafe || !message)abort();errno=EAGAIN;
}
static void one(int mode) {
 fixture_mode(mode);fixture_nested(nested);
 errno=E2BIG;PGconn *c=PQconnectStartParams((const char *const *)(uintptr_t)0x1111,(const char *const *)(uintptr_t)0x2222,1);
 if(errno!=EAGAIN || c!=(mode==1 ? NULL:fixture_connection()))abort();if(!c)return;
 fixture_notice(notice,(void *)(uintptr_t)0xcafe);
 CHECK(PQsetNoticeProcessor(c,notice,(void *)(uintptr_t)0xcafe)==fixture_old_notice());
 if(mode==18) { CHECK(PQflush((PGconn *)(uintptr_t)0x7777)==0);CHECK((PQfinish(c),1));return; }
 CHECK(PQconnectPoll(c)==(mode==2 ? PGRES_POLLING_FAILED:PGRES_POLLING_OK));
 if(mode==2) { CHECK((PQfinish(c),1));return; }
 CHECK(PQsetnonblocking(c,1)==(mode==3 ? -1:0));if(mode==3) { CHECK((PQfinish(c),1));return; }
 CHECK(PQsocket(c)==(mode==7 ? -1:19));if(mode==7) { CHECK((PQfinish(c),1));return; }
 int total=mode==19 ? 4:mode==28 ? 2:3;
 for(int stage=1;stage<=total;++stage) {
  const char *sql=(const char *)(uintptr_t)(0x3000+stage);
  const Oid *types=(const Oid *)(uintptr_t)0x4000;
  const char *const *params=(const char *const *)(uintptr_t)0x5000;
  const int *lengths=(const int *)(uintptr_t)0x6000,*formats=(const int *)(uintptr_t)0x7000;
  int count=stage==3 ? 1:0;
  fixture_expect(sql,count,types,params,lengths,formats,1);
  CHECK(PQsendQueryParams(c,sql,count,types,params,lengths,formats,1)==(mode==4 && stage==2 ? 0:1));
  if(mode==4 && stage==2)break;
  CHECK(PQflush(c)==(mode==5 && stage==2 ? -1:0));if(mode==5 && stage==2)break;
  CHECK(PQconsumeInput(c)==(mode==6 && stage==2 ? 0:1));if(mode==6 && stage==2)break;
  CHECK(PQisBusy(c)==(mode==8 ? 1:0));
  struct pollfd p={.fd=19,.events=POLLIN,.revents=0};errno=E2BIG;int result=poll(&p,1,17);
  if(result!=(mode==9 || mode==11 ? -1:mode==10 ? 0:1) || errno!=(mode==9 ? EINTR:mode==11 ? EIO:EAGAIN) ||
     p.revents!=(mode==11 ? POLLERR:POLLIN))abort();
  CHECK(PQgetResult(c)==(PGresult *)(uintptr_t)0x5678);
  if(mode==17 && stage==3)CHECK(PQgetResult(c)==(PGresult *)(uintptr_t)0x5678);
  CHECK(PQgetResult(c)==NULL);
 }
 CHECK((PQfinish(c),1));
}
static void *worker(void *unused) { (void)unused;one(0);return NULL; }
int main(int argc,char **argv) {
 int mode=argc>1 ? atoi(argv[1]):0;
 if(mode==25) {
  pthread_t threads[8];for(int i=0;i<8;++i)if(pthread_create(&threads[i],NULL,worker,NULL))abort();
  for(int i=0;i<8;++i)if(pthread_join(threads[i],NULL))abort();
 } else if(mode==24) { for(int i=0;i<257;++i)one(1); }
 else one(mode);
 return 0;
}
'''


class CanonicalTraceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="asm-canonical-trace-mock-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.base = Path(cls.temporary.name)
        cls.source = ROOT / "tools/diagnostics/canonical_libpq_trace.c"
        cls.headers = subprocess.check_output(["pkg-config", "--cflags", "libpq"], text=True).strip()
        cls.header_version = subprocess.check_output(["pkg-config", "--modversion", "libpq"], text=True).strip()
        cls.compiler = subprocess.check_output(["cc", "--version"], text=True).splitlines()[0]
        cls.system = platform.system()
        cls.built = False

    @classmethod
    def build(cls):
        if cls.built:
            return
        if cls.system not in ("Darwin", "Linux"):
            raise RuntimeError("The typed mock smoke requires Darwin or Linux.")
        suffix = ".dylib" if cls.system == "Darwin" else ".so"
        shared = "-dynamiclib" if cls.system == "Darwin" else "-shared"
        flags = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC", "-pthread", *shlex.split(cls.headers)]
        cls.trace, cls.provider = cls.base / ("trace" + suffix), cls.base / ("provider" + suffix)
        (cls.base / "provider.c").write_text(PROVIDER)
        (cls.base / "driver.c").write_text(DRIVER)
        libraries = [] if cls.system == "Darwin" else ["-ldl"]
        subprocess.run([*flags, shared, str(cls.base / "provider.c"), "-o", str(cls.provider), *libraries], capture_output=True, check=True, timeout=20)
        dependency = ["-Wl,-needed_library," + str(cls.provider)] if cls.system == "Darwin" else []
        subprocess.run([*flags, shared, str(cls.source), "-o", str(cls.trace), *dependency, *libraries], capture_output=True, check=True, timeout=20)
        cls.executable = cls.base / "driver"
        subprocess.run([*flags, str(cls.base / "driver.c"), str(cls.trace), str(cls.provider), "-Wl,-rpath," + str(cls.base), "-o", str(cls.executable)], capture_output=True, check=True, timeout=20)
        cls.built = True

    def run_case(self, mode=0, *, error=None):
        self.assertTrue(self.source.is_file(), "The canonical observer is not implemented.")
        type(self).build()
        env = {key: value for key, value in os.environ.items() if key not in {"LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "DYLD_FORCE_FLAT_NAMESPACE"}}
        if self.system == "Darwin":
            env.update(DYLD_INSERT_LIBRARIES=str(self.trace), DYLD_FORCE_FLAT_NAMESPACE="1")
        else:
            env["LD_PRELOAD"] = str(self.trace)
        result = subprocess.run([str(self.executable), str(mode)], env=env, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stdout, b"")
        self.assertNotIn(b"private", result.stderr)
        self.assertTrue(all(len(line) <= 4096 for line in result.stderr.splitlines(keepends=True)))
        if error:
            self.assertIn(b"ASM_CANONICAL_TRACE_ERROR=" + error.encode(), result.stderr)
        else:
            self.assertNotIn(b"ASM_CANONICAL_TRACE_ERROR=", result.stderr)
        records = [json.loads(line[len(PREFIX):]) for line in result.stderr.splitlines() if line.startswith(PREFIX)]
        self.assertLessEqual(len(records), 256)
        spec = importlib.util.spec_from_file_location("canonical_trace_mock_reader", ROOT / "tools/canonical_riscv_trace.py")
        reader = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(reader)
        log = self.base / ("result-" + str(mode) + ".log")
        log.write_bytes(result.stderr)
        if error:
            with self.assertRaises(ValueError):
                reader.read_trace(log)
        else:
            found, matched = reader.read_trace(log)
            self.assertEqual(found, records)
            self.assertEqual(matched, b"".join(line for line in result.stderr.splitlines(keepends=True) if line.startswith(PREFIX)))
        return records, result.stderr

    def test_three_ordinals_preserve_all_arguments_callbacks_results_and_errno(self):
        found = self.run_case()[0][0]
        self.assertEqual((found["route"], found["sends"], found["active_phase"], found["first_api"]), (0, 3, 3, 0))
        self.assertEqual([phase["status"] for phase in found["phases"]], [1, 2, 2])
        self.assertEqual([phase["guard"] for phase in found["phases"]], [-1, 1, -1])
        self.assertTrue(all(phase["drain_ns"] > phase["result_ns"] >= phase["send_ns"] > 0 for phase in found["phases"]))
        self.assertTrue(found["end_cpu_ns"] >= found["finish_cpu_ns"] >= found["start_cpu_ns"] > 0)

    def test_null_constructor_does_not_claim_a_finish_call(self):
        found = self.run_case(1)[0][0]
        self.assertEqual((found["connect_return"], found["finish_called"], found["finish_ns"], found["first_api"]), (0, 0, 0, 1))
        self.assertGreater(found["end_ns"], found["start_ns"])

    def test_provider_internal_constructor_calls_do_not_claim_application_ownership(self):
        found = self.run_case(21)[0][0]
        self.assertEqual((found["first_api"], found["socket"]), (0, 19))
        self.assertEqual(found["poll_calls"], 3)

    def test_query_failures_retain_the_exact_entered_ordinal(self):
        for mode, api in ((4, 5), (5, 6), (6, 7), (12, 10), (13, 15), (14, 11), (15, 13), (16, 15)):
            with self.subTest(mode=mode):
                found = self.run_case(mode)[0][0]
                self.assertEqual(found["first_api"], api)
                self.assertEqual(found["phases"][1]["ordinal"], 2)
        found = self.run_case(12)[0][0]
        self.assertEqual(found["phases"][1]["sqlstate"], "57014")
        self.assertEqual(self.run_case(13)[0][0]["phases"][1]["guard"], 0)
        self.assertEqual(self.run_case(16)[0][0]["phases"][1]["guard"], -1)

    def test_connect_and_poll_adversity_survives_later_calls(self):
        for mode, api in ((2, 2), (3, 3), (7, 4), (9, 9), (10, 9), (11, 9), (17, 16), (29, 10)):
            with self.subTest(mode=mode):
                self.assertEqual(self.run_case(mode)[0][0]["first_api"], api)
        self.assertEqual(self.run_case(9)[0][0]["poll_eintr"], 3)
        self.assertEqual(self.run_case(10)[0][0]["poll_timeouts"], 3)

    def test_readiness_can_finish_after_guard_without_inventing_export(self):
        found = self.run_case(28)[0][0]
        self.assertEqual((found["sends"], found["active_phase"]), (2, 2))
        self.assertEqual((found["phases"][2]["send_ns"], found["phases"][2]["status"]), (0, -1))

    def test_export_metadata_uses_the_canonical_limit_instead_of_the_reference_limit(self):
        found = self.run_case(30)[0][0]
        self.assertEqual((found["phases"][2]["bytes"], found["first_api"]), (20000, 0))
        oversized = self.run_case(31)[0][0]
        self.assertEqual((oversized["phases"][2]["bytes"], oversized["first_api"]), (4194305, 14))

    def test_untrusted_sqlstate_is_not_logged(self):
        self.assertTrue(all(phase["sqlstate"] == "" for phase in self.run_case(20)[0][0]["phases"]))

    def test_ownership_extra_phase_and_clock_errors_are_inconclusive(self):
        for mode, error in ((18, "ownership"), (19, "phase"), (22, "clock"), (23, "clock")):
            with self.subTest(mode=mode):
                self.run_case(mode, error=error)

    def test_parallel_workers_keep_records_and_connection_ids_separate(self):
        records = self.run_case(25)[0]
        self.assertEqual(len(records), 8)
        self.assertEqual(len({item["id"] for item in records}), 8)
        self.assertTrue(all(item["sends"] == 3 for item in records))

    def test_record_count_overflow_is_visible(self):
        records, raw = self.run_case(24, error="record_count")
        self.assertEqual(len(records), 256)
        self.assertLessEqual(len(raw), 1048576)


def trace_record(identity=1):
    value = {
        "schema": 1, "id": identity, "route": 0,
        "start_ns": 1, "start_cpu_ns": 1, "created_ns": 2, "created_cpu_ns": 2,
        "connect_ns": 3, "connect_cpu_ns": 3, "finish_ns": 40, "finish_cpu_ns": 40,
        "end_ns": 41, "end_cpu_ns": 41, "finish_called": 1, "connect_return": 1,
        "connect_poll": 3, "nonblocking": 0, "socket": 19, "sends": 3, "active_phase": 3,
        "first_api": 0, "first_return": 0, "first_errno": 0, "poll_calls": 3,
        "poll_ns": 3, "poll_cpu_ns": 3, "poll_return": 1, "poll_errno": 0,
        "poll_events": 1, "poll_revents": 1, "poll_timeout": 17,
        "poll_eintr": 0, "poll_timeouts": 0, "poll_errors": 0, "phases": [],
    }
    for ordinal in (1, 2, 3):
        value["phases"].append({
            "ordinal": ordinal, "send_ns": ordinal * 10, "send_cpu_ns": ordinal * 10,
            "result_ns": ordinal * 10 + 1, "result_cpu_ns": ordinal * 10 + 1,
            "drain_ns": ordinal * 10 + 2, "drain_cpu_ns": ordinal * 10 + 2,
            "send_return": 1, "results": 1, "status": 1 if ordinal == 1 else 2,
            "rows": 0 if ordinal == 1 else 1, "fields": 0 if ordinal == 1 else 1,
            "null_cell": -1 if ordinal == 1 else 0,
            "bytes": -1 if ordinal == 1 else 1 if ordinal == 2 else 20000,
            "guard": 1 if ordinal == 2 else -1, "sqlstate": "",
        })
    return value


def trace_line(value):
    return PREFIX + json.dumps(value, sort_keys=True).encode("ascii") + b"\n"


class CanonicalTraceReaderTests(unittest.TestCase):
    def reader(self):
        path = ROOT / "tools/canonical_riscv_trace.py"
        self.assertTrue(path.is_file(), "The bounded canonical trace reader is not implemented.")
        spec = importlib.util.spec_from_file_location("canonical_trace_reader", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def read(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private-input.log"
            path.write_bytes(data)
            return self.reader().read_trace(path)

    def test_raw_matching_lines_and_connection_order_are_retained(self):
        first, second = trace_line(trace_record(2)), trace_line(trace_record(1))
        found, raw = self.read(b"fixed unrelated line\n" + first + second)
        self.assertEqual([item["id"] for item in found], [2, 1])
        self.assertEqual(raw, first + second)
        self.assertEqual(found[0]["phases"][2]["bytes"], 20000)

    def test_unknown_fields_wrong_types_and_unsafe_sqlstate_are_refused(self):
        cases = []
        for key, bad in (("route", 1), ("id", True), ("start_ns", 0), ("first_api", 17),
                         ("connect_poll", 5), ("end_ns", 1 << 63), ("schema", 1.0)):
            value = trace_record(); value[key] = bad; cases.append(value)
        value = trace_record(); value["unknown"] = "private text"; cases.append(value)
        value = trace_record(); value["phases"][1]["sqlstate"] = "private text"; cases.append(value)
        value = trace_record(); value["phases"][2]["guard"] = 1; cases.append(value)
        value = trace_record(); value["phases"][1]["ordinal"] = 1; cases.append(value)
        for value in cases:
            with self.subTest(value=str(value)[:80]), self.assertRaisesRegex(ValueError, "^Invalid canonical trace evidence\\.$"):
                self.read(trace_line(value))
        for payload in (b'{"schema":1,"schema":1}', b'{"schema":NaN}', b'private provider text'):
            with self.assertRaisesRegex(ValueError, "^Invalid canonical trace evidence\\.$"):
                self.read(PREFIX + payload + b"\n")

    def test_incomplete_clocks_and_phase_order_are_not_accepted(self):
        for change in ("finish", "phase", "drain", "cpu"):
            value = trace_record()
            if change == "finish": value["finish_called"] = 0
            elif change == "phase": value["active_phase"] = 2
            elif change == "drain": value["phases"][0]["drain_ns"] = 0
            else: value["end_cpu_ns"] = 1
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.read(trace_line(value))

    def test_connection_completion_cannot_follow_finish_entry_before_any_send(self):
        for clock in ("wall", "cpu"):
            value = trace_record()
            value.update(sends=0, active_phase=0, nonblocking=-1, first_api=3, first_return=-1, first_errno=11)
            for phase in value["phases"]:
                phase.update({name: 0 for name in ("send_ns", "send_cpu_ns", "result_ns", "result_cpu_ns", "drain_ns", "drain_cpu_ns", "results")})
                phase.update({name: -1 for name in ("send_return", "status", "rows", "fields", "null_cell", "bytes", "guard")})
            if clock == "wall":
                value.update(connect_ns=35, finish_ns=30)
            else:
                value.update(connect_cpu_ns=35, finish_cpu_ns=30)
            with self.subTest(clock=clock), self.assertRaises(ValueError):
                self.read(trace_line(value))

    def test_duplicate_connections_errors_missing_and_embedded_prefix_fail_closed(self):
        for data in (b"unrelated only\n", trace_line(trace_record()) * 2,
                     b"ASM_CANONICAL_TRACE_ERROR=clock\n" + trace_line(trace_record()),
                     b"unexpected " + trace_line(trace_record()), trace_line(trace_record())[:-1]):
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                self.read(data)

    def test_record_line_file_and_count_bounds_are_enforced(self):
        original = trace_line(trace_record())
        exact = original[:-1] + b" " * (4096 - len(original)) + b"\n"
        self.assertEqual(len(self.read(exact)[1]), 4096)
        with self.assertRaises(ValueError): self.read(exact[:-1] + b" \n")
        complete = b"".join(trace_line(trace_record(index)) for index in range(1, 257))
        self.assertEqual(len(self.read(complete)[0]), 256)
        with self.assertRaises(ValueError): self.read(complete + trace_line(trace_record(1)))
        with self.assertRaises(ValueError): self.read(original + b"x" * 1048576)

    def test_links_directories_and_fifos_are_refused_without_input_disclosure(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            original = base / "original"; original.write_bytes(trace_line(trace_record()))
            link = base / "link"; link.symlink_to(original)
            fifo = base / "fifo"; os.mkfifo(fifo)
            for path in (base, link, fifo):
                with self.subTest(path=path.name), self.assertRaisesRegex(ValueError, "^Invalid canonical trace evidence\\.$"):
                    self.reader().read_records(path)


if __name__ == "__main__":
    unittest.main()
