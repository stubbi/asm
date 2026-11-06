"""Bounded post-workload query evidence for the retained reference fixture.

SPDX-License-Identifier: AGPL-3.0-or-later
No application result is replaced. The caller owns the outer runtime limits.
EXPLAIN semantics: https://www.postgresql.org/docs/16/sql-explain.html
"""
from concurrent.futures import ThreadPoolExecutor
import ctypes
import hashlib
import importlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import stat
import tempfile
import time
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from riscv64_combined import bounded_process, elf_machine

ERROR = "Invalid bounded query-cost evidence."
QUERY_SHA = "5cd15a09fa823567a83b4042b799a33e9bd379ec3cd346b96371c02ebd234b0d"
MAX_BYTES = 65536
MAX_DEPTH = 32
MAX_NODES = 256
OPTIONS = "-c default_transaction_read_only=on -c statement_timeout=1000 -c lock_timeout=200 -c search_path=pg_catalog,public"
EXPLAIN = "EXPLAIN (ANALYZE TRUE, BUFFERS TRUE, FORMAT JSON, TIMING FALSE, SUMMARY TRUE)\n"
CPU_STAT = Path("/sys/fs/cgroup/cpu.stat")
PG_CONFIG = Path("/opt/asm/postgres/bin/pg_config")
NODE_TYPES = frozenset(("Result", "ProjectSet", "ModifyTable", "Append", "Merge Append", "Recursive Union",
    "BitmapAnd", "BitmapOr", "Seq Scan", "Sample Scan", "Gather", "Gather Merge", "Index Scan",
    "Index Only Scan", "Bitmap Index Scan", "Bitmap Heap Scan", "Tid Scan", "Tid Range Scan",
    "Subquery Scan", "Function Scan", "Table Function Scan", "Values Scan", "CTE Scan", "Named Tuplestore Scan",
    "WorkTable Scan", "Foreign Scan", "Custom Scan", "Nested Loop", "Merge Join", "Hash Join", "Materialize",
    "Memoize", "Sort", "Incremental Sort", "Group", "Aggregate", "WindowAgg", "Unique", "SetOp", "LockRows",
    "Limit", "Hash"))
RELATIONS = frozenset(("accounts", "namespaces", "packages", "releases", "artifacts", "publication_events"))
INDEXES = frozenset(("accounts_pkey", "accounts_github_id_key", "namespaces_pkey", "packages_pkey",
    "packages_full_name_key", "packages_namespace_name_key", "releases_pkey", "releases_order",
    "releases_package_id_major_minor_patch_key", "artifacts_pkey", "artifacts_selection",
    "artifacts_url_key", "artifacts_release_id_ordinal_key", "artifacts_release_id_target_kind_key",
    "publication_events_pkey", "publication_events_release_id_key"))
NUMBERS = frozenset(("Startup Cost", "Total Cost", "Plan Rows", "Plan Width", "Actual Startup Time",
    "Actual Total Time", "Actual Rows", "Actual Loops", "Rows Removed by Filter", "Rows Removed by Join Filter",
    "Rows Removed by Index Recheck", "Heap Fetches", "Shared Hit Blocks", "Shared Read Blocks",
    "Shared Dirtied Blocks", "Shared Written Blocks", "Local Hit Blocks", "Local Read Blocks",
    "Local Dirtied Blocks", "Local Written Blocks", "Temp Read Blocks", "Temp Written Blocks",
    "I/O Read Time", "I/O Write Time", "Temp I/O Read Time", "Temp I/O Write Time", "Sort Space Used",
    "Peak Memory Usage", "Hash Buckets", "Original Hash Buckets", "Hash Batches", "Original Hash Batches"))
CONTROL_SQL = """SELECT json_build_object('jit',current_setting('jit'),'jit_available',pg_jit_available(),
'statement_timeout',current_setting('statement_timeout'),'lock_timeout',current_setting('lock_timeout'),
 'transaction_read_only',current_setting('transaction_read_only'),'stats',(
 SELECT json_agg(json_build_object('table_id',v.id,'reltuples',c.reltuples,'relpages',c.relpages,
 'n_live_tup',s.n_live_tup,'n_dead_tup',s.n_dead_tup,'analyze_count',s.analyze_count,
 'autoanalyze_count',s.autoanalyze_count,'last_analyze_set',s.last_analyze IS NOT NULL,
 'last_autoanalyze_set',s.last_autoanalyze IS NOT NULL) ORDER BY v.id)
 FROM (VALUES (1,'accounts'),(2,'namespaces'),(3,'packages'),(4,'releases'),(5,'artifacts'),
 (6,'publication_events')) AS v(id,name)
 JOIN pg_catalog.pg_namespace n ON n.nspname='asm'
 JOIN pg_catalog.pg_class c ON c.relnamespace=n.oid AND c.relname=v.name
 JOIN pg_catalog.pg_stat_all_tables s ON s.relid=c.oid))::text"""


def _number(value, minimum=0):
    if type(value) not in (int, float) or not math.isfinite(value) or not minimum <= value <= 1e15:
        raise ValueError(ERROR)
    return value


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise ValueError(ERROR)
        result[key] = value
    return result


def _json(raw):
    if type(raw) is not bytes or not 0 < len(raw) <= MAX_BYTES: raise ValueError(ERROR)
    def invalid(_): raise ValueError(ERROR)
    try:
        value = json.loads(raw, object_pairs_hook=_object, parse_constant=invalid)
        count = 0
        def visit(item, depth):
            nonlocal count
            count += 1
            if depth > MAX_DEPTH or count > 10000: raise ValueError(ERROR)
            if type(item) is dict:
                for child in item.values(): visit(child, depth + 1)
            elif type(item) is list:
                for child in item: visit(child, depth + 1)
            elif type(item) in (int, float):
                if not math.isfinite(item): raise ValueError(ERROR)
        visit(value, 0)
        return value
    except (ValueError, UnicodeError, RecursionError, OverflowError):
        raise ValueError(ERROR) from None


def sanitize_plan(raw: bytes) -> dict:
    """Keep fixed identifiers and numeric plan fields; discard all expressions."""
    value = _json(raw)
    if type(value) is not list or len(value) != 1 or type(value[0]) is not dict: raise ValueError(ERROR)
    root = value[0]
    if not {"Plan", "Planning Time", "Execution Time"} <= root.keys(): raise ValueError(ERROR)
    result = {key: _number(root[key]) for key in ("Planning Time", "Execution Time")}
    count = 0
    def node(item, depth):
        nonlocal count
        count += 1
        if type(item) is not dict or count > MAX_NODES or depth > MAX_DEPTH: raise ValueError(ERROR)
        if type(item.get("Node Type")) is not str or item["Node Type"] not in NODE_TYPES: raise ValueError(ERROR)
        if not {"Startup Cost", "Total Cost", "Plan Rows", "Plan Width", "Actual Rows", "Actual Loops"} <= item.keys():
            raise ValueError(ERROR)
        safe = {"Node Type": item["Node Type"]}
        for key, allowed in (("Relation Name", RELATIONS), ("Index Name", INDEXES)):
            if key in item:
                if type(item[key]) is not str or item[key] not in allowed: raise ValueError(ERROR)
                safe[key] = item[key]
        for key in NUMBERS & item.keys(): safe[key] = _number(item[key])
        if "Plans" in item:
            if type(item["Plans"]) is not list: raise ValueError(ERROR)
            safe["Plans"] = [node(child, depth + 1) for child in item["Plans"]]
        return safe
    result["Plan"] = node(root["Plan"], 0)
    if type(root.get("Planning")) is dict:
        result["Planning"] = {k: _number(v) for k, v in root["Planning"].items() if k in NUMBERS}
    result["source_bytes"] = len(raw)
    result["source_sha256"] = hashlib.sha256(raw).hexdigest()
    return result


def _read(path, maximum):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= maximum: raise ValueError(ERROR)
        data = stream.read(maximum + 1)
    if len(data) != info.st_size or len(data) > maximum: raise ValueError(ERROR)
    return data


def _budget(deadline):
    if time.monotonic() >= deadline: raise TimeoutError(ERROR)


class QueryFailure(Exception):
    def __init__(self, status, state):
        self.status, self.state = status, state
        super().__init__(ERROR)


def _query(db, sql, params, deadline, *, command=False, maximum=MAX_BYTES):
    """Fetch exactly one non-NULL field without copying an unbounded C string."""
    lib, conn = db.lib, db.conn
    for name in ("PQgetlength", "PQgetisnull"):
        getattr(lib, name).argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        getattr(lib, name).restype = ctypes.c_int
    lib.PQgetvalue.restype = ctypes.c_void_p
    lib.PQresultErrorField.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.PQresultErrorField.restype = ctypes.c_void_p
    values = (ctypes.c_char_p * len(params))(*(v.encode() for v in params))
    _budget(deadline)
    if lib.PQsendQueryParams(conn, sql.encode(), len(params), None, values, None, None, 0) != 1:
        raise QueryFailure(-1, "")
    while True:
        _budget(deadline)
        flushing = lib.PQflush(conn)
        if flushing == 0: break
        if flushing != 1: raise QueryFailure(-1, "")
        db.wait(True, deadline)
    payload = None
    while True:
        _budget(deadline)
        if lib.PQconsumeInput(conn) != 1: raise QueryFailure(-1, "")
        if lib.PQisBusy(conn):
            db.wait(False, deadline)
            continue
        result = lib.PQgetResult(conn)
        if not result:
            if payload is None: raise ValueError(ERROR)
            _budget(deadline)
            return payload
        try:
            status = lib.PQresultStatus(result)
            if command and status == 1 and payload is None:
                payload = b""
                continue
            if status != 2:
                pointer = lib.PQresultErrorField(result, ord("C"))
                state = bytearray()
                if pointer:
                    for index in range(6):
                        character = ctypes.c_ubyte.from_address(pointer + index).value
                        if character == 0: break
                        state.append(character)
                state = state.decode("ascii") if re.fullmatch(rb"[A-Z0-9]{5}", state) else ""
                raise QueryFailure(status if type(status) is int and -1 <= status <= 12 else -1, state)
            if (payload is not None or lib.PQntuples(result) != 1 or lib.PQnfields(result) != 1
                    or lib.PQgetisnull(result, 0, 0)): raise ValueError(ERROR)
            size = lib.PQgetlength(result, 0, 0)
            if not 0 < size <= maximum: raise ValueError(ERROR)
            pointer = lib.PQgetvalue(result, 0, 0)
            if not pointer: raise ValueError(ERROR)
            payload = ctypes.string_at(pointer, size)
        finally:
            lib.PQclear(result)


def _url(case, *, admin=False):
    raw = case.cluster.url(database=case.dbname) if admin else _read(case.url_files["reader"], 4096).decode().strip()
    url = urlsplit(raw)
    if (url.scheme != "postgresql" or url.hostname != "127.0.0.1" or url.port != case.cluster.port
            or url.username != ("asm_fixture_admin" if admin else case.reader) or not url.password or not re.fullmatch(r"/[a-z0-9_]+", url.path)
            or url.fragment): raise ValueError(ERROR)
    pairs = parse_qsl(url.query, keep_blank_values=True, strict_parsing=True)
    if len(pairs) != len(dict(pairs)): raise ValueError(ERROR)
    values = dict(pairs)
    if set(values) - {"hostaddr", "sslmode", "gssencmode", "connect_timeout", "options"}: raise ValueError(ERROR)
    if values.get("hostaddr") != "127.0.0.1" or values.get("sslmode") != "disable" or values.get("gssencmode") != "disable":
        raise ValueError(ERROR)
    values.update(hostaddr="127.0.0.1", connect_timeout="2", options=OPTIONS.replace("read_only=on", "read_only=off") if admin else OPTIONS, application_name="asm-assembly-prototype")
    return urlunsplit((url.scheme, url.netloc, url.path, urlencode(values), ""))


def _guard(case):
    if case.fixture_ready is not True or not case._owned_server_stopped(case.server, case.attribution): raise ValueError(ERROR)
    if case.attribution is not None and case.attribution.failure is not None: raise ValueError(ERROR)
    data = case.diagnostic.data
    arms = data["controlled_search_comparison"]["arms"]
    if len(arms) != 2 or [arm["label"] for arm in arms] != ["direct", "proxy"]: raise ValueError(ERROR)
    for arm in arms:
        attribution = arm["attribution"]
        if (type(attribution.get("returncode")) is not int or attribution["returncode"] != 0
                or attribution.get("cleanup_errors") != []
                or attribution.get("released") is not True or attribution.get("target_ready") is not True
                or "failure" in attribution
                or any(key in arm for key in ("cleanup_failure", "log_flush_failure", "trace_failure"))): raise ValueError(ERROR)
    if any(data["phase_traces"][key].get("association") != "complete" for key in ("main", "direct", "proxy")):
        raise ValueError(ERROR)


def _connect(fixture, url, deadline):
    """Reuse fixture wait/close, with fixed parameters and a pre-poll notice sink."""
    _budget(deadline)
    db = fixture.Database.__new__(fixture.Database)
    db.conn = None
    db.lib = lib = ctypes.CDLL(os.environ["ASM_PROTO_LIBPQ"])
    signatures = {
        "PQconnectStartParams": ([ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_char_p), ctypes.c_int], ctypes.c_void_p),
        "PQsetnonblocking": ([ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
        "PQsendQueryParams": ([ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_char_p), ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
        "PQgetResult": ([ctypes.c_void_p], ctypes.c_void_p),
        "PQgetvalue": ([ctypes.c_void_p, ctypes.c_int, ctypes.c_int], ctypes.c_void_p),
    }
    for name in ("PQconnectPoll", "PQsocket", "PQflush", "PQconsumeInput", "PQisBusy", "PQresultStatus", "PQntuples", "PQnfields"):
        signatures[name] = ([ctypes.c_void_p], ctypes.c_int)
    for name in ("PQclear", "PQfinish"): signatures[name] = ([ctypes.c_void_p], None)
    for name, (args, result) in signatures.items():
        function = getattr(lib, name)
        function.argtypes, function.restype = args, result
    notice_type = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p)
    db._notice = notice_type(lambda argument, message: None)
    lib.PQsetNoticeProcessor.argtypes = [ctypes.c_void_p, notice_type, ctypes.c_void_p]
    lib.PQsetNoticeProcessor.restype = ctypes.c_void_p
    # The reader/admin URL is privately constructed above, never logged.
    # Fixed entries follow dbname expansion and override ambient/default options.
    admin = urlsplit(url).username == "asm_fixture_admin"
    options = OPTIONS.replace("read_only=on", "read_only=off") if admin else OPTIONS
    names = ("dbname", "hostaddr", "host", "connect_timeout", "options", "application_name")
    values = (url, "127.0.0.1", "127.0.0.1", "2", options, "asm-assembly-prototype")
    keys = (ctypes.c_char_p * 7)(*(key.encode() for key in names), None)
    values = (ctypes.c_char_p * 7)(*(value.encode() for value in values), None)
    try:
        _budget(deadline)
        db.conn = lib.PQconnectStartParams(keys, values, 1)
        if not db.conn: raise ValueError(ERROR)
        lib.PQsetNoticeProcessor(db.conn, db._notice, None)
        while True:
            _budget(deadline)
            status = lib.PQconnectPoll(db.conn)
            if status == 3: break
            if status not in (1, 2): raise ValueError(ERROR)
            db.wait(status == 2, deadline)
        _budget(deadline)
        if lib.PQsetnonblocking(db.conn, 1) != 0: raise ValueError(ERROR)
        return db
    except BaseException:
        db.close()
        raise


def _cpu_stat():
    try:
        with os.fdopen(os.open(CPU_STAT, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
            raw = stream.read(4097)
        if len(raw) > 4096: raise ValueError(ERROR)
        allowed = {"usage_usec", "user_usec", "system_usec", "nr_periods", "nr_throttled", "throttled_usec"}
        values = {}
        for line in raw.decode("ascii").splitlines():
            fields = line.split()
            if not fields or fields[0] not in allowed: continue
            if (len(fields) != 2 or fields[0] in values or not fields[1].isdecimal()
                    or len(fields[1]) > 20): raise ValueError(ERROR)
            values[fields[0]] = int(fields[1])
        if not values: raise ValueError(ERROR)
        return {"outcome": "pass", "values": values, "monotonic": time.monotonic()}
    except Exception:
        return {"outcome": "unavailable"}


def _analyze(fixture, url, deadline):
    report, db = {"outcome": "fail", "scope": "diagnostic-only-statistics-refresh"}, None
    absolute = min(deadline, time.monotonic() + 2)
    try:
        _budget(absolute)
        db = _connect(fixture, url, absolute)
        _query(db, "ANALYZE asm.accounts, asm.namespaces, asm.packages, asm.releases, asm.artifacts, asm.publication_events", [], absolute, command=True)
        _budget(absolute)
        report["outcome"] = "pass"
    except QueryFailure as error:
        report.update(status=error.status, sqlstate=error.state, failure="provider-status")
    except Exception:
        report["failure"] = "invalid-or-unavailable"
    finally:
        if db is not None:
            try: db.close()
            except Exception: report.update(outcome="fail", failure="cleanup")
        if time.monotonic() >= absolute: report.update(outcome="fail", failure="deadline")
    return report


def _row(fixture, url, query, index, explain, deadline):
    start = time.monotonic()
    row = {"index": index, "outcome": "fail", "stage": "connect", "status": None, "sqlstate": "",
           "start_monotonic": start, "setup_connect_ms": None, "query_ms": None, "attempted": False}
    db, connected = None, None
    absolute = min(deadline, start + 2)
    try:
        _budget(absolute)
        row["attempted"] = True
        db = _connect(fixture, url, absolute)
        connected = time.monotonic()
        row["connect_end_monotonic"] = connected
        row["setup_connect_ms"] = round((connected - start) * 1000, 6)
        row["stage"] = "query"
        raw = _query(db, (EXPLAIN if explain else "") + query, [f"fixture {index:02d}", ""], absolute,
                     maximum=MAX_BYTES if explain else 16384)
        finished = time.monotonic()
        row["query_end_monotonic"] = finished
        row["query_ms"] = round((finished - connected) * 1000, 6)
        row["status"] = 2
        row["stage"] = "result"
        if explain:
            row["plan"] = sanitize_plan(raw)
        else:
            value = _json(raw)
            if (type(value) is not dict or type(value.get("schema")) is not int or value["schema"] != 0 or value.get("experimental") is not True
                    or value.get("next_after") is not None or value.get("order") != "package-name-ascii"
                    or type(value.get("packages")) is not list or len(value["packages"]) != 1
                    or value["packages"][0].get("name") != f"fixture/p{index:02d}"): raise ValueError(ERROR)
            row["result_bytes"], row["result_sha256"] = len(raw), hashlib.sha256(raw).hexdigest()
            row["result_matches"] = True
        _budget(absolute)
        row.update(outcome="pass", stage="complete")
    except QueryFailure as error:
        row.update(status=error.status, sqlstate=error.state, failure="provider-status")
    except Exception as error:
        row["failure"] = "deadline" if isinstance(error, TimeoutError) or time.monotonic() >= absolute else "invalid-or-unavailable"
    finally:
        observed = time.monotonic()
        if connected is not None and row["query_ms"] is None:
            row["query_end_monotonic"] = observed
            row["query_ms"] = round((observed - connected) * 1000, 6)
        if connected is None:
            row["setup_connect_ms"] = round((observed - start) * 1000, 6)
        if db is not None:
            try: db.close()
            except Exception: row.update(outcome="fail", failure="cleanup")
        if time.monotonic() >= absolute: row.update(outcome="fail", failure="deadline")
        row["close_end_monotonic"] = time.monotonic()
        row["elapsed_ms"] = round((time.monotonic() - start) * 1000, 6)
    return row


def _pg_config(parent, deadline):
    report = {"outcome": "fail"}
    data = _read(PG_CONFIG, 16 * 1024 * 1024)
    elf_machine(data)
    report.update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
    with tempfile.TemporaryDirectory(prefix="pg-config-", dir=parent) as temporary:
        for option in ("--version", "--configure"):
            _budget(deadline)
            log = Path(temporary) / "output"
            args = ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "HOME=/nonexistent", "LC_ALL=C", "TZ=UTC",
                    "QEMU_LD_PREFIX=/", "LD_LIBRARY_PATH=/opt/asm/postgres/lib", str(PG_CONFIG), option]
            result = bounded_process(args, log, timeout=min(2, deadline - time.monotonic()), max_bytes=16384)
            raw = _read(log, 16384)
            report[option[2:]] = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
                                  "outcome": result["outcome"], "exit_code": result.get("exit_code")}
            if result["outcome"] != "pass": return report
            if option == "--version":
                if raw.strip() != b"PostgreSQL 16.15": raise ValueError(ERROR)
            else:
                options = shlex.split(raw.decode("ascii"))
                report["with_llvm"] = "--with-llvm" in options
    _budget(deadline)
    report["outcome"] = "pass"
    return report


def _control(fixture, url, deadline):
    start, db = time.monotonic(), None
    report = {"outcome": "fail"}
    absolute = min(deadline, start + 2)
    try:
        _budget(absolute)
        db = _connect(fixture, url, absolute)
        value = _json(_query(db, CONTROL_SQL, [], absolute))
        expected = {"jit", "jit_available", "statement_timeout", "lock_timeout", "transaction_read_only", "stats"}
        if type(value) is not dict or set(value) != expected: raise ValueError(ERROR)
        if (value["jit"] not in ("on", "off") or type(value["jit_available"]) is not bool
                or value["statement_timeout"] != "1s" or value["lock_timeout"] != "200ms"
                or value["transaction_read_only"] != "on" or type(value["stats"]) is not list
                or len(value["stats"]) != 6): raise ValueError(ERROR)
        for index, row in enumerate(value["stats"], 1):
            fields = {"table_id", "reltuples", "relpages", "n_live_tup", "n_dead_tup", "analyze_count",
                      "autoanalyze_count", "last_analyze_set", "last_autoanalyze_set"}
            if type(row) is not dict or set(row) != fields or type(row["table_id"]) is not int or row["table_id"] != index:
                raise ValueError(ERROR)
            for key in fields - {"last_analyze_set", "last_autoanalyze_set"}: _number(row[key], -1 if key == "reltuples" else 0)
            if any(type(row[key]) is not bool for key in ("last_analyze_set", "last_autoanalyze_set")): raise ValueError(ERROR)
        _budget(absolute)
        report.update(outcome="pass", **value)
    except Exception:
        report["failure"] = "invalid-or-unavailable"
    finally:
        if db is not None:
            try: db.close()
            except Exception: report.update(outcome="fail", failure="cleanup")
        if time.monotonic() >= absolute: report.update(outcome="fail", failure="deadline")
    return report


def _retain_plans(rows):
    """Keep all plan totals/root fields, with at most two bounded full trees."""
    retained = 0
    for row in rows:
        if "plan" not in row: continue
        full = row["plan"]
        keep = row["outcome"] == "pass" and retained < 2 and len(json.dumps(full, indent=2).encode()) <= MAX_BYTES
        row["full_tree_retained"] = keep
        if keep:
            retained += 1
        else:
            row["plan"] = {**full, "Plan": {key: value for key, value in full["Plan"].items() if key != "Plans"}}
    return retained


def run_diagnostic(case, source: Path, deadline: float) -> dict:
    """Collect four direct waves after original work; never print private data."""
    report = {"schema": 1, "scope": "reference-query-cost-probe", "qualification": "UNQUALIFIED", "outcome": "fail",
        "order": ["controls_before", "search_before", "explain_before", "analyze", "search_after", "explain_after", "controls_after", "pg_config"], "waves": [], "query_sha256": QUERY_SHA,
        "limits": {"seconds": 30, "per_query_seconds": 2, "statement_ms": 1000, "lock_ms": 200,
                   "workers": 8, "queries_per_wave": 16, "search_result_bytes": 16384,
                   "plan_result_bytes": MAX_BYTES, "plan_nodes": MAX_NODES,
                   "full_trees_per_explain_wave": 2, "full_tree_bytes": MAX_BYTES, "report_bytes": 512 * 1024},
        "limits_of_evidence": ["Post-workload direct libpq measurements do not replace original HTTP results.",
            "A passing diagnostic means complete usable measurements; individual query failures remain failures.",
            "setup_connect_ms includes Python/ctypes setup, connection startup, authentication and scheduling; it is not pure SCRAM cost.",
            "query_ms includes protocol, scheduling, result transfer and drain; it is not isolated server CPU.",
            "EXPLAIN ANALYZE TIMING OFF still measures total execution; it adds instrumentation and discards SELECT output.",
            "Planning Time excludes parse/rewrite; Execution Time excludes parse/rewrite/planning and ordinary result transmission.",
            "Planner costs use arbitrary cost units, not milliseconds.",
            "Python/ctypes under QEMU has different dispatch/GIL costs from the assembly/MHD application.",
            "After waves follow diagnostic-only ANALYZE and warmer caches; order effects are not isolated.",
            "Buffer counts include descendants; do not sum them as independent costs.",
            "The fixed search then EXPLAIN order and existing warm caches are not randomized comparisons.",
            "Catalog statistics are estimates and can lag; they are not measured current row counts."]}
    started = time.monotonic()
    try:
        if type(deadline) not in (int, float) or not math.isfinite(deadline): raise ValueError(ERROR)
        deadline = min(deadline, started + 30)
        _budget(deadline)
        if any(key.startswith("PG") for key in os.environ): raise ValueError(ERROR)
        _guard(case)
        raw = _read(source / "search.sql", 16384)
        if hashlib.sha256(raw).hexdigest() != QUERY_SHA: raise ValueError(ERROR)
        query = raw.decode("ascii")
        fixture = importlib.import_module("local_postgres")
        if Path(fixture.__file__).resolve() != (source / "local_postgres.py").resolve(): raise ValueError(ERROR)
        url = _url(case)
        report["controls_before"] = _control(fixture, url, deadline)
        for label in ("search_before", "explain_before", "search_after", "explain_after"):
            if label == "search_after":
                report["analyze"] = _analyze(fixture, _url(case, admin=True), deadline)
            before = _cpu_stat()
            with ThreadPoolExecutor(max_workers=8) as pool:
                rows = list(pool.map(lambda index: _row(fixture, url, query, index, label.startswith("explain"), deadline), range(1, 17)))
            full_trees = _retain_plans(rows) if label.startswith("explain") else 0
            report["waves"].append({"label": label, "records": rows, "cpu_before": before, "cpu_after": _cpu_stat(),
                "successful": sum(row["outcome"] == "pass" for row in rows), "full_trees": full_trees,
                "collection_complete": len(rows) == 16})
        report["controls_after"] = _control(fixture, url, deadline)
        try: report["pg_config"] = _pg_config(case.base, deadline)
        except Exception: report["pg_config"] = {"outcome": "fail", "failure": "invalid-or-unavailable"}
        _budget(deadline)
        report["comparison_valid"] = (report["analyze"]["outcome"] == "pass"
            and all(wave["collection_complete"] and wave["successful"] > 0
                    and (not wave["label"].startswith("explain") or wave["full_trees"] > 0) for wave in report["waves"]))
        if (report["comparison_valid"] and report["controls_before"]["outcome"] == "pass"
                and report["controls_after"]["outcome"] == "pass" and report["pg_config"]["outcome"] == "pass"):
            report["outcome"] = "pass"
    except Exception:
        report["failure"] = "invalid-preconditions-or-incomplete-budget"
    if len(json.dumps(report, indent=2).encode()) > 512 * 1024:
        for wave in report["waves"]:
            for row in wave["records"]:
                if "plan" in row:
                    row["plan"]["Plan"].pop("Plans", None)
                    row["full_tree_retained"] = False
        report.update(outcome="fail", comparison_valid=False, failure="retained-byte-bound")
    if (type(deadline) in (int, float) and math.isfinite(deadline)
            and time.monotonic() >= min(deadline, started + 30)):
        report.update(outcome="fail", comparison_valid=False, failure="deadline")
    report["seconds"] = round(time.monotonic() - started, 6)
    return report
