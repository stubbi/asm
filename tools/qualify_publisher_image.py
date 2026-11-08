#!/usr/bin/env python3
"""Qualify the exact assembly publisher image against owned PostgreSQL 18.6.

SPDX-License-Identifier: AGPL-3.0-or-later
Only the derived test image contains fixture servers, tools, or synthetic keys.
"""
from __future__ import annotations

import argparse
import contextlib
import ctypes
import hashlib
import os
from pathlib import Path
import platform
import selectors
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import registry
import test_operator_image as images
import v2_image_publication as policy

PREFIX = b"ASM_PUBLISHER_QUALIFICATION="
ROOT = Path(__file__).resolve().parents[1]
EXECUTABLE = "/usr/local/bin/asm-publisher"
ARTIFACTS = ("/opt/asm/postgres18/bin/initdb", "/opt/asm/postgres18/bin/postgres",
    "/opt/asm/postgres/bin/psql", "/opt/asm/postgres/lib/libpq.so.5",
    "/qualification/source/build/asm-registry-v2", "/qualification/source/build/asm-trust",
    "/usr/sbin/nginx", "/usr/bin/python3", "/usr/bin/node", "/usr/bin/as", "/usr/bin/ld", "/usr/bin/openssl")
SECURITY = {"uid": 65532, "gid": 65532, "read_only_root": True, "effective_capabilities": 0,
            "no_new_privileges": True, "cluster_token": False}
derived_contract = images.derived_contract
need = images.need


def required_test_ids():
    """Read the trusted test inventory without importing database fixtures."""
    return policy.required_test_ids("publisher")


def receipt_contract(value, revision, files):
    fields = {"schema", "source_revision", "tests_run", "tests_skipped", "test_ids", "security", "os",
        "architecture", "execution", "database_fixture_version", "loaded_libraries", "publisher_sha256",
        "source_marker_sha256", "qualification_artifacts"}
    registry.exact_keys(value, fields, fields, "publisher qualification receipt")
    need(type(value["schema"]) is int and value["schema"] == 1 and value["source_revision"] == revision,
         "The qualification source identity differs.")
    need(value["os"] == "linux" and value["architecture"] == "amd64" and value["execution"] == "native",
         "The qualification requires native Linux AMD64.")
    need(type(value["tests_run"]) is int and value["tests_run"] == 55
         and type(value["tests_skipped"]) is int and value["tests_skipped"] == 0
         and value["test_ids"] == required_test_ids(), "The exact publisher suite did not run without skips.")
    need(isinstance(value["security"], dict) and value["security"] == SECURITY
         and all(type(value["security"][name]) is type(expected) for name, expected in SECURITY.items()),
         "The publisher qualification isolation differs.")
    need(value["database_fixture_version"] == "18.6"
         and value["loaded_libraries"] == {"libpq": "16.15", "OpenSSL": "3.5.9"}, "The reviewed dependency profiles differ.")
    need(value["publisher_sha256"] == files[EXECUTABLE]
         and value["source_marker_sha256"] == files["/app/SOURCE.json"], "The tested publisher bytes differ.")
    artifacts = value["qualification_artifacts"]
    need(isinstance(artifacts, dict) and set(artifacts) == set(ARTIFACTS)
         and all(isinstance(digest, str) and registry.HEX64.fullmatch(digest) for digest in artifacts.values()),
         "The fixture artifact inventory differs.")
    return value


def parse_child(raw, revision, files):
    need(isinstance(raw, bytes) and len(raw) <= 65536 and raw.startswith(PREFIX), "The bounded qualification marker is missing.")
    value = registry.strict_json(raw[len(PREFIX):])
    need(raw == PREFIX + registry.json_bytes(value), "The qualification marker is ambiguous or noncanonical.")
    return receipt_contract(value, revision, files)


def run_child(arguments, log_path, *, maximum=8 * 1024 * 1024, timeout=900):
    """Bound both streams and retain a private log, including after failure."""
    descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb", buffering=0) as log:
        os.fchmod(log.fileno(), 0o600)
        process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        selector, output, total = selectors.DefaultSelector(), bytearray(), 0
        deadline = time.monotonic() + timeout
        try:
            for stream in (process.stdout, process.stderr):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, stream is process.stdout)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                need(remaining > 0, "The publisher qualification deadline expired; retain the child log.")
                events = selector.select(remaining)
                need(events, "The publisher qualification deadline expired; retain the child log.")
                for key, _ in events:
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                        continue
                    pending = memoryview(chunk[:max(0, maximum - total)])
                    while pending:
                        amount = log.write(pending)
                        need(type(amount) is int and 0 < amount <= len(pending), "The publisher qualification log write stopped.")
                        pending = pending[amount:]
                    total += len(chunk)
                    need(total <= maximum, "The publisher qualification log exceeded its byte limit.")
                    if key.data:
                        output.extend(chunk)
                        need(len(output) <= 65536, "The publisher qualification marker exceeded its byte limit.")
            need(process.wait(timeout=max(0.01, deadline - time.monotonic())) == 0,
                 "The publisher qualification child failed; retain its log.")
            return bytes(output)
        finally:
            selector.close()
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            for stream in (process.stdout, process.stderr):
                if not stream.closed:
                    stream.close()


def digest_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_suite(suite, expected):
    actual = []
    class Result(unittest.TextTestResult):
        def startTest(self, test):
            actual.append(test.id())
            super().startTest(test)
    with contextlib.redirect_stdout(sys.stderr):
        result = unittest.TextTestRunner(stream=sys.stderr, verbosity=2, resultclass=Result).run(suite)
    need(result.wasSuccessful() and result.testsRun == len(expected) and not result.skipped and sorted(actual) == expected,
         "The complete publisher suite did not pass without skips.")
    return result, sorted(actual)


def inside(revision):
    need(platform.system() == "Linux" and platform.machine() == "x86_64", "Use native Linux AMD64 for publisher qualification.")
    process = dict(line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines() if ":" in line)
    security = {"uid": os.geteuid(), "gid": os.getegid(), "read_only_root": bool(os.statvfs("/").f_flag & os.ST_RDONLY),
        "effective_capabilities": int(process["CapEff"].strip(), 16), "no_new_privileges": process["NoNewPrivs"].strip() == "1",
        "cluster_token": Path("/var/run/secrets/kubernetes.io/serviceaccount/token").exists()}
    need(security == SECURITY, "The publisher qualification isolation differs.")
    marker = registry.strict_json(Path("/app/SOURCE.json").read_bytes())
    need(marker["source_revision"] == revision, "The publisher source marker differs.")
    sys.path[:0] = [str(ROOT / "tests/publisher"), "/opt/asm/storage"]
    os.environ.update(ASM_PROTO_PG_BINDIR="/opt/asm/postgres/bin", ASM_PROTO_LIBPQ="/opt/asm/postgres/lib/libpq.so.5",
        ASM_PROTO_PG18_BINDIR="/opt/asm/postgres18/bin", ASM_PUBLISHER_BINARY=EXECUTABLE,
        ASM_SERVER_SOURCE_REVISION=revision, ASM_REGISTRY_TEST_BINARY=str(ROOT / "build/asm-registry-v2"),
        ASM_REGISTRY_TRUST=str(ROOT / "build/asm-trust"), ASM_TEST_NGINX="/usr/sbin/nginx")
    import run_pg18
    run_pg18.preflight()
    crypto = ctypes.CDLL("/opt/asm/openssl/lib/libcrypto.so.3")
    crypto.OpenSSL_version.argtypes = [ctypes.c_int]
    crypto.OpenSSL_version.restype = ctypes.c_char_p
    need(crypto.OpenSSL_version(0).decode().startswith("OpenSSL 3.5.9 "), "The reviewed publisher OpenSSL version differs.")
    expected = required_test_ids()
    suite = run_pg18.load_suites(["authority", "distribution", "runtime", "full-flow"])
    need(suite.countTestCases() == 55, "The publisher suite count differs.")
    result, actual = run_suite(suite, expected)
    receipt = {"schema": 1, "source_revision": revision, "os": "linux", "architecture": "amd64", "execution": "native",
        "tests_run": result.testsRun, "tests_skipped": len(result.skipped), "test_ids": sorted(actual), "security": security,
        "database_fixture_version": "18.6", "loaded_libraries": {"libpq": "16.15", "OpenSSL": "3.5.9"},
        "publisher_sha256": digest_file(EXECUTABLE), "source_marker_sha256": digest_file("/app/SOURCE.json"),
        "qualification_artifacts": {name: digest_file(name) for name in ARTIFACTS}}
    sys.stdout.buffer.write(PREFIX + registry.json_bytes(receipt))


def qualify(args):
    log_path = Path(str(args.output) + ".child.log")
    need(not args.output.exists() and not args.output.is_symlink() and not log_path.exists() and not log_path.is_symlink(),
         "Select a new report and child log; preserve the previous qualification evidence.")
    need(platform.system() == "Linux" and platform.machine() == "x86_64", "Use a native Linux AMD64 qualification host.")
    client = ["docker", "--context", args.context]
    need(images.command([*client, "info", "--format", "{{.OSType}}/{{.Architecture}}"] ).decode().strip()
         in {"linux/x86_64", "linux/amd64"}, "The qualification daemon is not native AMD64 Linux.")
    inspections = []
    for name in (args.image, args.qualification_image):
        value = registry.strict_json(images.command([*client, "image", "inspect", name]))
        need(isinstance(value, list) and len(value) == 1, "Inspect one exact image at each qualification boundary.")
        images.v2_image_contract(value[0], args.revision, "publisher")
        inspections.append(value[0])
    runtime, qualifier = inspections
    need(runtime["Id"] != qualifier["Id"] and len(qualifier["RootFS"]["Layers"]) > len(runtime["RootFS"]["Layers"]),
         "Use a distinct qualification image derived from the exact final image.")
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="asm-publisher-reports-") as directory:
        reports = []
        for number, inspection in enumerate(inspections):
            path = Path(directory) / (str(number) + ".json")
            images.runtime_smoke(SimpleNamespace(context=args.context, image=inspection["Id"], revision=args.revision,
                smoke_kind="publisher", output=str(path)))
            reports.append(registry.strict_json(path.read_bytes()))
    report, qualified = reports
    derived_contract(runtime, qualifier, report["runtime_files"], qualified["runtime_files"])
    absence = "for x in cc gcc g++ clang go make postgres initdb; do if command -v \"$x\" >/dev/null 2>&1; then exit 1; fi; done; for x in /opt/asm/go/bin/go /opt/asm/postgres/bin/postgres /opt/asm/postgres/bin/initdb /opt/asm/postgres18/bin/postgres /opt/asm/postgres18/bin/initdb; do test ! -e \"$x\" || exit 1; done"
    images.command([*client, "run", "--rm", "--pull=never", *images.security(), "--entrypoint", "/bin/sh", runtime["Id"], "-c", absence])
    name = "asm-publisher-qualification-" + uuid.uuid4().hex
    arguments = [*client, "run", "--rm", "--pull=never", "--name", name, "--platform", "linux/amd64",
        "--read-only", "--network=none", "--user", "65532:65532", "--cap-drop=ALL", "--security-opt=no-new-privileges",
        "--pids-limit=256", "--memory=2g", "--cpus=2", "--tmpfs", "/tmp:rw,nosuid,nodev,exec,size=1g,uid=65532,gid=65532,mode=0700",
        "--entrypoint", "/usr/bin/python3", qualifier["Id"], "-B", "-I", "/qualification/source/tools/qualify_publisher_image.py",
        "--inside", "--revision", args.revision]
    try:
        receipt = parse_child(run_child(arguments, log_path), args.revision, report["runtime_files"])
    finally:
        subprocess.run([*client, "rm", "--force", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    report.update(receipt)
    report.update(scope="v2-runtime-qualification", qualification_image_id=qualifier["Id"],
        qualifier_runtime_files=qualified["runtime_files"], final_compiler_and_postgresql_server_absent=True,
        seconds=round(time.monotonic() - started, 3), child_log_sha256=digest_file(log_path),
        limit="Exact-image native fixture qualification does not establish public deployment, key custody, provider semantics, or recovery.")
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(registry.json_bytes(report))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inside", action="store_true")
    parser.add_argument("--revision", required=True)
    parser.add_argument("--context")
    parser.add_argument("--image")
    parser.add_argument("--qualification-image")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    need(registry.HEX40.fullmatch(args.revision) and args.revision != "0" * 40, "Select an exact source revision.")
    if args.inside:
        inside(args.revision)
    else:
        need(args.context and args.image and args.qualification_image and args.output,
             "Select an explicit context, final image, derived qualification image, and new report.")
        qualify(args)


def run_cli():
    try:
        main()
        return 0
    except images.SmokeFailure as failure:
        print(f"Publisher image qualification failed: {failure}. Retain the bounded child log and build evidence.", file=sys.stderr)
        return 1
    except (ValueError, OSError, subprocess.SubprocessError):
        print("Publisher image qualification failed. Retain the bounded child log and build evidence.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(run_cli())
