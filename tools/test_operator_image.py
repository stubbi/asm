#!/usr/bin/env python3
"""Qualify an explicit operator image; this is isolated test orchestration.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
import ctypes
import importlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time
import unittest
import uuid
from urllib.parse import quote, urlencode

sys.path.insert(0, str(Path(__file__).resolve().parent))
import operator_source
import registry

PREFIX = "ASM_OPERATOR_QUALIFICATION="
ENTRYPOINT = ["/usr/bin/python3", "-I", "/app/tools/operator_entrypoint.py"]
MAC_CASE = "test_database.CatalogDatabaseTests.test_extended_acl_on_private_key_cannot_reach_mutation"


class CheckFailure(ValueError):
    """A fixed assertion message supplied only by this qualification harness."""


class SmokeFailure(ValueError):
    """A fixed smoke stage and classification, without raw tool diagnostics."""


def need(value, message):
    if not value:
        raise CheckFailure(message)


def command(arguments, *, timeout=20):
    result = subprocess.run(arguments, capture_output=True, check=True, timeout=timeout)
    need(len(result.stdout) <= 4 * 1024 * 1024 and len(result.stderr) <= 1024 * 1024,
         "Qualification command output exceeds its limit.")
    return result.stdout


def image_contract(value, revision):
    config = value.get("Config", {})
    need(value.get("Architecture") == "amd64" and value.get("Os") == "linux", "The operator target must be Linux AMD64.")
    need(re.fullmatch(r"sha256:[0-9a-f]{64}", value.get("Id", "")), "The image has no immutable ID.")
    need(config.get("User") == "65532:65532", "The image must use UID/GID 65532.")
    need(config.get("Entrypoint") == ENTRYPOINT and config.get("Cmd") == ["--help"], "The operator entrypoint differs.")
    need(config.get("Labels", {}).get("org.opencontainers.image.revision") == revision, "Image source identity differs.")
    need(value.get("RootFS", {}).get("Layers"), "The runtime image has no filesystem layers.")
    return value["Id"]


def v2_image_contract(value, revision, role):
    """Inspect source candidates; this does not grant image publication authority."""
    entries = {"operator": ENTRYPOINT, "publisher": ["/usr/local/bin/asm-publisher"],
        "checker": ["/usr/bin/python3", "-B", "-I", "/app/tools/checker_entrypoint.py"]}
    need(role in entries, "Select one explicit V2 runtime role.")
    need(re.fullmatch(r"[0-9a-f]{40}", revision or "") and revision != "0" * 40, "Supply the exact source revision.")
    config = value.get("Config", {})
    need(value.get("Architecture") == "amd64" and value.get("Os") == "linux", "V2 images require Linux AMD64.")
    need(re.fullmatch(r"sha256:[0-9a-f]{64}", value.get("Id", "")), "The image has no immutable ID.")
    need(config.get("User") == "65532:65532", "The image must use UID/GID 65532.")
    need(config.get("Entrypoint") == entries[role] and config.get("Cmd") == ["--help"], "The V2 entrypoint differs.")
    need(not config.get("Volumes"), "V2 images must not declare writable image volumes.")
    labels = config.get("Labels", {})
    need(labels.get("org.opencontainers.image.revision") == revision
         and labels.get("org.opencontainers.image.source") == "https://github.com/stubbi/asm"
         and labels.get("org.opencontainers.image.licenses") == "AGPL-3.0-or-later", "Image source identity differs.")
    need(value.get("RootFS", {}).get("Layers"), "The runtime image has no filesystem layers.")
    return value["Id"]


def runtime_smoke(args):
    """Record actual-image smoke evidence separately from native release qualification."""
    state = {"stage": "configuration"}
    try:
        return _runtime_smoke(args, state)
    except SmokeFailure:
        raise
    except CheckFailure as failure:
        raise SmokeFailure(f"stage={state['stage']} failure=contract: {failure}") from None
    except subprocess.CalledProcessError as failure:
        raise SmokeFailure(f"stage={state['stage']} failure=command-status actual={failure.returncode} "
            f"stdout_bytes={len(failure.stdout or b'')} stderr_bytes={len(failure.stderr or b'')}") from None
    except subprocess.TimeoutExpired:
        raise SmokeFailure(f"stage={state['stage']} failure=timeout") from None
    except OSError:
        raise SmokeFailure(f"stage={state['stage']} failure=operating-system") from None
    except (ValueError, KeyError, TypeError):
        raise SmokeFailure(f"stage={state['stage']} failure=invalid-data") from None


def _runtime_smoke(args, state):
    need(args.context and args.image and args.output, "Select an explicit Docker context, image, and new report file.")
    client = ["docker", "--context", args.context]
    state["stage"] = "image-inspection"
    inspections = registry.strict_json(command([*client, "image", "inspect", args.image]))
    need(isinstance(inspections, list) and len(inspections) == 1, "Inspect one exact local image.")
    image_id = v2_image_contract(inspections[0], args.revision, args.smoke_kind)

    def run(arguments=(), *, entrypoint=None, status=0):
        options = [*client, "run", "--rm", "--pull=never", "--platform", "linux/amd64", *security()]
        if entrypoint is not None:
            options += ["--entrypoint", entrypoint]
        result = subprocess.run([*options, image_id, *arguments], capture_output=True, timeout=30)
        need(len(result.stdout) <= 1024 * 1024 and len(result.stderr) <= 65536, "Image smoke output exceeds its bound.")
        if result.returncode != status:
            raise SmokeFailure(f"stage={state['stage']} failure=command-status expected={status} actual={result.returncode} "
                f"stdout_bytes={len(result.stdout)} stderr_bytes={len(result.stderr)}")
        return result

    state["stage"] = "source-marker"
    source = registry.strict_json(run(["/app/SOURCE.json"], entrypoint="/bin/cat").stdout)
    need(source["source_revision"] == args.revision and source["repository"] == "https://github.com/stubbi/asm",
         "The runtime source marker differs.")
    state["stage"] = "process-policy"
    process = dict(line.split(":", 1) for line in run(["/proc/self/status"], entrypoint="/bin/cat").stdout.decode().splitlines() if ":" in line)
    need(process["Uid"].split() == ["65532"] * 4 and process["Gid"].split() == ["65532"] * 4
         and int(process["CapEff"].strip(), 16) == 0 and process["NoNewPrivs"].strip() == "1", "Unexpected runtime privileges.")
    state["stage"] = "help"
    help_result = run(status=64 if args.smoke_kind == "publisher" else 0)
    state["stage"] = "invalid-input"
    invalid = run(["--not-an-option"], status=64 if args.smoke_kind == "publisher" else 2)
    need(not invalid.stdout, "Invalid input emitted machine output.")
    files = {"/app/SOURCE.json"}
    if args.smoke_kind == "publisher":
        executable = "/usr/local/bin/asm-publisher"
        files.add(executable)
        state["stage"] = "publisher-libraries"
        libraries = run([executable], entrypoint="/usr/bin/ldd").stdout.decode()
        need("not found" not in libraries and "libcrypto.so.3 => /opt/asm/openssl/lib/libcrypto.so.3" in libraries
             and "libssl.so.3 => /opt/asm/openssl/lib/libssl.so.3" in libraries, "The reviewed publisher crypto profile is unresolved.")
        files.update(re.findall(r"(?:=>\s+)?(/[^\s()]+)", libraries))
        state["stage"] = "publisher-source"
        run(["-a", "-q", "-F", args.revision, executable], entrypoint="/bin/grep")
    else:
        selected = operator_source.FILES if args.smoke_kind == "operator" else (
            "tools/checker_entrypoint.py", "tools/image_source.py", "tools/publication_check.py", "tools/registry.py", "tools/registry_storage.py")
        files.update("/app/" + name for name in selected)
        if args.smoke_kind == "operator":
            files.update(("/app/bin/asm-trust", "/usr/bin/kubectl", "/opt/asm/postgres/bin/psql"))
            state["stage"] = "missing-credentials"
            refusal = run(["publisher-admin", "--connection-file", "/absent", "migrate"], status=1)
            need(not refusal.stdout, "Missing credentials emitted machine output.")
    hashes = {}
    state["stage"] = "file-hashes"
    for line in run(sorted(files), entrypoint="/usr/bin/sha256sum").stdout.decode().splitlines():
        digest, name = line.split("  ", 1)
        need(name in files and name not in hashes and re.fullmatch(r"[0-9a-f]{64}", digest), "Invalid image file digest.")
        hashes[name] = digest
    need(set(hashes) == files, "The image digest record is incomplete.")
    state["stage"] = "source-hashes"
    for name, digest in hashes.items():
        if name.startswith("/app/") and name != "/app/SOURCE.json" and name[5:] in source["files"]:
            need(digest == source["files"][name[5:]], "Runtime source bytes differ from the accepted source.")
    state["stage"] = "daemon-info"
    report = {"schema": 1, "status": "pass", "scope": "v2-runtime-smoke", "role": args.smoke_kind,
        "source_revision": args.revision, "runtime_image_id": image_id, "source": source,
        "runtime_files": hashes, "help_exit_status": help_result.returncode,
        "daemon": command([*client, "info", "--format", "{{.OSType}}/{{.Architecture}}"]).decode().strip(),
        "limit": "Smoke checks do not qualify native execution, hostile-input isolation, Kubernetes deployment, or publication."}
    state["stage"] = "write-report"
    with Path(args.output).open("x") as stream:
        json.dump(report, stream, indent=2, sort_keys=True)
        stream.write("\n")


def derived_contract(runtime, qualifier, files, qualified_files):
    layers = runtime["RootFS"]["Layers"]
    need(qualifier["RootFS"]["Layers"][:len(layers)] == layers, "Qualification must derive from the exact final filesystem.")
    need(files == qualified_files, "Qualification changed an application or loaded runtime dependency.")


def test_contract(result, count):
    need(result.wasSuccessful() and result.testsRun == count, "The complete operator suite did not pass.")
    inapplicable = []
    for case, reason in result.skipped:
        need(case.id() == MAC_CASE and "macOS" in reason, "An applicable operator test was skipped.")
        inapplicable.append({"id": case.id(), "reason": reason})
    need(len(inapplicable) <= 1, "A platform exclusion was duplicated.")
    return inapplicable


def security():
    return ["--read-only", "--network", "none", "--user", "65532:65532",
            "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", "128",
            "--memory", "512m", "--cpus", "2"]


def docker(image, *arguments, entrypoint=None, timeout=20):
    options = ["docker", "run", "--rm", "--platform", "linux/amd64", *security()]
    if entrypoint:
        options += ["--entrypoint", entrypoint]
    return command([*options, image, *arguments], timeout=timeout)


def runtime_files(image):
    executables = ["/opt/asm/postgres/bin/psql", "/usr/bin/python3", "/usr/bin/git"]
    paths = set(executables)
    for executable in executables:
        text = docker(image, executable, entrypoint="/usr/bin/ldd").decode()
        need("not found" not in text, "The operator has an unresolved runtime library.")
        paths.update(re.findall(r"(?:=>\s+)?(/[^\s()]+)", text))
    paths.update("/app/" + name for name in operator_source.FILES)
    paths.add("/app/SOURCE.json")
    need(1 <= len(paths) <= 96, "The loaded runtime file inventory exceeds its bound.")
    files = {}
    for line in docker(image, *sorted(paths), entrypoint="/usr/bin/sha256sum").decode().splitlines():
        digest, name = line.split("  ", 1)
        need(name in paths and name not in files and re.fullmatch(r"[0-9a-f]{64}", digest), "Invalid runtime file digest.")
        files[name] = digest
    need(set(files) == paths, "The runtime file inventory is incomplete.")
    return files


def package_inventory(image):
    text = docker(image, "--show", "--showformat=${binary:Package}\t${Version}\t${source:Package}\t${source:Version}\n",
                  entrypoint="/usr/bin/dpkg-query").decode()
    packages = []
    for line in text.splitlines():
        name, version, source, source_version = line.split("\t")
        need(name and version and source and source_version, "A resolved package has no source identity.")
        packages.append({"package": name, "version": version, "source_package": source,
                         "source_version": source_version,
                         "source_index": "https://snapshot.debian.org/package/" + quote(source, safe="") + "/" + quote(source_version, safe="") + "/"})
    need(packages, "The resolved package inventory is empty.")
    return packages


def make_projection_fixtures(base):
    need(os.geteuid() == 0, "Synthetic projected image fixtures require the build identity.")
    base.mkdir(mode=0o755)
    keys = base / "_keys"
    keys.mkdir(mode=0o700)
    command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
             "-subj", "/CN=Synthetic operator image fixture", "-keyout", str(keys / "key"), "-out", str(keys / "cert")])
    for case in ("valid", "wrong-owner", "wrong-gid", "bad-mode", "symlink-key", "missing-key", "escaping-generation"):
        root = base / case
        root.mkdir(mode=0o755)
        mounts = {}
        for name in ("config", "tls"):
            mount = root / name
            mount.mkdir(mode=0o550)
            generation = mount / "..generation_one"
            generation.mkdir(mode=0o550)
            mounts[name] = generation
            os.chown(mount, 0, 65532)
            os.chown(generation, 0, 65532)
            (mount / "..data").symlink_to(generation.name)
            os.lchown(mount / "..data", 0, 65532)
        tls = root / "tls"
        query = {"sslmode": "verify-full", "sslrootcert": str(tls / "ca.crt"),
                 "sslcert": str(tls / "tls.crt"), "sslkey": str(tls / "tls.key")}
        content = {mounts["config"] / "database.url":
            ("postgresql://asm_operator@localhost:5432/asm?" + urlencode(query, quote_via=quote) + "\n").encode(),
            mounts["tls"] / "ca.crt": (keys / "cert").read_bytes(),
            mounts["tls"] / "tls.crt": (keys / "cert").read_bytes(),
            mounts["tls"] / "tls.key": (keys / "key").read_bytes()}
        for path, body in content.items():
            path.write_bytes(body)
            os.chown(path, 0, 65532)
            path.chmod(0o440)
        key = mounts["tls"] / "tls.key"
        if case == "wrong-owner":
            os.chown(key, 65531, 65532)
        elif case == "wrong-gid":
            os.chown(key, 0, 440)
        elif case == "bad-mode":
            key.chmod(0o444)
        elif case in {"symlink-key", "missing-key"}:
            key.unlink()
            if case == "symlink-key":
                key.symlink_to("ca.crt")
                os.lchown(key, 0, 65532)
        elif case == "escaping-generation":
            pointer = tls / "..data"
            pointer.unlink()
            pointer.symlink_to("../outside")
            os.lchown(pointer, 0, 65532)

    # These fixed seeds are SYNTHETIC TEST ONLY. This derived qualification
    # target never supplies a production root or a runtime signing credential.
    import hashlib
    synthetic = keys / "SYNTHETIC-online-signers"
    synthetic.mkdir(mode=0o700)
    names = ("root1", "root2", "root3", "targets", "snapshot", "timestamp")
    for name in names:
        seed = hashlib.sha256(("ASM SYNTHETIC ONLINE PROJECTION TEST ONLY " + name).encode()).digest()
        encoded = synthetic / (name + ".der")
        encoded.write_bytes(bytes.fromhex("302e020100300506032b657004220420") + seed)
        encoded.chmod(0o600)
        private = synthetic / (name + ".pem")
        command(["openssl", "pkey", "-inform", "DER", "-in", str(encoded), "-out", str(private)])
        private.chmod(0o600)
        command(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(synthetic / (name + ".pub"))])
    trust = "/app/bin/asm-trust"
    unsigned, first, signed = (synthetic / name for name in ("unsigned.json", "first.json", "registry-root.json"))
    command([trust, "prepare-root", str(unsigned), *(str(synthetic / (name + ".pub")) for name in names)])
    command([trust, "sign-root", str(unsigned), str(synthetic / "root1.pem"), str(first)])
    command([trust, "sign-root", str(first), str(synthetic / "root2.pem"), str(signed)])
    for case in ("signers-valid", "signers-wrong-role", "signers-symlink-key", "signers-bad-mode"):
        root = base / case
        root.mkdir(mode=0o755)
        for name in ("keys", "root"):
            mount = root / name
            mount.mkdir(mode=0o550)
            generation = mount / "..generation_one"
            generation.mkdir(mode=0o550)
            for directory in (mount, generation):
                os.chown(directory, 0, 65532)
            (mount / "..data").symlink_to(generation.name)
            os.lchown(mount / "..data", 0, 65532)
            content = ({role + ".pem": (synthetic / (role + ".pem")).read_bytes()
                        for role in ("targets", "snapshot", "timestamp")} if name == "keys" else
                       {"registry-root.json": signed.read_bytes()})
            for filename, body in content.items():
                path = generation / filename
                path.write_bytes(body)
                os.chown(path, 0, 65532)
                path.chmod(0o440)
                (mount / filename).symlink_to("..data/" + filename)
                os.lchown(mount / filename, 0, 65532)
        key = root / "keys/..generation_one/targets.pem"
        if case == "signers-wrong-role":
            key.write_bytes((synthetic / "snapshot.pem").read_bytes())
        elif case == "signers-symlink-key":
            key.unlink()
            key.symlink_to("snapshot.pem")
            os.lchown(key, 0, 65532)
        elif case == "signers-bad-mode":
            key.chmod(0o444)


def actual_entrypoint_test(case):
    """Run the published command interface against this test's owned fresh database."""
    def call(name, *arguments, authority=None):
        argv = [*ENTRYPOINT, name]
        if authority:
            argv += ["--connection-file", str(case.configs[authority])]
        result = subprocess.run([*argv, *arguments], capture_output=True, timeout=30,
                                env={"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1"})
        case.assertEqual(result.returncode, 0, result.stderr.decode())
        return json.loads(result.stdout)
    call("migrate", authority="migrator")
    call("grant", authority="migrator")
    case.assertEqual(call("status", authority="operator")["revision"], 0)
    for number, namespace in enumerate(sorted({record["name"].split("/")[0] for record in case.records})):
        bound = call("bind-namespace", "--namespace", namespace, "--github-id", str(12345 + number), authority="operator")
        case.assertEqual(bound["ownership_evidence"], "operator-assertion")
    plan = call("plan", "--expected-revision", "0")
    imported = call("import", "--expected-revision", "0", "--plan-sha256", plan["plan_sha256"], authority="operator")
    case.assertEqual(imported["revision"], 1)
    case.assertEqual(call("status", authority="operator")["acceptance_commit"], plan["acceptance_commit"])
    case.assertEqual(case.guard(), [["1"]])


def inside(args):
    need(platform.system() == "Linux" and platform.machine() == "x86_64", "Operator qualification requires native Linux AMD64.")
    need(os.geteuid() == 65532 and os.getegid() == 65532 and set(os.getgroups()) <= {65532}, "Unexpected operator identity or projected-reader group.")
    need(os.statvfs("/").f_flag & os.ST_RDONLY, "The qualification root filesystem must be read-only.")
    process = dict(line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines() if ":" in line)
    need(process.get("NoNewPrivs", "").strip() == "1" and int(process.get("CapEff", "1").strip(), 16) == 0,
         "Unexpected privilege authority.")
    need(not Path("/var/run/secrets/kubernetes.io/serviceaccount/token").exists(), "A cluster token entered qualification.")
    libpq = ctypes.CDLL("/opt/asm/postgres/lib/libpq.so.5")
    libpq.PQlibVersion.restype = ctypes.c_int
    need(libpq.PQlibVersion() == 160015, "The loaded libpq is not PostgreSQL 16.15.")
    crypto = ctypes.CDLL("libcrypto.so.3")
    crypto.OpenSSL_version.argtypes = [ctypes.c_int]
    crypto.OpenSSL_version.restype = ctypes.c_char_p
    openssl = crypto.OpenSSL_version(0).decode()
    marker = json.loads(Path("/app/SOURCE.json").read_bytes())
    need(marker["source_revision"] == args.revision, "The accepted source differs from the qualified image revision.")
    os.environ.update(ASM_PROTO_PG_BINDIR="/opt/asm/postgres/bin", ASM_PROTO_LIBPQ="/opt/asm/postgres/lib/libpq.so.5",
                      ASM_OPERATOR_PROJECTION_FIXTURES="/qualification/projected",
                      ASM_TEST_TRUST_TOOL="/app/bin/asm-trust")
    sys.path.insert(0, "/qualification/tests/hosted_registry")
    module = importlib.import_module("test_database")
    setattr(module.CatalogDatabaseTests, "test_actual_image_entrypoint", actual_entrypoint_test)
    suite = unittest.TestSuite()
    for directory in ("/qualification/tests/hosted_registry", "/qualification/tests/operator_image"):
        suite.addTests(unittest.TestLoader().discover(directory, pattern="test_*.py"))
    count = suite.countTestCases()
    need(count >= 56, "The complete operator qualification suite is unavailable.")
    started = time.monotonic()
    result = unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
    inapplicable = test_contract(result, count)
    report = {"schema": 1, "status": "pass", "scope": "explicit-registry-operator", "architecture": "amd64",
              "os": "linux", "execution": "native", "source_revision": args.revision,
              "tests_run": result.testsRun, "applicable_tests_run": result.testsRun - len(inapplicable),
              "applicable_tests_skipped": 0, "not_applicable": inapplicable,
              "seconds": round(time.monotonic() - started, 3), "database_fixture_version": "16.15",
              "database_limit": "PostgreSQL 18.6 private activation compatibility remains unqualified.",
              "loaded_libraries": {"libpq": "16.15", "OpenSSL": openssl},
              "security": {"uid": 65532, "gid": 65532, "projected_reader_gid": 65532, "read_only_root": True,
                           "effective_capabilities": 0, "no_new_privileges": True, "cluster_token": False}}
    print(PREFIX + json.dumps(report, sort_keys=True))


def qualify(args):
    need(platform.system() == "Linux" and platform.machine() == "x86_64", "Use the native AMD64 Linux qualification runner.")
    need(command(["docker", "info", "--format", "{{.OSType}}/{{.Architecture}}"] ).decode().strip()
         in {"linux/x86_64", "linux/amd64"}, "The Docker daemon is not a native AMD64 Linux host.")
    values = []
    for image in (args.image, args.qualification_image):
        result = json.loads(command(["docker", "image", "inspect", image]))
        need(len(result) == 1, "Expected one exact local image.")
        image_contract(result[0], args.revision)
        values.append(result[0])
    runtime, qualifier = values
    image_id, qualification_id = runtime["Id"], qualifier["Id"]
    files = runtime_files(image_id)
    derived_contract(runtime, qualifier, files, runtime_files(qualification_id))
    source = json.loads(docker(image_id, "/app/SOURCE.json", entrypoint="/bin/cat"))
    need(source["source_revision"] == args.revision and set(source["files"]) == set(operator_source.FILES), "Image source marker differs.")
    for path, digest in source["files"].items():
        need(files["/app/" + path] == digest, "Packaged application bytes differ from accepted source objects.")
    # The exact final image must plan offline and reject missing credentials.
    plan = json.loads(docker(image_id, "plan", "--expected-revision", "0", timeout=60))
    need(plan["acceptance_commit"] == args.revision and not plan["artifact_bytes_checked"], "The actual image plan source or evidence differs.")
    refused = subprocess.run(["docker", "run", "--rm", *security(), image_id, "status", "--connection-file", "/missing"],
                             capture_output=True, timeout=20)
    need(refused.returncode != 0 and not refused.stdout, "Missing configuration must fail without machine output.")
    forbidden = json.loads(docker(image_id, "-I", "-c",
        "import json,shutil;from pathlib import Path;values={v:shutil.which(v) for v in ('gcc','cc','make','postgres','initdb')};values.update({'/opt/asm/postgres/bin/'+v:Path('/opt/asm/postgres/bin',v).exists() for v in ('postgres','initdb')});print(json.dumps(values))", entrypoint="/usr/bin/python3"))
    need(not any(forbidden.values()), "The final operator contains a compiler or PostgreSQL server tool.")
    packages = package_inventory(image_id)
    name = "asm-operator-qualification-" + uuid.uuid4().hex
    try:
        result = subprocess.run(["docker", "run", "--rm", "--name", name, "--platform", "linux/amd64", *security(),
            "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=512m,uid=65532,gid=65532,mode=0700",
            "--entrypoint", "/usr/bin/python3", qualification_id, "-I", "/qualification/tools/test_operator_image.py",
            "--inside", "--revision", args.revision], capture_output=True, timeout=300)
    except subprocess.TimeoutExpired as failure:
        sys.stdout.buffer.write(failure.stdout or b"")
        sys.stderr.buffer.write(failure.stderr or b"")
        raise
    finally:
        subprocess.run(["docker", "rm", "--force", name], capture_output=True, timeout=10)
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    need(result.returncode == 0, "The actual image operator qualification failed.")
    reports = [json.loads(line[len(PREFIX):]) for line in result.stdout.decode().splitlines() if line.startswith(PREFIX)]
    need(len(reports) == 1, "Expected one complete successful operator report.")
    report = reports[0]
    need(report["source_revision"] == args.revision and report["applicable_tests_skipped"] == 0, "Qualification identity or test coverage differs.")
    report.update(runtime_image_id=image_id, qualification_image_id=qualification_id, runtime_files=files,
                  source=source, resolved_packages=packages, plan=plan,
                  postgresql_source={"version": "16.15", "url": "https://ftp.postgresql.org/pub/source/v16.15/postgresql-16.15.tar.bz2",
                      "sha256": "c1575341fa7bd40f5274ea465b34390f4dc64cdd0770af327005caaeb9f6b7ed"},
                  final_compiler_and_postgresql_server_absent=True,
                  reproducibility_limit="Resolved signed Debian packages can change between repository updates; this report binds the exact tested image.")
    Path(args.output).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inside", action="store_true")
    parser.add_argument("--make-projection-fixtures", type=Path)
    parser.add_argument("--revision")
    parser.add_argument("--image")
    parser.add_argument("--qualification-image")
    parser.add_argument("--output")
    parser.add_argument("--context", help="Explicit Docker context for V2 smoke checks; ambient context is unchanged")
    parser.add_argument("--smoke-kind", choices=("operator", "publisher", "checker"))
    args = parser.parse_args()
    if args.make_projection_fixtures:
        make_projection_fixtures(args.make_projection_fixtures)
        return
    need(re.fullmatch(r"[0-9a-f]{40}", args.revision or "") and args.revision != "0" * 40, "Supply an exact source revision.")
    if args.smoke_kind:
        runtime_smoke(args)
    elif args.inside:
        inside(args)
    else:
        need(args.image and args.qualification_image and args.output, "Supply both image names and a report path.")
        qualify(args)


if __name__ == "__main__":
    try:
        main()
    except SmokeFailure as failure:
        print(f"Operator image qualification failed: {failure}. Retain the complete test and build logs.", file=sys.stderr)
        raise SystemExit(1)
    except (ValueError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        print("Operator image qualification failed; retain the complete test and build logs.", file=sys.stderr)
        raise SystemExit(1)
