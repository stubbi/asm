"""Independent real-SQL oracles in a disposable database of the owned cluster.

SPDX-License-Identifier: AGPL-3.0-or-later
The benchmark Asm catalog receives only fixed baseline SELECTs. Cluster-global
CREATE/DROP DATABASE commands use its management connection. Case mutations use
a separate database, one rollback-only transaction, and no roles or grants.
This is diagnostic orchestration, not native package-manager implementation.
"""
import hashlib
import importlib
import json
import math
from pathlib import Path
import re
import time
from types import SimpleNamespace

import riscv64_reference_performance as perf

ERROR = "The bounded SQL equivalence check failed."
MIGRATION_SHA384 = "e9fce69caa758cb9d15a700d92b76aba0fc3ca466a81624733124a742f2211aadae612ab877bd908a6e1d6ab5e803ef2"
MAX_SQL = 16384
MAX_REPORT = 32768
SUMMARY_ZERO = 'Text "quoted" <script>ignored</script> & data'


class EquivalenceError(Exception):
    pass


def _digest(data):
    return hashlib.sha256(data).hexdigest()


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def _package(index):
    return {"name": f"fixture/p{index:02d}", "latest": "0.2.0",
        "summary": SUMMARY_ZERO if index == 0 else f"Assembly fixture {index:02d}",
        "license": "MIT", "owner_github_id": 12345, "targets": ["x86_64-linux"]}


def _result(packages=(), next_after=None):
    return {"schema": 0, "experimental": True, "packages": list(packages),
            "next_after": next_after, "order": "package-name-ascii"}


def _semantic(version, summary, targets=("x86_64-linux",), license="MIT"):
    return _result([{"name": "fixture/semantic", "latest": version, "summary": summary,
        "license": license, "owner_github_id": 12345, "targets": list(targets)}])


def _same(actual, expected):
    if type(actual) is not type(expected):
        return False
    if type(expected) is dict:
        return list(actual) == list(expected) and all(_same(actual[key], value) for key, value in expected.items())
    if type(expected) is list:
        return len(actual) == len(expected) and all(_same(a, b) for a, b in zip(actual, expected))
    return actual == expected


def _absolute(deadline):
    perf._budget(deadline)
    return min(deadline, time.monotonic() + 2)


def _command(db, sql, params, deadline):
    if any(type(value) not in (str, int) for value in params):
        raise ValueError(ERROR)
    return perf._query(db, sql, [str(value) for value in params], _absolute(deadline), command=True)


def _script(db, sql, deadline):
    """Execute only the exact migration or the fixed seed script, with no rows."""
    absolute = _absolute(deadline)
    lib = db.lib
    import ctypes
    lib.PQsendQuery.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.PQsendQuery.restype = ctypes.c_int
    if lib.PQsendQuery(db.conn, sql.encode("ascii")) != 1:
        raise ValueError(ERROR)
    while True:
        perf._budget(absolute)
        flushed = lib.PQflush(db.conn)
        if flushed == 0:
            break
        if flushed != 1:
            raise ValueError(ERROR)
        db.wait(True, absolute)
    count = 0
    while True:
        perf._budget(absolute)
        if lib.PQconsumeInput(db.conn) != 1:
            raise ValueError(ERROR)
        if lib.PQisBusy(db.conn):
            db.wait(False, absolute)
            continue
        result = lib.PQgetResult(db.conn)
        if not result:
            if not 0 < count <= 128:
                raise ValueError(ERROR)
            perf._budget(absolute)
            return
        try:
            count += 1
            if count > 128 or lib.PQresultStatus(result) != 1:
                raise ValueError(ERROR)
        finally:
            lib.PQclear(result)


SEED = """
BEGIN ISOLATION LEVEL READ COMMITTED;
INSERT INTO asm.accounts (id,github_id) OVERRIDING SYSTEM VALUE VALUES (1,12345);
INSERT INTO asm.namespaces (name,owner_id) VALUES ('fixture',1);
INSERT INTO asm.packages (id,namespace,name) OVERRIDING SYSTEM VALUE
 SELECT i+1,'fixture','p'||lpad(i::text,2,'0') FROM generate_series(0,22) i;
INSERT INTO asm.releases (id,package_id,major,minor,patch,summary,license,source_repository,source_commit,source_path,record_digest)
 OVERRIDING SYSTEM VALUE SELECT i+1,i+1,0,2,0,
 CASE WHEN i=0 THEN 'Text "quoted" <script>ignored</script> & data' ELSE 'Assembly fixture '||lpad(i::text,2,'0') END,
 'MIT','https://github.com/stubbi/asm',repeat('a',40),'.',repeat('b',64) FROM generate_series(0,22) i;
INSERT INTO asm.artifacts (id,release_id,ordinal,target,kind,sha256,url,bytes) OVERRIDING SYSTEM VALUE
 SELECT i+1,i+1,0,'x86_64-linux','source',repeat('b',64),
 'https://github.com/stubbi/asm/releases/download/v0.2.0/p'||lpad(i::text,2,'0')||'.tar.gz',512 FROM generate_series(0,22) i;
INSERT INTO asm.publication_events (id,release_id,kind,acceptance_repository,acceptance_commit,yanked) OVERRIDING SYSTEM VALUE
 SELECT i+1,i+1,'operator_import','https://github.com/stubbi/asm',repeat('c',40),false FROM generate_series(0,22) i;
COMMIT;
"""
COUNTS = """SELECT json_build_object('accounts',(SELECT count(*) FROM asm.accounts),
'namespaces',(SELECT count(*) FROM asm.namespaces),'packages',(SELECT count(*) FROM asm.packages),
'releases',(SELECT count(*) FROM asm.releases),'artifacts',(SELECT count(*) FROM asm.artifacts),
'publications',(SELECT count(*) FROM asm.publication_events))::text"""


def _snapshot(db, baseline, deadline):
    first = perf._json(perf._query(db, baseline, ["", ""], _absolute(deadline)))
    last = perf._json(perf._query(db, baseline, ["", "fixture/p19"], _absolute(deadline)))
    counts = perf._json(perf._query(db, COUNTS, [], _absolute(deadline)))
    if (not _same(first, _result([_package(i) for i in range(20)], "fixture/p19"))
            or not _same(last, _result([_package(i) for i in range(20, 23)]))
            or not _same(counts, {"accounts": 1, "namespaces": 1, "packages": 23,
                                 "releases": 23, "artifacts": 23, "publications": 23})):
        raise EquivalenceError(ERROR)
    return _digest(_canonical([first, last, counts]))


def _compare(db, baseline, candidate, params, expected, deadline, row):
    absolute = _absolute(deadline)
    row["outcome"] = "fail"
    a = perf._query(db, baseline, params, absolute)
    row["baseline_sha256"] = _digest(a)
    b = perf._query(db, candidate, params, absolute)
    row["candidate_sha256"] = _digest(b)
    row["expected_sha256"] = _digest(_canonical(expected))
    if a != b or not _same(perf._json(a), expected) or not _same(perf._json(b), expected):
        raise EquivalenceError(ERROR)
    perf._budget(absolute)
    row["outcome"] = "pass"


def _release(db, deadline, serial, version, summary, *, publish=True, yanked=False, targets=None, license="MIT"):
    major, minor, patch = version
    release_id = 10000 + serial
    _command(db, """INSERT INTO asm.releases
 (id,package_id,major,minor,patch,summary,license,source_repository,source_commit,source_path,record_digest)
 OVERRIDING SYSTEM VALUE VALUES ($1,10000,$2,$3,$4,$5,$6,'https://github.com/stubbi/asm',repeat('a',40),'.',repeat('b',64))""",
        [release_id, major, minor, patch, summary, license], deadline)
    entries = targets or [("x86_64-linux", "source")]
    for ordinal, (target, kind) in enumerate(entries):
        _command(db, """INSERT INTO asm.artifacts (id,release_id,ordinal,target,kind,sha256,url,bytes)
 OVERRIDING SYSTEM VALUE VALUES ($1,$2,$3,$4,$5,repeat('b',64),$6,512)""",
            [20000 + serial * 10 + ordinal, release_id, ordinal, target, kind,
             f"https://github.com/stubbi/asm/releases/download/sqlcase/{serial}-{ordinal}.tar.gz"], deadline)
    if publish:
        _command(db, """INSERT INTO asm.publication_events
 (id,release_id,kind,acceptance_repository,acceptance_commit,yanked,yank_reason)
 OVERRIDING SYSTEM VALUE VALUES ($1,$2,'operator_import','https://github.com/stubbi/asm',repeat('c',40),$3,
 CASE WHEN $3::boolean THEN 'semantic fixture' ELSE NULL END)""",
            [30000 + serial, release_id, "true" if yanked else "false"], deadline)


def verify(case, baseline: str, candidate: str, deadline: float) -> dict:
    """Require independent JSON answers and raw A/B equality before profiling."""
    started = time.monotonic()
    empty = lambda index: {"index": index, "outcome": "not-run", "baseline_sha256": "",
                            "candidate_sha256": "", "expected_sha256": ""}
    report = {"schema": 1, "scope": "reference-search-sql-equivalence", "qualification": "UNQUALIFIED",
        "outcome": "fail", "expected_cases": 16, "cases": [{**empty(i), "checks": 0} for i in range(1, 17)],
        "original_queries": [empty(i) for i in range(1, 24)], "original_queries_passed": 0,
        "cleanup": {"transaction_rolled_back": False, "case_database_dropped": False,
                    "original_catalog_unchanged": False}, "baseline_sha256": "", "candidate_sha256": ""}
    management = database = None
    created = transaction = False
    original = None
    failure = "invalid-input"
    try:
        if (type(deadline) not in (int, float) or not math.isfinite(deadline)
                or type(baseline) is not str or type(candidate) is not str):
            raise ValueError(ERROR)
        perf._budget(deadline)
        a, b = baseline.encode("ascii"), candidate.encode("ascii")
        if not 0 < len(a) <= MAX_SQL or not 0 < len(b) <= MAX_SQL or _digest(a) != perf.QUERY_SHA:
            raise ValueError(ERROR)
        report.update(baseline_sha256=_digest(a), candidate_sha256=_digest(b))
        if (re.fullmatch(r"asm_proto_[0-9a-f]{12}", case.names) is None or case.dbname != case.names
                or case.fixture_ready is not True or any(key.startswith("PG") for key in perf.os.environ)):
            raise ValueError(ERROR)
        name = case.names + "_sqlcases"
        fixture = importlib.import_module("local_postgres")
        migration = perf._read(Path(fixture.__file__).parent / "fixtures/0001_registry.sql", MAX_SQL)
        if hashlib.sha384(migration).hexdigest() != MIGRATION_SHA384:
            raise ValueError(ERROR)
        failure = "database-operation"
        management = perf._connect(fixture, perf._url(case, admin=True), _absolute(deadline))
        original = _snapshot(management, baseline, deadline)
        _command(management, 'CREATE DATABASE "' + name + '"', [], deadline)
        created = True
        target = SimpleNamespace(cluster=case.cluster, dbname=name)
        database = perf._connect(fixture, perf._url(target, admin=True), _absolute(deadline))
        _script(database, migration.decode("ascii"), deadline)
        _script(database, SEED, deadline)

        def group(index, checks):
            record = report["cases"][index - 1]
            record["outcome"] = "fail"
            hashes = [[], [], []]
            for params, expected, original_index in checks:
                row = report["original_queries"][original_index] if original_index is not None else empty(1)
                try:
                    _compare(database, baseline, candidate, params, expected, deadline, row)
                finally:
                    for values, key in zip(hashes, ("baseline_sha256", "candidate_sha256", "expected_sha256")):
                        if row[key]: values.append(row[key])
                    for values, key in zip(hashes, ("baseline_sha256", "candidate_sha256", "expected_sha256")):
                        record[key] = _digest(_canonical(values)) if values else ""
                record["checks"] += 1
                if original_index is not None: report["original_queries_passed"] += 1
            record["outcome"] = "pass"

        group(1, [([f"fixture/p{i:02d}", ""], _result([_package(i)]), i) for i in range(23)])
        group(2, [(["", ""], _result([_package(i) for i in range(20)], "fixture/p19"), None),
                  (["fixture", ""], _result([_package(i) for i in range(20)], "fixture/p19"), None),
                  (["", "fixture/p19"], _result([_package(i) for i in range(20, 23)]), None)])
        group(3, [(["", "fixture/p01"], _result([_package(i) for i in range(2, 22)], "fixture/p21"), None),
                  (["fixture", "fixture/p01"], _result([_package(i) for i in range(2, 22)], "fixture/p21"), None)])
        group(4, [(["", "fixture/p02"], _result([_package(i) for i in range(3, 23)]), None),
                  (["fixture", "fixture/p02"], _result([_package(i) for i in range(3, 23)]), None)])
        group(5, [(["", "fixture/P00"], _result([_package(i) for i in range(20)], "fixture/p19"), None),
                  (["", "fixture/p0:"], _result([_package(i) for i in range(10, 23)]), None)])
        group(6, [(["", "fixture/p22"], _result(), None), (["semantic-no-match", ""], _result(), None)])
        group(7, [([token, ""], _result(), None) for token in ("%", "_", "' OR 1=1 --")])
        transaction = True
        _command(database, "BEGIN ISOLATION LEVEL READ COMMITTED", [], deadline)
        _command(database, "INSERT INTO asm.packages (id,namespace,name) OVERRIDING SYSTEM VALUE VALUES (10000,'fixture','semantic')", [], deadline)
        _release(database, deadline, 1, (12, 0, 0), "unpublishedonlyneedle", publish=False,
                 targets=[("aarch64-linux", "source")])
        group(8, [(["fixture/semantic", ""], _result(), None)])
        _release(database, deadline, 2, (9, 9, 10), "patchwinner", targets=[("riscv64-linux", "source")])
        _release(database, deadline, 3, (9, 9, 9), "retiredpatchneedle")
        group(9, [(["fixture/semantic", ""], _semantic("9.9.10", "patchwinner", ("riscv64-linux",)), None)])
        group(10, [(["retiredpatchneedle", ""], _result(), None)])
        _release(database, deadline, 4, (9, 10, 0), "minorwinner")
        group(11, [(["fixture/semantic", ""], _semantic("9.10.0", "minorwinner"), None)])
        _release(database, deadline, 5, (10, 0, 0), "majorwinner", targets=[("riscv64-linux", "executable"),
            ("x86_64-linux", "source"), ("aarch64-linux", "executable"), ("x86_64-linux", "executable")], license="Apache-2.0")
        group(12, [(["fixture/semantic", ""], _semantic("10.0.0", "majorwinner",
                    ("aarch64-linux", "riscv64-linux", "x86_64-linux"), license="Apache-2.0"), None)])
        _release(database, deadline, 6, (11, 0, 0), "yankedonlyneedle", yanked=True)
        group(13, [(["fixture/semantic", ""], _semantic("10.0.0", "majorwinner",
                    ("aarch64-linux", "riscv64-linux", "x86_64-linux"), license="Apache-2.0"), None)])
        group(14, [(["yankedonlyneedle", ""], _result(), None)])
        group(15, [(["unpublishedonlyneedle", ""], _result(), None)])
        _command(database, "ROLLBACK", [], deadline)
        transaction = False
        report["cleanup"]["transaction_rolled_back"] = True
        group(16, [(["", ""], _result([_package(i) for i in range(20)], "fixture/p19"), None),
                   (["", "fixture/p19"], _result([_package(i) for i in range(20, 23)]), None)])
        report["outcome"] = "pass"
    except Exception as error:
        report["failure"] = "equivalence" if isinstance(error, EquivalenceError) else failure
        if isinstance(error, TimeoutError) or (type(deadline) in (int, float) and math.isfinite(deadline) and time.monotonic() >= deadline):
            report["failure"] = "deadline"
    finally:
        if database is not None:
            if transaction:
                try:
                    _command(database, "ROLLBACK", [], deadline)
                    report["cleanup"]["transaction_rolled_back"] = True
                except Exception:
                    report.update(outcome="fail", failure="cleanup")
            try: database.close()
            except Exception: report.update(outcome="fail", failure="cleanup")
        if management is not None:
            if created:
                try:
                    _command(management, 'DROP DATABASE "' + name + '"', [], deadline)
                    report["cleanup"]["case_database_dropped"] = True
                except Exception: report.update(outcome="fail", failure="cleanup")
            try:
                report["cleanup"]["original_catalog_unchanged"] = original is not None and original == _snapshot(management, baseline, deadline)
            except Exception: report.update(outcome="fail", failure="cleanup")
            try: management.close()
            except Exception: report.update(outcome="fail", failure="cleanup")
    if (not all(report["cleanup"].values()) or report["original_queries_passed"] != 23
            or any(row["outcome"] != "pass" for row in report["cases"])):
        report["outcome"] = "fail"
    if len(_canonical(report)) > MAX_REPORT:
        report.update(outcome="fail", failure="invalid-input")
    if type(deadline) in (int, float) and math.isfinite(deadline) and time.monotonic() >= deadline:
        report.update(outcome="fail", failure="deadline")
    report["elapsed_seconds"] = round(time.monotonic() - started, 6)
    return report
