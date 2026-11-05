#!/usr/bin/env python3
"""Run bounded full-system RISC-V Linux qualification on a disposable CI host.

This is test orchestration. All CLI package behavior remains in native assembly.
SPDX-License-Identifier: AGPL-3.0-or-later
"""

import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import selectors
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BASE = "https://cloud-images.ubuntu.com/noble/20261017/"
# Ubuntu's dated SHA256SUMS and unpacked/SHA256SUMS, checked 2026-11-05.
IMAGES = {
    "rootfs": ("noble-server-cloudimg-riscv64.img",
               "2d48190b4de1a809879c7b2137381a24b52a3a23a65b4d4a7b3f6d7ae774b7e9", 1073741824),
    "kernel": ("unpacked/noble-server-cloudimg-riscv64-vmlinuz-generic",
               "adabe59d732f2f6df2afa88b8e4fe2a99cbf89b91fd510039d7cff645dc82a48", 67108864),
    "initrd": ("unpacked/noble-server-cloudimg-riscv64-initrd-generic",
               "c70dff64b1fc6b3ec15dd4056408763fd63b80aef52f7a8333f9f1858d301b1a", 100663296),
}
LIMITS = {"memory_mib": 3072, "cpus": 2, "overlay_bytes": 8589934592,
          "boot_seconds": 900, "provision_seconds": 900, "test_seconds": 2400,
          "total_seconds": 3600}
GUEST = "/tmp/asm-riscv64-ci"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def bind_guest(report, artifact, commit, provenance_digest):
    """Require independently copied bytes, exact source and complete guest gates."""
    if (not isinstance(report, dict) or report.get("schema") != 2
            or report.get("qualification_scope") != "native-cli-behavior"
            or report.get("target") != "riscv64-linux"
            or report.get("outcome") != "pass" or report.get("execution_mode") != "emulated"
            or report.get("emulation_kind") != "system" or report.get("native_qualified") is not False
            or report.get("release_qualified") is not False):
        raise ValueError("Guest report does not declare successful full-system emulation")
    if (report.get("host", {}).get("system") != "Linux"
            or report.get("host", {}).get("machine") != "riscv64"
            or report.get("source", {}).get("commit") != commit
            or report.get("source", {}).get("clean") is not True):
        raise ValueError("Guest report does not bind clean RISC-V Linux source")
    provenance = report.get("emulator_provenance", {})
    if provenance.get("sha256") != provenance_digest or provenance.get("origin") != "host-provided":
        raise ValueError("Guest report does not bind host-provided emulator provenance")
    required = ("artifact", "runtime", "toolchain", "make_test", "focused_tests", "artifact_binding")
    for name in required:
        check = report.get("checks", {}).get(name, {})
        if check.get("outcome") != "pass":
            raise ValueError(f"Guest required check did not pass: {name}")
        if name in ("make_test", "focused_tests"):
            if (type(check.get("tests_run")) is not int or check["tests_run"] <= 0
                    or check.get("skipped_checks") is not False or check.get("exit_code") != 0
                    or check.get("timed_out") is not False or check.get("incomplete_checks") is not False):
                raise ValueError(f"Guest suite was empty, skipped, or failed: {name}")
    if artifact.is_symlink() or not artifact.is_file() or not 0 < artifact.stat().st_size <= 67108864:
        raise ValueError("Copied CLI artifact is absent or outside its bound")
    if report.get("artifact", {}).get("sha256") != digest(artifact):
        raise ValueError("Copied CLI artifact differs from the guest report")


def bind_root_modules(record, directory):
    files = sorted(directory.glob("test_*.py"))
    if not files or any(path.is_symlink() or not path.is_file() for path in files):
        raise ValueError("Host root CLI module inventory is empty or invalid")
    expected = {path.stem: {"path": path.name, "sha256": digest(path)} for path in files}
    if record != expected:
        raise ValueError("Guest root CLI module metadata does not bind every host module")


class Runner:
    def __init__(self, output, private):
        self.output, self.private = output, private
        self.deadline = time.monotonic() + LIMITS["total_seconds"]
        self.qemu = None
        self.ssh_options = ["-F", "/dev/null", "-i", str(private / "client"),
                            "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                            "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={private / 'known_hosts'}",
                            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "HostKeyAlgorithms=ssh-ed25519",
                            "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=10",
                            "-o", "ServerAliveCountMax=3", "-o", "LogLevel=ERROR",
                            "-p", "2222", "asmci@127.0.0.1"]

    def run(self, command, name, timeout=60, *, data=None, check=True, maximum_log_bytes=67108864,
            stderr_name=None):
        command = list(map(str, command))
        expires = min(self.deadline, time.monotonic() + timeout)
        process = subprocess.Popen(list(map(str, command)), cwd=ROOT, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE if stderr_name else subprocess.STDOUT,
                                   start_new_session=True)
        streams = [(process.stdout, self.output / name)]
        if stderr_name:
            streams.append((process.stderr, self.output / stderr_name))
        selector = selectors.DefaultSelector()
        outputs = []
        payload = memoryview(data or b"")
        position = 0
        try:
            for pipe, path in streams:
                os.set_blocking(pipe.fileno(), False)
                output = path.open("wb")
                outputs.append(output)
                selector.register(pipe, selectors.EVENT_READ, {"output": output, "bytes": 0})
            if payload:
                os.set_blocking(process.stdin.fileno(), False)
                selector.register(process.stdin, selectors.EVENT_WRITE, None)
            else:
                process.stdin.close()
            # The deadline covers the leader, descendants and inherited pipes.
            while selector.get_map() or process.poll() is None:
                remaining = expires - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                for key, events in selector.select(min(remaining, .1)):
                    if events & selectors.EVENT_WRITE:
                        try:
                            position += os.write(key.fd, payload[position:position + 65536])
                        except BlockingIOError:
                            continue
                        except BrokenPipeError:
                            position = len(payload)
                        if position == len(payload):
                            selector.unregister(key.fileobj)
                            key.fileobj.close()
                    else:
                        try:
                            block = os.read(key.fd, 65536)
                        except BlockingIOError:
                            continue
                        if not block:
                            selector.unregister(key.fileobj)
                            key.fileobj.close()
                            continue
                        record = key.data
                        record["output"].write(block[:max(0, maximum_log_bytes - record["bytes"])])
                        record["bytes"] += len(block)
                        if record["bytes"] > maximum_log_bytes:
                            raise ValueError(f"Command output exceeds {maximum_log_bytes} bytes: {name}")
        finally:
            # Kill before closing any pipe. No reader thread can hold a close lock.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=1)
            selector.close()
            for pipe in (process.stdin, process.stdout, process.stderr):
                if pipe is not None:
                    pipe.close()
            for output in outputs:
                output.close()
        if check and process.returncode:
            raise ValueError(f"Command failed with exit {process.returncode}: {name}")
        return process.returncode

    def ssh(self, script, name, timeout=60, *, check=True):
        return self.run(["/usr/bin/ssh", *self.ssh_options, "bash -se"], name, timeout,
                        data=script.encode(), check=check)

    def copy_in(self, source, destination, name):
        # Only public Git objects and host provenance enter the guest over SSH.
        command = "umask 077; cat > " + shlex.quote(destination)
        return self.run(["/usr/bin/ssh", *self.ssh_options, command], name, 180, data=source.read_bytes())

    def copy_out(self, relative, destination, maximum):
        # Fixed paths; reject links/special files and bound bytes inside the guest.
        code = ("import os,stat,sys; "
                f"f=os.open({(GUEST + '/' + relative)!r},os.O_RDONLY|os.O_NOFOLLOW); "
                "s=os.fstat(f); "
                f"assert stat.S_ISREG(s.st_mode) and s.st_size <= {maximum}; "
                f"b=os.fdopen(f,'rb').read({maximum + 1}); assert len(b)<= {maximum}; "
                "sys.stdout.buffer.write(b)")
        command = "sudo -n /usr/bin/python3 -c " + shlex.quote(code)
        # Host-side limits also apply if a guest root process changes its tools.
        status = self.run(["/usr/bin/ssh", *self.ssh_options, command], destination, 60, check=False,
                          maximum_log_bytes=maximum, stderr_name=destination + ".transport.log")
        return status == 0 and (self.output / destination).stat().st_size <= maximum

    def stop(self):
        if self.qemu and self.qemu.poll() is None:
            os.killpg(self.qemu.pid, signal.SIGTERM)
            try:
                self.qemu.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.qemu.pid, signal.SIGKILL)
                self.qemu.wait()
        if hasattr(self, "console_thread"):
            self.console_thread.join(timeout=5)

    def images(self):
        result = {}
        for name, (relative, expected, maximum) in IMAGES.items():
            path = self.private / name
            status = self.run(["/usr/bin/curl", "--disable", "--fail", "--location", "--proto", "=https",
                      "--proto-redir", "=https", "--connect-timeout", "20", "--max-time", "600",
                      "--max-filesize", str(maximum), "--output", str(path), BASE + relative],
                     f"download-{name}.log", 620, check=False)
            actual = {"url": BASE + relative, "expected_sha256": expected, "exit_code": status,
                      "bytes": path.stat().st_size if path.exists() else 0,
                      "sha256": digest(path) if path.exists() else None}
            (self.output / f"image-{name}.json").write_text(json.dumps(actual, indent=2, sort_keys=True) + "\n")
            if status or not 0 < actual["bytes"] <= maximum or actual["sha256"] != expected:
                raise ValueError(f"Pinned guest image digest/size differs: {name}")
            path.chmod(0o444)
            result[name] = {"url": BASE + relative, "sha256": expected, "bytes": path.stat().st_size}
        # QEMU's RISC-V raw kernel loader does not expand gzip.
        kernel = self.private / "kernel"
        with kernel.open("rb") as stream:
            compressed = stream.read(2) == b"\x1f\x8b"
        if compressed:
            with gzip.open(kernel, "rb") as source, (self.private / "kernel-raw").open("wb") as output:
                total = 0
                while block := source.read(1048576):
                    total += len(block)
                    if total > 268435456:
                        raise ValueError("Expanded kernel exceeds 256 MiB")
                    output.write(block)
        else:
            (self.private / "kernel-raw").symlink_to(kernel)
        return result

    def seed(self):
        for name in ("client", "guest-host"):
            self.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "asm-ci",
                      "-f", str(self.private / name)], f"keygen-{name}.log")
        host_public = (self.private / "guest-host.pub").read_text().strip()
        (self.private / "known_hosts").write_text("[127.0.0.1]:2222 " + host_public + "\n")
        config = {"users": [{"name": "asmci", "lock_passwd": True, "shell": "/bin/bash",
                             "sudo": "ALL=(ALL) NOPASSWD:ALL",
                             "ssh_authorized_keys": [(self.private / "client.pub").read_text().strip()]}],
                  "disable_root": True, "ssh_pwauth": False, "ssh_deletekeys": True,
                  "ssh_keys": {"ed25519_private": (self.private / "guest-host").read_text(),
                               "ed25519_public": host_public}, "growpart": {"mode": "auto"}}
        user = self.private / "user-data"
        user.write_text("#cloud-config\n" + json.dumps(config))
        metadata = self.private / "meta-data"
        metadata.write_text(json.dumps({"instance-id": "asm-riscv64-ci", "local-hostname": "asm-riscv64-ci"}))
        network = self.private / "network-config"
        network.write_text(json.dumps({"version": 2, "ethernets": {"eth0": {
            "match": {"macaddress": "52:54:00:12:34:56"}, "set-name": "eth0", "dhcp4": True}}}))
        seed = self.private / "seed.img"
        self.run(["/usr/bin/cloud-localds", "--network-config", str(network), str(seed), str(user), str(metadata)],
                 "seed.log")
        return seed

    def start(self, seed, firmware):
        base, overlay = self.private / "rootfs", self.private / "overlay.qcow2"
        self.run(["/usr/bin/qemu-img", "info", "--output=json", str(base)], "base-image.json")
        info = json.loads((self.output / "base-image.json").read_text())
        if info.get("format") != "qcow2" or info.get("virtual-size", LIMITS["overlay_bytes"] + 1) > LIMITS["overlay_bytes"]:
            raise ValueError("Pinned base must be qcow2 and fit the bounded overlay")
        self.run(["/usr/bin/qemu-img", "create", "-f", "qcow2", "-F", "qcow2", "-b", str(base),
                  str(overlay), str(LIMITS["overlay_bytes"])], "overlay.log")
        arguments = ["/usr/bin/qemu-system-riscv64", "-machine", "virt", "-cpu", "rv64",
                     "-accel", "tcg,thread=multi", "-smp", "2", "-m", "3072", "-bios", str(firmware),
                     "-kernel", str(self.private / "kernel-raw"), "-initrd", str(self.private / "initrd"),
                     "-append", "root=LABEL=cloudimg-rootfs rw console=ttyS0 loglevel=4",
                     "-drive", f"file={overlay},format=qcow2,if=virtio",
                     "-drive", f"file={seed},format=raw,if=virtio,readonly=on",
                     "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22",
                     "-device", "virtio-net-device,netdev=net0,mac=52:54:00:12:34:56",
                     "-device", "virtio-rng-device", "-display", "none", "-monitor", "none",
                     "-serial", "stdio", "-no-reboot"]
        # A noisy guest cannot consume unbounded host disk through its console.
        with (self.output / "qemu.log").open("wb") as errors:
            self.qemu = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=errors,
                                         start_new_session=True, env={"PATH": "/usr/bin:/bin", "LANG": "C"})
        self.console_exceeded = False

        def console():
            total = 0
            with (self.output / "serial.log").open("wb") as output:
                while block := self.qemu.stdout.read1(65536):
                    total += len(block)
                    if total > 67108864:
                        self.console_exceeded = True
                        try:
                            os.killpg(self.qemu.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        break
                    output.write(block)

        self.console_thread = threading.Thread(target=console, daemon=True)
        self.console_thread.start()
        return arguments

    def ready(self):
        deadline = min(self.deadline, time.monotonic() + LIMITS["boot_seconds"])
        probes = []
        while time.monotonic() < deadline:
            if self.qemu.poll() is not None:
                raise ValueError("QEMU exited before guest readiness; inspect serial.log and qemu.log")
            name = f"ssh-readiness-{len(probes) + 1:03d}.log"
            try:
                status = self.ssh("true\n", name, min(10, deadline - time.monotonic()), check=False)
                probes.append({"log": name, "exit_code": status, "outcome": "ready" if status == 0 else "not-ready"})
            except subprocess.TimeoutExpired:
                status = None
                probes.append({"log": name, "outcome": "timeout"})
            (self.output / "boot-probes.json").write_text(json.dumps(probes, indent=2) + "\n")
            if status == 0:
                self.ssh("sudo -n cloud-init status --wait\n", "cloud-init.log", int(deadline - time.monotonic()))
                return
            output = (self.output / name).read_text(errors="replace")
            if re.search(r"Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED|Permission denied|Bad configuration", output):
                raise ValueError(f"Guest SSH trust/authentication failed: {name}")
            time.sleep(3)
        raise ValueError("Guest did not become ready within 900 seconds")


def execute(args, report):
    output = args.output.resolve()
    runner, current, ready = None, "source", False
    try:
        if platform.system() != "Linux" or os.environ.get("GITHUB_ACTIONS") != "true":
            raise ValueError("VM execution is restricted to disposable Linux GitHub Actions hosts")
        if shutil.disk_usage("/tmp").free < 12 * 1073741824:
            raise ValueError("Full-system qualification requires 12 GiB of free temporary disk")
        with tempfile.TemporaryDirectory(prefix="asm-riscv64-system-", dir="/tmp") as temporary:
            private = Path(temporary)
            runner = Runner(output, private)
            try:
                runner.run(["git", "--no-replace-objects", "rev-parse", "HEAD"], "source-commit.log")
                runner.run(["git", "--no-replace-objects", "status", "--porcelain=v1"], "source-status.log")
                if ((output / "source-commit.log").read_text().strip() != args.commit
                        or (output / "source-status.log").read_text().strip()):
                    raise ValueError("Host checkout must be clean and match the requested commit")
                bundle = private / "source.bundle"
                runner.run(["git", "--no-replace-objects", "bundle", "create", str(bundle), "HEAD"], "source-bundle.log", 120)
                if bundle.stat().st_size > 536870912:
                    raise ValueError("Source bundle exceeds 512 MiB")
                report["source"].update(clean=True, bundle_sha256=digest(bundle), bundle_bytes=bundle.stat().st_size)
                report["checks"][current] = {"outcome": "pass"}
                current = "guest_tool_inputs"
                if args.guest_binutils is None:
                    raise ValueError("Full-system checks require --guest-binutils from the reviewed provider")
                spec = importlib.util.spec_from_file_location("guest_binutils", ROOT / "tools/riscv64_guest_binutils.py")
                provider = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(provider)
                guest_tools = provider.validate_manifest(args.guest_binutils)
                tool_names = provider.TOOL_NAMES
                tool_manifest = args.guest_binutils / "manifest.json"
                shutil.copy2(tool_manifest, output / "guest-binutils-manifest.json")
                report["guest_binutils"] = {"manifest_sha256": digest(tool_manifest),
                                             "source": guest_tools["source"], "tools": guest_tools["tools"]}
                report["checks"][current] = {"outcome": "pass"}
                current = "images"
                print("Full-system check: download and verify the pinned guest images", flush=True)
                images = runner.images()
                report["images"] = images
                report["checks"][current] = {"outcome": "pass"}
                current = "boot"
                print("Full-system check: boot the isolated RISC-V Linux guest", flush=True)
                seed = runner.seed()
                firmware = Path("/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.bin")
                if not firmware.is_file():
                    raise ValueError("Required distro OpenSBI firmware is absent")
                runner.run(["/usr/bin/qemu-system-riscv64", "--version"], "qemu-version.log")
                arguments = runner.start(seed, firmware)
                provenance = {"schema": 1, "execution_mode": "emulated", "emulation_kind": "system",
                              "emulator": {"path": arguments[0], "sha256": digest(Path(arguments[0])),
                                           "version": (output / "qemu-version.log").read_text().splitlines()[0],
                                           "arguments": arguments[1:]},
                              "host": {"system": platform.system(), "machine": platform.machine(), "release": platform.release()},
                              "images": images, "source": report["source"], "limits": LIMITS,
                              "guest_binutils": report["guest_binutils"],
                              "boot": {"firmware_sha256": digest(firmware), "seed_sha256": digest(seed),
                                       "loaded_kernel_sha256": digest(private / "kernel-raw")},
                              "run_url": report["run_url"]}
                provenance_path = output / "provenance.json"
                provenance_path.write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
                report["provenance_sha256"] = digest(provenance_path)
                write_report(output, report)
                runner.ready()
                ready = True
                report["checks"][current] = {"outcome": "pass"}
                current = "provision"
                print("Full-system check: install native guest tools and transfer the exact source", flush=True)
                runner.ssh("sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update\n"
                           "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y "
                           "python3 git curl gzip binutils gcc libc6-dev make\n"
                           "uname -a\ncat /etc/os-release\ndpkg-query -W\n"
                           "test $(uname -m) = riscv64\n", "guest-provision.log", LIMITS["provision_seconds"])
                runner.copy_in(bundle, "/home/asmci/source.bundle", "source-transfer.log")
                runner.ssh(f"sudo -n mkdir -m 755 {GUEST}\nsudo -n git --no-replace-objects -C {GUEST} init -q\n"
                           f"sudo -n git --no-replace-objects -C {GUEST} fetch -q /home/asmci/source.bundle HEAD\n"
                           f"sudo -n git --no-replace-objects -C {GUEST} checkout -q --detach FETCH_HEAD\n"
                           f"test $(sudo -n git --no-replace-objects -C {GUEST} rev-parse HEAD) = {args.commit}\n"
                           f"sudo -n mkdir -p {GUEST}/build\n", "guest-source.log", 180)
                runner.copy_in(provenance_path, "/home/asmci/provenance.json", "provenance-transfer.log")
                runner.ssh(f"sudo -n install -m 644 /home/asmci/provenance.json {GUEST}/build/riscv64-system-provenance.json\n",
                           "guest-provenance.log")
                runner.copy_in(tool_manifest, "/home/asmci/guest-binutils-manifest.json", "tool-manifest-transfer.log")
                for name in tool_names:
                    runner.copy_in(args.guest_binutils / "bin" / name, "/home/asmci/" + name, "tool-transfer-" + name + ".log")
                install = ("sudo -n /usr/bin/python3 - <<'ASM_TOOLS'\n"
                           "import hashlib,json,os,stat,subprocess\n"
                           "from pathlib import Path\n"
                           "manifest=Path('/home/asmci/guest-binutils-manifest.json')\n"
                           f"assert hashlib.sha256(manifest.read_bytes()).hexdigest()=={digest(tool_manifest)!r}\n"
                           "record=json.loads(manifest.read_bytes())\n"
                           f"for name in {tuple(tool_names)!r}:\n"
                           "    expected=record['tools'][name]\n"
                           "    source=os.open('/home/asmci/'+name,os.O_RDONLY|os.O_NOFOLLOW)\n"
                           "    info=os.fstat(source)\n"
                           "    assert stat.S_ISREG(info.st_mode) and 64<=info.st_size<=67108864\n"
                           "    data=os.fdopen(source,'rb').read(67108865)\n"
                           "    assert len(data)==expected['bytes'] and hashlib.sha256(data).hexdigest()==expected['sha256']\n"
                           "    destination='/usr/bin/'+name\n"
                           "    target=os.open(destination,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o755)\n"
                           "    os.fchmod(target,0o755)\n"
                           "    with os.fdopen(target,'wb') as output: output.write(data)\n"
                           "    assert hashlib.sha256(Path(destination).read_bytes()).hexdigest()==expected['sha256']\n"
                           "    subprocess.run([destination,'--version'],check=True,timeout=30)\n"
                           "ASM_TOOLS\n")
                runner.ssh(install, "guest-tools.log", 180)
                report["checks"][current] = {"outcome": "pass"}
                current = "qualification"
                print("Full-system check: run the unchanged CLI and focused suites as guest root", flush=True)
                report["scope"] = "full-system emulation of native CLI behavior through unchanged make test and focused tests"
                write_report(output, report)
                script = (f"cd {GUEST}\nsudo -n env -i HOME=/root PATH=/usr/bin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 "
                          "/bin/bash -se <<'ASM_GUEST'\n"
                          "python3 tools/riscv64.py --check\n"
                          "make ARCH=riscv64 build/asm-riscv64-linux\n"
                          "python3 tools/riscv64_test.py --asm build/asm-riscv64-linux "
                          "--execution-mode emulated --emulation-kind system "
                          "--emulator-provenance build/riscv64-system-provenance.json --suite-timeout 1800 "
                          "--evidence build/riscv64-qualification.json\nASM_GUEST\n")
                result = runner.ssh(script, "guest-qualification.log", LIMITS["test_seconds"], check=False)
                report["checks"][current] = {"outcome": "pass" if result == 0 else "fail", "exit_code": result}
                current = "binding"
            finally:
                if ready:
                    files = [("build/asm-riscv64-linux", "asm-riscv64-linux", 67108864),
                             ("build/riscv64-qualification.json", "guest-qualification.json", 4194304)]
                    files += [(f"build/riscv64-qualification-logs/{name}.log", f"guest-{name}.log", 33554432)
                              for name in ("runtime", "toolchain", "linked-toolchain", "make-test", "focused-tests")]
                    report["copied_evidence"] = {}
                    for source, destination, maximum in files:
                        try:
                            copied = runner.copy_out(source, destination, maximum)
                            path = output / destination
                            report["copied_evidence"][destination] = {"outcome": "pass" if copied else "fail",
                                                                       "bytes": path.stat().st_size,
                                                                       "sha256": digest(path)}
                        except (OSError, ValueError, subprocess.SubprocessError) as error:
                            report["copied_evidence"][destination] = {"outcome": "fail", "error": str(error)}
                runner.stop()
            guest = json.loads((output / "guest-qualification.json").read_bytes())
            report["guest_checks"] = guest.get("checks", {})
            report["reference_package_gate"] = guest.get("reference_package_gate", {"outcome": "not-run"})
            bind_guest(guest, output / "asm-riscv64-linux", args.commit, report["provenance_sha256"])
            bind_root_modules(guest.get("root_cli_modules"), ROOT / "tests")
            report["root_cli_modules"] = guest["root_cli_modules"]
            if runner.console_exceeded:
                raise ValueError("Guest serial output exceeded 64 MiB")
            for name, record in report["copied_evidence"].items():
                if record["outcome"] != "pass":
                    raise ValueError(f"Required guest evidence was not copied: {name}")
            for name, filename in (("make_test", "guest-make-test.log"), ("focused_tests", "guest-focused-tests.log")):
                if digest(output / filename) != guest["checks"][name]["log_sha256"]:
                    raise ValueError(f"Copied guest log differs: {name}")
            report["artifact"] = guest["artifact"]
            report["checks"][current] = {"outcome": "pass"}
            if all(check["outcome"] == "pass" for check in report["checks"].values()):
                report["outcome"] = "pass"
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        report["checks"][current] = {"outcome": "fail", "error": str(error)}
    finally:
        if runner:
            runner.stop()
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        report["retained_files"] = {path.name: {"sha256": digest(path), "bytes": path.stat().st_size}
                                    for path in sorted(output.iterdir()) if path.is_file() and path.name != "report.json"}
        write_report(output, report)
    print(f"RISC-V full-system emulated qualification: {report['outcome']}; evidence: {output / 'report.json'}")
    return 0 if report["outcome"] == "pass" else 1


def initial_report(commit):
    return {"schema": 1, "target": "riscv64-linux", "execution_mode": "emulated",
            "qualification_scope": "native-cli-behavior",
            "emulation_kind": "system", "outcome": "fail", "scope": "runtime not reached",
            "native_qualified": False, "release_qualified": False,
            "started_at": datetime.now(timezone.utc).isoformat(), "source": {"commit": commit},
            "checks": {name: {"outcome": "not-run"} for name in
                       ("source", "guest_tool_inputs", "images", "boot", "provision", "qualification", "binding")}}


def write_report(output, report):
    output.mkdir(parents=True, exist_ok=True)
    temporary = output / "report.json.tmp"
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    temporary.replace(output / "report.json")


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--initialize-only", action="store_true")
    parser.add_argument("--output", type=Path, default=Path("build/riscv64-system"))
    parser.add_argument("--commit", required=True)
    parser.add_argument("--guest-binutils", type=Path)
    args = parser.parse_args(arguments)
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        parser.error("--commit must be an exact Git commit")
    report = initial_report(args.commit)
    report["head_commit"] = os.environ.get("ASM_CI_HEAD_SHA", args.commit)
    report["run_attempt"] = os.environ.get("GITHUB_RUN_ATTEMPT", "unknown")
    report["run_url"] = (f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/"
                         f"{os.environ.get('GITHUB_REPOSITORY', 'unknown')}/actions/runs/"
                         f"{os.environ.get('GITHUB_RUN_ID', 'unknown')}")
    write_report(args.output, report)
    if args.initialize_only:
        return 0
    return execute(args, report)


if __name__ == "__main__":
    raise SystemExit(main())
