#!/usr/bin/env python3
"""Check diagnostic forwarding, bounded output, and failure preservation.
SPDX-License-Identifier: AGPL-3.0-or-later
No PostgreSQL server, network, Docker, or package code is executed.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import riscv_probe as probe

FAKE = r'''
#include <libpq-fe.h>
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
static int phase=-1, delivered, finished;
static const char *state="57014", *last_sql;
static PGconn *connection=(PGconn *)(uintptr_t)0x1234;
int poll(struct pollfd *fds,nfds_t count,int timeout) {
    if(count!=1 || timeout!=0) abort();
    fds[0].revents=POLLERR; errno=EAGAIN; return -1;
}
void fixture_state(const char *value) { state=value; }
int fixture_forwarded(void) { return finished && phase==2 && last_sql && strcmp(last_sql,"SQL must stay private")==0; }
PGconn *PQconnectStartParams(const char *const *keys,const char *const *values,int expand) {
    if (!keys || !values || expand!=1) { abort(); }
    return connection;
}
PostgresPollingStatusType PQconnectPoll(PGconn *c) { if(c!=connection) abort(); return PGRES_POLLING_OK; }
int PQsslInUse(PGconn *c) { if(c!=connection) abort(); return 1; }
int PQsetnonblocking(PGconn *c,int value) { if(c!=connection || value!=1) abort(); return 0; }
int PQsendQueryParams(PGconn *c,const char *sql,int count,const Oid *types,const char *const *values,
                      const int *lengths,const int *formats,int format) {
    if(c!=connection || types || lengths || formats || format || count!=(phase==1 ? 1:0)) abort();
    if(phase==1 && (!values || strcmp(values[0],"/registry/v1/index-all.tsv"))) abort();
    ++phase; delivered=0; last_sql=sql; return 1;
}
int PQflush(PGconn *c) { if(c!=connection) abort(); return 0; }
int PQconsumeInput(PGconn *c) { if(c!=connection) abort(); return 1; }
PGresult *PQgetResult(PGconn *c) { if(c!=connection) abort(); return delivered++ ? NULL : (PGresult *)(uintptr_t)0x5678; }
ExecStatusType PQresultStatus(const PGresult *r) { (void)r; return phase==0 ? PGRES_COMMAND_OK : phase==1 ? PGRES_TUPLES_OK : PGRES_FATAL_ERROR; }
int PQntuples(const PGresult *r) { (void)r; return phase==1 ? 1:0; }
int PQnfields(const PGresult *r) { (void)r; return phase==1 ? 1:0; }
int PQgetisnull(const PGresult *r,int row,int column) { (void)r; (void)row; (void)column; return 0; }
int PQgetlength(const PGresult *r,int row,int column) { (void)r; (void)row; (void)column; return 1; }
char *PQgetvalue(const PGresult *r,int row,int column) { (void)r; (void)row; (void)column; return "1"; }
char *PQresultErrorField(const PGresult *r,int field) { (void)r; return phase==2 && field==PG_DIAG_SQLSTATE ? (char *)state : NULL; }
void PQfinish(PGconn *c) { if(c!=connection) abort(); finished=1; }
'''
DRIVER = r'''
#include <libpq-fe.h>
#include <stdint.h>
#include <errno.h>
#include <poll.h>
extern void fixture_state(const char *);
extern int fixture_forwarded(void);
int main(int argc,char **argv) {
    const char *keys[]={"dbname",0}, *values[]={"connection data must stay private",0};
    if(argc==2) fixture_state(argv[1]);
    PGconn *c=PQconnectStartParams(keys,values,1);
    struct pollfd p={.fd=-1,.events=POLLIN,.revents=0};
    if(poll(&p,1,0)!=-1 || errno!=EAGAIN || p.revents!=POLLERR) return 5;
    if(c!=(PGconn *)(uintptr_t)0x1234 || PQconnectPoll(c)!=PGRES_POLLING_OK || PQsslInUse(c)!=1 || PQsetnonblocking(c,1)!=0) return 1;
    const char *params[]={"/registry/v1/index-all.tsv"};
    for(int i=0;i<3;++i) {
        if(PQsendQueryParams(c,"SQL must stay private",i==2 ? 1:0,0,i==2 ? params:0,0,0,0)!=1 || PQflush(c)!=0 || PQconsumeInput(c)!=1) return 2;
        if(PQgetResult(c)!=(PGresult *)(uintptr_t)0x5678 || PQgetResult(c)!=0) return 3;
    }
    PQfinish(c);
    return fixture_forwarded() ? 0:4;
}
'''


class DiagnosticTests(unittest.TestCase):
    def test_response_identity_refuses_arbitrary_body_code_and_header_text(self):
        secret = "postgresql://do-not-log.invalid/private.key"
        body = json.dumps({"error": {"code": secret}}).encode()
        found = probe.response_identity(503, {"Content-Type": secret}, body)
        self.assertEqual(found["status"], 503)
        self.assertEqual(found["bytes"], len(body))
        self.assertEqual(found["body_sha256"], hashlib.sha256(body).hexdigest())
        self.assertEqual(found["error_code"], "unrecognized")
        self.assertEqual(found["content_type"], "unrecognized")
        self.assertNotIn(secret, json.dumps(found))

    def test_response_identity_distinguishes_the_fixed_application_error(self):
        found = probe.response_identity(503, {"Content-Type": "application/json; charset=utf-8"},
            b'{"error":{"code":"temporarily_unavailable","message":"The database request could not finish. Try again shortly."}}\n')
        self.assertEqual(found["error_code"], "temporarily_unavailable")
        self.assertEqual(found["content_type"], "application/json; charset=utf-8")
        self.assertTrue(found["exact_application_unavailable_body"])

    def test_trace_refuses_an_oversized_file(self):
        with tempfile.TemporaryDirectory(prefix="asm-trace-bound-") as directory:
            path = Path(directory)/"trace.log"
            path.write_bytes(b"x"*(1024*1024+1))
            with self.assertRaises(ValueError):
                probe.read_traces(path)

    def test_assertions_still_fail_without_disclosing_response_differences(self):
        class Case(unittest.TestCase):
            def runTest(self):
                self.assertEqual("arbitrary response text", "expected")
        result = probe.SafeResult()
        Case().run(result)
        self.assertEqual(result.testsRun, 1)
        self.assertEqual(len(result.failures), 1)
        self.assertEqual(result.failures[0][1], "AssertionError")
        self.assertFalse(result.wasSuccessful())

    def test_interposer_forwards_calls_and_only_emits_bounded_metadata(self):
        if platform.system() != "Linux":
            raise RuntimeError("Linux LD_PRELOAD forwarding check did not run on this host.")
        with tempfile.TemporaryDirectory(prefix="asm-trace-check-") as directory:
            base = Path(directory)
            fake = base/"fake.c"
            driver = base/"driver.c"
            fake.write_text(FAKE)
            driver.write_text(DRIVER)
            flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "libpq"], text=True))
            extension = ".so"
            shared = "-shared"
            library = base/("libfakepq"+extension)
            trace = base/("trace"+extension)
            source = Path(__file__).with_name("libpq_trace.c")
            for item, output in ((fake, library), (source, trace)):
                args = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC", shared, *flags,
                        str(item), "-o", str(output), "-pthread"]
                args.append("-ldl")
                subprocess.run(args, check=True, capture_output=True, timeout=15)
            executable = base/"driver"
            subprocess.run(["cc", *flags, str(driver), str(library), "-Wl,-rpath,"+str(base), "-o", str(executable)],
                           check=True, capture_output=True, timeout=15)
            env = {key: value for key, value in os.environ.items() if key not in
                   {"LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "DYLD_FORCE_FLAT_NAMESPACE"}}
            env["LD_PRELOAD"] = str(trace)
            for state, expected in (("57014", "57014"), ("arbitrary SQL state must stay private", "")):
                result = subprocess.run([str(executable), state],
                                        env=env, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                path = base/"trace.log"
                path.write_bytes(result.stderr)
                records = probe.read_traces(path)
                self.assertEqual(len(records), 1)
                record = records[0]
                self.assertEqual(record["sends"], 3)
                self.assertEqual(record["polls"], 1)
                self.assertEqual(record["poll_result"], -1)
                self.assertEqual(record["poll_revents"], 8)
                self.assertEqual(record["route"], 3)
                self.assertEqual(record["phases"][1]["guard_one"], 1)
                self.assertEqual(record["phases"][2]["status"], 7)
                self.assertEqual(record["phases"][2]["sqlstate"], expected)
                self.assertLess(len(result.stderr), 3072)
                self.assertNotIn(b"private", result.stderr)
                # Invalid producer keys and values cannot become output.
                for change in (dict(record, unexpected=1), dict(record, route="private")):
                    path.write_text(probe.TRACE+json.dumps(change)+"\n")
                    with self.assertRaises(ValueError):
                        probe.read_traces(path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
