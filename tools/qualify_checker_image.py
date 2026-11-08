#!/usr/bin/env python3
"""Qualify one final checker image on a native Linux AMD64 runner.

SPDX-License-Identifier: AGPL-3.0-or-later
Root prepares secret-free private fixtures owned by UID/GID 65532. Every task
uses the final image entrypoint and one read-only input mount. No host code is
mounted. This does not qualify Kubernetes, gVisor, network policies, or a PVC.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import selectors
import stat
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import operator_source
import publication_check
import registry
from test_operator_image import command, need, runtime_smoke

ROOT = Path(__file__).resolve().parents[1]
CHECKER_FILES = ("tools/checker_entrypoint.py", "tools/image_source.py", "tools/publication_check.py",
                 "tools/registry.py", "tools/registry_storage.py")
# Runtime inputs and receipts cannot select or omit a required case.
REQUIRED_CASES = ("absent-object", "corrupt-object", "feature-mismatch", "linked-object", "malformed-archive",
                  "malformed-manifest", "target-mismatch", "valid-features", "valid-source")
MAX_RECEIPT = 32768
INPUT_REFUSAL = b"Asm checker: input is unavailable or invalid. Inspect the retained task and staged files.\n"
LIMIT = ("These synthetic source-artifact tasks check the bundled entrypoint and receipt bindings. "
         "They do not qualify executable-container formats, Kubernetes, gVisor, network policy enforcement, PVC access, or hosted publication.")


def native_contract(client):
    """Require the native operator qualification model and root fixture setup."""
    need(platform.system() == "Linux" and platform.machine() == "x86_64",
         "Use the native AMD64 Linux qualification runner.")
    need(os.geteuid() == 0, "Use sudo for private UID/GID 65532 fixture preparation.")
    need(command([*client, "info", "--format", "{{.OSType}}/{{.Architecture}}"] ).decode().strip()
         in {"linux/x86_64", "linux/amd64"}, "The Docker daemon is not a native AMD64 Linux host.")


def accepted_source(revision):
    """Read only committed regular files; sudo trusts only this checkout path."""
    def git(*arguments, maximum=1024 * 1024):
        return operator_source.git(ROOT, "-c", "safe.directory=" + str(ROOT), *arguments, maximum=maximum)
    need(git("cat-file", "-t", revision, maximum=32) == b"commit\n", "The source identity is not a commit.")
    listing = git("ls-tree", "-r", "-z", "--full-tree", revision, "--", *operator_source.FILES)
    files = {}
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        mode, kind, oid = metadata.decode("ascii").split()
        name = raw_name.decode("ascii")
        need(mode == "100644" and kind == "blob" and name not in files, "Committed source has an unexpected file type.")
        files[name] = hashlib.sha256(git("cat-file", "blob", oid)).hexdigest()
    need(set(files) == set(operator_source.FILES), "The accepted source omits a required runtime file.")
    return files


def source_contract(report, revision, accepted):
    source, runtime = report["source"], report["runtime_files"]
    need(type(source.get("schema")) is int and source["schema"] == 1
         and source.get("repository") == operator_source.REPOSITORY and source.get("source_revision") == revision,
         "The checker source marker differs from the accepted source.")
    need(source.get("files") == accepted and set(accepted) == set(operator_source.FILES),
         "The checker source bytes differ from the accepted commit.")
    need(set(runtime) == {"/app/SOURCE.json", *("/app/" + name for name in CHECKER_FILES)}
         and all(runtime["/app/" + name] == accepted[name] for name in CHECKER_FILES)
         and runtime["/app/SOURCE.json"] == hashlib.sha256(registry.json_bytes(source)).hexdigest(),
         "The final checker modules differ from the accepted commit.")


def make_fixture(root, identity):
    """Create one bounded synthetic task. Caller assigns image ownership later."""
    need(identity in REQUIRED_CASES, "Select one required checker case.")
    root.mkdir(mode=0o700)
    objects = root / "objects"
    objects.mkdir(mode=0o700)
    task = hashlib.sha256(("Asm final checker synthetic task " + identity).encode()).hexdigest()[:32]
    extra = ""
    if identity in {"valid-features", "feature-mismatch"}:
        # Same optional dependency and feature profile as tests/publisher/test_features.py.
        extra = ('\n[dependencies]\n"z/math" = { features = ["wide", "portable"], version = "^2.0.0", '
                 'optional = true, default-features = false }\n"a/math" = "*"\n[features]\n'
                 'vectors = ["z/math/portable", "dep:z/math"]\ndefault = ["vectors"]\n')
    project = '[package]\nname = "hello"\nversion = "1.0.0"\n[target.x86_64-linux]\nsource = "src/main.s"\n'
    archive = registry.make_archive({"asm.toml": ((project + extra).encode(), 0o644),
        "LICENSE": (b"Synthetic fixture under MIT.\n", 0o644), "README.md": (b"Synthetic checker fixture.\n", 0o644),
        "src/main.s": (b".global _start\n_start: nop\n", 0o644)})
    if identity == "malformed-archive":
        archive = b"Not an archive.\n"
    digest = hashlib.sha256(archive).hexdigest()
    declaration = {"sha256": digest, "bytes": len(archive)}
    value = {"schema": 2, "owner_id": "2" * 32, "name": "example/hello", "version": "1.0.0",
        "summary": "Synthetic final checker image fixture.", "license": "MIT",
        "source": {"commit": {"algorithm": "git-sha1", "digest": "b" * 40}, "path": ".", "archive": declaration},
        "artifacts": [{"kind": "source", "format": "tar.gz", "isa": "x86_64", "os": "linux", "abi": "sysv-amd64",
                       "cpu_features": [], **declaration}]}
    if extra:
        value["dependencies"] = [
            {"default_features": True, "features": [], "name": "a/math", "optional": False, "requirement": "*"},
            {"default_features": False, "features": ["portable", "wide"], "name": "z/math", "optional": True,
             "requirement": "^2.0.0"}]
        value["features"] = [{"members": ["vectors"], "name": "default"},
                             {"members": ["dep:z/math", "z/math/portable"], "name": "vectors"}]
        if identity == "feature-mismatch":
            value["features"][1]["members"] = ["dep:z/math"]
    if identity == "target-mismatch":
        value["artifacts"][0].update(isa="aarch64", abi="aapcs64")
    manifest = registry.json_bytes(value) if identity != "malformed-manifest" else b'{"schema":2,"schema":2}\n'
    (root / "manifest.json").write_bytes(manifest)
    (root / "manifest.json").chmod(0o600)
    object_file = objects / (task + "-" + digest)
    if identity != "absent-object":
        body = b"!" + archive[1:] if identity == "corrupt-object" else archive
        if identity == "linked-object":
            sentinel = root / "sentinel"
            sentinel.write_bytes(body)
            sentinel.chmod(0o600)
            object_file.symlink_to("../sentinel")
        else:
            object_file.write_bytes(body)
            object_file.chmod(0o600)
    outcome = ("pass" if identity in {"valid-source", "valid-features"} else "error"
               if identity in {"corrupt-object", "absent-object", "linked-object"} else "fail")
    return {"id": identity, "task_id": task, "manifest_sha256": hashlib.sha256(manifest).hexdigest(),
            "objects": [dict(declaration)], "expected_outcome": None if identity == "malformed-manifest" else outcome,
            "exit_status": 1 if identity == "malformed-manifest" else 0}


def snapshot(root):
    """Record bytes, ownership, mode, and links without traversing a symlink."""
    result = {}
    for path in [root, *sorted(root.rglob("*"))]:
        info = path.lstat()
        record = [info.st_mode, info.st_uid, info.st_gid, info.st_nlink]
        if stat.S_ISLNK(info.st_mode):
            record.append(os.readlink(path))
        elif stat.S_ISREG(info.st_mode):
            record.append(hashlib.sha256(path.read_bytes()).hexdigest())
        else:
            need(stat.S_ISDIR(info.st_mode), "The synthetic input contains a special file.")
        result[str(path.relative_to(root))] = record
    return result


def receipt_contract(raw, case, revision, policy):
    need(0 < len(raw) <= MAX_RECEIPT, "The checker receipt exceeds its byte limit.")
    value = registry.strict_json(raw)
    need(registry.json_bytes(value) == raw, "The checker receipt is not canonical JSON.")
    expected = {"schema": 1, "task_id": case["task_id"], "manifest_sha256": case["manifest_sha256"],
        "checker_revision": revision, "policy_sha256": policy, "outcome": case["expected_outcome"],
        "objects": [{**item, "outcome": case["expected_outcome"]} for item in case["objects"]]}
    need(isinstance(value, dict) and type(value.get("schema")) is int and value == expected
         and all(type(item["bytes"]) is int for item in value["objects"]),
         "The checker receipt binding or outcome differs.")
    return value


def coverage_contract(report):
    need(report.get("test_ids") == list(REQUIRED_CASES)
         and type(report.get("tests_run")) is int and report["tests_run"] == len(REQUIRED_CASES)
         and type(report.get("tests_skipped")) is int and report["tests_skipped"] == 0,
         "Every fixed checker qualification case must run without a skip.")
    need(report.get("execution") == "native" and report.get("os") == "linux" and report.get("architecture") == "amd64",
         "Checker qualification requires native Linux AMD64 execution.")


def case_arguments(client, image, name, root, task):
    need(not any(character in str(root) for character in (",", "\n", "\r", "\0")), "The synthetic input path is invalid.")
    return [*client, "run", "--rm", "--pull=never", "--name", name, "--platform", "linux/amd64",
        "--read-only", "--network", "none", "--user", "65532:65532", "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges", "--pids-limit", "16", "--memory", "512m", "--cpus", "1",
        "--mount", "type=bind,src=" + str(root) + ",dst=/input,readonly", image, "--task", task]


def run_case(arguments, *, timeout=35):
    """Bound both pipes and wall time while retaining an expected nonzero exit."""
    process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env={"PATH": os.defpath, "HOME": "/nonexistent", "LC_ALL": "C"})
    streams = selectors.DefaultSelector()
    output, errors = bytearray(), bytearray()
    deadline = time.monotonic() + timeout
    try:
        for pipe, target in ((process.stdout, output), (process.stderr, errors)):
            os.set_blocking(pipe.fileno(), False)
            streams.register(pipe, selectors.EVENT_READ, target)
        while streams.get_map():
            remaining = deadline - time.monotonic()
            need(remaining > 0, "The checker qualification deadline expired.")
            ready = streams.select(remaining)
            need(ready, "The checker qualification deadline expired.")
            for key, _ in ready:
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    streams.unregister(key.fileobj)
                    continue
                key.data.extend(chunk)
                need(len(key.data) <= (MAX_RECEIPT if key.data is output else 65536),
                     "The checker qualification output exceeds its byte limit.")
        try:
            status = process.wait(timeout=max(0.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            raise ValueError("The checker qualification deadline expired.") from None
        return subprocess.CompletedProcess(arguments, status, bytes(output), bytes(errors))
    finally:
        streams.close()
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
        process.stdout.close()
        process.stderr.close()


def qualify(args, state=None):
    state = state if state is not None else {}
    state["stage"] = "configuration"
    need(args.context and args.image and args.output, "Select a Docker context, final image, and new report file.")
    need(re.fullmatch(r"[0-9a-f]{40}", args.revision or "") and args.revision != "0" * 40,
         "Supply the exact source revision.")
    client = ["docker", "--context", args.context]
    state["stage"] = "native-runner"
    native_contract(client)
    state["stage"] = "accepted-source"
    accepted = accepted_source(args.revision)
    for name in CHECKER_FILES:
        need(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == accepted[name],
             "The qualification source differs from the accepted commit.")
    policy = publication_check.policy_digest()
    with tempfile.TemporaryDirectory(prefix="asm-checker-image-") as directory:
        base = Path(directory).resolve()
        smoke_file = base / "smoke.json"
        state["stage"] = "final-image-smoke"
        runtime_smoke(SimpleNamespace(context=args.context, image=args.image, revision=args.revision,
                                     smoke_kind="checker", output=str(smoke_file)))
        report = registry.strict_json(smoke_file.read_bytes())
        state["stage"] = "source-binding"
        source_contract(report, args.revision, accepted)
        image_id = report["runtime_image_id"]
        # This fixed probe is separate from task execution. It mounts no input.
        probe = ('import json,os;from pathlib import Path;'
                 'print(json.dumps({"read_only_root":bool(os.statvfs("/").f_flag & os.ST_RDONLY),'
                 '"cluster_token":Path("/var/run/secrets/kubernetes.io/serviceaccount/token").exists()}))')
        state["stage"] = "root-and-token-probe"
        probe_name = "asm-checker-probe-" + uuid.uuid4().hex
        try:
            checked = run_case([*client, "run", "--rm", "--pull=never", "--name", probe_name,
                "--platform", "linux/amd64", "--read-only", "--network", "none", "--user", "65532:65532",
                "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", "16", "--memory", "512m",
                "--cpus", "1", "--entrypoint", "/usr/bin/python3", image_id, "-I", "-c", probe])
        finally:
            run_case([*client, "rm", "--force", probe_name], timeout=5)
        measured = registry.strict_json(checked.stdout)
        need(checked.returncode == 0 and not checked.stderr and isinstance(measured, dict)
             and set(measured) == {"read_only_root", "cluster_token"}
             and measured["read_only_root"] is True and measured["cluster_token"] is False,
             "The checker root filesystem or token policy differs.")
        cases = []
        for identity in REQUIRED_CASES:
            state["stage"] = "fixture-" + identity
            root = base / identity
            case = make_fixture(root, identity)
            for path in [root, *root.rglob("*")]:
                os.chown(path, 65532, 65532, follow_symlinks=False)
            before = snapshot(root)
            name = "asm-checker-qualification-" + uuid.uuid4().hex
            try:
                state["stage"] = "task-" + identity
                result = run_case(case_arguments(client, image_id, name, root, case["task_id"]))
            finally:
                # --rm normally removes an exited container before this fallback.
                # A timeout still fails qualification after this bounded cleanup.
                run_case([*client, "rm", "--force", name], timeout=5)
            state["stage"] = "receipt-" + identity
            need(snapshot(root) == before, "The checker changed its synthetic input.")
            need(result.returncode == case["exit_status"], "The checker qualification exit status differs.")
            if case["expected_outcome"] is None:
                need(not result.stdout and result.stderr == INPUT_REFUSAL,
                     "Malformed input must return the exact checker input refusal without a receipt.")
            else:
                need(not result.stderr, "A completed checker receipt also emitted an error.")
                receipt_contract(result.stdout, case, args.revision, policy)
            cases.append({"id": identity, "task_id": case["task_id"], "manifest_sha256": case["manifest_sha256"],
                "expected_outcome": case["expected_outcome"], "exit_status": result.returncode,
                "receipt_sha256": hashlib.sha256(result.stdout).hexdigest() if result.stdout else None})
        report.update(scope="v2-runtime-qualification", os="linux", architecture="amd64", execution="native",
            tests_run=len(cases), tests_skipped=0, test_ids=[case["id"] for case in cases], cases=cases,
            checker_policy_sha256=policy, inputs_unchanged=True, limit=LIMIT,
            security={"uid": 65532, "gid": 65532, "read_only_root": True, "effective_capabilities": 0,
                      "no_new_privileges": True, "cluster_token": False, "network": "none"})
        coverage_contract(report)
        state["stage"] = "write-report"
        with Path(args.output).open("x") as output:
            json.dump(report, output, indent=2, sort_keys=True)
            output.write("\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--context", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    state = {"stage": "configuration"}
    try:
        qualify(args, state=state)
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        print(f"Checker image qualification failed: stage={state['stage']}. "
              "Retain the source, image inspection, and complete test logs.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
