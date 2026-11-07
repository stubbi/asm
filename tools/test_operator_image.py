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

PREFIX = "ASM_OPERATOR_QUALIFICATION="
ENTRYPOINT = ["/usr/bin/python3", "-I", "/app/tools/operator_entrypoint.py"]
MAC_CASE = "test_database.CatalogDatabaseTests.test_extended_acl_on_private_key_cannot_reach_mutation"


def need(value, message):
    if not value:
        raise ValueError(message)


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
                      ASM_OPERATOR_PROJECTION_FIXTURES="/qualification/projected")
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
    args = parser.parse_args()
    if args.make_projection_fixtures:
        make_projection_fixtures(args.make_projection_fixtures)
        return
    need(re.fullmatch(r"[0-9a-f]{40}", args.revision or "") and args.revision != "0" * 40, "Supply an exact source revision.")
    if args.inside:
        inside(args)
    else:
        need(args.image and args.qualification_image and args.output, "Supply both image names and a report path.")
        qualify(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        print("Operator image qualification failed; retain the complete test and build logs.", file=sys.stderr)
        raise SystemExit(1)
