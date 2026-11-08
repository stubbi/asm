#!/usr/bin/env python3
"""Exercise the published installer and first project with no user credentials.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import signal
import stat
import subprocess
import tempfile
import time

import registry

SITE = "https://asm.build"
INSTALL = "curl -qfsS -m120 https://asm.build/install.sh | sh"
TARGETS = {("Linux", "x86_64"): "x86_64-linux", ("Linux", "aarch64"): "aarch64-linux",
           ("Darwin", "arm64"): "aarch64-macos"}
PROXIES = ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
           "all_proxy", "ALL_PROXY", "no_proxy", "NO_PROXY")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def clean_environment(home):
    """Forward only the documented, bounded transport routing settings."""
    environment = {"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"}
    for name in PROXIES:
        if name in os.environ:
            value = os.environ[name]
            require(len(value.encode()) <= 2048 and all(33 <= ord(c) <= 126 for c in value),
                    "A proxy setting exceeds its bound or contains whitespace/control characters.")
            environment[name] = value
    return environment


def command(arguments, *, cwd, environment, evidence, timeout, deadline, output_limit=65536,
            record_stdout=True):
    """Bound wall time and both output streams; retain failures before raising."""
    remaining = min(timeout, deadline - time.monotonic())
    require(remaining > 0, "The complete production-install check exceeded its time limit.")
    item = {"arguments": arguments, "timeout_seconds": remaining}
    evidence["commands"].append(item)
    started = time.monotonic()
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    process = subprocess.Popen(arguments, cwd=cwd, env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            while selector.get_map():
                left = started + remaining - time.monotonic()
                if left <= 0:
                    item["timed_out"] = True
                    raise RuntimeError("The command timed out.")
                for key, _ in selector.select(min(left, 0.1)):
                    block = os.read(key.fileobj.fileno(), 8192)
                    if not block:
                        selector.unregister(key.fileobj)
                        continue
                    stream = buffers[key.data]
                    if len(stream) + len(block) > output_limit:
                        stream.extend(block[:output_limit - len(stream)])
                        item["output_limit_exceeded"] = True
                        raise RuntimeError("The command exceeded its output limit.")
                    stream.extend(block)
        process.wait(timeout=max(0.01, started + remaining - time.monotonic()))
    except BaseException as error:
        item["error"] = str(error) or type(error).__name__
        if isinstance(error, subprocess.TimeoutExpired):
            item["timed_out"] = True
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=10)
        raise
    finally:
        process.stdout.close()
        process.stderr.close()
        item.update(exit_code=process.returncode, elapsed_seconds=round(time.monotonic() - started, 3),
                    stderr=buffers["stderr"].decode("utf-8", "replace"))
        if record_stdout:
            item["stdout"] = buffers["stdout"].decode("utf-8", "replace")
        else:
            item.update(stdout_bytes=len(buffers["stdout"]), stdout_sha256=sha256(buffers["stdout"]))
    return item, bytes(buffers["stdout"])


def fetch(path, limit, *, cwd, environment, evidence, deadline):
    item, data = command(["/usr/bin/curl", "-q", "--proto", "=https", "--proto-redir", "=https",
                          "--fail", "--silent", "--show-error", "--location", "--max-redirs", "4",
                          "--connect-timeout", "15", "--max-time", "120", "--max-filesize", str(limit),
                          "--url", SITE + path], cwd=cwd, environment=environment, evidence=evidence,
                         timeout=125, deadline=deadline, output_limit=limit, record_stdout=False)
    require(item["exit_code"] == 0, "A required public website download failed. See the retained command error.")
    require(0 < len(data) <= limit, "A public website response is empty or exceeds its bound.")
    return data


def installed_identity(path, record, artifact):
    metadata = path.lstat()
    require(stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1 and metadata.st_uid == os.getuid()
            and metadata.st_mode & 0o100 and not metadata.st_mode & 0o6022,
            "The installed command has unsafe ownership, mode, or links.")
    require(metadata.st_size == artifact["bytes"], "The installed command size differs from its public record.")
    data = path.read_bytes()
    registry.validate_artifact(data, record, artifact)
    return {"sha256": sha256(data), "bytes": len(data), "device": metadata.st_dev,
            "inode": metadata.st_ino, "mode": stat.S_IMODE(metadata.st_mode), "mtime_ns": metadata.st_mtime_ns}


def check(expected_target, expected_commit, evidence):
    target = TARGETS.get((platform.system(), platform.machine()))
    evidence.update(host={"system": platform.system(), "machine": platform.machine(),
                          "version": platform.release()}, target=target)
    require(target is not None, "This native host has no published POSIX installer target.")
    require(expected_target is None or target == expected_target, "The native host differs from the required target.")
    if platform.system() == "Darwin":
        require(int(platform.mac_ver()[0].split(".")[0]) >= 15, "The native host requires macOS 15 or later.")
    temporary_root = "/private/tmp" if platform.system() == "Darwin" else "/tmp"
    deadline = time.monotonic() + 900
    with tempfile.TemporaryDirectory(prefix="asm-published-install-", dir=temporary_root) as directory:
        root = Path(directory)
        root.chmod(0o700)
        home = root / "home"
        home.mkdir(mode=0o700)
        environment = clean_environment(home)
        evidence["environment_names"] = sorted(environment)
        common = {"cwd": home, "environment": environment, "evidence": evidence, "deadline": deadline}
        evidence["phase"] = "read public release metadata"
        build_data = fetch("/build.json", 65536, **common)
        build = registry.strict_json(build_data)
        require(isinstance(build, dict) and type(build.get("schema")) is int and build["schema"] == 1,
                "The website build metadata is invalid.")
        commit = build.get("reference_commit")
        require(isinstance(commit, str) and registry.HEX40.fullmatch(commit) and commit != "0" * 40,
                "The website does not identify an exact source commit.")
        require(expected_commit is None or commit == expected_commit, "The website differs from the expected published commit.")
        version = build.get("bootstrap_version")
        registry.version_tuple(version)
        record_data = fetch(f"/registry/v1/packages/stubbi/asm/{version}.json", 1048576, **common)
        record = registry.validate_manifest(registry.strict_json(record_data))
        require(record["name"] == "stubbi/asm" and record["version"] == version and not record["yanked"]
                and record["source"]["repository"] == "https://github.com/stubbi/asm",
                "The public record does not identify the current Asm release.")
        selected = [a for a in record["artifacts"] if a["target"] == target and a["kind"] == "executable"]
        require(len(selected) == 1, "The published release has no unique executable for this native host.")
        artifact = selected[0]
        require(artifact["url"] == f"https://github.com/stubbi/asm/releases/download/v{version}/asm-{version}-{target}",
                "The public executable URL differs from the release identity.")
        script = fetch("/install.sh", 1048576, **common)
        evidence.update(site_commit=commit, build_sha256=sha256(build_data), version=version,
                        release_source_commit=record["source"]["commit"], record_sha256=sha256(record_data),
                        observed_installer_sha256=sha256(script), artifact=artifact,
                        installer_binding="Installer hash observed before and after the unchanged README pipeline.")
        evidence["phase"] = "check the public executable copy"
        public_path = f"/bootstrap/sha256/{artifact['sha256']}/asm-{version}-{target}"
        public_bytes = fetch(public_path, artifact["bytes"], **common)
        registry.validate_artifact(public_bytes, record, artifact)
        evidence["first_party_executable"] = {"url": SITE + public_path, "bytes": len(public_bytes),
                                               "sha256": sha256(public_bytes)}
        evidence["phase"] = "run the normal published installer"
        item, _ = command(["/bin/sh", "-c", INSTALL], **common, timeout=480)
        require(item["exit_code"] == 0, "The published installer failed. See the retained command error.")
        executable = home / ".local/bin/asm"
        identity = installed_identity(executable, record, artifact)
        evidence["installed"] = identity
        evidence["phase"] = "run the published first project"
        for arguments, cwd, expected in ((["version"], home, f"asm {version} ({target})\n"),
                                          (["new", "hello"], home, None),
                                          (["run"], home / "hello", "Hello from asm!\n"),
                                          (["test"], home / "hello", "Passed tests/main.s\n")):
            item, output = command([str(executable), *arguments], cwd=cwd, environment=environment,
                                   evidence=evidence, deadline=deadline, timeout=60)
            require(item["exit_code"] == 0, "A published first-project command failed.")
            require(expected is None or output.decode() == expected, "A published first-project command returned unexpected output.")
        for name in ("asm.toml", "src/main.s", "tests/main.s"):
            require((home / "hello" / name).is_file(), "The first project is missing a required file.")
        evidence["phase"] = "check an unchanged repeat installation"
        item, _ = command(["/bin/sh", "-c", INSTALL], **common, timeout=150)
        require(item["exit_code"] == 0 and "already installed" in item["stdout"], "The repeat installation did not report an unchanged command.")
        require(installed_identity(executable, record, artifact) == identity, "A repeat installation changed the installed command.")
        evidence["repeat_installation"] = "unchanged"
        evidence["phase"] = "preserve an unrelated existing command"
        other_home = root / "existing"
        other_bin = other_home / ".local/bin"
        other_bin.mkdir(parents=True, mode=0o700)
        other_home.chmod(0o700)
        (other_home / ".local").chmod(0o700)
        other = other_bin / "asm"
        original = b"An unrelated command. Do not execute or overwrite.\n"
        other.write_bytes(original)
        other.chmod(0o755)
        stamp = other.stat()
        item, _ = command(["/bin/sh", "-c", INSTALL], cwd=other_home,
                          environment=clean_environment(other_home), evidence=evidence, deadline=deadline, timeout=150)
        require(item["exit_code"] != 0 and "existing asm file" in item["stderr"] and other.read_bytes() == original
                and other.stat().st_ino == stamp.st_ino and other.stat().st_mode == stamp.st_mode,
                "The installer did not safely refuse an unrelated existing command.")
        evidence["existing_command"] = "refused and preserved"
        evidence["phase"] = "confirm stable publication"
        require(fetch("/build.json", 65536, **common) == build_data and fetch("/install.sh", 1048576, **common) == script,
                "The published website or installer changed during the check. Run the check against the current deployment.")
        evidence.update(status="pass", phase="complete")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-target", choices=sorted(set(TARGETS.values())))
    parser.add_argument("--expected-site-commit")
    arguments = parser.parse_args()
    evidence = {"schema": 1, "started_at": datetime.now(timezone.utc).isoformat(), "status": "error",
                "phase": "check native host", "commands": [], "credential_free": True,
                "checker_sha256": sha256(Path(__file__).read_bytes()),
                "expected_site_commit": arguments.expected_site_commit,
                "scope": "Published POSIX installer, public executable copy, exact installed bytes, first project, repeat and refusal paths."}
    try:
        check(arguments.expected_target, arguments.expected_site_commit, evidence)
    except Exception as error:
        evidence["error"] = str(error)
    finally:
        evidence["finished_at"] = datetime.now(timezone.utc).isoformat()
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Published install: {evidence['status']}; evidence: {arguments.output}")
    return 0 if evidence["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
