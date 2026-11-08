#!/usr/bin/env python3
"""Run one private registry check job, retain bytes, then commit its fenced result.

This operator command is separate from the assembly HTTP application. The
checker receives read-only task inputs and source, without the database file,
object-store credentials, Docker socket, signing keys, or network access.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import secrets
import shutil
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import publication_check
import registry
import registry_admin
import registry_mirror
from registry_storage import _directory


def _result(connection, sql, maximum=160 * 1024):
    raw = connection.execute(sql).encode("utf-8")
    registry.require(0 < len(raw) <= maximum, "worker database result exceeds its limit")
    return registry.strict_json(raw)


def run_one(connection, store, staging: Path, worker_id: str, checker, *, work_root=None):
    """Claim one task. Preserve input and retained bytes after uncertain completion.

    The injected checker is a trusted operator boundary, never a task field.
    Production invocation below supplies only the fixed container executor.
    """
    registry.require(re.fullmatch("[0-9a-f]{32}", worker_id or ""), "invalid worker identity")
    worker = registry_admin.sql_text(worker_id)
    lease = _result(connection, f"SELECT asm_publication.claim_check({worker},60);")
    if lease is None:
        return None
    fields = {"task_id", "fence", "manifest", "manifest_sha256", "objects"}
    registry.exact_keys(lease, fields, fields, "worker lease")
    task = lease["task_id"]
    registry.require(isinstance(task, str) and re.fullmatch("[0-9a-f]{32}", task)
        and type(lease["fence"]) is int and 0 < lease["fence"] < 2**63, "invalid worker lease identity")
    registry.require(isinstance(lease["manifest"], str), "worker manifest must be text")
    raw = lease["manifest"].encode("ascii")
    _, objects = publication_check.manifest(raw)
    registry.require(hashlib.sha256(raw).hexdigest() == lease["manifest_sha256"], "worker manifest binding differs")
    expected = [{"sha256": digest, "bytes": objects[digest]} for digest in sorted(objects)]
    registry.require(lease["objects"] == expected, "worker object declarations differ")
    directory = tempfile.mkdtemp(prefix="asm-check-input-", dir=work_root)
    checked = False
    try:
        manifest = Path(directory) / "manifest.json"
        descriptor = os.open(manifest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(raw)
        view = Path(directory) / "objects"
        view.mkdir(mode=0o700)
        for item in expected:
            filename = task + "-" + item["sha256"]
            try:
                data = publication_check._read(staging / filename, item["bytes"])
            except publication_check.InputUnavailable:
                # The checker reports absent or unsafe staging as an error.
                continue
            descriptor = os.open(view / filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
            del data
        receipt = checker(task, manifest, view)
        checked = True
    finally:
        # An unknown remote outcome can leave a checker using this view.
        # Preserve it for operator reconciliation, together with staged bytes.
        if checked:
            shutil.rmtree(directory)
    fields = {"schema", "task_id", "manifest_sha256", "checker_revision", "policy_sha256", "outcome", "objects"}
    registry.exact_keys(receipt, fields, fields, "check receipt")
    registry.require(type(receipt["schema"]) is int and receipt["schema"] == 1
        and receipt["task_id"] == task and receipt["manifest_sha256"] == lease["manifest_sha256"]
        and isinstance(receipt["checker_revision"], str) and registry.HEX40.fullmatch(receipt["checker_revision"])
        and receipt["checker_revision"] != "0" * 40
        and receipt["policy_sha256"] == publication_check.policy_digest(), "check receipt binding differs")
    registry.require(isinstance(receipt["objects"], list) and len(receipt["objects"]) == len(expected), "check receipt objects differ")
    outcomes = []
    for declaration, result in zip(expected, receipt["objects"], strict=True):
        registry.exact_keys(result, {"sha256", "bytes", "outcome"}, {"sha256", "bytes", "outcome"}, "object result")
        registry.require(result["sha256"] == declaration["sha256"] and type(result["bytes"]) is int
            and result["bytes"] == declaration["bytes"] and result["outcome"] in ("pass", "fail", "error"),
            "check receipt object binding differs")
        outcomes.append(result["outcome"])
    outcome = "fail" if "fail" in outcomes else "error" if "error" in outcomes else "pass"
    registry.require(receipt["outcome"] == outcome, "check receipt outcome differs")
    if outcome == "pass":
        for item in expected:
            store.put_blob(staging / (task + "-" + item["sha256"]), item["sha256"], item["bytes"])
        store.create_object("publications/v2/intents/" + lease["manifest_sha256"] + ".json", raw)
    encoded = registry.json_bytes(receipt).decode("ascii")
    return _result(connection, "SELECT asm_publication.complete_check(" + registry_admin.sql_text(task) + "," +
        worker + "," + str(lease["fence"]) + "," + registry_admin.sql_text(encoded) + ");", maximum=65536)


def container_arguments(docker, socket, image, name, config, task, manifest, staging, revision):
    """Return direct Docker arguments for a preloaded, digest-selected runtime.

    Image selection and the local daemon socket are trusted operator inputs.
    Package fields cannot select the executable, image, command, or mounts.
    """
    registry.require(isinstance(image, str) and re.fullmatch(r"(?:[A-Za-z0-9._/:-]+@)?sha256:[0-9a-f]{64}", image),
                     "select a preloaded checker runtime by image digest")
    registry.require(Path(socket).is_absolute() and ".." not in Path(socket).parts, "select an absolute local Docker socket")
    registry.require(re.fullmatch("asm-check-[0-9a-f]{32}", name or ""), "invalid checker process identity")
    registry.require(manifest.name == "manifest.json" and staging.absolute() == manifest.parent.absolute() / "objects",
                     "checker inputs must use one private task view")
    args = [docker, "--config", str(config), "--host", "unix://" + socket, "run", "--name", name,
        "--rm", "--pull=never", "--network=none", "--read-only", "--cap-drop=ALL",
        "--security-opt=no-new-privileges", "--user", f"{os.getuid()}:{os.getgid()}",
        "--memory=512m", "--memory-swap=512m", "--cpus=1", "--pids-limit=16", "--ulimit", "core=0",
        "--entrypoint", "/usr/bin/python3"]
    mounts = [(Path(__file__).with_name(source), "/checker/" + source)
              for source in ("publication_check.py", "registry.py", "registry_storage.py")]
    # Mount the private parent, not a lone file under a root-owned directory.
    mounts += [(manifest.parent, "/input")]
    for source, destination in mounts:
        source = str(Path(source).absolute())
        registry.require(not any(char in source for char in (",", "\n", "\r", "\0")), "checker mount path contains unsupported characters")
        args += ["--mount", f"type=bind,src={source},dst={destination},readonly"]
    return args + [image, "-B", "-I", "/checker/publication_check.py", "check", "--task", task,
        "--manifest", "/input/manifest.json", "--objects", "/input/objects", "--checker-revision", revision]


def isolated_checker(docker, socket, image, revision):
    registry.require(registry.HEX40.fullmatch(revision or "") and revision != "0" * 40, "select the exact checker source revision")

    def run(task, manifest, staging):
        name = "asm-check-" + secrets.token_hex(16)
        # Empty explicit Docker configuration prevents ambient proxy/auth injection.
        with tempfile.TemporaryDirectory(prefix="asm-check-config-") as config:
            args = container_arguments(docker, socket, image, name, Path(config), task, manifest, staging, revision)
            prefix = args[:5]
            try:
                volumes = registry.strict_json(registry_admin.run_bounded(
                    prefix + ["image", "inspect", "--format", "{{json .Config.Volumes}}", image],
                    environment=registry_admin.clean_environment(), output_limit=4096, timeout=5))
                registry.require(volumes is None or volumes == {},
                                 "checker runtime must not declare writable image volumes")
                raw = registry_admin.run_bounded(args, environment=registry_admin.clean_environment(),
                                                  output_limit=32768, timeout=35)
                receipt = registry.strict_json(raw)
                registry.require(registry.json_bytes(receipt) == raw, "checker result is not canonical")
                return receipt
            finally:
                try:
                    registry_admin.run_bounded(prefix + ["rm", "--force", name], environment=registry_admin.clean_environment(),
                                               output_limit=4096, timeout=5)
                except (registry_admin.AdminError, OSError):
                    # --rm handles completed jobs; an unavailable daemon needs
                    # operator reconciliation. No different process is targeted.
                    pass
    return run


def main(argv=None, *, fixed_tools=None, checker_revision=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--connection-file", type=Path, required=True)
    parser.add_argument("--staging", type=Path, required=True)
    parser.add_argument("--work-root", type=Path, required=True,
                        help="Private task directory; Kubernetes requires the dedicated input PVC root")
    parser.add_argument("--worker-id", required=True)
    parser.add_argument("--checker-image", required=True)
    if fixed_tools is None:
        parser.add_argument("--psql", required=True)
        parser.add_argument("--executor", choices=("docker", "kubernetes"), default="docker")
        parser.add_argument("--docker", default="docker")
        parser.add_argument("--docker-socket")
        parser.add_argument("--kubectl", type=Path)
        parser.add_argument("--checker-revision", required=True)
    else:
        registry.require(set(fixed_tools) == {"psql", "kubectl"} and checker_revision is not None,
                         "invalid fixed worker tools")
        parser.set_defaults(psql=fixed_tools["psql"], kubectl=fixed_tools["kubectl"],
                            checker_revision=checker_revision, executor="kubernetes")
    parser.add_argument("--kubeconfig", type=Path)
    parser.add_argument("--checker-namespace")
    parser.add_argument("--checker-claim")
    parser.add_argument("--checker-node")
    parser.add_argument("--checker-runtime")
    registry_mirror._store_arguments(parser)
    args = parser.parse_args(argv)
    try:
        if args.executor == "docker":
            registry.require(args.docker_socket is not None, "select the local Docker socket")
            executable = shutil.which(args.docker)
            registry.require(executable is not None, "install the selected Docker client before running a check job")
            checker = isolated_checker(executable, args.docker_socket, args.checker_image, args.checker_revision)
        else:
            import kubernetes_checker
            registry.require(all(value is not None for value in (args.kubectl, args.kubeconfig,
                args.checker_namespace, args.checker_claim, args.checker_node, args.checker_runtime)),
                "select the Kubernetes client, private configuration, namespace, input claim, node, and runtime")
            checker = kubernetes_checker.kubernetes_checker(args.kubectl, args.kubeconfig, args.checker_image,
                args.checker_revision, namespace=args.checker_namespace, claim=args.checker_claim,
                node=args.checker_node, runtime=args.checker_runtime, work_root=args.work_root)
        with _directory(args.work_root, private=True):
            pass
        store = registry_mirror._store(args)
        with registry_admin.Connection(args.connection_file, args.psql, "asm_publication_worker") as connection:
            result = run_one(connection, store, args.staging, args.worker_id, checker, work_root=args.work_root)
        if result is not None:
            sys.stdout.buffer.write(registry.json_bytes(result))
        return 0
    except (registry.RegistryError, registry_admin.AdminError, publication_check.InputUnavailable,
            OSError, UnicodeError, TypeError):
        print("Asm worker: the operation failed or its result is unknown. Inspect the task before retrying.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
