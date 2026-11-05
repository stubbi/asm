"""Observe hosted startup through the real assembly executable on native Linux.

SPDX-License-Identifier: AGPL-3.0-or-later
Python and the preload library are test fixtures, not an application backend.
The TLS database is disposable. Preparer cases need no database.
"""
from contextlib import contextmanager
import http.client
import os
from pathlib import Path
import resource
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

import test_runtime as runtime_fixture


def executable():
    value = os.environ.get("ASM_SERVER_BINARY", "")
    if not value or not Path(value).is_file():
        raise AssertionError("ASM_SERVER_BINARY must identify the built assembly runtime; no executable check ran.")
    return Path(value).resolve()


def fixture_environment(base, mode):
    value = os.environ.get("ASM_SERVER_STARTUP_FIXTURE", "")
    if not value or not Path(value).is_file():
        raise AssertionError("Build make test-fixtures and set ASM_SERVER_STARTUP_FIXTURE; no preload check ran.")
    # Do not inherit another fault injection mode or ambient PostgreSQL options.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("PG", "ASM_STARTUP_")) and key != "LD_PRELOAD"}
    env.update(LD_PRELOAD=str(Path(value).resolve()), ASM_STARTUP_MODE=mode,
               ASM_STARTUP_LOG=str(base / "fixture.log"))
    return env


def events(base):
    log = base / "fixture.log"
    return log.read_text().splitlines() if log.exists() else []


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
            raise AssertionError("The owned runtime did not stop within three seconds.")


def child_limits():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_FSIZE, (4 * 1024 * 1024, 4 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_CPU, (5, 5))


def response(port, path):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=0.3)
    try:
        connection.request("GET", path)
        result = connection.getresponse()
        return result.status, result.read()
    finally:
        connection.close()


class StartupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Composition keeps imported RuntimeTests and its sixteen cases out of
        # this module's test discovery. Register cleanup before setup can fail.
        class OwnedTlsFixture(runtime_fixture.RuntimeTests):
            pass
        cls.tls = OwnedTlsFixture
        cls.addClassCleanup(cls.tls.doClassCleanups)
        cls.tls.setUpClass()
        cls.binary = executable()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asm-startup-", dir=self.tls.base)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.port = runtime_fixture.free_port()
        self.config = self.base / "database.url"
        self.raw = self.tls.configs["reader"].read_text().replace("&hostaddr=127.0.0.1", "")
        self.config.write_text(self.raw)
        self.config.chmod(0o600)

    def environment(self, mode="synthetic", raw=None):
        if raw is not None:
            self.config.write_text(raw)
        env = fixture_environment(self.base, mode)
        env.update(ASM_DATABASE_URL_FILE=str(self.config), ASM_BIND=f"127.0.0.1:{self.port}")
        return env

    @contextmanager
    def serving(self, mode="synthetic", raw=None):
        with (self.base / "stdout").open("wb") as out, (self.base / "stderr").open("wb") as err:
            process = subprocess.Popen([str(self.binary), "serve"], env=self.environment(mode, raw),
                                       stdout=out, stderr=err, preexec_fn=child_limits)
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    self.assertIsNone(process.poll(), (self.base / "stderr").read_bytes())
                    try:
                        if response(self.port, "/health/ready")[0] == 200:
                            break
                    except OSError:
                        pass
                    time.sleep(0.01)
                else:
                    self.fail("The DNS-only runtime did not become ready within three seconds.")
                yield process
            finally:
                stop(process)
        self.assertEqual((self.base / "stdout").read_bytes(), b"")
        self.assertNotIn(b"postgresql://", (self.base / "stderr").read_bytes())

    def refusal(self, mode="synthetic", raw=None, *, full_stderr=False, minimum=None):
        env = self.environment(mode, raw)
        read_fd = write_fd = None
        if full_stderr:
            read_fd, write_fd = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
            try:
                while True:
                    os.write(write_fd, b"x" * 4096)
            except BlockingIOError:
                pass
            os.set_blocking(write_fd, True)
        started = time.monotonic()
        process = subprocess.Popen([str(self.binary), "serve"], env=env,
                                   stdout=subprocess.PIPE, stderr=write_fd if full_stderr else subprocess.PIPE,
                                   preexec_fn=child_limits, start_new_session=True)
        try:
            # Observe admission throughout startup rather than after exit only.
            deadline = started + 2.8
            while process.poll() is None and time.monotonic() < deadline:
                try:
                    with socket.create_connection(("127.0.0.1", self.port), timeout=0.01):
                        self.fail("A refused startup opened its HTTP listener.")
                except OSError:
                    pass
                time.sleep(0.005)
            self.assertIsNotNone(process.poll(), "The startup exceeded its two-second configured deadline and test margin.")
            stdout, stderr = process.communicate(timeout=0.2)
            self.assertEqual(process.returncode, 78, stderr)
            self.assertEqual(stdout, b"")
            if stderr is not None:
                self.assertNotIn(b"postgresql://", stderr)
            elapsed = time.monotonic() - started
            self.assertLess(elapsed, 2.8)
            if minimum is not None:
                self.assertGreater(elapsed, minimum)
        finally:
            if process.poll() is None:
                # SIGKILL to the owned process group also removes a worker left
                # alive by an incorrect thread-only timeout exit.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate(timeout=2)
            if write_fd is not None:
                os.close(write_fd)
                os.close(read_fd)
        return events(self.base)

    def assert_profile(self, log):
        self.assertEqual(log.count("lookup"), 1, log)
        self.assertIn("profile-valid", log)
        self.assertIn("watchdog-ready", log)
        for forbidden in ("bad-profile", "bad-wait", "storage-invalid", "watchdog-invalid",
                          "cancel-forbidden", "freed-live-result", "state-invalid", "pinned-address-invalid"):
            self.assertNotIn(forbidden, log)

    def test_dns_only_localhost_uses_real_dns_and_tls(self):
        with self.serving("real"):
            self.assertEqual(response(self.port, "/health/live")[0], 200)
        log = events(self.base)
        self.assert_profile(log)
        self.assertIn("freed-completed-result", log)
        self.assertIn("state-restored", log)
        self.assertIn("pinned-address-valid", log)

    def test_explicit_ipv4_bypasses_dns(self):
        # A lookup would block: success therefore observes the bypass.
        with self.serving("submit-stall", self.tls.configs["reader"].read_text()):
            self.assertEqual(response(self.port, "/health/ready")[0], 200)
        self.assertNotIn("lookup", events(self.base))

    def test_first_address_is_pinned_across_connections_and_no_watchdog_remains(self):
        with self.serving():
            for _ in range(4):
                self.assertEqual(response(self.port, "/health/ready")[0], 200)
            # A forgotten two-second timer must not kill later requests.
            time.sleep(2.1)
            self.assertEqual(response(self.port, "/registry/v1/index.json")[0], 200)
        log = events(self.base)
        self.assert_profile(log)
        self.assertGreaterEqual(log.count("database-connect"), 5)
        self.assertIn("state-restored", log)
        self.assertEqual(log.count("pinned-address-valid"), log.count("database-connect"), log)

    def test_inherited_blocked_alarm_handler_mask_and_empty_timer_are_restored(self):
        with self.serving("blocked-alarm"):
            self.assertEqual(response(self.port, "/health/ready")[0], 200)
        log = events(self.base)
        self.assert_profile(log)
        self.assertIn("state-restored", log)

    def test_nonempty_inherited_timers_are_refused_before_dns_or_database(self):
        for mode in ("active-timer", "expired-periodic"):
            with self.subTest(mode=mode):
                (self.base / "fixture.log").unlink(missing_ok=True)
                log = self.refusal(mode)
                self.assertIn("initialized", log)
                if mode == "expired-periodic":
                    self.assertIn("expired-periodic-ready", log)
                    self.assertNotIn("expired-periodic-unavailable", log)
                self.assertNotIn("lookup", log)
                self.assertNotIn("database-connect", log)

    def test_dns_does_not_relax_tls_refusals(self):
        for transform in (lambda value: value.replace("verify-full", "require"),
                          lambda value: value.replace("ca.crt", "unrelated.crt"),
                          lambda value: value.replace("reader.crt", "operator.crt").replace("reader.key", "operator.key")):
            with self.subTest(transform=transform):
                self.refusal(raw=transform(self.raw))

    def test_malformed_first_result_and_resolver_failures_do_not_connect(self):
        for mode in ("bad-family", "bad-socktype", "bad-protocol", "bad-length", "null-address",
                     "bad-address-family", "null-result", "submit-fail", "lookup-fail", "pending-alarm"):
            with self.subTest(mode=mode):
                (self.base / "fixture.log").unlink(missing_ok=True)
                log = self.refusal(mode)
                self.assert_profile(log)
                self.assertNotIn("database-connect", log)
                if mode == "submit-fail":
                    self.assertNotIn("freed-completed-result", log)

    def test_watchdog_covers_blocked_submission_wait_and_full_diagnostic_pipe(self):
        for mode, full in (("submit-stall", False), ("submit-stall-worker", False),
                           ("wait-stall", False), ("lookup-fail", True)):
            with self.subTest(mode=mode, full_stderr=full):
                (self.base / "fixture.log").unlink(missing_ok=True)
                log = self.refusal(mode, full_stderr=full, minimum=1.5)
                self.assert_profile(log)
                self.assertNotIn("database-connect", log)
                if mode == "submit-stall-worker":
                    self.assertIn("blocked-worker-ready", log)
                    self.assertNotIn("blocked-worker-setup-failed", log)
                if mode == "wait-stall":
                    self.assertIn("wait", log)

    def test_repeated_interruptions_share_one_absolute_budget(self):
        log = self.refusal("interrupt", minimum=1.5)
        self.assert_profile(log)
        self.assertGreater(log.count("wait"), 5)
        remaining = [int(item.removeprefix("wait-ms=")) for item in log if item.startswith("wait-ms=")]
        self.assertGreater(remaining[0] - remaining[-1], 1000, remaining)
        self.assertTrue(all(later <= earlier for earlier, later in zip(remaining, remaining[1:])), remaining)
        self.assertNotIn("database-connect", log)


class PrepareConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = executable()
        if os.getuid() == 0 or os.getgid() == 0 or os.getuid() != os.geteuid() or os.getgid() != os.getegid():
            raise AssertionError("Run preparer tests with a nonzero real UID/GID and matching effective IDs.")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asm-prepare-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "source"
        self.dest = self.base / "destination"
        self.source.mkdir(mode=0o750)
        self.dest.mkdir(mode=0o770)
        self.key = self.source / "database.url"
        self.content = b"postgresql://fixture@localhost/db?sslmode=verify-full\n"
        self.key.write_bytes(self.content)
        self.key.chmod(0o640)
        self.output = self.dest / "private/database.url"

    def run_prepare(self, *, source=None, dest=None, expected=0, mode=None, arguments=None):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("PG", "ASM_STARTUP_")) and key != "LD_PRELOAD"}
        # Invalid serving settings establish that prepare-config is independent.
        if mode:
            env.update(fixture_environment(self.base, mode))
        env.update(ASM_BIND="invalid", ASM_DATABASE_URL_FILE="/does/not/exist", PGHOST="untrusted.invalid")
        argv = arguments if arguments is not None else (
            "prepare-config", str(self.source if source is None else source), str(self.dest if dest is None else dest))
        started = time.monotonic()
        result = subprocess.run([str(self.binary), *argv], env=env, capture_output=True, timeout=3,
                                preexec_fn=child_limits)
        self.assertEqual(result.returncode, expected, result.stderr)
        self.assertEqual(result.stdout, b"")
        if expected == 0:
            self.assertEqual(result.stderr, b"")
        else:
            self.assertTrue(result.stderr, "A refusal needs a useful diagnostic.")
            self.assertNotIn(self.content.rstrip(), result.stderr)
        self.assertLess(time.monotonic() - started, 2.8)
        return result

    def assert_snapshot(self, expected=None, output=None):
        output = output or self.output
        self.assertEqual(output.read_bytes(), self.content if expected is None else expected)
        info = output.lstat()
        self.assertTrue(stat.S_ISREG(info.st_mode))
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
        self.assertEqual(info.st_nlink, 1)
        self.assertEqual((info.st_uid, info.st_gid), (os.getuid(), os.getgid()))
        info = output.parent.lstat()
        self.assertTrue(stat.S_ISDIR(info.st_mode))
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o700)
        self.assertEqual(info.st_uid, os.getuid())
        self.assertEqual(list(output.parent.iterdir()), [output])

    def refuse(self, **kwargs):
        self.run_prepare(expected=78, **kwargs)
        self.assertFalse(self.output.exists())
        if self.output.parent.is_dir() and not self.output.parent.is_symlink():
            self.assertEqual(list(self.output.parent.iterdir()), [])

    def test_atomicwriter_projection_preserves_lf_and_idempotent_inode(self):
        self.key.unlink()
        generation = self.source / "..2026_11_05_000000"
        generation.mkdir(mode=0o750)
        (generation / "database.url").write_bytes(self.content)
        (generation / "database.url").chmod(0o640)
        (self.source / "..data").symlink_to(generation.name)
        self.key.symlink_to("..data/database.url")
        self.run_prepare()
        self.assert_snapshot()
        before = self.output.stat()
        self.run_prepare()
        after = self.output.stat()
        self.assertEqual((before.st_dev, before.st_ino, before.st_mtime_ns),
                         (after.st_dev, after.st_ino, after.st_mtime_ns))
        self.assert_snapshot()

    def test_content_bounds_and_printable_ascii_without_url_interpretation(self):
        for content in (b"x", b"x" * 4096, b"x" * 4095 + b"\n", b"a b~!\n"):
            with self.subTest(size=len(content)):
                self.key.write_bytes(content)
                self.run_prepare()
                self.assert_snapshot(content)
                self.output.unlink()
        for content in (b"", b"x" * 4097, b"x" * 4096 + b"\n", b"x\x00y", b"x\ny",
                        b"x\r\n", b"x\ty", b"\x1f", b"\x7f", b"\x80", b"\n", b"x\n\n"):
            with self.subTest(content=repr(content[:20]), size=len(content)):
                self.key.write_bytes(content)
                self.refuse()

    def test_source_modes_types_and_hardlinks_are_rejected(self):
        for mode in (0o400, 0o440, 0o600, 0o640):
            with self.subTest(accepted_mode=oct(mode)):
                self.key.chmod(mode)
                self.run_prepare()
                self.assert_snapshot()
                self.output.unlink()
        for mode in (0o000, 0o200, 0o700, 0o650, 0o660, 0o644, 0o602, 0o601,
                     0o600 | stat.S_ISUID, 0o600 | stat.S_ISGID, 0o600 | stat.S_ISVTX):
            with self.subTest(mode=oct(mode)):
                self.key.chmod(mode)
                self.refuse()
        self.key.chmod(0o640)
        alias = self.source / "alias"
        os.link(self.key, alias)
        self.refuse()
        alias.unlink()
        self.key.unlink()
        for kind in ("missing", "directory", "fifo", "socket"):
            with self.subTest(kind=kind):
                sock = None
                if kind == "directory":
                    self.key.mkdir()
                elif kind == "fifo":
                    os.mkfifo(self.key, 0o600)
                elif kind == "socket":
                    sock = socket.socket(socket.AF_UNIX)
                    sock.bind(str(self.key))
                try:
                    self.refuse()
                finally:
                    if sock:
                        sock.close()
                    if self.key.is_dir():
                        self.key.rmdir()
                    else:
                        self.key.unlink(missing_ok=True)

    def test_source_and_destination_root_modes_are_enforced(self):
        for root, mode in ((self.source, 0o770), (self.source, 0o757), (self.dest, 0o777)):
            with self.subTest(root=root.name, mode=oct(mode)):
                original = stat.S_IMODE(root.stat().st_mode)
                root.chmod(mode)
                try:
                    self.refuse()
                finally:
                    root.chmod(original)
        # Output group write is permitted because the snapshot child is private.
        for mode in (0o770, 0o2770):
            with self.subTest(accepted_destination_mode=oct(mode)):
                self.dest.chmod(mode)
                self.run_prepare()
                self.assert_snapshot()
                self.output.unlink()
                self.output.parent.rmdir()

    def test_directory_arguments_reject_relative_symlink_and_noncanonical_final_components(self):
        linked = self.base / "linked"
        linked.symlink_to(self.source, target_is_directory=True)
        for source, dest in (("relative", self.dest), (self.source, "relative"),
                             ("", self.dest), (self.source, ""),
                             (linked, self.dest), (self.source, linked),
                             (str(self.source) + "/", self.dest), (str(self.source) + "/.", self.dest),
                             (str(self.source) + "/..", self.dest), (self.source, str(self.dest) + "/"),
                             (self.source, str(self.dest) + "/."), (self.source, str(self.dest) + "/.."),
                             ("/" + "x" * 1024, self.dest), (self.source, "/" + "x" * 1024),
                             (self.key, self.dest), (self.source, self.key)):
            with self.subTest(source=str(source), dest=str(dest)):
                self.refuse(source=source, dest=dest)
        # '/' is valid argument syntax. Its absent key must be a configuration
        # refusal, never a usage error. Tests do not create anything under '/'.
        if not Path("/database.url").exists():
            self.refuse(source="/")

    def test_directory_arguments_accept_the_exact_1024_byte_bound(self):
        def bounded_directory(name):
            current = self.base / name
            current.mkdir(mode=0o700)
            while len(str(current).encode()) < 1024:
                remaining = 1024 - len(str(current).encode()) - 1
                if remaining == 0:
                    raise AssertionError("The fixture cannot add an empty final component.")
                component = min(120, remaining)
                # Avoid leaving a one-byte remainder for the next separator.
                if remaining - component == 1:
                    component -= 1
                current = current / ("x" * component)
                current.mkdir(mode=0o700)
            self.assertEqual(len(str(current).encode()), 1024)
            return current

        source = bounded_directory("source-boundary")
        dest = bounded_directory("destination-boundary")
        key = source / "database.url"
        key.write_bytes(self.content)
        key.chmod(0o640)
        self.run_prepare(source=source, dest=dest)
        self.assert_snapshot(output=dest / "private/database.url")

    def test_cli_arity_has_usage_status(self):
        for args in (("prepare-config",), ("prepare-config", str(self.source)),
                     ("prepare-config", str(self.source), str(self.dest), "extra")):
            with self.subTest(arguments=args):
                self.run_prepare(arguments=args, expected=64)

    def test_projection_escapes_and_magiclinks_fail_closed(self):
        outside = self.base / "outside.url"
        outside.write_bytes(self.content)
        outside.chmod(0o640)
        self.key.unlink()
        with outside.open("rb") as stream:
            for target in (str(outside), "../outside.url", "/proc/self/fd/" + str(stream.fileno()),
                           "loop"):
                with self.subTest(target=target):
                    self.key.symlink_to(target)
                    if target == "loop":
                        (self.source / "loop").symlink_to("database.url")
                    try:
                        self.refuse()
                    finally:
                        self.key.unlink()
                        (self.source / "loop").unlink(missing_ok=True)
        self.assertEqual(outside.read_bytes(), self.content)

    def test_seccomp_denial_and_persistent_interruptions_fail_with_bounded_cleanup(self):
        for mode in ("deny-openat2", "unsupported-openat2", "interrupt-read", "interrupt-write",
                     "interrupt-fsync", "interrupt-rename"):
            with self.subTest(mode=mode):
                (self.base / "fixture.log").unlink(missing_ok=True)
                self.refuse(mode=mode)
                self.assertIn("seccomp-installing", events(self.base))
                self.assertNotIn("seccomp-setup-failed", events(self.base))
                self.assertEqual(self.key.read_bytes(), self.content)

    def test_existing_destination_and_unrelated_files_are_preserved(self):
        unrelated = self.dest / "unrelated"
        unrelated.write_bytes(b"keep me")
        self.output.parent.mkdir(mode=0o700)
        for kind in ("different", "symlink", "directory", "fifo", "socket", "hardlink", "public"):
            with self.subTest(kind=kind):
                if kind == "directory":
                    self.output.mkdir(mode=0o700)
                elif kind == "fifo":
                    os.mkfifo(self.output, 0o600)
                elif kind == "socket":
                    with socket.socket(socket.AF_UNIX) as sock:
                        sock.bind(str(self.output))
                elif kind == "symlink":
                    self.output.symlink_to(unrelated)
                else:
                    self.output.write_bytes(self.content if kind in ("public", "hardlink") else b"retained bytes")
                    self.output.chmod(0o644 if kind == "public" else 0o600)
                    if kind == "hardlink":
                        os.link(self.output, self.dest / "retained-link")
                before = self.output.lstat()
                value = os.readlink(self.output) if kind == "symlink" else (
                    self.output.read_bytes() if stat.S_ISREG(before.st_mode) else None)
                self.run_prepare(expected=78)
                after = self.output.lstat()
                self.assertEqual((before.st_dev, before.st_ino, before.st_mode),
                                 (after.st_dev, after.st_ino, after.st_mode))
                if kind == "symlink":
                    self.assertEqual(os.readlink(self.output), value)
                elif stat.S_ISREG(before.st_mode):
                    self.assertEqual(self.output.read_bytes(), value)
                self.assertEqual(unrelated.read_bytes(), b"keep me")
                self.assertEqual({entry.name for entry in self.output.parent.iterdir()}, {"database.url"})
                if kind == "directory":
                    self.output.rmdir()
                else:
                    self.output.unlink()
                (self.dest / "retained-link").unlink(missing_ok=True)

    def test_unrelated_private_directory_is_never_replaced(self):
        other = self.base / "other"
        other.mkdir()
        for kind in ("symlink", "file", "public-directory"):
            with self.subTest(kind=kind):
                if kind == "symlink":
                    self.output.parent.symlink_to(other, target_is_directory=True)
                elif kind == "file":
                    self.output.parent.write_bytes(b"retained")
                else:
                    self.output.parent.mkdir(mode=0o755)
                    self.output.parent.chmod(0o755)
                before = self.output.parent.lstat()
                self.run_prepare(expected=78)
                after = self.output.parent.lstat()
                self.assertEqual((before.st_ino, before.st_mode), (after.st_ino, after.st_mode))
                self.assertEqual(list(other.iterdir()), [])
                if kind == "public-directory":
                    self.output.parent.rmdir()
                else:
                    self.output.parent.unlink()

    def test_atomicwriter_generation_replacement_never_mixes_bytes(self):
        self.key.unlink()
        contents = (b"a" * 4095 + b"\n", b"b" * 4095 + b"\n")
        for index, content in enumerate(contents):
            generation = self.source / ("..generation" + str(index))
            generation.mkdir(mode=0o750)
            key = generation / "database.url"
            key.write_bytes(content)
            key.chmod(0o640)
        (self.source / "..data").symlink_to("..generation0")
        self.key.symlink_to("..data/database.url")
        finished = threading.Event()
        errors = []

        def replace_generation():
            index = 1
            try:
                while not finished.is_set():
                    temporary = self.source / "..data-tmp"
                    temporary.symlink_to("..generation" + str(index))
                    temporary.replace(self.source / "..data")
                    index = 1 - index
                    finished.wait(0.001)
            except BaseException as error:
                errors.append(error)

        worker = threading.Thread(target=replace_generation, daemon=True)
        worker.start()
        try:
            for index in range(12):
                destination = self.base / ("generation-dest-" + str(index))
                destination.mkdir(mode=0o700)
                self.run_prepare(dest=destination)
                output = destination / "private/database.url"
                self.assertIn(output.read_bytes(), contents)
                self.assert_snapshot(output.read_bytes(), output)
        finally:
            finished.set()
            worker.join(timeout=2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(errors, [])

    def test_real_root_and_foreign_uid_gid_ownership(self):
        value = os.environ.get("ASM_SERVER_STARTUP_OWNERSHIP")
        self.assertTrue(value, "Privileged test setup is required: use --prepare-ownership-fixtures DIR UID GID, then set ASM_SERVER_STARTUP_OWNERSHIP=DIR.")
        prepared = Path(value)
        self.assertTrue(prepared.is_absolute())
        self.assertFalse(prepared.is_symlink())
        metadata = (prepared / "identity").read_text().split()
        self.assertEqual(metadata, [str(os.getuid()), str(os.getgid())], "Ownership fixtures target a different test identity.")
        self.run_prepare(source=prepared / "root-owned-source")
        self.assert_snapshot(b"root-owned test bytes\n")
        self.output.unlink()
        for name in ("foreign-root", "foreign-file", "wrong-group-root", "wrong-group-file"):
            with self.subTest(source=name):
                self.refuse(source=prepared / name)
        for name in ("foreign-destination", "wrong-group-destination", "root-owned-private", "foreign-existing"):
            with self.subTest(destination=name):
                destination = prepared / name
                # Refusal must retain the privileged fixture exactly.
                before = tree_identity(destination)
                self.run_prepare(dest=destination, expected=78)
                self.assertEqual(tree_identity(destination), before)


def tree_identity(path):
    result = []
    for root, directories, files in os.walk(path):
        for item in [Path(root), *(Path(root) / name for name in sorted(directories + files))]:
            info = item.lstat()
            result.append((str(item.relative_to(path)), info.st_uid, info.st_gid,
                           info.st_mode, info.st_nlink, info.st_ino,
                           readable_bytes(item) if stat.S_ISREG(info.st_mode) else None))
    return result


def readable_bytes(path):
    try:
        return path.read_bytes()
    except PermissionError:
        return "unreadable by test UID"


def prepare_ownership_fixtures(directory, uid, gid):
    """Privileged TEST SETUP only; never launch asm-hub or a database as root.

    The caller supplies a new directory beneath an owned disposable test parent.
    Remove that entire directory as root after the non-root suite completes.
    """
    if os.getuid() != 0 or uid <= 0 or gid <= 0:
        raise RuntimeError("Ownership setup requires root and a nonzero test UID/GID.")
    directory = Path(directory)
    if not directory.is_absolute() or directory.exists() or directory.is_symlink():
        raise RuntimeError("Supply a new absolute ownership fixture directory.")
    directory.mkdir(mode=0o755)
    directory.chmod(0o755)
    foreign_uid = uid + 1 if uid != 65534 else uid - 1
    foreign_gid = gid + 1 if gid != 65534 else gid - 1
    for name in ("root-owned-source", "foreign-root", "foreign-file", "wrong-group-root", "wrong-group-file"):
        source = directory / name
        source.mkdir(mode=0o750)
        source.chmod(0o750)
        os.chown(source, uid, gid)
        key = source / "database.url"
        key.write_bytes(b"root-owned test bytes\n")
        key.chmod(0o640)
        os.chown(key, uid, gid)
        if name == "root-owned-source":
            os.chown(source, 0, gid)
            os.chown(key, 0, gid)
        elif name == "foreign-root":
            os.chown(source, foreign_uid, gid)
        elif name == "foreign-file":
            os.chown(key, foreign_uid, gid)
        elif name == "wrong-group-root":
            os.chown(source, uid, foreign_gid)
        elif name == "wrong-group-file":
            os.chown(key, uid, foreign_gid)
    for name in ("foreign-destination", "wrong-group-destination", "root-owned-private", "foreign-existing"):
        dest = directory / name
        dest.mkdir(mode=0o750)
        dest.chmod(0o770 if name == "foreign-destination" else 0o750)
        os.chown(dest, foreign_uid if name == "foreign-destination" else uid,
                 foreign_gid if name == "wrong-group-destination" else gid)
        if name in ("root-owned-private", "foreign-existing"):
            private = dest / "private"
            private.mkdir(mode=0o700)
            os.chown(private, uid if name == "foreign-existing" else 0, gid)
            if name == "foreign-existing":
                key = private / "database.url"
                key.write_bytes(b"postgresql://fixture@localhost/db?sslmode=verify-full\n")
                key.chmod(0o600)
                os.chown(key, foreign_uid, gid)
    identity = directory / "identity"
    identity.write_text(f"{uid} {gid}\n")
    identity.chmod(0o644)


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "--prepare-ownership-fixtures":
        prepare_ownership_fixtures(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    else:
        unittest.main(verbosity=2)
