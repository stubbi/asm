#!/usr/bin/env python3
"""Observe synthetic preflight failures without changing qualification policy.

SPDX-License-Identifier: AGPL-3.0-or-later
Temporary diagnostic tooling. It never reads production credentials.
"""
import errno
import hashlib
import json
import os
from pathlib import Path
import selectors
import stat
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prepare_operator as prepare
from registry_admin import AdminError

REASONS = {
    "Use the expected projected volume owner and group.": "owner_group_mismatch",
    "Use a read-only or protected projected volume directory.": "projected_directory_writable",
    "Use one owned AtomicWriter generation pointer.": "generation_pointer_metadata",
    "Use one relative projected generation name.": "generation_pointer_name",
    "Use bounded root:GID65532 projected files with mode0440.": "projected_file_metadata",
    "The projected generation changed during its snapshot.": "generation_changed",
    "Use the fixed files in the projected TLS mount.": "tls_path_identity",
    "Use credential files without extended ACLs.": "extended_acl",
    "Cannot inspect the credential file ACL.": "acl_inspection",
}
STAGES = {function.__code__: stage for function, stage in (
    (prepare.prepare, "prepare_entry"), (prepare.open_protected_directory, "directory_walk"),
    (prepare.check_directory, "projected_directory_policy"), (prepare.projected.__wrapped__, "generation_pin"),
    (prepare.read_projected, "projected_file_read"), (prepare.parse_source_url, "url_policy"),
    (prepare.resolve_ipv4, "dns_resolution"), (prepare.write_private, "private_write"),
    (prepare.same_parent, "parent_identity"), (prepare.publish_snapshot, "atomic_publication"))}


def capture(arguments, *, cwd=None, timeout=15, maximum=16384):
    """Bound each stream and the child deadline; always kill/wait on failure."""
    process = subprocess.Popen(arguments, cwd=cwd, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    streams = {"stdout": bytearray(), "stderr": bytearray()}
    timed_out = limited = False
    deadline = time.monotonic() + timeout
    selector = selectors.DefaultSelector()
    try:
        for name in streams:
            stream = getattr(process, name)
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        while selector.get_map() and not limited:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            for key, _ in selector.select(remaining):
                chunk = os.read(key.fd, 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                output = streams[key.data]
                available = maximum - len(output)
                output.extend(chunk[:available])
                if len(chunk) > available:
                    limited = True
                    break
        if not limited and not timed_out:
            try:
                process.wait(timeout=max(0.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                timed_out = True
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
        process.stdout.close()
        process.stderr.close()
    return {"pid": process.pid, "exit_code": process.returncode, "timed_out": timed_out,
            "output_limit": limited, **{name: bytes(body) for name, body in streams.items()}}


def metadata(identifier, path):
    """Read lstat metadata only; never disclose paths, targets, or file content."""
    try:
        value = path.lstat()
    except OSError as error:
        reason = {errno.ENOENT: "missing", errno.EACCES: "permission_denied"}.get(error.errno, "metadata_error")
        return {"id": identifier, "available": False, "reason": reason}
    return {"id": identifier, "available": True, "uid": value.st_uid, "gid": value.st_gid,
            "mode": format(stat.S_IMODE(value.st_mode), "04o"), "symlink": stat.S_ISLNK(value.st_mode)}


def openssl_result(result):
    error = result["stderr"].lower()
    missing = b"openssl.cnf" in error and b"no such file or directory" in error
    denied = b"openssl.cnf" in error and b"permission denied" in error
    reason = ("timeout" if result["timed_out"] else "output_limit" if result["output_limit"] else
              "success" if result["exit_code"] == 0 else "config_missing" if missing else
              "config_permission_denied" if denied else "setup_failed")
    return {"stage": "openssl_first_ca", "reason": reason, "exit_code": result["exit_code"],
            "timed_out": result["timed_out"], "output_limit": result["output_limit"],
            "stderr_prefix_bytes": len(result["stderr"]),
            "stderr_prefix_sha256": hashlib.sha256(result["stderr"]).hexdigest()}


def projection_attempt(base):
    with tempfile.TemporaryDirectory(prefix="asm-diagnostic-prepare-") as name:
        try:
            prepare.prepare(base / "valid/config", base / "valid/tls", Path(name) / "private",
                            "asm_operator", Path("/opt/asm/postgres/bin/psql"), resolve_dns=True)
        except (AdminError, OSError) as error:
            stage = "prepare_entry"
            trace = error.__traceback__
            while trace:
                stage = STAGES.get(trace.tb_frame.f_code, stage)
                trace = trace.tb_next
            if isinstance(error, AdminError):
                kind, reason = "AdminError", REASONS.get(str(error), "other_constant_refusal")
            else:
                kind = "OSError"
                reason = {errno.ENOENT: "missing_file", errno.EACCES: "permission_denied",
                          errno.ELOOP: "symlink_refused"}.get(error.errno, "io_error")
            return {"status": "refused", "stage": stage, "exception": kind, "reason": reason}
    return {"status": "prepared", "stage": "prepare_complete"}


def main():
    if sys.platform != "linux" or os.geteuid() != 65532 or os.getegid() != 65532:
        print(json.dumps({"scope": "unqualified_operator_diagnostics", "reason": "unexpected_identity"}))
        return 1
    config = [metadata(identifier, Path(path)) for identifier, path in (
        ("ssl_default_config", "/usr/lib/ssl/openssl.cnf"), ("ssl_etc_config", "/etc/ssl/openssl.cnf"))]
    for item, path in zip(config, ("/usr/lib/ssl/openssl.cnf", "/etc/ssl/openssl.cnf")):
        item["readable"] = os.access(path, os.R_OK)
    with tempfile.TemporaryDirectory(prefix="asm-diagnostic-openssl-") as name:
        result = capture(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=Asm runtime test CA", "-addext", "basicConstraints=critical,CA:TRUE",
            "-keyout", "ca.key", "-out", "ca.crt"], cwd=name)
    base = Path("/qualification/projected")
    projected = []
    for case in ("valid", "wrong-owner", "wrong-gid", "bad-mode", "symlink-key", "missing-key", "escaping-generation"):
        for volume, names in (("config", ("database.url",)), ("tls", ("ca.crt", "tls.crt", "tls.key"))):
            mount = base / case / volume
            identifier = case.replace("-", "_") + "_" + volume
            for suffix, path in (("mount", mount), ("pointer", mount / "..data"), ("generation", mount / "..generation_one")):
                projected.append(metadata(identifier + "_" + suffix, path))
            for index, filename in enumerate(names):
                projected.append(metadata(identifier + "_file_" + str(index), mount / "..generation_one" / filename))
    print(json.dumps({"schema": 1, "scope": "unqualified_operator_diagnostics", "qualified": False,
        "openssl_conf_override_present": "OPENSSL_CONF" in os.environ, "openssl_config": config,
        "openssl_setup": openssl_result(result), "projected": projected,
        "preparation": projection_attempt(base)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        result = main()
    except Exception:
        print(json.dumps({"scope": "unqualified_operator_diagnostics", "reason": "diagnostic_internal_error"}))
        result = 1
    raise SystemExit(result)
