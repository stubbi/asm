#!/usr/bin/env python3
"""Qualify the selected PostgreSQL 18.6 image against unchanged Asm clients.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import ctypes
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import selectors
import signal
import subprocess
import sys
import time
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import postgres18_fixture as fixture
import postgres18_docker
import deployment_envelope as envelope
import registry
from postgres18_fixture import need
import test_operator_image as operator
import test_server_image as server

PREFIX = "ASM_POSTGRES18_QUALIFICATION="
IMAGES = {"operator": ("asm-operator:runtime-amd64", "asm-operator:qualification-amd64", "asm-postgres18:operator"),
          "http": ("asm-server:runtime-amd64", "asm-server:qualification-amd64", "asm-postgres18:http")}
DATABASE = "asm-postgres18:database"
STDOUT_LIMIT = 4 * 1024 * 1024
STDERR_LIMIT = 1024 * 1024


class CommandFailure(ValueError):
    def __init__(self, result, message="A qualification command failed; inspect the retained stage log."):
        super().__init__(message)
        self.stdout, self.stderr = result.stdout, result.stderr


def bounded_result(arguments, *, timeout, environment=None):
    """Use the operator's nonblocking selector pattern while retaining bounded diagnostics."""
    output, errors = bytearray(), bytearray()
    selector = selectors.DefaultSelector()
    process, completed = None, False
    deadline = time.monotonic() + timeout
    try:
        blocked = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
        try:
            process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, env=environment, start_new_session=True)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
        for stream, buffer, limit in ((process.stdout, output, STDOUT_LIMIT), (process.stderr, errors, STDERR_LIMIT)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, (buffer, limit))
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(arguments, timeout, output=bytes(output), stderr=bytes(errors))
            events = selector.select(remaining)
            if not events:
                raise subprocess.TimeoutExpired(arguments, timeout, output=bytes(output), stderr=bytes(errors))
            for key, _ in events:
                buffer, limit = key.data
                chunk = os.read(key.fd, min(65536, limit - len(buffer) + 1))
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                remaining_bytes = limit - len(buffer)
                buffer.extend(chunk[:remaining_bytes])
                if len(chunk) > remaining_bytes:
                    result = subprocess.CompletedProcess(arguments, None, bytes(output), bytes(errors))
                    raise CommandFailure(result, "Qualification output exceeded its byte limit.")
        try:
            returncode = process.wait(timeout=max(0.001, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            raise subprocess.TimeoutExpired(arguments, timeout, output=bytes(output), stderr=bytes(errors))
        completed = True
        return subprocess.CompletedProcess(arguments, returncode, bytes(output), bytes(errors))
    except QualificationTerminated as error:
        error.stdout, error.stderr = bytes(output), bytes(errors)
        raise
    finally:
        selector.close()
        if process is not None:
            if not completed or process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait(timeout=3)
            for stream in (process.stdout, process.stderr):
                if stream is not None and not stream.closed:
                    stream.close()


def command(arguments, *, timeout=20, check=True):
    with postgres18_docker.invocation(arguments) as (fixed_arguments, environment):
        result = bounded_result(fixed_arguments, timeout=timeout, environment=environment)
    if check and result.returncode != 0:
        raise CommandFailure(result)
    return result


class QualificationTerminated(ValueError):
    pass


@contextmanager
def termination_guard():
    state = {"signal": None, "cleanup": False}
    def terminate(signum, frame):
        state["signal"] = signum
        if not state["cleanup"]:
            raise QualificationTerminated("Qualification received SIGTERM; cleanup is required.")
    previous = signal.signal(signal.SIGTERM, terminate)
    try:
        yield state
    finally:
        signal.signal(signal.SIGTERM, previous)


def inspect(kind, name):
    values = registry.strict_json(command(["docker", kind, "inspect", name]).stdout)
    need(isinstance(values, list) and len(values) == 1, "Expected one exact Docker object.")
    return values[0]


def derived_contract(base, derived, files, derived_files):
    layers = base.get("RootFS", {}).get("Layers", [])
    need(layers and derived.get("RootFS", {}).get("Layers", [])[:len(layers)] == layers,
         "The qualification image replaced a base filesystem layer.")
    need(files == derived_files, "The qualification image changed a loaded runtime dependency.")


def container_contract(value, name, image, nonce, user, network, profile="compatibility"):
    need(profile in {"compatibility", envelope.PROFILE}, "Select a fixed qualification profile.")
    constrained = profile == envelope.PROFILE and user == "65532:65532"
    config, host = value.get("Config", {}), value.get("HostConfig", {})
    need(re.fullmatch(r"[0-9a-f]{64}", value.get("Id", "")) and value.get("Name") == "/" + name and
         value.get("Image") == image and config.get("User") == user and
         config.get("Labels", {}).get("asm.qualification.nonce") == nonce, "The container is not owned by this run.")
    need(host.get("ReadonlyRootfs") is True and host.get("Privileged") is False and
         host.get("NetworkMode") == network and not host.get("PortBindings") and
         host.get("CapDrop") == ["ALL"] and not host.get("CapAdd") and
         host.get("PidsLimit") == 128 and host.get("NanoCpus") == (1000000000 if constrained else 2000000000) and
         host.get("Memory") == (2147483648 if user == "26:26" else 268435456 if constrained else 536870912) and
         (not constrained or host.get("MemorySwap") == 268435456 and host.get("Tmpfs") == {
             "/tmp": "rw,nosuid,nodev,noexec,size=64m,uid=65532,gid=65532,mode=0700"}) and
         host.get("SecurityOpt") in (["no-new-privileges"], ["no-new-privileges:true"]) and
         not value.get("Mounts"), "The owned container isolation differs.")
    return value["Id"]


def remove_container(record, nonce):
    result = command(["docker", "container", "inspect", record["id"] or record["name"]], check=False)
    if result.returncode:
        need(record["id"] is None, "An owned container disappeared before cleanup inspection.")
        listed = command(["docker", "container", "ls", "--all", "--no-trunc", "--filter", "name=^/" + record["name"] + "$", "--format", "{{.ID}}"])
        need(not listed.stdout.strip(), "An uncertain container creation still has an unresolved owned name.")
        return
    values = registry.strict_json(result.stdout)
    need(isinstance(values, list) and len(values) == 1, "Cleanup container identity is ambiguous.")
    actual = container_contract(values[0], record["name"], record["image"], nonce, record["user"], record["network"], record.get("profile", "compatibility"))
    need(record["id"] is None or actual == record["id"], "The owned container ID changed.")
    command(["docker", "rm", "--force", actual], timeout=10)


def cleanup_owned(owned, remove):
    results = []
    for identity in reversed(owned):
        try:
            remove(identity)
            results.append({"identity": identity, "status": "removed"})
        except Exception as error:
            results.append({"identity": identity, "status": "error", "error": type(error).__name__})
    return results


def cleanup_contract(results):
    need(all(result.get("status") == "removed" for result in results), "Owned resource cleanup failed; the gate failed.")


def report_contract(value, suite, revision, nonce, migration, profile="compatibility", expected_fixture=None, expected_metrics_tools=None):
    need(profile in {"compatibility", envelope.PROFILE}, "Select a fixed qualification profile.")
    constrained = profile == envelope.PROFILE
    fields = {"schema", "status", "scope", "suite", "source_revision", "tests_run",
              "not_applicable", "applicable_tests_skipped", "client_libpq_version", "database", "migration_sha384"}
    if suite != "operator":
        fields |= {"metrics_test_tools", "cases"}
    if suite in {"http", "baseline"}:
        fields.add("metrics")
    if constrained:
        fields |= {"profile", "measurement_scope", "cgroup", "cases", "fixture", "requests", "availability"}
    need(isinstance(value, dict) and set(value) == fields,
         "The compatibility report fields differ.")
    need(type(value["schema"]) is int and value["schema"] == 1 and value["status"] == "pass" and
         value["scope"] == (envelope.SCOPE if constrained else "selected-cnpg18-compatibility") and
         value["suite"] == suite and value["source_revision"] == revision and
         type(value["tests_run"]) is int and value["tests_run"] >= (22 if suite in {"http", "baseline"} else envelope.SUITES[suite][2] if constrained else 23) and
         type(value["applicable_tests_skipped"]) is int and value["applicable_tests_skipped"] == 0 and
         type(value["client_libpq_version"]) is int and value["client_libpq_version"] == 160015 and
         value["migration_sha384"] == migration, "The compatibility report identity, versions, migration, or coverage differs.")
    exclusions = value["not_applicable"]
    need(isinstance(exclusions, list) and len(exclusions) <= (1 if suite == "operator" else 0) and
         all(isinstance(item, dict) and set(item) == {"id", "reason"} and item["id"] == operator.MAC_CASE and
             isinstance(item["reason"], str) and "macOS" in item["reason"] for item in exclusions), "An applicable assertion was excluded.")
    database = value["database"]
    need(isinstance(database, dict) and set(database) == {"server_version_num", "data_directory", "nonce", "system_identifier",
         "session_user", "tls_protocol"} and type(database["server_version_num"]) is int and
         database["server_version_num"] == 180006 and database["nonce"] == nonce and database["data_directory"] == fixture.DATA and
         database["session_user"] == "asm_fixture_admin" and database["tls_protocol"] in {"TLSv1.2", "TLSv1.3"} and
         isinstance(database["system_identifier"], str) and re.fullmatch(r"[1-9][0-9]{0,19}", database["system_identifier"]) and
         int(database["system_identifier"]) < 2 ** 64, "The compatibility report lacks its actual owned TLS database identity.")
    if suite != "operator":
        server.runtime_case_contract(value["cases"], "baseline" if suite == "http" else suite)
        need(value["tests_run"] == len(value["cases"]), "The PostgreSQL 18 count differs from its case identities.")
        server.metrics_test_tools_contract(value["metrics_test_tools"])
        need(expected_metrics_tools is not None and server.typed_equal(value["metrics_test_tools"], expected_metrics_tools),
             "The PostgreSQL 18 report changed its actual metrics qualification tools.")
    if suite in {"http", "baseline"}:
        server.metrics_evidence_contract(value["metrics"])
        need(server.typed_equal(value["metrics"]["test_tools"], value["metrics_test_tools"]),
             "The PostgreSQL 18 metrics result identifies different qualification tools.")
    if constrained:
        need(value["profile"] == envelope.PROFILE and value["measurement_scope"] == envelope.MEASUREMENT_SCOPE and
             isinstance(value["cases"], list) and len(value["cases"]) == value["tests_run"] and
             all(isinstance(case, str) and len(case) <= 512 and case.startswith(envelope.SUITES[suite][0] + "." +
                 envelope.SUITES[suite][1] + ".test_") for case in value["cases"]), "The fixed envelope report scope or cases differ.")
        need(expected_fixture is not None and server.typed_equal(value["fixture"], expected_fixture), "The admission failure fixture binding differs.")
        envelope.validate_snapshots(value["cgroup"], value["cases"])
        need(value["requests"] and server.typed_equal(value["availability"], envelope.request_contract(value["requests"])),
             "The actual request availability results are absent or differ.")
    return value


def base_security(user, network, *, database=False, profile="compatibility"):
    need(profile in {"compatibility", envelope.PROFILE}, "Select a fixed qualification profile.")
    constrained = profile == envelope.PROFILE and not database
    arguments = ["--read-only", "--network", network, "--user", user, "--cap-drop", "ALL",
                 "--security-opt", "no-new-privileges", "--pids-limit", "128", "--memory",
                 "2g" if database else "256m" if constrained else "512m", "--cpus", "1" if constrained else "2"]
    return arguments + (["--memory-swap", "256m"] if constrained else [])


def load_profile_suite(name, factory):
    need(name in envelope.SUITES, "Select a fixed envelope test module.")
    module = __import__(envelope.SUITES[name][0])
    cls = getattr(module, envelope.SUITES[name][1])
    cls.postgres_factory = staticmethod(factory)
    records = []
    original = cls.raw_request.__func__
    def valid_request(path, method="GET", body=None, headers=None):
        return method == "GET" and body is None and not headers and path in {
            "/health/live", "/health/ready", "/api/v2/status", "/metrics", *registry_admin_routes()}
    def observed(selected, path, method="GET", body=None):
        return envelope.observe(records, path, lambda: original(selected, path, method, body),
                                valid=valid_request(path, method, body))
    cls.raw_request = classmethod(observed)
    if name == "baseline":
        original_metrics = cls.metrics_request
        def observed_metrics(selected, port, path, **arguments):
            valid = valid_request(path, arguments.get("method", "GET"), arguments.get("body"), arguments.get("headers"))
            return envelope.observe(records, path, lambda: original_metrics(selected, port, path, **arguments), valid=valid)
        cls.metrics_request = observed_metrics
    cls.request_records = records
    os.environ.update(ASM_SERVER_CONNECT_NULL_FIXTURE=server.FIXTURE_PATH,
                      ASM_METRICS_TEST_DIRECTORY="/qualification/server")
    return unittest.defaultTestLoader.loadTestsFromModule(module)


def registry_admin_routes():
    return ("/registry/v1/index.tsv", "/registry/v1/index-macos.tsv", "/registry/v1/index-all.tsv", "/registry/v1/index.json")


def suite_contract(result, count):
    need(not result.expectedFailures and not result.unexpectedSuccesses,
         "The required suite contains an expected failure or an unexpected success.")
    return operator.test_contract(result, count)


def admission_fixture(image, runner):
    mode = runner(image, "-c", "%a:%u:%g:%s", server.FIXTURE_PATH, entrypoint="/usr/bin/stat").decode()
    fields = runner(image, server.FIXTURE_PATH, entrypoint="/usr/bin/sha256sum").decode().split()
    need(len(fields) == 2 and fields[1] == server.FIXTURE_PATH, "The fixed admission fixture digest is unavailable.")
    return server.fixture_descriptor(mode, fields[0])


def database_files(image, runner):
    executables = ["/usr/lib/postgresql/18/bin/postgres", "/usr/lib/postgresql/18/bin/initdb",
                   "/usr/lib/postgresql/18/lib/plpgsql.so"]
    paths = set(executables)
    for executable in executables:
        loaded = runner(image, executable, entrypoint="/usr/bin/ldd", user="26:26").decode()
        need("not found" not in loaded, "A selected database runtime library is unavailable.")
        paths.update(re.findall(r"(?:=>\s+)?(/[^\s()]+)", loaded))
    need(1 <= len(paths) <= 128, "The database dependency inventory exceeds its bound.")
    values = {}
    for line in runner(image, *sorted(paths), entrypoint="/usr/bin/sha256sum", user="26:26").decode().splitlines():
        digest, path = line.split("  ", 1)
        need(path in paths and path not in values and re.fullmatch(r"[0-9a-f]{64}", digest), "Invalid database dependency digest.")
        values[path] = digest
    need(set(values) == paths, "The database dependency inventory is incomplete.")
    return values


def inside(args):
    need(platform.system() == "Linux" and platform.machine() == "x86_64" and os.geteuid() == os.getegid() == 65532,
         "Compatibility tests require native Linux AMD64 and UID/GID 65532.")
    need(os.statvfs("/").f_flag & os.ST_RDONLY and set(os.getgroups()) <= {65532}, "Unexpected application filesystem or group authority.")
    status = dict(line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines() if ":" in line)
    need(status.get("NoNewPrivs", "").strip() == "1" and int(status.get("CapEff", "1").strip(), 16) == 0 and
         not Path("/var/run/secrets/kubernetes.io/serviceaccount/token").exists(), "Unexpected application privilege or cluster authority.")
    declaration = fixture.read_declaration(fixture.FIXTURE, args.revision)
    libpq = ctypes.CDLL("/opt/asm/postgres/lib/libpq.so.5")
    libpq.PQlibVersion.restype = ctypes.c_int
    need(libpq.PQlibVersion() == 160015, "Compatibility qualification changed the application libpq version.")
    os.environ.update(ASM_PROTO_PG_BINDIR="/opt/asm/postgres/bin", ASM_PROTO_LIBPQ="/opt/asm/postgres/lib/libpq.so.5")
    sys.path.insert(0, "/qualification/server")
    import test_runtime
    identities = []
    factory = fixture.postgres_factory(test_runtime.TlsPostgres, test_runtime.Database, declaration, identities)
    constrained = getattr(args, "profile", "compatibility") == envelope.PROFILE
    if constrained:
        os.environ.update(ASM_SERVER_BINARY="/usr/local/bin/asm-hub", ASM_SERVER_SOURCE_REVISION=args.revision)
        suite = load_profile_suite(args.suite, factory)
        minimum = 22 if args.suite == "baseline" else envelope.SUITES[args.suite][2]
        mode = Path(server.FIXTURE_PATH).lstat()
        import stat
        need(stat.S_ISREG(mode.st_mode), "The fixed admission fixture must be a regular file.")
        fixture_evidence = server.fixture_descriptor(f"{stat.S_IMODE(mode.st_mode):o}:{mode.st_uid}:{mode.st_gid}:{mode.st_size}",
            hashlib.sha256(Path(server.FIXTURE_PATH).read_bytes()).hexdigest())
    elif args.suite == "operator":
        sys.path.insert(0, "/qualification/tests/hosted_registry")
        import test_database
        test_database.CatalogDatabaseTests.postgres_factory = staticmethod(factory)
        setattr(test_database.CatalogDatabaseTests, "test_actual_image_entrypoint", operator.actual_entrypoint_test)
        suite = unittest.TestLoader().discover("/qualification/tests/hosted_registry", pattern="test_*.py")
        minimum = 23
    else:
        os.environ.update(ASM_SERVER_BINARY="/usr/local/bin/asm-hub", ASM_SERVER_SOURCE_REVISION=args.revision)
        test_runtime.RuntimeTests.postgres_factory = staticmethod(factory)
        need(hasattr(test_runtime.RuntimeTests, "test_canonical_exports_preserve_exact_current_bytes_and_media_types"),
             "The canonical HTTP export assertions are unavailable.")
        suite = unittest.defaultTestLoader.loadTestsFromModule(test_runtime)
        minimum = 22
    metrics = None
    if args.suite != "operator":
        case_ids = server.runtime_suite_names(suite, "baseline" if args.suite == "http" else args.suite)
        tools_directory = Path("/qualification/server")
        metrics_tools = server.metrics_tool_inventory(tools_directory, "amd64", root_owned=True)
        os.environ["ASM_METRICS_TEST_DIRECTORY"] = str(tools_directory)
        if args.suite in {"http", "baseline"}:
            metrics = server.prepare_metrics(suite, tools_directory, "amd64", root_owned=True)
    count = suite.countTestCases()
    need(count >= minimum, "The complete compatibility suite is unavailable.")
    samples = []
    result = envelope.run_suite(suite, samples) if constrained else unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
    exclusions = suite_contract(result, count)
    need(args.suite == "operator" or not exclusions, "An HTTP compatibility assertion was excluded.")
    need(len(identities) == 1, "The suite did not establish exactly one owned database identity.")
    report = {"schema": 1, "status": "pass", "scope": "selected-cnpg18-compatibility", "suite": args.suite,
              "source_revision": args.revision, "tests_run": result.testsRun, "not_applicable": exclusions,
              "applicable_tests_skipped": 0, "client_libpq_version": 160015, "database": identities[0],
              "migration_sha384": hashlib.sha384(Path("/qualification/server/catalog/schema.sql").read_bytes()).hexdigest()}
    if args.suite != "operator":
        report.update(metrics_test_tools=metrics_tools, cases=case_ids)
    if metrics is not None:
        report["metrics"] = metrics
    if constrained:
        cls = getattr(sys.modules[envelope.SUITES[args.suite][0]], envelope.SUITES[args.suite][1])
        cases = [sample["phase"][len("before:"):] for sample in samples if sample["phase"].startswith("before:")]
        envelope.validate_snapshots(samples, cases)
        report.update(scope=envelope.SCOPE, profile=envelope.PROFILE, measurement_scope=envelope.MEASUREMENT_SCOPE,
                      cgroup=samples, cases=cases, fixture=fixture_evidence, requests=cls.request_records,
                      availability=envelope.request_contract(cls.request_records))
    print(PREFIX + json.dumps(report, sort_keys=True))


def qualify(args):
    with termination_guard() as termination:
        return qualify_owned(args, termination)


def qualify_owned(args, termination):
    need(platform.system() == "Linux" and platform.machine() == "x86_64", "Use the native Linux AMD64 runner.")
    profile = getattr(args, "profile", "compatibility")
    need(profile in {"compatibility", envelope.PROFILE}, "Select a fixed qualification profile.")
    constrained = profile == envelope.PROFILE
    output = Path(args.output)
    output.mkdir(mode=0o700)
    report = {"schema": 1, "status": "fail", "scope": "selected-cnpg18-compatibility", "source_revision": args.revision,
              "architecture": "amd64", "os": "linux", "execution": "native", "suites": [], "cleanup": [],
              "started_at": datetime.now(timezone.utc).isoformat(),
              "resources": {"database_memory_bytes": 2147483648, "application_memory_bytes": 536870912,
                            "cpus_per_container": 2, "pids_per_container": 128, "tmpfs_bytes_per_container": 536870912}}
    records, owned = {}, []
    if constrained:
        report.update(scope=envelope.SCOPE, profile=profile, measurement_scope=envelope.MEASUREMENT_SCOPE)
        report["resources"].update(application_memory_bytes=268435456, application_cpus=1,
                                   application_swap_bytes=0, application_tmpfs_bytes=67108864,
                                   database_cpus=2, database_tmpfs_bytes=536870912)
        del report["resources"]["cpus_per_container"], report["resources"]["tmpfs_bytes_per_container"]
    preparation_identity = None

    def remove(identity):
        record = records[identity]
        try:
            remove_container(record, declaration["nonce"])
        except (CommandFailure, subprocess.TimeoutExpired) as error:
            (output / (identity + ".cleanup.stdout.log")).write_bytes(error.stdout or b"")
            (output / (identity + ".cleanup.stderr.log")).write_bytes(error.stderr or b"")
            raise

    def create(image, user, network, *, database=False, suite=None, entrypoint=None, arguments=()):
        name = "asm-postgres18-" + uuid.uuid4().hex
        records[name] = {"name": name, "id": None, "image": image, "user": user, "network": network,
                         "profile": profile, "suite": suite,
                         "purpose": "database" if database and entrypoint is None else "application" if suite else "probe"}
        owned.append(name)
        temporary = "/run/asm-postgres18:rw,nosuid,nodev,noexec,size=512m,uid=26,gid=26,mode=0700" if database else \
                    "/tmp:rw,nosuid,nodev,noexec,size=" + ("64m" if constrained else "512m") + ",uid=65532,gid=65532,mode=0700"
        argv = ["docker", "create", "--name", name, "--platform", "linux/amd64", *base_security(user, network, database=database, profile=profile),
                "--tmpfs", temporary, "--label", "asm.qualification.nonce=" + declaration["nonce"]]
        if entrypoint is not None or not database:
            argv += ["--entrypoint", entrypoint or "/usr/bin/python3"]
        argv += [image]
        if entrypoint is not None:
            argv += list(arguments)
        elif not database:
            argv += ["-I", "/qualification/tools/test_postgres18_image.py", "--inside", "--suite", suite, "--revision", args.revision]
            if constrained:
                argv += ["--profile", profile]
        elif constrained:
            argv += ["--log-file"]
        identity = command(argv).stdout.decode().strip()
        need(re.fullmatch(r"[0-9a-f]{64}", identity), "Docker did not return an exact owned container ID.")
        actual = container_contract(inspect("container", identity), name, image, declaration["nonce"], user, network, profile)
        need(actual == identity, "Docker returned a different owned container ID.")
        records[name]["id"] = identity
        return identity

    def probe(image, *arguments, entrypoint, user="65532:65532", timeout=20):
        identity = create(image, user, "none", database=user == "26:26", entrypoint=entrypoint, arguments=arguments)
        return command(["docker", "start", "--attach", identity], timeout=timeout).stdout

    try:
        need(command(["docker", "info", "--format", "{{.OSType}}/{{.Architecture}}"] ).stdout.decode().strip() in
             {"linux/x86_64", "linux/amd64"}, "The Docker daemon is not native Linux AMD64.")
        preparation_identity, preparation_nonce = fixture.preparation_owner(fixture.PREPARATION)
        declaration = fixture.read_declaration(fixture.PREPARATION / "app", args.revision)
        need(preparation_nonce == declaration["nonce"], "The preparation and image fixture nonces differ.")
        base, database = inspect("image", fixture.DATABASE_IMAGE), inspect("image", DATABASE)
        need(base.get("Id") == fixture.CONFIG and base.get("Architecture") == "amd64" and base.get("Os") == "linux" and
             base.get("Config", {}).get("User") == "26" and
             any(value.endswith("@" + fixture.INDEX) for value in base.get("RepoDigests", [])), "The selected database image binding differs.")
        need(database.get("Architecture") == "amd64" and database.get("Os") == "linux" and
             database.get("Config", {}).get("User") == "26:26", "The database qualifier target or identity differs.")
        dependencies = database_files(base["Id"], probe)
        derived_contract(base, database, dependencies, database_files(database["Id"], probe))
        for name in ("ca.crt", "server.crt"):
            body = probe(database["Id"], "/qualification/postgres18/" + name, entrypoint="/bin/cat", user="26:26")
            need(hashlib.sha256(body).hexdigest() == declaration["files"][name], "The sidecar TLS certificate binding differs.")
        nonce = probe(database["Id"], "/qualification/postgres18/nonce", entrypoint="/bin/cat", user="26:26")
        need(nonce == (declaration["nonce"] + "\n").encode(), "The sidecar ownership nonce differs.")
        report["database_image"] = {"reference": fixture.DATABASE_IMAGE, "index_digest": fixture.INDEX,
            "platform_digest": fixture.PLATFORM, "config_digest": fixture.CONFIG, "qualification_image_id": database["Id"],
            "runtime_files": dependencies}
        selected = [(suite, IMAGES["http"]) for suite in envelope.SUITES] if constrained else IMAGES.items()
        for suite, names in selected:
            runtime, original, qualifier = [inspect("image", name) for name in names]
            if suite == "operator":
                for value in (runtime, original, qualifier):
                    operator.image_contract(value, args.revision)
                get_files = lambda identity: operator.runtime_files(identity, runner=probe)
            else:
                server.image_contract(runtime, "amd64", args.revision)
                for value in (original, qualifier):
                    server.image_contract(value, "amd64", args.revision, qualification=True)
                get_files = lambda identity: server.runtime_files(identity, "amd64", runner=probe)
            files = get_files(runtime["Id"])
            derived_contract(runtime, original, files, get_files(original["Id"]))
            derived_contract(original, qualifier, files, get_files(qualifier["Id"]))
            expected_fixture = None
            expected_metrics_tools = None
            if suite != "operator":
                expected_metrics_tools = server.metrics_image_tools(original["Id"], "amd64", runner=probe)
                need(server.typed_equal(expected_metrics_tools, server.metrics_image_tools(qualifier["Id"], "amd64", runner=probe)),
                     "The PostgreSQL 18 derived image changed a metrics qualification tool.")
            if constrained:
                expected_fixture = admission_fixture(original["Id"], probe)
                need(expected_fixture == admission_fixture(qualifier["Id"], probe), "The derived image changed the admission fixture.")
            database_id = create(database["Id"], "26:26", "none", database=True)
            command(["docker", "start", database_id])
            deadline = time.monotonic() + 30
            while True:
                ready = command(["docker", "exec", database_id, "/usr/lib/postgresql/18/bin/pg_isready", "-h", "127.0.0.1", "-p", "5432"], check=False, timeout=3)
                if ready.returncode == 0:
                    break
                need(time.monotonic() < deadline and inspect("container", database_id).get("State", {}).get("Running"),
                     "The owned database did not start within its initialization and startup deadlines.")
                time.sleep(0.05)
            app_id = create(qualifier["Id"], "65532:65532", "container:" + database_id, suite=suite)
            try:
                result = command(["docker", "start", "--attach", app_id], timeout=180 if constrained else 300, check=False)
            except (subprocess.TimeoutExpired, CommandFailure, QualificationTerminated) as error:
                (output / (suite + ".stdout.log")).write_bytes(getattr(error, "stdout", None) or b"")
                (output / (suite + ".stderr.log")).write_bytes(getattr(error, "stderr", None) or b"")
                raise
            (output / (suite + ".stdout.log")).write_bytes(result.stdout)
            (output / (suite + ".stderr.log")).write_bytes(result.stderr)
            if constrained:
                state = inspect("container", app_id)
                (output / (suite + ".container.json")).write_text(json.dumps(state, sort_keys=True) + "\n")
                need(not state.get("State", {}).get("OOMKilled") and state.get("State", {}).get("ExitCode") == 0,
                     "The shared driver/runtime container failed or was OOM-killed.")
            need(result.returncode == 0, "A real compatibility suite failed; retain its first failure.")
            reports = [registry.strict_json(line[len(PREFIX):]) for line in result.stdout.decode().splitlines() if line.startswith(PREFIX)]
            need(len(reports) == 1, "Expected exactly one complete compatibility report.")
            migration = hashlib.sha384(Path("server/catalog/schema.sql").read_bytes()).hexdigest()
            report_contract(reports[0], suite, args.revision, declaration["nonce"], migration, profile, expected_fixture, expected_metrics_tools)
            report["suites"].append(dict(reports[0], runtime_image_id=runtime["Id"], qualification_image_id=qualifier["Id"],
                                         database_container_id=database_id, runtime_files=files))
        need(len({value["database"]["system_identifier"] for value in report["suites"]}) == (3 if constrained else 2), "The suites did not use fresh database clusters.")
        report["status"] = "pass"
    except Exception as error:
        report["failure"] = {"error": type(error).__name__, "message": str(error) if isinstance(error, ValueError) else "Qualification failed; inspect stage logs."}
        if isinstance(error, (CommandFailure, subprocess.TimeoutExpired, QualificationTerminated)):
            (output / "failure.stdout.log").write_bytes(getattr(error, "stdout", b"") or b"")
            (output / "failure.stderr.log").write_bytes(getattr(error, "stderr", b"") or b"")
    finally:
        termination["cleanup"] = True
        for record in records.values():
            if constrained and record["id"] is not None and record["purpose"] == "application":
                try:
                    state = inspect("container", record["id"])
                    container_contract(state, record["name"], record["image"], declaration["nonce"], record["user"], record["network"], profile)
                    (output / (record["suite"] + ".container.json")).write_text(json.dumps(state, sort_keys=True) + "\n")
                except Exception as error:
                    report.setdefault("state_failures", []).append({"identity": record["id"], "error": type(error).__name__})
            if record["id"] is not None and record["purpose"] == "database":
                try:
                    container_contract(inspect("container", record["id"]), record["name"], record["image"],
                                       declaration["nonce"], record["user"], record["network"], profile)
                    logs = command(["docker", "logs", record["id"]], check=False)
                    (output / (record["name"] + ".database.log")).write_bytes(logs.stdout + logs.stderr)
                    need(logs.returncode == 0, "Owned database log retrieval failed.")
                    if constrained:
                        file_log = command(["docker", "exec", record["id"], "/bin/cat", fixture.LOG_PATH], check=False)
                        (output / (record["name"] + ".database.file.log")).write_bytes(file_log.stdout)
                        (output / (record["name"] + ".database.file.stderr.log")).write_bytes(file_log.stderr)
                        need(file_log.returncode == 0 and 0 < len(file_log.stdout) <= fixture.LOG_LIMIT,
                             "The owned database file log is absent or exceeds its bound.")
                except Exception as error:
                    report.setdefault("log_failures", []).append({"identity": record["id"], "error": type(error).__name__})
                    if isinstance(error, (CommandFailure, subprocess.TimeoutExpired)):
                        (output / (record["name"] + ".database.failure.stdout.log")).write_bytes(error.stdout or b"")
                        (output / (record["name"] + ".database.failure.stderr.log")).write_bytes(error.stderr or b"")
        report["cleanup"] = cleanup_owned(owned, remove)
        if preparation_identity is not None:
            try:
                fixture.remove_preparation(fixture.PREPARATION, preparation_identity, preparation_nonce)
                report["preparation_cleanup"] = "removed"
            except Exception as error:
                report["preparation_cleanup"] = "error"
                report["preparation_cleanup_error"] = type(error).__name__
        if any(value["status"] != "removed" for value in report["cleanup"]) or report.get("preparation_cleanup") != "removed" or report.get("log_failures") or report.get("state_failures"):
            report["status"] = "fail"
        if termination["signal"] is not None:
            report["status"] = "fail"
            report.setdefault("failure", {"error": "QualificationTerminated", "message": "Qualification received SIGTERM; cleanup was required."})
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        (output / "qualification.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    need(report["status"] == "pass", "PostgreSQL 18.6 compatibility failed; retain the complete evidence directory.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--cleanup-preparation", action="store_true")
    parser.add_argument("--inside", action="store_true")
    parser.add_argument("--suite", choices=("operator", "http", *envelope.SUITES))
    parser.add_argument("--profile", choices=("compatibility", envelope.PROFILE), default="compatibility")
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output")
    args = parser.parse_args()
    need(re.fullmatch(r"[0-9a-f]{40}", args.revision) and args.revision != "0" * 40, "Supply an exact source revision.")
    if args.cleanup_preparation:
        need(not args.prepare and not args.inside and not args.suite and not args.output and args.profile == "compatibility", "Cleanup accepts no execution or target options.")
        identity, nonce = fixture.preparation_owner(fixture.PREPARATION)
        fixture.remove_preparation(fixture.PREPARATION, identity, nonce)
    elif args.prepare:
        need(not args.inside and not args.suite and not args.output and args.profile == "compatibility", "Preparation accepts no execution or target options.")
        fixture.prepare(fixture.PREPARATION, args.revision)
    elif args.inside:
        need(args.suite and not args.output, "Select the fixed image suite.")
        need(args.suite in (envelope.SUITES if args.profile == envelope.PROFILE else ("operator", "http")), "The suite does not belong to this fixed profile.")
        inside(args)
    else:
        need(args.output and not args.suite, "Supply a new evidence directory.")
        qualify(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError):
        print("PostgreSQL 18.6 compatibility did not pass. Inspect the retained evidence.", file=sys.stderr)
        raise SystemExit(1)
