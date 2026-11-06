#!/usr/bin/env python3
"""Bind a trusted host capture and run the unchanged reference HTTP methods.

SPDX-License-Identifier: AGPL-3.0-or-later
This is UNQUALIFIED test orchestration. Registration is metadata, not command
authority. The trusted runner assumes registration, alias, and emulator bytes
remain stable between this capture and launch. These checks are not race-free.
The parent verifies the actual selected server before invoking this adapter.
The fixture verifies it again when constructing BinfmtFifoConfig.
"""
import argparse
import ast
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import stat
import struct
import sys
import tempfile
import time
import unittest

REGISTRATION_PATH = "/proc/sys/fs/binfmt_misc/qemu-riscv64"
REGISTRATION_FILE = Path(REGISTRATION_PATH)
REGISTERED_ALIAS = Path("/usr/libexec/qemu-binfmt/riscv64-binfmt-P")
EMULATOR_FILE = Path("/usr/bin/qemu-riscv64-static")
EMULATOR_SHA256 = "be89e201dc6112ef101617ab575c95119ad123f80ca2b51b6c36ef218ac9df65"
EMULATOR_BYTES = 4431192
SERVER_SHA256 = "3e0bce8b6d9be340be5dfabbdd39fda064d7c9dd46287432561d315603ba93c9"
REGISTRATION_TEXT = (
    "enabled\ninterpreter /usr/libexec/qemu-binfmt/riscv64-binfmt-P\nflags: POF\noffset 0\n"
    "magic 7f454c460201010000000000000000000200f300\n"
    "mask ffffffffffffff00fffffffffffffffffeffffff\n")
REGISTRATION_KEYS = frozenset(("schema", "scope", "source_revision", "fixture_revision", "run_id", "captured_at",
    "registration_path", "registration_text", "emulator_sha256", "emulator_bytes", "server_sha256", "fixture_sha256"))
METHODS = (
    "test_a_stalled_database_does_not_stall_liveness",
    "test_configuration_rejects_nonregular_public_and_malformed_files",
    "test_connection_cap_bounds_http_threads_and_recovers",
    "test_fixture_retains_reference_records_and_query_limits",
    "test_health_and_declared_dependency_boundary",
    "test_query_rejects_duplicates_unknown_fields_controls_and_oversize",
    "test_readiness_loses_permissions_and_recovers",
    "test_real_pagination_does_not_drop_or_repeat_packages",
    "test_search_uses_parameters_and_literal_matching",
    "test_shutdown_is_bounded_with_a_stalled_database",
    "test_simultaneous_searches_keep_request_data_separate",
    "test_startup_rejects_migrator_and_missing_grants",
    "test_unknown_route_method_and_body_fail_without_database_writes",
    "test_uri_and_header_limits",
)
ERROR = "Invalid reference suite inputs."
MAX_JSON = 1024 * 1024


def bounded_bytes(path, limit):
    """Read a bounded regular file through a no-follow, nonblocking descriptor."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        if path.is_symlink():
            raise ValueError(ERROR)
        with os.fdopen(os.open(path, flags), "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
                raise ValueError(ERROR)
            data = source.read(limit + 1)
        if len(data) > limit:
            raise ValueError(ERROR)
        return data
    except OSError:
        raise ValueError(ERROR) from None


def read_object(path, limit=MAX_JSON):
    def fields(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(ERROR)
            value[key] = item
        return value
    def constant(_value):
        raise ValueError(ERROR)
    try:
        result = json.loads(bounded_bytes(path, limit), object_pairs_hook=fields,
                            parse_constant=constant)
    except (ValueError, UnicodeError, RecursionError):
        raise ValueError(ERROR) from None
    if type(result) is not dict:
        raise ValueError(ERROR)
    return result


def registration_contract(record: dict, inputs: dict, fixture_sha256: str) -> None:
    if type(record) is not dict or set(record) != REGISTRATION_KEYS or type(inputs) is not dict:
        raise ValueError(ERROR)
    try:
        encoded = json.dumps(record, separators=(",", ":"), allow_nan=False).encode()
    except (ValueError, TypeError, RecursionError):
        raise ValueError(ERROR) from None
    if len(encoded) > 4096 or type(record["schema"]) is not int or record["schema"] != 1:
        raise ValueError(ERROR)
    if record["scope"] != "asm-riscv64-binfmt-registration":
        raise ValueError(ERROR)
    for key, input_key in (("source_revision", "revision"), ("fixture_revision", "fixture_revision")):
        if (type(record[key]) is not str or re.fullmatch(r"[0-9a-f]{40}", record[key]) is None
                or record[key] != inputs.get(input_key)):
            raise ValueError(ERROR)
    if type(record["run_id"]) is not str or re.fullmatch(r"[0-9]{1,32}", record["run_id"]) is None:
        raise ValueError(ERROR)
    timestamp = record["captured_at"]
    if type(timestamp) is not str or re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)", timestamp) is None:
        raise ValueError(ERROR)
    try:
        if datetime.fromisoformat(timestamp.replace("Z", "+00:00")).utcoffset().total_seconds() != 0:
            raise ValueError(ERROR)
    except (ValueError, AttributeError):
        raise ValueError(ERROR) from None
    if (record["registration_path"] != REGISTRATION_PATH or type(record["registration_text"]) is not str
            or len(record["registration_text"].encode()) > 1024 or record["registration_text"] != REGISTRATION_TEXT
            or record["emulator_sha256"] != EMULATOR_SHA256 or type(record["emulator_bytes"]) is not int
            or record["emulator_bytes"] != EMULATOR_BYTES or record["server_sha256"] != SERVER_SHA256
            or type(fixture_sha256) is not str or re.fullmatch(r"[0-9a-f]{64}", fixture_sha256) is None
            or record["fixture_sha256"] != fixture_sha256):
        raise ValueError(ERROR)


def capture_registration(context: Path, *, run_id: str) -> dict:
    """Capture fixed host files, then atomically publish one new readonly receipt."""
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise ValueError(ERROR)
    output = context / "binfmt-registration.json"
    if output.exists() or output.is_symlink():
        raise ValueError(ERROR)
    inputs = read_object(context / "input-manifest.json")
    fixture = bounded_bytes(context / "source/test_server.py", MAX_JSON)
    raw = bounded_bytes(REGISTRATION_FILE, 1024)
    emulator = bounded_bytes(EMULATOR_FILE, EMULATOR_BYTES)
    if (len(emulator) != EMULATOR_BYTES or hashlib.sha256(emulator).hexdigest() != EMULATOR_SHA256
            or len(emulator) < 64 or emulator[:7] != b"\x7fELF\x02\x01\x01"
            or struct.unpack_from("<H", emulator, 18)[0] != 62
            or REGISTERED_ALIAS.resolve(strict=True) != EMULATOR_FILE.resolve(strict=True)):
        raise ValueError(ERROR)
    try:
        text = raw.decode("ascii")
    except UnicodeError:
        raise ValueError(ERROR) from None
    record = {"schema": 1, "scope": "asm-riscv64-binfmt-registration",
        "source_revision": inputs.get("revision"), "fixture_revision": inputs.get("fixture_revision"),
        "run_id": run_id, "captured_at": datetime.now(timezone.utc).isoformat(),
        "registration_path": REGISTRATION_PATH, "registration_text": text,
        "emulator_sha256": EMULATOR_SHA256, "emulator_bytes": EMULATOR_BYTES,
        "server_sha256": SERVER_SHA256, "fixture_sha256": hashlib.sha256(fixture).hexdigest()}
    registration_contract(record, inputs, record["fixture_sha256"])
    data = json.dumps(record, separators=(",", ":"), sort_keys=True).encode() + b"\n"
    if len(data) > 4096:
        raise ValueError(ERROR)
    descriptor, stage = tempfile.mkstemp(prefix=".binfmt-registration-", dir=context)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            os.fchmod(stream.fileno(), 0o444)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(stage, output, follow_symlinks=False)
        except OSError:
            raise ValueError(ERROR) from None
    finally:
        Path(stage).unlink(missing_ok=True)
    return record


def trace_library(trace_directory):
    """Use fixed filenames. Build metadata cannot select an executable or path."""
    from riscv64_reference_build import BUILD_SCOPE, elf_contract
    manifest = read_object(trace_directory / "manifest.json")
    if (type(manifest.get("schema")) is not int or manifest["schema"] != 1
            or manifest.get("scope") != BUILD_SCOPE or manifest.get("qualification") != "UNQUALIFIED"
            or manifest.get("outcome") != "pass" or manifest.get("target") != "riscv64-linux"
            or manifest.get("isa") != "RV64GC" or manifest.get("abi") != "LP64D"):
        raise ValueError(ERROR)
    outputs = manifest.get("outputs")
    if type(outputs) is not dict or set(outputs) != {"reference_libpq_trace.so", "libreference_provider.so", "reference_trace_check"}:
        raise ValueError(ERROR)
    entry = outputs["reference_libpq_trace.so"]
    path = trace_directory / "reference_libpq_trace.so"
    bounded_bytes(path, MAX_JSON)
    actual = elf_contract(path, shared=True)
    if (type(entry) is not dict or set(entry) != set(actual)
            or any(type(entry[key]) is not type(value) or entry[key] != value for key, value in actual.items())):
        raise ValueError(ERROR)
    return path.resolve(), actual["sha256"]


class FinalizationError(Exception):
    def __init__(self, errors):
        self.errors = errors
        super().__init__("Reference fixture finalization failed.")


def error_type(error):
    name = type(error).__name__
    return name if name in {"AssertionError", "RuntimeError", "ValueError", "TypeError", "OSError", "TimeoutError",
                           "SystemExit", "KeyboardInterrupt", "AttributeError", "KeyError"} else "Exception"


class PrivateResult(unittest.TextTestResult):
    """Retain failures without printing traceback, query values, or credentials."""
    def getDescription(self, test):
        parent = getattr(test, "test_case", test)
        name = getattr(parent, "_testMethodName", "")
        return name if name in METHODS else "reference fixture"

    def _exc_info_to_string(self, err, test):
        error = err[1]
        if isinstance(error, FinalizationError):
            return "; ".join(phase + ": " + error_type(value) for phase, value in error.errors)
        return error_type(error)

    def addSkip(self, test, reason):
        super().addSkip(test, "not-run")


def check_deadline(deadline):
    if type(deadline) not in (int, float) or not math.isfinite(deadline) or time.monotonic() >= deadline:
        raise ValueError(ERROR)


def candidate_suite(cls, source, deadline):
    """Use the owned fixture for SQL only; no HTTP method is an acceptance result."""
    errors, setup, measurement = [], False, {"outcome": "fail"}
    try:
        check_deadline(deadline)
        cls.setUpClass()
        setup = True
        cls.stop_server()
        check_deadline(deadline)
        from riscv64_reference_performance import run_candidate
        measurement = run_candidate(cls, source, deadline)
        cls.diagnostic.optional_update("query_candidate", measurement)
        check_deadline(deadline)
    except BaseException as error:
        errors.append({"stage": "candidate", "type": error_type(error)})
    finally:
        if setup:
            try:
                cls.tearDownClass()
            except BaseException as error:
                errors.append({"stage": "teardown", "type": error_type(error)})
        cls.doClassCleanups()
        for _kind, error, _traceback in cls.tearDown_exceptions:
            errors.append({"stage": "cleanup", "type": error_type(error)})
    success = measurement.get("outcome") == "pass" and not errors and time.monotonic() < deadline
    summary = {"schema": 1, "scope": "UNQUALIFIED-query-candidate", "outcome": "pass" if success else "fail",
               "tests_run": 0, "http_methods_not_run": 14, "errors": errors}
    print("ASM_REFERENCE_SQL=" + json.dumps(summary, separators=(",", ":")))
    return 0 if success else 1


def run_suite(source: Path, registration_path: Path, trace_directory: Path, deadline: float,
              *, query_cost_probe=False, sql_candidate=False) -> int:
    check_deadline(deadline)
    fixture_path = source / "test_server.py"
    fixture_data = bounded_bytes(fixture_path, MAX_JSON)
    inputs = read_object(source.parent / "input-manifest.json")
    registration = read_object(registration_path, 4096)
    registration_contract(registration, inputs, hashlib.sha256(fixture_data).hexdigest())
    tree = ast.parse(fixture_data)
    classes = [node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "ServerTests"]
    if len(classes) != 1:
        raise ValueError(ERROR)
    names = sorted(node.name for node in classes[0].body if isinstance(node, ast.FunctionDef) and node.name.startswith("test_"))
    if tuple(names) != METHODS or ("test_methods" in inputs and inputs["test_methods"] != list(METHODS)):
        raise ValueError(ERROR)
    library, sha256 = trace_library(trace_directory)
    from riscv64_reference_trace import read_records
    check_deadline(deadline)
    sys.path.insert(0, str(source.resolve()))
    name = "_asm_reference_fixture"
    spec = importlib.util.spec_from_file_location(name, fixture_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    cls = module.ServerTests
    if not issubclass(cls, unittest.TestCase) or tuple(unittest.defaultTestLoader.getTestCaseNames(cls)) != METHODS:
        raise ValueError(ERROR)
    cls.attribution_config = module.BinfmtFifoConfig(registration=registration, runner_deadline=deadline)
    cls.trace_config = module.PhaseTraceConfig(library_path=library, sha256=sha256, read_records=read_records)
    if sql_candidate:
        return candidate_suite(cls, source, deadline)
    original_teardown = cls.tearDownClass.__func__

    @classmethod
    def teardown(case):
        errors = []
        try:
            check_deadline(deadline)
            case.run_controlled_search_comparison()
            check_deadline(deadline)
        except BaseException as error:
            errors.append(("comparison", error))
        finally:
            if query_cost_probe:
                try:
                    check_deadline(deadline)
                    from riscv64_reference_performance import run_diagnostic
                    measurement = run_diagnostic(case, source, deadline)
                    case.diagnostic.optional_update("query_cost_probe", measurement)
                    if measurement.get("outcome") != "pass":
                        raise ValueError("The bounded query-cost measurement is incomplete.")
                    check_deadline(deadline)
                except BaseException as error:
                    errors.append(("query-cost", error))
            try:
                original_teardown(case)
            except BaseException as error:
                errors.append(("teardown", error))
        if errors:
            raise FinalizationError(errors)

    cls.tearDownClass = teardown
    check_deadline(deadline)
    result = unittest.TextTestRunner(verbosity=2, resultclass=PrivateResult).run(unittest.defaultTestLoader.loadTestsFromTestCase(cls))
    return 0 if (result.wasSuccessful() and result.testsRun == 14 and not result.skipped
                 and not result.expectedFailures and time.monotonic() < deadline) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture-registration", type=Path)
    parser.add_argument("--run-id")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--registration", type=Path)
    parser.add_argument("--trace-directory", type=Path)
    parser.add_argument("--deadline", type=float)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--query-cost-probe", action="store_true")
    group.add_argument("--query-candidate", action="store_true")
    args = parser.parse_args()
    try:
        if args.capture_registration:
            if args.run_id is None or args.query_cost_probe or args.query_candidate or any(value is not None for value in (args.source, args.registration, args.trace_directory, args.deadline)):
                parser.error("Supply only --run-id with --capture-registration.")
            capture_registration(args.capture_registration, run_id=args.run_id)
            return 0
        if any(value is None for value in (args.source, args.registration, args.trace_directory, args.deadline)):
            parser.error("Supply --source, --registration, --trace-directory, and --deadline.")
        return run_suite(args.source, args.registration, args.trace_directory, args.deadline,
                         query_cost_probe=args.query_cost_probe, sql_candidate=args.query_candidate)
    except Exception:
        print(ERROR, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
