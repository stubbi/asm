"""Real HTTP and PostgreSQL checks for the assembly experiment.

SPDX-License-Identifier: AGPL-3.0-or-later

Python supplies test orchestration only. The served application is the native
assembly executable. The fixture owns a fresh local PostgreSQL cluster and
creates its test records without an external service or reference executable.
"""
from concurrent.futures import ThreadPoolExecutor
import base64
from datetime import datetime
import hashlib
import http.client
from itertools import islice
import json
import math
import os
from pathlib import Path
import platform
import re
import select
import secrets
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from urllib.parse import urlencode, urlsplit
import uuid

from local_postgres import Database, LocalPostgres, MIGRATION_SHA384, create_catalog


BUILD = Path(os.environ.get("ASM_PROTO_BUILD_DIR", Path(__file__).resolve().parent / "build"))
BINARY = Path(os.environ["ASM_PROTO_BINARY"])


class BinfmtFifoConfig:
    """Explicit trusted-runner input. This record never selects a command."""
    QEMU_SHA256 = "be89e201dc6112ef101617ab575c95119ad123f80ca2b51b6c36ef218ac9df65"
    QEMU_BYTES = 4431192
    REGISTRATION = {
        "interpreter": "/usr/libexec/qemu-binfmt/riscv64-binfmt-P", "flags:": "POF", "offset": "0",
        "magic": "7f454c460201010000000000000000000200f300",
        "mask": "ffffffffffffff00fffffffffffffffffeffffff",
    }

    def __init__(self, registration, runner_deadline):
        if not isinstance(registration, dict):
            raise ValueError("Use the fixed host registration schema.")
        encoded = json.dumps(registration, separators=(",", ":"), allow_nan=False).encode()
        if len(encoded) > 4096:
            raise ValueError("The registration capture exceeds its bound.")
        self.registration = json.loads(encoded)
        self.registration_digest = hashlib.sha256(encoded).hexdigest()
        self.runner_deadline = runner_deadline
        self.validate()

    def validate(self):
        record = self.registration
        keys = {"schema", "scope", "source_revision", "fixture_revision", "run_id", "captured_at",
                "registration_path", "registration_text", "emulator_sha256", "emulator_bytes",
                "server_sha256", "fixture_sha256"}
        if set(record) != keys or type(record["schema"]) is not int or record["schema"] != 1:
            raise ValueError("The host registration schema differs.")
        if record["scope"] != "asm-riscv64-binfmt-registration":
            raise ValueError("The host registration scope differs.")
        for key in ("source_revision", "fixture_revision", "server_sha256", "fixture_sha256"):
            length = 40 if key.endswith("revision") else 64
            if not isinstance(record[key], str) or re.fullmatch("[0-9a-f]{" + str(length) + "}", record[key]) is None:
                raise ValueError("The registration identity is malformed.")
        if not isinstance(record["run_id"], str) or re.fullmatch("[0-9]{1,32}", record["run_id"]) is None:
            raise ValueError("The registration run identity is malformed.")
        try:
            captured = datetime.fromisoformat(record["captured_at"].replace("Z", "+00:00"))
        except (ValueError, TypeError, AttributeError):
            raise ValueError("The registration capture time is malformed.") from None
        if captured.utcoffset() is None or captured.utcoffset().total_seconds() != 0:
            raise ValueError("Use a UTC registration capture time.")
        if (record["registration_path"] != "/proc/sys/fs/binfmt_misc/qemu-riscv64" or
                record["emulator_sha256"] != self.QEMU_SHA256 or type(record["emulator_bytes"]) is not int or
                record["emulator_bytes"] != self.QEMU_BYTES):
            raise ValueError("The reviewed registration or emulator pin differs.")
        text = record["registration_text"]
        if not isinstance(text, str) or len(text.encode()) > 1024 or "\x00" in text:
            raise ValueError("The raw registration exceeds its bound.")
        rows = text.splitlines()
        parsed = {}
        for row in rows[1:]:
            fields = row.split()
            if len(fields) != 2 or fields[0] in parsed:
                raise ValueError("The raw registration is ambiguous.")
            parsed[fields[0]] = fields[1]
        if not rows or rows[0] != "enabled" or parsed != self.REGISTRATION:
            raise ValueError("The registered interpreter convention differs.")
        magic, mask = bytes.fromhex(parsed["magic"]), bytes.fromhex(parsed["mask"])
        with BINARY.open("rb") as source:
            header = source.read(len(magic))
        if len(header) != len(magic) or any((a & c) != (b & c) for a, b, c in zip(header, magic, mask)):
            raise ValueError("The selected server does not match the registered ELF rule.")
        if (hashlib.sha256(BINARY.read_bytes()).hexdigest() != record["server_sha256"] or
                hashlib.sha256(Path(__file__).read_bytes()).hexdigest() != record["fixture_sha256"]):
            raise ValueError("The selected server or fixture digest differs.")
        if (type(self.runner_deadline) not in (int, float) or not math.isfinite(self.runner_deadline) or
                time.monotonic() >= self.runner_deadline):
            raise ValueError("The existing runner deadline is unavailable or expired.")
        encoded = json.dumps(record, separators=(",", ":"), allow_nan=False).encode()
        if len(encoded) > 4096 or hashlib.sha256(encoded).hexdigest() != self.registration_digest:
            raise ValueError("The host registration capture changed.")


class PhaseTraceConfig:
    """Pinned child-only injection with a trusted, separately reviewed parser."""
    def __init__(self, library_path, sha256, read_records):
        self.library_path, self.sha256, self.read_records = Path(library_path), sha256, read_records
        if not callable(read_records) or not isinstance(sha256, str) or re.fullmatch("[0-9a-f]{64}", sha256) is None:
            raise ValueError("Use a pinned trace library and reviewed record callback.")
        self.validate()

    def validate(self):
        path = str(self.library_path)
        if not self.library_path.is_absolute() or len(path) > 4096 or any(ch.isspace() or ch in ":\x00" for ch in path):
            raise ValueError("The trace library path is unsuitable for child-only preload.")
        info = self.library_path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > 1048576:
            raise ValueError("The pinned trace library is unavailable or oversized.")
        if hashlib.sha256(self.library_path.read_bytes()).hexdigest() != self.sha256:
            raise ValueError("The trace library digest differs.")

    def child_environment(self, environment):
        self.validate()
        if environment.get("LD_PRELOAD"):
            raise ValueError("An ambient preload conflicts with the pinned trace library.")
        result = dict(environment)
        result["LD_PRELOAD"] = str(self.library_path)
        return result


class RecoveryPending(RuntimeError):
    """Owned application cleanup may use only the remaining recovery budget."""


class BinfmtFifoAttribution:
    """Owned pre-target barrier, exact host-task identity, and bounded log drain."""
    def __init__(self, config, *, label):
        if not isinstance(config, BinfmtFifoConfig):
            raise ValueError("Use explicit BinfmtFifoConfig input.")
        config.validate()
        self.config, self.proc, self.reader_fd, self.thread = config, None, None, None
        self.stopping, self.lock = threading.Event(), threading.Lock()
        self.failure, self.identity, self.helper = None, None, None
        self.directory = Path(tempfile.mkdtemp(prefix="qemu-fifo-", dir=BUILD))
        self.fifo = self.directory / "barrier"
        fifo_created = False
        try:
            if "%" in str(self.fifo):
                raise ValueError("The FIFO path must not contain a log filename template.")
            os.mkfifo(self.fifo, 0o600)
            fifo_created = True
            self.fifo_identity = self.fifo.lstat()
        except BaseException as error:
            try:
                if fifo_created:
                    self.fifo.unlink()
                self.directory.rmdir()
            except OSError as cleanup_error:
                error.add_note("Owned FIFO construction cleanup failed: " + type(cleanup_error).__name__)
            raise
        self.record = {"schema": 1, "qualification": "UNQUALIFIED", "label": label,
                       "mechanism": "owned-global-log-open-before-guest-target-loading-or-execution",
                       "assumption": "Reviewed readonly host capture remains applicable at launch; pathname checks are not race-free.",
                       "registration": config.registration, "registration_sha256": config.registration_digest,
                       "fifo": {"path": str(self.fifo), "device": self.fifo_identity.st_dev,
                                "inode": self.fifo_identity.st_ino, "mode": "0600", "directory_mode": "0700"},
                       "limits": {"proc_read_bytes": 4096, "task_rows": 64, "drain_chunk_bytes": 4096,
                                  "drain_bytes": 65536, "runner_deadline": config.runner_deadline},
                       "reader_ever_opened": False, "released": False, "drained_bytes": 0,
                       "early_eof_count": 0, "writer_connected": False, "cleanup_errors": []}

    def child_environment(self):
        if os.environ.get("QEMU_LD_PREFIX", "/") != "/":
            raise ValueError("The reviewed loader prefix differs.")
        environment = {key: value for key, value in os.environ.items() if not key.startswith("QEMU_")}
        environment.update(QEMU_LD_PREFIX="/", QEMU_LOG="guest_errors", QEMU_LOG_FILENAME=str(self.fifo),
                           QEMU_UNSET_ENV="QEMU_LOG,QEMU_LOG_FILENAME,QEMU_UNSET_ENV")
        self.environment = environment
        self.record["qemu_environment"] = {key: value for key, value in environment.items() if key.startswith("QEMU_")}
        self.record["retained_environment_keys"] = sorted(environment)[:256]
        return dict(environment)

    def _error(self, stage, error=None):
        with self.lock:
            if self.failure is None:
                self.failure = RuntimeError("The optional FIFO attribution failed: " + stage + ".")
                self.record["failure"] = {"stage": stage, "type": type(error).__name__ if error else "RuntimeError",
                                          "errno": getattr(error, "errno", None), "monotonic": time.monotonic()}
        return self.failure

    def _budget(self, deadline, stage):
        observed = time.monotonic()
        if observed >= min(deadline, self.config.runner_deadline):
            raise self._error(stage)

    @staticmethod
    def _read(path):
        with path.open("rb") as source:
            raw = source.read(4096)
        if len(raw) >= 4096:
            raise ValueError("A proc identity read reached its bound.")
        return raw.decode("utf-8", errors="strict")

    def _stat(self, path, expected_tid):
        text = self._read(path)
        prefix, tail = text.rsplit(")", 1)
        pid, comm = prefix.split(" (", 1)
        fields = tail.split()
        if int(pid) != expected_tid or len(fields) < 20 or not fields[19].isdecimal():
            raise ValueError("A proc task identity is malformed.")
        return {"tid": expected_tid, "start_ticks": int(fields[19]), "comm": comm[:128], "state": fields[0]}

    def _task_ids(self):
        with os.scandir(f"/proc/{self.proc.pid}/task") as entries:
            names = [entry.name for entry in islice(entries, 65)]
        if len(names) > 64 or any(not name.isdecimal() for name in names):
            raise ValueError("The proc task roster is incomplete or oversized.")
        return sorted(int(name) for name in names)

    def _roster(self):
        root = Path(f"/proc/{self.proc.pid}")
        before = self._task_ids()
        tasks = [self._stat(root / "task" / str(tid) / "stat", tid) for tid in before]
        status = self._read(root / "status")
        counts = [row.split()[1] for row in status.splitlines() if row.startswith("Threads:")]
        if len(counts) != 1 or not counts[0].isdecimal() or int(counts[0]) != len(tasks) or before != self._task_ids():
            raise ValueError("The proc task roster changed or differs from the aggregate count.")
        main = self._stat(root / "stat", self.proc.pid)
        if not any(task["tid"] == main["tid"] and task["start_ticks"] == main["start_ticks"] for task in tasks):
            raise ValueError("The main task is missing from the complete roster.")
        return {"pid": self.proc.pid, "start_ticks": main["start_ticks"], "raw_count": len(tasks), "tasks": tasks}

    def _exe_identity(self):
        path = Path(f"/proc/{self.proc.pid}/exe")
        digest = hashlib.sha256()
        with path.open("rb") as source:
            before = os.fstat(source.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_size != BinfmtFifoConfig.QEMU_BYTES:
                raise ValueError("The actual emulator byte size differs.")
            for chunk in iter(lambda: source.read(65536), b""):
                digest.update(chunk)
            after = os.fstat(source.fileno())
        if (before.st_dev, before.st_ino, before.st_size) != (after.st_dev, after.st_ino, after.st_size):
            raise ValueError("The actual emulator changed during hashing.")
        if digest.hexdigest() != BinfmtFifoConfig.QEMU_SHA256:
            raise ValueError("The actual emulator digest differs.")
        return {"sha256": digest.hexdigest(), "bytes": before.st_size, "device": before.st_dev,
                "inode": before.st_ino, "proc_exe": os.readlink(path)[:1024]}

    def _verify_fifo(self):
        fifo, directory = self.fifo.lstat(), self.directory.lstat()
        if (not stat.S_ISFIFO(fifo.st_mode) or stat.S_IMODE(fifo.st_mode) != 0o600 or fifo.st_nlink != 1 or
                fifo.st_uid != os.getuid() or (fifo.st_dev, fifo.st_ino) !=
                (self.fifo_identity.st_dev, self.fifo_identity.st_ino) or not stat.S_ISDIR(directory.st_mode) or
                stat.S_IMODE(directory.st_mode) != 0o700 or directory.st_uid != os.getuid()):
            raise ValueError("The owned FIFO path or identity changed.")

    def capture_and_release(self, proc, deadline):
        self.proc = proc
        self.record["pid"], self.record["startup_deadline"] = proc.pid, deadline
        try:
            self._budget(deadline, "startup_before_identity")
            self.config.validate()
            self._verify_fifo()
            if self.reader_fd is not None or self.record["reader_ever_opened"] or not hasattr(self, "environment"):
                raise ValueError("The no-reader or child-environment invariant is unavailable.")
            expected = {"QEMU_LD_PREFIX": "/", "QEMU_LOG": "guest_errors", "QEMU_LOG_FILENAME": str(self.fifo),
                        "QEMU_UNSET_ENV": "QEMU_LOG,QEMU_LOG_FILENAME,QEMU_UNSET_ENV"}
            if {key: value for key, value in self.environment.items() if key.startswith("QEMU_")} != expected:
                raise ValueError("The selected child launch controls changed.")
            exe = self._exe_identity()
            self._budget(deadline, "startup_after_executable_hash")
            samples = []
            while True:
                self._budget(deadline, "startup_task_capture")
                sample = self._roster()
                if sample["raw_count"] == 2:
                    samples.append(sample)
                    if len(samples) == 2 and samples[0] == samples[1]:
                        break
                    samples = samples[-1:]
                elif sample["raw_count"] > 2:
                    raise ValueError("The pre-target task count differs from main plus one.")
                else:
                    samples = []
                if proc.poll() is not None:
                    raise ValueError("The attributed server exited before release.")
            helper = next(task for task in samples[-1]["tasks"] if task["tid"] != proc.pid)
            self._verify_fifo()
            actual = os.stat(f"/proc/{proc.pid}/exe")
            if (actual.st_dev, actual.st_ino, actual.st_size) != (exe["device"], exe["inode"], exe["bytes"]):
                raise ValueError("The actual emulator identity changed before release.")
            if proc.poll() is not None:
                raise ValueError("The attributed server exited before release.")
            self._budget(deadline, "startup_before_release")
            self.identity, self.helper = samples[-1], helper
            self.record.update(executable=exe, pre_target_samples=samples, pre_target_host_task=helper,
                               no_reader_before_capture=True, captured_monotonic=time.monotonic())
            self.reader_fd = os.open(self.fifo, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
            opened = os.fstat(self.reader_fd)
            if (opened.st_dev, opened.st_ino) != (self.fifo_identity.st_dev, self.fifo_identity.st_ino):
                raise ValueError("The opened FIFO differs from its captured identity.")
            self.record["reader_ever_opened"], self.record["released"] = True, True
            self.thread = threading.Thread(target=self._drain, daemon=True, name="asm-qemu-log-drain")
            self.thread.start()
            self._budget(deadline, "startup_after_release")
        except BaseException as error:
            self._error("capture_or_release", error)
            raise

    def _drain(self):
        try:
            while not self.stopping.is_set():
                self._budget(self.config.runner_deadline, "runner_lifetime")
                readable, _, _ = select.select([self.reader_fd], [], [], 0.05)
                if not readable:
                    continue
                try:
                    raw = os.read(self.reader_fd, 4096)
                except BlockingIOError:
                    self.record["writer_connected"] = True
                    continue
                if not raw:
                    if self.proc.poll() is not None:
                        return
                    if self.record["writer_connected"] or self.record.get("target_ready", False):
                        raise ValueError("The log writer closed while the server remained live.")
                    self.record["early_eof_count"] += 1
                    self.stopping.wait(0.01)
                    continue
                self.record["writer_connected"] = True
                self.record["drained_bytes"] += len(raw)
                if self.record["drained_bytes"] > 65536:
                    raise ValueError("The optional log drain exceeded its byte bound.")
        except BaseException as error:
            self._error("log_drain", error)
            if self.proc.poll() is None:
                try:
                    self.proc.terminate()
                except OSError as cleanup_error:
                    self.record["cleanup_errors"].append({"type": type(cleanup_error).__name__, "errno": cleanup_error.errno})

    def _verify_running_identity(self):
        root = Path(f"/proc/{self.proc.pid}")
        main = self._stat(root / "stat", self.proc.pid)
        helper = self._stat(root / "task" / str(self.helper["tid"]) / "stat", self.helper["tid"])
        executable = os.stat(root / "exe")
        recorded = self.record["executable"]
        if (main["start_ticks"] != self.identity["start_ticks"] or helper["start_ticks"] != self.helper["start_ticks"] or
                (executable.st_dev, executable.st_ino, executable.st_size) !=
                (recorded["device"], recorded["inode"], recorded["bytes"])):
            raise ValueError("The proved process or host-task identity changed.")

    def check(self):
        if self.failure is not None:
            raise self.failure
        try:
            self._budget(self.config.runner_deadline, "runner_lifetime")
            if not self.record["released"] or self.proc.poll() is not None or not self.thread.is_alive():
                raise ValueError("The attributed process or log drain is unavailable.")
            self._verify_running_identity()
            self._budget(self.config.runner_deadline, "runner_lifetime_after_identity")
        except BaseException as error:
            raise self._error("live_identity_or_drain", error) from error

    def application_tasks(self):
        self.check()
        try:
            roster = self._roster()
            if roster["start_ticks"] != self.identity["start_ticks"] or self.helper not in roster["tasks"]:
                # Task comm/state can change; exclusion uses only the exact identity.
                matches = [task for task in roster["tasks"] if (task["tid"], task["start_ticks"]) ==
                           (self.helper["tid"], self.helper["start_ticks"])]
                if roster["start_ticks"] != self.identity["start_ticks"] or len(matches) != 1:
                    raise ValueError("The exact pre-target host task is absent or reused.")
            application = [task for task in roster["tasks"] if (task["tid"], task["start_ticks"]) !=
                           (self.helper["tid"], self.helper["start_ticks"])]
            self.check()
            return {**roster, "application_count": len(application), "application_tasks": application,
                    "excluded_identity": {"tid": self.helper["tid"], "start_ticks": self.helper["start_ticks"]}}
        except BaseException as error:
            raise self._error("application_task_roster", error) from error

    def observe_phase(self, phase, snapshot, clients):
        if phase not in ("baseline", "cap", "recovery"):
            self.check()
            return
        roster = self.application_tasks()
        snapshot["application_roster"] = roster
        identities = {(task["tid"], task["start_ticks"]) for task in roster["application_tasks"]}
        if snapshot["errors"] or any(snapshot[key] for key in ("tasks_truncated", "fds_truncated", "retention_truncated")):
            raise self._error(phase + "_socket_observation_incomplete")
        socket_fds = {(row["fd"], row["link"]) for row in snapshot["socket_fds"]}
        if len(socket_fds) != len(snapshot["socket_fds"]):
            raise self._error(phase + "_socket_ownership_ambiguous")
        tcp = set()
        for entry in snapshot["tcp"]:
            fields = entry["row"].split()
            if len(fields) < 10 or fields[9] != entry["inode"]:
                raise self._error(phase + "_socket_identity")
            tcp.add((entry["table"], entry["inode"], fields[1], fields[2], fields[3]))
        if len(tcp) != len(snapshot["tcp"]):
            raise self._error(phase + "_socket_rows_ambiguous")
        if phase == "baseline":
            if roster["application_count"] != 2:
                raise self._error("baseline_application_count")
            port = self.record.get("server_port")
            if type(port) is not int or not 1 <= port <= 65535 or len(socket_fds) != 1 or len(tcp) != 1:
                raise self._error("baseline_listener_only_ownership")
            listener = next(iter(tcp))
            if (listener[0] != "tcp" or listener[2] != "0100007F:" + format(port, "04X") or
                    listener[3] != "00000000:0000" or listener[4] != "0A" or
                    next(iter(socket_fds))[1] != "socket:[" + listener[1] + "]"):
                raise self._error("baseline_listener_identity")
            self.baseline = identities
            self.baseline_socket_fds, self.baseline_tcp = socket_fds, tcp
        elif phase == "recovery":
            if (not hasattr(self, "baseline") or not self.baseline <= identities or
                    not self.baseline_socket_fds <= socket_fds or not self.baseline_tcp <= tcp):
                raise self._error("recovery_application_identities")
            if identities != self.baseline or socket_fds != self.baseline_socket_fds or tcp != self.baseline_tcp:
                raise RecoveryPending("The owned application tasks or sockets have not returned to baseline.")
        else:
            if (not hasattr(self, "baseline") or not self.baseline <= identities or
                    len(identities - self.baseline) != 16 or roster["application_count"] != 18):
                raise self._error("cap_worker_identities")
            sent = {row["index"] for row in clients if row["event"] == "send" and "exception" not in row}
            connected = {row["index"]: (tuple(row["local"]), tuple(row["peer"]))
                         for row in clients if row["event"] == "connect" and "exception" not in row}
            if sent != set(range(16)) or set(connected) != sent:
                raise self._error("held_client_observation_incomplete")
            expected = {(peer, local) for local, peer in connected.values()}
            observed, accepted_tcp, accepted_inodes = set(), set(), set()
            for entry in snapshot["tcp"]:
                fields = entry["row"].split()
                if entry["table"] != "tcp" or len(fields) < 10 or fields[3] != "01":
                    continue
                endpoints = []
                for encoded in fields[1:3]:
                    address, port = encoded.split(":")
                    endpoints.append((socket.inet_ntop(socket.AF_INET, bytes.fromhex(address)[::-1]), int(port, 16)))
                if tuple(endpoints) in expected:
                    observed.add(tuple(endpoints))
                    accepted_inodes.add(entry["inode"])
                    accepted_tcp.add((entry["table"], entry["inode"], fields[1], fields[2], fields[3]))
            snapshot["matched_held_connections"] = len(observed)
            snapshot["new_worker_identities"] = [list(identity) for identity in sorted(identities - self.baseline)]
            if len(expected) != 16 or observed != expected:
                raise self._error("cap_held_connections")
            extra_fds = socket_fds - self.baseline_socket_fds
            if (not self.baseline_socket_fds <= socket_fds or len(extra_fds) != 16 or
                    {link[8:-1] for _, link in extra_fds} != accepted_inodes or
                    tcp != self.baseline_tcp | accepted_tcp):
                raise self._error("cap_extra_or_changed_socket_ownership")

    def close(self):
        primary = self.failure
        def cleanup_error(stage, error):
            nonlocal primary
            if len(self.record["cleanup_errors"]) < 8:
                self.record["cleanup_errors"].append({"stage": stage, "type": type(error).__name__,
                                                       "errno": getattr(error, "errno", None)})
            if primary is None:
                primary = error
        try:
            if self.proc is not None and self.proc.poll() is None:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired as error:
                    cleanup_error("graceful_stop_deadline", error)
                    self.record["forced_stop"] = True
                    self.proc.kill()
                    self.proc.wait(timeout=2)
                self.record["returncode"] = self.proc.poll()
        except BaseException as error:
            cleanup_error("stop_process", error)
        finally:
            self.stopping.set()
            try:
                if self.thread is not None:
                    self.thread.join(timeout=2)
                    if self.thread.is_alive():
                        raise RuntimeError("The owned log drainer did not stop.")
            except BaseException as error:
                cleanup_error("join_drain", error)
            try:
                if self.reader_fd is not None:
                    os.close(self.reader_fd)
                    self.reader_fd = None
                if self.fifo.exists():
                    self._verify_fifo()
                    self.fifo.unlink()
                if self.directory.exists():
                    self.directory.rmdir()
            except BaseException as error:
                cleanup_error("close_owned_fifo", error)
        if primary is None:
            primary = self.failure
        if primary is not None:
            raise primary


class ReferenceDiagnostic:
    """Bounded fixture observations. These records never qualify the server."""
    RAW_LIMIT = 16384
    PROC_LIMIT = 131072
    JSON_LIMIT = 1048576
    SNAPSHOT_LIMIT = 65536
    STATUS_FIELDS = ("Name", "State", "Tgid", "Pid", "PPid", "Threads", "NSpid", "NStgid")

    def __init__(self, server_pid, forbidden):
        self.server_pid = server_pid
        self.forbidden = sorted((value for value in forbidden if value), key=len, reverse=True)
        self.directory = Path(tempfile.mkdtemp(prefix="reference-causal-", dir=BUILD))
        digest, size = hashlib.sha256(), 0
        with BINARY.open("rb") as source:
            for chunk in iter(lambda: source.read(131072), b""):
                digest.update(chunk)
                size += len(chunk)
        self.data = {
            "schema": 1, "scope": "reference-server-causal-diagnostic", "qualification": "UNQUALIFIED",
            "base_commit": "04c93b3f0200173298d24f22a06393bc359a1af0",
            "runtime": {"path": str(BINARY), "sha256": digest.hexdigest(), "bytes": size},
            "limits": {"raw_response_bytes_per_query": self.RAW_LIMIT, "proc_read_bytes": self.PROC_LIMIT + 1,
                       "proc_retained_bytes": self.PROC_LIMIT,
                       "task_rows_per_snapshot": 64, "fd_links_per_snapshot": 128,
                       "snapshot_json_bytes": self.SNAPSHOT_LIMIT, "snapshots": 8,
                       "total_json_bytes": self.JSON_LIMIT, "errors_per_snapshot": 32},
            "redaction": "Known fixture password and complete connection URLs; no arbitrary exception text.",
            "observer_effect": "Snapshots and evidence writes add work. Timings are diagnostic and unqualified.",
            "observer": {"system": platform.system(), "release": platform.release(),
                         "machine": platform.machine(), "pid": os.getpid()},
            "server": {"pid": server_pid},
            "publication_errors": [],
            "connection_cap": {"recovery": "not_reached", "clients": [], "snapshots": []},
            "simultaneous_searches": {"workers": 8, "timeout_seconds": 4, "records": [None] * 16},
        }
        errors = []
        for label, pid in (("observer", os.getpid()), ("server", server_pid)):
            self.data[label]["proc_status"] = self._status(self._read(Path(f"/proc/{pid}/status"), 16384, errors))
            try:
                self.data[label]["proc_exe"] = self._safe(os.readlink(f"/proc/{pid}/exe"))[:1024]
            except OSError as error:
                self._error(errors, f"/proc/{pid}/exe", error)
        self.data["procfs"] = "available" if Path("/proc/self/status").is_file() else "unavailable"
        self.data["identity_errors"] = errors
        self.publish()

    @staticmethod
    def exception(error, stage):
        return {"type": type(error).__name__, "errno": getattr(error, "errno", None), "stage": stage}

    def _safe(self, value):
        raw = value.encode("utf-8", errors="replace")
        for secret in self.forbidden:
            raw = raw.replace(secret, b"[REDACTED]")
        return raw.decode("utf-8", errors="replace")

    def _error(self, errors, path, error):
        self._note(errors, {"path": str(path), **self.exception(error, "procfs")})

    @staticmethod
    def _note(errors, note):
        if len(errors) < 31:
            errors.append(note)
        elif len(errors) == 31:
            errors.append({"omitted_errors": 1})
        else:
            errors[-1]["omitted_errors"] += 1

    def _read(self, path, limit, errors):
        try:
            with path.open("rb") as source:
                raw = source.read(limit + 1)
            if len(raw) > limit:
                self._note(errors, {"path": str(path), "truncated": True, "limit": limit})
            return self._safe(raw[:limit].decode("utf-8", errors="replace"))
        except OSError as error:
            self._error(errors, path, error)
            return ""

    def _status(self, text):
        return {key: value.strip()[:128] for row in text.splitlines() if ":" in row
                for key, value in [row.split(":", 1)] if key in self.STATUS_FIELDS}

    def _entries(self, path, limit, errors):
        try:
            with os.scandir(path) as entries:
                names = [entry.name for entry in islice(entries, limit + 1)]
            return sorted((int(name) for name in names[:limit] if name.isdecimal())), len(names) > limit
        except OSError as error:
            self._error(errors, path, error)
            return [], False

    def publish(self):
        """Use only our newly created private directory. A write failure fails the test."""
        payload = json.dumps(self.data, separators=(",", ":"), ensure_ascii=True).encode() + b"\n"
        if len(payload) > self.JSON_LIMIT:
            raise ValueError("Reference diagnostic exceeded its JSON limit.")
        temporary = None
        try:
            fd, temporary = tempfile.mkstemp(prefix=".capture-", dir=self.directory)
            with os.fdopen(fd, "wb") as output:
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.directory / "diagnostic.json")
        except OSError as error:
            if len(self.data["publication_errors"]) < 32:
                self.data["publication_errors"].append(self.exception(error, "evidence-write"))
            raise
        finally:
            if temporary is not None:
                Path(temporary).unlink(missing_ok=True)

    def response(self, record, status, headers, raw=None, *, complete=True):
        record.update(status=status, headers={key: self._safe(value)[:128] for key, value in headers
                      if key.lower() in ("content-type", "content-length", "connection", "cache-control",
                                         "x-content-type-options")})
        if raw is None:
            return
        safe = raw
        for secret in self.forbidden:
            safe = safe.replace(secret, b"[REDACTED]")
        record.update(body_bytes=len(raw), body_sha256=hashlib.sha256(raw).hexdigest(),
                      body_base64=base64.b64encode(safe[:self.RAW_LIMIT]).decode("ascii"),
                      body_truncated=len(raw) > self.RAW_LIMIT or len(safe) > self.RAW_LIMIT,
                      body_redacted=safe != raw, body_complete=complete,
                      body_state="complete" if complete else "partial")

    def client(self, index, event, client, start, error=None):
        record = {"index": index, "event": event, "start_monotonic": start, "end_monotonic": time.monotonic()}
        if client is not None and event != "close":
            for label, getter in (("local", client.getsockname), ("peer", client.getpeername)):
                try:
                    record[label] = getter()
                except OSError as endpoint_error:
                    record[label] = self.exception(endpoint_error, "endpoint")
        if error is not None:
            record["exception"] = self.exception(error, event)
        self.data["connection_cap"]["clients"].append(record)

    def snapshot(self, phase, *, retain=True, **observations):
        """Read only this server's task roster and owned TCP socket rows."""
        errors, root = [], Path(f"/proc/{self.server_pid}")
        snapshot = {"phase": phase, "start_monotonic": time.monotonic(), "observations": observations,
                    "status": self._status(self._read(root / "status", 16384, errors)),
                    "tasks": [], "socket_fds": [], "tcp": [], "errors": errors}
        ids, snapshot["tasks_truncated"] = self._entries(root / "task", 64, errors)
        snapshot["task_ids"] = ids
        for tid in ids:
            task = root / "task" / str(tid)
            snapshot["tasks"].append({"tid": tid, "comm": self._read(task / "comm", 256, errors)[:128],
                                      "status": self._status(self._read(task / "status", 16384, errors)),
                                      "wchan": self._read(task / "wchan", 256, errors)[:128]})
        fds, snapshot["fds_truncated"] = self._entries(root / "fd", 128, errors)
        inodes = set()
        for fd in fds:
            try:
                link = os.readlink(root / "fd" / str(fd))
            except OSError as error:
                self._error(errors, root / "fd" / str(fd), error)
                continue
            if link.startswith("socket:[") and link.endswith("]") and link[8:-1].isdecimal():
                inodes.add(link[8:-1])
                snapshot["socket_fds"].append({"fd": fd, "link": link})
        for table in ("tcp", "tcp6"):
            for row in self._read(root / "net" / table, self.PROC_LIMIT, errors).splitlines()[1:]:
                fields = row.split()
                if len(fields) > 9 and fields[9] in inodes and len(snapshot["tcp"]) < 128:
                    snapshot["tcp"].append({"table": table, "inode": fields[9], "row": row[:512]})
        snapshot["end_monotonic"] = time.monotonic()
        snapshot["retention_truncated"] = False
        while len(json.dumps(snapshot, separators=(",", ":")).encode()) > self.SNAPSHOT_LIMIT:
            snapshot["retention_truncated"] = True
            for key in ("tcp", "tasks", "socket_fds"):
                if snapshot[key]:
                    snapshot[key].pop()
                    break
            else:
                raise ValueError("Reference diagnostic snapshot exceeded its limit.")
        pending = None
        attribution = getattr(self, "attribution", None)
        if attribution is not None:
            try:
                attribution.observe_phase(phase, snapshot, self.data["connection_cap"]["clients"])
            except BaseException as error:
                pending = error
                snapshot["attribution_error"] = self.exception(error, "attribution")
                if retain and phase == "recovery" and self.data["connection_cap"]["recovery"] == "observed_success":
                    self.data["connection_cap"]["recovery"] = "inconclusive_attribution_observation"
            self.data["attribution"] = attribution.record
            snapshot["end_monotonic"] = time.monotonic()
        if not retain:
            return snapshot, pending
        return self.retain_snapshot(snapshot, pending)

    def retain_snapshot(self, snapshot, pending=None):
        encoded = json.dumps(snapshot, separators=(",", ":"), ensure_ascii=True).encode()
        if len(encoded) > self.SNAPSHOT_LIMIT:
            self.data["snapshot_evidence_overflow"] = {"phase": snapshot["phase"], "bytes": len(encoded),
                "sha256": hashlib.sha256(encoded).hexdigest(), "outcome": "inconclusive", "limit": self.SNAPSHOT_LIMIT}
            self.publish()
            raise ValueError("The complete augmented snapshot exceeded its evidence bound.")
        snapshots = self.data["connection_cap"]["snapshots"]
        if len(snapshots) >= 8:
            raise ValueError("Reference diagnostic exceeded its snapshot limit.")
        snapshots.append(snapshot)
        self.publish()
        if pending is not None:
            raise pending
        return snapshot

    def optional_update(self, key, value, *, failure_metadata=False):
        """Commit an optional section without dropping earlier accepted evidence."""
        candidate = dict(self.data)
        candidate[key] = value
        encoded = json.dumps(candidate, separators=(",", ":"), ensure_ascii=True).encode()
        limit = self.JSON_LIMIT if failure_metadata else self.JSON_LIMIT - 4096
        if len(encoded) > limit:
            self.data["optional_evidence_overflow"] = {"section": key, "attempted_json_bytes": len(encoded),
                "attempted_value_sha256": hashlib.sha256(json.dumps(value, separators=(",", ":")).encode()).hexdigest(),
                "limit_bytes": self.JSON_LIMIT, "outcome": "inconclusive"}
            self.publish()
            raise ValueError("The optional evidence exceeds the cumulative diagnostic budget.")
        previous = self.data
        candidate[key] = json.loads(json.dumps(value, separators=(",", ":"), ensure_ascii=True))
        self.data = candidate
        try:
            self.publish()
        except BaseException:
            self.data = previous
            raise


class CohortDiagnostic:
    """Route the existing search collector into one isolated comparison arm."""
    def __init__(self, owner, comparison, index):
        self.owner, self.comparison, self.index = owner, comparison, index
        self.data = {"simultaneous_searches": {"records": []}}
        self.response, self.exception = owner.response, owner.exception

    def publish(self):
        arm = self.comparison["arms"][self.index]
        arm["records"] = self.data["simultaneous_searches"]["records"]
        try:
            self.owner.optional_update("controlled_search_comparison", self.comparison)
        except ValueError:
            if self.owner.data.get("optional_evidence_overflow", {}).get("section") == "controlled_search_comparison":
                arm["rejected_records"] = [{"index": row["index"], "status": row["status"],
                    "body_bytes": row["body_bytes"], "body_sha256": row["body_sha256"],
                    "exception": row["exception"], "raw_body_retained": False} for row in arm["records"]]
                arm["records"] = []  # This cohort was rejected; earlier accepted cohorts remain unchanged.
            raise


class GateProxy:
    """A local TCP fixture. Closed gate accepts but forwards no protocol bytes."""
    def __init__(self, target_port):
        self.target_port = target_port
        self.closed_gate = threading.Event()
        self.stopping = threading.Event()
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(32)
        self.listener.settimeout(0.1)
        self.port = self.listener.getsockname()[1]
        self.workers = []
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stopping.is_set():
            try:
                client, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            worker = threading.Thread(target=self.connection, args=(client,), daemon=True)
            self.workers.append(worker)
            worker.start()

    def connection(self, client):
        with client:
            if self.closed_gate.is_set():
                self.stopping.wait(4)
                return
            with socket.create_connection(("127.0.0.1", self.target_port), timeout=2) as server:
                client.settimeout(2)
                server.settimeout(2)
                while not self.stopping.is_set():
                    readable, _, _ = select.select([client, server], [], [], 0.1)
                    for source in readable:
                        try:
                            data = source.recv(65536)
                            if not data:
                                return
                            (server if source is client else client).sendall(data)
                        except OSError:
                            return

    def close(self):
        self.stopping.set()
        self.listener.close()
        deadline = time.monotonic() + 3
        self.thread.join(timeout=3)
        for worker in self.workers:
            worker.join(timeout=max(0, deadline - time.monotonic()))
        if self.thread.is_alive() or any(worker.is_alive() for worker in self.workers):
            raise RuntimeError("The local proxy did not stop within its cleanup deadline.")


class ServerTests(unittest.TestCase):
    attribution_config = None
    trace_config = None
    fixture_ready = False

    @classmethod
    def setUpClass(cls):
        cls.fixture_ready, cls.attribution, cls.diagnostic = False, None, None
        cls._main_trace_collected = False
        cls.temp = tempfile.TemporaryDirectory(prefix="asm-server-test-", dir=BUILD)
        cls.addClassCleanup(cls.temp.cleanup)
        cls.base = Path(cls.temp.name)
        cls.cluster = LocalPostgres(cls.base)
        cls.addClassCleanup(cls.cluster.close)
        cls.cluster.start()
        cls.names = "asm_proto_" + uuid.uuid4().hex[:12]
        cls.dbname = cls.names
        cls.migrator = cls.names + "_m"
        cls.reader = cls.names + "_r"
        cls.operator = cls.names + "_o"
        cls.password = secrets.token_hex(24)
        cls.admin = cls.cluster.admin
        cls.proxy = GateProxy(cls.cluster.port)
        cls.addClassCleanup(cls.proxy.close)
        for role in (cls.migrator, cls.reader, cls.operator):
            cls.admin.execute(f'CREATE ROLE "{role}" LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD \'{cls.password}\'')
            cls.addClassCleanup(cls.admin.execute, f'DROP ROLE "{role}"')
        cls.admin.execute(f'CREATE DATABASE "{cls.dbname}" OWNER "{cls.migrator}"')
        cls.addClassCleanup(cls.admin.execute, f'DROP DATABASE "{cls.dbname}" WITH (FORCE)')
        cls.fixture_admin = Database(cls.cluster.url(database=cls.dbname))
        cls.addClassCleanup(cls.fixture_admin.close)
        cls.url_files = {}
        for label, role in (("migrator", cls.migrator), ("reader", cls.reader), ("operator", cls.operator)):
            path = cls.base / (label + ".url")
            path.write_text(cls.cluster.url(database=cls.dbname, role=role, password=cls.password) + "\n")
            path.chmod(0o600)
            cls.url_files[label] = path
        cls.proxy_file = cls.base / "proxy.url"
        cls.proxy_file.write_text(cls.cluster.url(database=cls.dbname, role=cls.reader, password=cls.password, port=cls.proxy.port) + "\n")
        cls.proxy_file.chmod(0o600)
        migrator = Database(cls.url_files["migrator"].read_text().strip())
        try:
            operator = Database(cls.url_files["operator"].read_text().strip())
            try:
                create_catalog(migrator, operator, cls.reader, cls.operator)
            finally:
                operator.close()
        finally:
            migrator.close()
        cls.expected_names = [f"fixture/p{i:02d}" for i in range(23)]
        cls.log = (cls.base / "server.log").open("wb")
        cls.addClassCleanup(cls.log.close)
        cls.port = cls.unused_port()
        if cls.attribution_config is None and cls.trace_config is None:
            cls.server = subprocess.Popen([str(BINARY), str(cls.port), str(cls.proxy_file)], stdout=cls.log, stderr=cls.log)
            cls.addClassCleanup(cls.stop_server)
            cls.wait_server(cls.server, cls.port)
        else:
            cls.server, cls.attribution = cls._start_diagnostic_server(cls.proxy_file, cls.port, cls.log, "main")
            cls.addClassCleanup(cls.stop_server)
        cls.diagnostic = ReferenceDiagnostic(cls.server.pid, [cls.password.encode()] +
            [path.read_bytes().strip() for path in (*cls.url_files.values(), cls.proxy_file)])
        cls.diagnostic.attribution = cls.attribution
        if cls.attribution is not None:
            cls.diagnostic.data["attribution"] = cls.attribution.record
            cls.diagnostic.publish()
        cls.evidence = {"binary_sha256": hashlib.sha256(BINARY.read_bytes()).hexdigest(),
                        "libpq_version": cls.admin.lib.PQlibVersion(), "database_version": cls.fixture_admin.execute("SHOW server_version")[0][0],
                        "schema_sha384": MIGRATION_SHA384, "fixture": "owned-local-cluster", "measurements": {}}
        cls.fixture_ready = True

    @classmethod
    def _start_diagnostic_server(cls, config_file, port, log, label):
        control, proc, early = None, None, None
        try:
            if cls.attribution_config is not None:
                control = BinfmtFifoAttribution(cls.attribution_config, label=label)
            environment = control.child_environment() if control is not None else dict(os.environ)
            if cls.trace_config is not None:
                if not isinstance(cls.trace_config, PhaseTraceConfig):
                    raise ValueError("Use explicit PhaseTraceConfig input.")
                environment = cls.trace_config.child_environment(environment)
            proc = subprocess.Popen([str(BINARY), str(port), str(config_file)], stdout=log, stderr=log, env=environment)
            deadline = time.monotonic() + 5
            if control is not None:
                control.record["server_argv"] = [str(BINARY), str(port), str(config_file)]
                control.record["server_port"] = port
                control.capture_and_release(proc, deadline)
            cls.wait_server(proc, port, deadline=deadline, attribution=control)
            if control is not None:
                control.record["target_ready"] = True
                control.check()
                control._budget(deadline, "startup_after_readiness")
            return proc, control
        except BaseException as primary:
            record = control.record if control is not None else {"qualification": "UNQUALIFIED", "label": label}
            record["launch_id"] = uuid.uuid4().hex
            record["launch_failure"] = ReferenceDiagnostic.exception(primary, "startup")
            try:
                if cls.diagnostic is None:
                    early = ReferenceDiagnostic(proc.pid if proc is not None else 0, [cls.password.encode()] +
                        [path.read_bytes().strip() for path in (*cls.url_files.values(), cls.proxy_file)])
                    early.data["launch_failure"] = record
                    early.publish()
                else:
                    cls.diagnostic.optional_update("launch_failures", cls.diagnostic.data.get("launch_failures", []) + [record])
            except BaseException as error:
                record["evidence_failure"] = ReferenceDiagnostic.exception(error, "evidence-write")
            try:
                cls._stop_owned_server(proc, control)
                record["cleanup_completed"] = True
                primary.asm_owned_cleanup_completed = True
            except BaseException as error:
                record["cleanup_completed"] = False
                primary.asm_owned_cleanup_completed = False
                record["launch_cleanup_failure"] = ReferenceDiagnostic.exception(error, "cleanup")
            try:
                log.flush()
                if early is not None:
                    early.publish()
                elif cls.diagnostic is not None:
                    previous = cls.diagnostic.data.get("launch_failures", [])
                    updated = [item for item in previous if item.get("launch_id") != record["launch_id"]] + [record]
                    cls.diagnostic.optional_update("launch_failures", updated)
            except BaseException:
                pass  # The original startup error remains primary; prior evidence is retained.
            raise

    @staticmethod
    def _stop_owned_server(proc, control):
        if control is not None:
            control.close()
        elif proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2)
                raise

    @staticmethod
    def _owned_server_stopped(proc, control):
        if proc is None or proc.poll() is None:
            return False
        return control is None or (control.reader_fd is None and
                                   (control.thread is None or not control.thread.is_alive()))

    @classmethod
    def _trace_not_run(cls, label, reason="owned_process_not_stopped_and_drainer_joined"):
        traces = dict(cls.diagnostic.data.get("phase_traces", {}))
        traces[label] = {"qualification": "UNQUALIFIED", "association": "inconclusive", "outcome": "not_run",
                         "reason": reason, "records": []}
        cls.diagnostic.optional_update("phase_traces", traces, failure_metadata=True)

    @classmethod
    def _collect_phase_trace(cls, label, log_path, cohort):
        if cls.trace_config is None:
            return
        section = {"qualification": "UNQUALIFIED", "library_sha256": cls.trace_config.sha256,
                   "association": "inconclusive", "records": [], "noncohort_ids": []}
        failure = None
        try:
            records = cls.trace_config.read_records(Path(log_path))
            if type(records) is not list or not 1 <= len(records) <= 256:
                raise ValueError("The reviewed phase parser did not return bounded records.")
            section["records"] = records
            if (len(cohort) != 16 or any(row is None or type(row.get("index")) is not int for row in cohort) or
                    {row["index"] for row in cohort} != set(range(1, 17))):
                raise ValueError("The HTTP cohort is unavailable for trace association.")
            indexed = {row["index"]: row for row in cohort}
            for row in cohort:
                if (any(type(row.get(key)) not in (int, float) or not math.isfinite(row[key])
                        for key in ("start_monotonic", "end_monotonic")) or
                        row["end_monotonic"] < row["start_monotonic"]):
                    raise ValueError("The HTTP cohort timestamps are unavailable.")
            start = int(min(row["start_monotonic"] for row in cohort) * 1000000000)
            end = int(max(row["end_monotonic"] for row in cohort) * 1000000000)
            section["cohort_window_ns"] = {"start": start, "end": end}
            associated = {}
            for row in records:
                overlap = row["start_ns"] <= end and row["end_ns"] >= start
                if overlap:
                    if row["index"] not in indexed or row["kind"] not in (-1, 2) or row["index"] in associated:
                        raise ValueError("The phase association is ambiguous.")
                    outcome = indexed[row["index"]]
                    if not (int(outcome["start_monotonic"] * 1000000000) <= row["start_ns"] <= row["end_ns"] <=
                            int(outcome["end_monotonic"] * 1000000000)):
                        raise ValueError("The terminal phase record is outside its HTTP outcome window.")
                    associated[row["index"]] = row["id"]
                else:
                    if label in ("direct", "proxy") and row["index"] != 0:
                        raise ValueError("A comparison arm has an extra positive-index terminal record outside its wave.")
                    section["noncohort_ids"].append(row["id"])
            if set(associated) != set(range(1, 17)):
                raise ValueError("The phase association is incomplete.")
            section["association"], section["cohort_record_ids"] = "complete", associated
        except Exception as error:
            failure = error
            section["failure"] = ReferenceDiagnostic.exception(error, "phase-association")
        traces = dict(cls.diagnostic.data.get("phase_traces", {}))
        traces[label] = section
        cls.diagnostic.optional_update("phase_traces", traces)
        if failure is not None:
            raise failure

    @classmethod
    def run_controlled_search_comparison(cls):
        """Runner-only pre-teardown helper. Never replace the original test result."""
        if not cls.fixture_ready or cls.diagnostic is None:
            raise RuntimeError("The owned reference fixture did not become ready.")
        if not isinstance(cls.attribution_config, BinfmtFifoConfig):
            raise ValueError("The controlled comparison requires explicit approved FIFO attribution.")
        if "controlled_search_comparison" in cls.diagnostic.data:
            raise RuntimeError("The controlled comparison already ran.")
        direct, proxy = (urlsplit(path.read_text().strip()) for path in (cls.url_files["reader"], cls.proxy_file))
        fields = lambda url: (url.scheme, url.username, url.password, url.hostname, url.path, url.query, url.fragment)
        if (fields(direct) != fields(proxy) or direct.port != cls.cluster.port or proxy.port != cls.proxy.port or
                direct.port == proxy.port or cls.proxy.closed_gate.is_set()):
            raise ValueError("The controlled URLs or proxy gate differ from the owned fixture.")
        comparison = {"qualification": "UNQUALIFIED", "scope": "controlled-direct-proxy-search",
                      "order": ["direct", "proxy"], "url_equivalence_except_port": True,
                      "workers_per_arm": 8, "queries_per_arm": 16, "http_timeout_seconds": 4,
                      "database_deadline_seconds": 2, "arms": []}
        cls.diagnostic.optional_update("controlled_search_comparison", comparison)
        failures, prohibit_next = [], False
        try:
            cls.stop_server()
            if not cls._owned_server_stopped(cls.server, cls.attribution):
                raise RuntimeError("The original owned server did not stop before comparison.")
        except BaseException as error:
            failures.append(error)
            comparison["main_cleanup_failure"] = ReferenceDiagnostic.exception(error, "main-cleanup")
            prohibit_next = True
        main_flushed = True
        try:
            cls.log.flush()
        except BaseException as error:
            main_flushed, prohibit_next = False, True
            failures.append(error)
            comparison["main_log_flush_failure"] = ReferenceDiagnostic.exception(error, "main-log-flush")
        if cls.trace_config is not None and not cls._main_trace_collected:
            cls._main_trace_collected = True
            try:
                if main_flushed and cls._owned_server_stopped(cls.server, cls.attribution):
                    cls._collect_phase_trace("main", cls.base / "server.log",
                                             cls.diagnostic.data["simultaneous_searches"]["records"])
                else:
                    cls._trace_not_run("main", "main_log_or_owned_process_not_ready")
                    prohibit_next = True
                    raise RuntimeError("The original server was not safely stopped for phase parsing.")
            except Exception as error:
                failures.append(error)
                comparison["main_trace_failure"] = ReferenceDiagnostic.exception(error, "main-trace")
        for index, (label, config_file) in enumerate((("direct", cls.url_files["reader"]), ("proxy", cls.proxy_file))):
            arm = {"label": label, "state": "not_run", "records": [], "qualification": "UNQUALIFIED"}
            comparison["arms"].append(arm)
            if prohibit_next or (cls.attribution_config is not None and time.monotonic() >= cls.attribution_config.runner_deadline):
                arm["reason"] = "earlier_cleanup_or_runner_budget"
                try:
                    cls.diagnostic.optional_update("controlled_search_comparison", comparison, failure_metadata=True)
                except BaseException:
                    if failures:
                        raise failures[0]
                    raise
                continue
            port, proc, control = cls.unused_port(), None, None
            log_path = cls.base / ("comparison-" + label + ".log")
            with log_path.open("wb") as log:
                log_path.chmod(0o600)
                try:
                    proc, control = cls._start_diagnostic_server(config_file, port, log, label)
                    if control is None or control.proc is not proc or not control.record.get("released", False):
                        raise RuntimeError("The comparison arm has no same-process FIFO attribution.")
                    control.check()
                    arm.update(state="running", pid=proc.pid, port=port)
                    if control is not None:
                        arm["attribution"] = control.record
                    cls.diagnostic.optional_update("controlled_search_comparison", comparison)
                    check = cls("test_simultaneous_searches_keep_request_data_separate")
                    check.port, check.attribution = port, control
                    check.diagnostic = CohortDiagnostic(cls.diagnostic, comparison, index)
                    check.test_simultaneous_searches_keep_request_data_separate()
                    arm["state"] = "passed"
                except BaseException as error:
                    failures.append(error)
                    arm["state"], arm["failure"] = "failed", ReferenceDiagnostic.exception(error, "arm")
                    if proc is None and not getattr(error, "asm_owned_cleanup_completed", False):
                        prohibit_next = True
                finally:
                    if proc is not None:
                        try:
                            cls._stop_owned_server(proc, control)
                            if not cls._owned_server_stopped(proc, control):
                                raise RuntimeError("The comparison arm did not stop and join its drainer.")
                        except BaseException as error:
                            failures.append(error)
                            prohibit_next = True
                            arm["cleanup_failure"] = ReferenceDiagnostic.exception(error, "arm-cleanup")
                            arm["state"] = "failed"
                    flushed = True
                    try:
                        log.flush()
                    except BaseException as error:
                        flushed, prohibit_next = False, True
                        failures.append(error)
                        arm["log_flush_failure"] = ReferenceDiagnostic.exception(error, "arm-log-flush")
                        arm["state"] = "failed"
                    if cls.trace_config is not None and proc is not None:
                        try:
                            if flushed and cls._owned_server_stopped(proc, control):
                                cls._collect_phase_trace(label, log_path, arm["records"])
                            else:
                                cls._trace_not_run(label, "arm_log_or_owned_process_not_ready")
                                prohibit_next = True
                                raise RuntimeError("The comparison server was not safely stopped for phase parsing.")
                        except Exception as error:
                            failures.append(error)
                            arm["trace_failure"] = ReferenceDiagnostic.exception(error, "arm-trace")
                            arm["state"] = "failed"
            try:
                cls.diagnostic.optional_update("controlled_search_comparison", comparison, failure_metadata=bool(failures))
            except Exception as error:
                failures.append(error)
                prohibit_next = True
        if failures:
            raise failures[0]
        return cls.diagnostic.data["controlled_search_comparison"]

    @staticmethod
    def unused_port():
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            return sock.getsockname()[1]

    @classmethod
    def wait_server(cls, proc, port, *, deadline=None, attribution=None):
        controlled = deadline is not None
        if deadline is None:
            deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if attribution is not None:
                attribution.check()
            if proc.poll() is not None:
                raise AssertionError(f"Assembly server stopped during startup: {proc.returncode}")
            try:
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=0.2)
                connection.request("GET", "/health/live")
                response = connection.getresponse()
                response.read()
                connection.close()
                if response.status == 200:
                    if controlled and time.monotonic() >= deadline:
                        raise RuntimeError("The diagnostic readiness observation exceeded the original startup deadline.")
                    return
            except OSError:
                time.sleep(0.02)
        raise AssertionError("Assembly server did not become live.")

    @classmethod
    def stop_server(cls):
        if getattr(cls, "attribution", None) is not None:
            try:
                cls._stop_owned_server(cls.server, cls.attribution)
            finally:
                primary = sys.exc_info()[1]
                if cls.diagnostic is not None:
                    cls.diagnostic.data["attribution"] = cls.attribution.record
                    try:
                        cls.diagnostic.publish()
                    except BaseException as error:
                        if primary is None:
                            raise
                        primary.add_note("Secondary attribution evidence publication failed: " + type(error).__name__)
            return
        if getattr(cls, "server", None) and cls.server.poll() is None:
            cls.server.terminate()
            try:
                cls.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.server.kill()
                cls.server.wait(timeout=2)
                raise

    @classmethod
    def tearDownClass(cls):
        cls.stop_server()
        cls.log.flush()
        evidence = BUILD / "evidence.json"
        evidence.write_text(json.dumps(cls.evidence, indent=2) + "\n")
        if cls.trace_config is None:
            saved_log = BUILD / "server-test.log"
            saved_log.write_bytes((cls.base / "server.log").read_bytes())

    def request(self, path, *, method="GET", body=None, headers=None, timeout=4, diagnostic=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        attribution = getattr(self, "attribution", None)
        stage = "transport"
        try:
            if attribution is not None:
                stage = "attribution"
                attribution.check()
                stage = "transport"
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            if diagnostic is not None:
                self.diagnostic.response(diagnostic, response.status, response.getheaders())
            data = response.read()
            if diagnostic is not None:
                self.diagnostic.response(diagnostic, response.status, response.getheaders(), data)
            stage = "json"
            parsed = json.loads(data)
            if attribution is not None:
                stage = "attribution"
                attribution.check()
            return response.status, dict(response.getheaders()), parsed
        except Exception as error:
            if diagnostic is not None:
                if isinstance(error, http.client.IncompleteRead):
                    self.diagnostic.response(diagnostic, diagnostic["status"], diagnostic["headers"].items(),
                                             error.partial, complete=False)
                diagnostic["exception"] = self.diagnostic.exception(error, stage)
            if attribution is not None and stage != "attribution":
                try:
                    attribution.check()
                except Exception as control_error:
                    if diagnostic is not None:
                        diagnostic["attribution_exception"] = self.diagnostic.exception(control_error, "attribution")
            raise
        finally:
            connection.close()
            if diagnostic is not None:
                diagnostic["end_monotonic"] = time.monotonic()
                diagnostic["elapsed_seconds"] = diagnostic["end_monotonic"] - diagnostic["start_monotonic"]

    def _snapshot_phase(self, phase, **observations):
        primary = sys.exc_info()[1]
        try:
            return self.diagnostic.snapshot(phase, **observations)
        except BaseException as error:
            if primary is None or getattr(self, "attribution", None) is None:
                raise
            failures = self.diagnostic.data.setdefault("secondary_attribution_errors", [])
            if len(failures) < 8:
                failures.append(self.diagnostic.exception(error, phase))
            try:
                self.diagnostic.publish()
            except BaseException:
                pass
            return None

    def _settled_recovery_snapshot(self, deadline, recovery_start, liveness_status):
        attempts = 0
        while True:
            attempts += 1
            snapshot, pending = self.diagnostic.snapshot("recovery", retain=False, liveness_status=liveness_status,
                elapsed_seconds=time.monotonic() - recovery_start, settling_attempts=attempts)
            if pending is None:
                self.diagnostic.retain_snapshot(snapshot)
                return
            if not isinstance(pending, RecoveryPending):
                self.diagnostic.retain_snapshot(snapshot, pending)
            observed = time.monotonic()
            if observed >= deadline:
                cap = self.diagnostic.data["connection_cap"]
                cap["recovery"] = "inconclusive_recovery_deadline_exhausted"
                cap["recovery_failure"] = {"stage": "recovery_socket_cleanup", "observed_monotonic": observed,
                                           "deadline_monotonic": deadline}
                failure = RuntimeError("The attributed recovery did not settle within its original deadline.")
                try:
                    self.diagnostic.retain_snapshot(snapshot)
                except BaseException as error:
                    failure.add_note("Secondary recovery evidence failure: " + type(error).__name__)
                raise failure
            select.select([], [], [], min(0.01, deadline - observed))

    def test_health_and_declared_dependency_boundary(self):
        self.assertEqual(self.request("/health/live")[2], {"status": "alive"})
        self.assertEqual(self.request("/health/ready")[2], {"status": "ready"})
        code, headers, data = self.request("/")
        self.assertEqual(code, 200)
        self.assertTrue(data["experimental"])
        self.assertEqual(data["application_language"], "assembly")
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(headers["Connection"], "close")

    def test_fixture_retains_reference_records_and_query_limits(self):
        canonical = (Path(__file__).parent / "fixtures/p00.json").read_bytes().rstrip(b"\n")
        expected = hashlib.sha256(canonical).hexdigest()
        digest = self.fixture_admin.execute("SELECT r.record_digest FROM asm.releases r JOIN asm.packages p ON p.id = r.package_id WHERE p.full_name = 'fixture/p00'")[0][0]
        detail = self.fixture_admin.execute("SELECT detail::text FROM asm.audit_events WHERE action = 'release_imported' AND subject = 'fixture/p00@0.2.0'")[0][0]
        self.assertEqual(digest, expected)
        self.assertEqual(json.loads(detail), {"record_sha256": expected,
                         "acceptance_repository": "https://github.com/stubbi/asm", "acceptance_commit": "c" * 40})
        self.assertEqual(self.fixture_admin.execute("SHOW statement_timeout"), [["5s"]])
        self.assertEqual(self.fixture_admin.execute("SHOW lock_timeout"), [["1s"]])

    def test_real_pagination_does_not_drop_or_repeat_packages(self):
        code, _, first = self.request("/prototype/packages")
        self.assertEqual(code, 200)
        self.assertEqual(len(first["packages"]), 20)
        code, _, second = self.request("/prototype/packages?" + urlencode({"after": first["next_after"]}))
        self.assertEqual(code, 200)
        names = [p["name"] for p in first["packages"] + second["packages"]]
        self.assertEqual(names, self.expected_names)
        self.assertIsNone(second["next_after"])
        self.assertEqual(first["packages"][0]["summary"], 'Text "quoted" <script>ignored</script> & data')
        self.assertEqual(first["packages"][0]["owner_github_id"], 12345)

    def test_search_uses_parameters_and_literal_matching(self):
        for query, expected in (("fixture 22", ["fixture/p22"]), ("FIXTURE 22", ["fixture/p22"]),
                                ("' OR 1=1 --", []), ("%", []), ("quoted", ["fixture/p00"])):
            with self.subTest(query=query):
                code, _, data = self.request("/prototype/packages?" + urlencode({"q": query}))
                self.assertEqual(code, 200)
                self.assertEqual([p["name"] for p in data["packages"]], expected)

    def test_query_rejects_duplicates_unknown_fields_controls_and_oversize(self):
        for query in ("q=a&q=b", "after=a&after=b", "unknown=1", "q=%00", "q=a%00b", "q=%0a",
                      "q=" + "a" * 161, "after=" + "a" * 105, "q=%c3%a9"):
            with self.subTest(query=query[:50]):
                self.assertEqual(self.request("/prototype/packages?" + query)[0], 400)

    def test_unknown_route_method_and_body_fail_without_database_writes(self):
        self.assertEqual(self.request("/missing")[0], 404)
        self.assertEqual(self.request("/prototype/packages", method="POST", body="ignored")[0], 405)
        self.assertEqual(self.request("/prototype/packages", body="ignored")[0], 400)
        self.assertEqual(self.request("/health/ready")[0], 200)

    def test_uri_and_header_limits(self):
        self.assertEqual(self.request("/" + "x" * 2048)[0], 414)
        headers = {f"X-Field-{i}": "x" for i in range(65)}
        self.assertEqual(self.request("/health/live", headers=headers)[0], 431)

    def test_readiness_loses_permissions_and_recovers(self):
        self.fixture_admin.execute(f'REVOKE SELECT ON asm.artifacts FROM "{self.reader}"')
        try:
            self.assertEqual(self.request("/health/ready")[0], 503)
            self.assertEqual(self.request("/health/live")[0], 200)
        finally:
            self.fixture_admin.execute(f'GRANT SELECT ON asm.artifacts TO "{self.reader}"')
        self.assertEqual(self.request("/health/ready")[0], 200)
        for schema in ("pgxtemp_", "pgxtempx", "pgxtoast_temp_", "pgxtoastxtempx"):
            with self.subTest(schema=schema):
                self.fixture_admin.execute(f'CREATE SCHEMA "{schema}"')
                try:
                    self.fixture_admin.execute(f'GRANT CREATE ON SCHEMA "{schema}" TO "{self.reader}"')
                    self.assertEqual(self.request("/health/ready")[0], 503)
                    self.assertEqual(self.request("/health/live")[0], 200)
                finally:
                    self.fixture_admin.execute(f'DROP SCHEMA "{schema}"')
                self.assertEqual(self.request("/health/ready")[0], 200)

    def test_startup_rejects_migrator_and_missing_grants(self):
        result = subprocess.run([str(BINARY), str(self.unused_port()), str(self.url_files["migrator"])],
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 78)
        self.assertNotIn(self.url_files["migrator"].read_bytes().strip(), result.stderr)
        self.fixture_admin.execute(f'REVOKE SELECT ON asm.packages FROM "{self.reader}"')
        try:
            result = subprocess.run([str(BINARY), str(self.unused_port()), str(self.url_files["reader"])],
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 78)
        finally:
            self.fixture_admin.execute(f'GRANT SELECT ON asm.packages TO "{self.reader}"')

    def test_configuration_rejects_nonregular_public_and_malformed_files(self):
        cases = []
        for name, data, mode in (("empty", b"", 0o600), ("oversize", b"a" * 4097, 0o600),
                                 ("nul", b"dbname=a\x00ignore", 0o600),
                                 ("public", self.url_files["reader"].read_bytes(), 0o644)):
            path = self.base / ("bad-" + name)
            path.write_bytes(data)
            path.chmod(mode)
            cases.append(path)
        link = self.base / "config-link"
        link.symlink_to(self.url_files["reader"])
        cases.append(link)
        fifo = self.base / "config-fifo"
        os.mkfifo(fifo, 0o600)
        cases.append(fifo)
        for path in cases:
            with self.subTest(file=path.name):
                result = subprocess.run([str(BINARY), str(self.unused_port()), str(path)], capture_output=True, timeout=1)
                self.assertEqual(result.returncode, 78)
                self.assertNotIn(self.password.encode(), result.stderr)

    def test_connection_cap_bounds_http_threads_and_recovers(self):
        held = []
        recovery_start = None
        cap_passed = False
        self._snapshot_phase("baseline")
        try:
            for index in range(16):
                start = time.monotonic()
                client = None
                try:
                    client = socket.create_connection(("127.0.0.1", self.port), timeout=1)
                except Exception as error:
                    self.diagnostic.client(index, "connect", client, start, error)
                    raise
                held.append(client)
                self.diagnostic.client(index, "connect", client, start)
                start = time.monotonic()
                try:
                    client.sendall(b"GET /health/live HTTP/1.1\r\nHost: localhost\r\nX-Pending: ")
                except Exception as error:
                    self.diagnostic.client(index, "send", client, start, error)
                    raise
                self.diagnostic.client(index, "send", client, start)
            def threads():
                if getattr(self, "attribution", None) is not None:
                    return self.attribution.application_tasks()["application_count"]
                rows = Path(f"/proc/{self.server.pid}/status").read_text().splitlines()
                return int(next(row.split()[1] for row in rows if row.startswith("Threads:")))
            deadline = time.monotonic() + 1
            while threads() < 18 and time.monotonic() < deadline:
                time.sleep(0.01)
            try:
                self.assertEqual(threads(), 18)  # main + listener + 16 connections
                cap_passed = True
                if getattr(self, "attribution", None) is not None:
                    self.attribution._budget(deadline, "cap_after_accepted_count")
            finally:
                self._snapshot_phase("cap", assertion_passed=cap_passed)
                if getattr(self, "attribution", None) is not None and cap_passed and sys.exc_info()[1] is None:
                    self.attribution._budget(deadline, "cap_after_observations")
            with socket.create_connection(("127.0.0.1", self.port), timeout=1) as extra:
                extra.settimeout(0.15)
                extra.sendall(b"GET /health/live HTTP/1.1\r\nHost: localhost\r\n\r\n")
                try:
                    data = extra.recv(1)
                    self.assertEqual(data, b"")
                except (socket.timeout, ConnectionResetError):
                    pass
                self.assertLessEqual(threads(), 18)
            if getattr(self, "attribution", None) is not None:
                # Optional proof work, including the final extra-client roster,
                # uses the same cap deadline. Native socket limits stay unchanged.
                self.attribution._budget(deadline, "cap_after_extra_client_observation")
            self.evidence["measurements"]["threads_at_connection_cap"] = 18
        finally:
            recovery_start = time.monotonic()
            try:
                for index, client in enumerate(held):
                    start = time.monotonic()
                    try:
                        client.close()
                    except Exception as error:
                        self.diagnostic.client(index, "close", None, start, error)
                        raise
                    self.diagnostic.client(index, "close", None, start)
            finally:
                deadline = time.monotonic() + 1
                budget = {"seconds": 1, "anchor_monotonic": deadline - 1, "deadline_monotonic": deadline}
                self.diagnostic.data["connection_cap"]["recovery_budget"] = budget
                self._snapshot_phase("immediate_post_closure")
                budget["remaining_seconds_after_snapshot"] = deadline - time.monotonic()
                if budget["remaining_seconds_after_snapshot"] <= 0:
                    self.diagnostic.data["connection_cap"]["observer_budget_exhausted"] = True
                    self.diagnostic.publish()
        # Closing the client sockets starts asynchronous library cleanup.
        # ITC wakes listener cleanup. Worker exit alone did not prove that the
        # admission slots were released when that wake channel was disabled.
        cap = self.diagnostic.data["connection_cap"]
        def require_recovery_budget(stage):
            observed = time.monotonic()
            budget["last_checked_monotonic"] = observed
            budget["remaining_seconds"] = deadline - observed
            if observed >= deadline:
                cap["recovery"] = ("inconclusive_observer_budget_exhausted" if stage == "post_snapshot"
                                   else "inconclusive_recovery_deadline_exhausted")
                cap["recovery_failure"] = {"stage": stage, "observed_monotonic": observed,
                                           "deadline_monotonic": deadline}
                raise RuntimeError("The diagnostic exhausted the existing recovery deadline.")
        cap["recovery"] = "reached"
        liveness_status = None
        try:
            require_recovery_budget("post_snapshot")
            while threads() > 2 and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(threads(), 2)
            require_recovery_budget("thread_count")
            self.assertEqual(self.request("/health/live")[0], 200)
            liveness_status = 200
            require_recovery_budget("liveness")
            self.evidence["measurements"]["connection_cap_recovery_seconds"] = time.monotonic() - recovery_start
            cap["recovery"] = "pending_observation" if getattr(self, "attribution", None) is not None else "observed_success"
        finally:
            if getattr(self, "attribution", None) is not None and cap["recovery"] == "pending_observation":
                try:
                    self._settled_recovery_snapshot(deadline, recovery_start, liveness_status)
                    require_recovery_budget("recovery_observations")
                except BaseException as primary:
                    if cap["recovery"] == "pending_observation":
                        cap["recovery"] = "inconclusive_attribution_observation"
                    try:
                        self.diagnostic.publish()
                    except BaseException as error:
                        primary.add_note("Secondary recovery evidence publication failed: " + type(error).__name__)
                    raise
                cap["recovery"] = "observed_success"
                try:
                    self.diagnostic.publish()
                except BaseException:
                    cap["recovery"] = "inconclusive_evidence_publication"
                    raise
            else:
                self._snapshot_phase("recovery", liveness_status=liveness_status,
                                     elapsed_seconds=time.monotonic() - recovery_start)

    def test_a_stalled_database_does_not_stall_liveness(self):
        self.proxy.closed_gate.set()
        try:
            with ThreadPoolExecutor(max_workers=2) as pool:
                start = time.monotonic()
                blocked = pool.submit(self.request, "/health/ready")
                time.sleep(0.05)
                live_start = time.monotonic()
                self.assertEqual(self.request("/health/live")[0], 200)
                live_elapsed = time.monotonic() - live_start
                self.assertLess(live_elapsed, 0.75)
                self.assertEqual(blocked.result(timeout=3)[0], 503)
                elapsed = time.monotonic() - start
                self.assertGreater(elapsed, 1.5)
                self.assertLess(elapsed, 2.75)
                self.evidence["measurements"]["stalled_database_seconds"] = elapsed
                self.evidence["measurements"]["liveness_during_stall_seconds"] = live_elapsed
        finally:
            self.proxy.closed_gate.clear()
        self.assertEqual(self.request("/health/ready")[0], 200)

    def test_simultaneous_searches_keep_request_data_separate(self):
        def one(i):
            query = f"fixture {i:02d}"
            path = "/prototype/packages?" + urlencode({"q": query})
            record = {"index": i, "query": query, "route": path, "start_monotonic": time.monotonic(),
                      "status": None, "headers": {}, "body_bytes": None, "body_sha256": None,
                      "body_base64": "", "body_truncated": False, "body_redacted": False,
                      "body_complete": False, "body_state": "unavailable", "exception": None}
            try:
                return self.request(path, diagnostic=record), None, record
            except Exception as error:
                return None, error, record
        with ThreadPoolExecutor(max_workers=8) as pool:
            outcomes = list(pool.map(one, range(1, 17)))
        # Every request record is committed before any response schema is used.
        self.diagnostic.data["simultaneous_searches"]["records"] = [record for _, _, record in outcomes]
        self.diagnostic.publish()
        results = []
        for response, error, _ in outcomes:
            if error is not None:
                raise error
            code, _, data = response
            results.append((code, [p["name"] for p in data["packages"]]))
        self.assertEqual(results, [(200, [f"fixture/p{i:02d}"]) for i in range(1, 17)])

    def test_shutdown_is_bounded_with_a_stalled_database(self):
        port = self.unused_port()
        proc = subprocess.Popen([str(BINARY), str(port), str(self.proxy_file)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            self.wait_server(proc, port)
            self.proxy.closed_gate.set()
            with socket.create_connection(("127.0.0.1", port), timeout=2) as client:
                client.sendall(b"GET /health/ready HTTP/1.1\r\nHost: localhost\r\n\r\n")
                time.sleep(0.05)
                start = time.monotonic()
                proc.terminate()
                self.assertEqual(proc.wait(timeout=3), 0)
                self.evidence["measurements"]["shutdown_during_stall_seconds"] = time.monotonic() - start
        finally:
            self.proxy.closed_gate.clear()
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=2)
            proc.stderr.close()


if __name__ == "__main__":
    unittest.main()
