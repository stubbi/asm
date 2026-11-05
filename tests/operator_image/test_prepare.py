"""Projected credential snapshots and bounded DNS use owned synthetic fixtures.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import ipaddress
import errno
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.parse import quote, urlsplit, parse_qsl

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import prepare_operator as prepare
from registry_admin import AdminError


def source_url(tls, **changes):
    options = {"sslmode": "verify-full", "sslrootcert": str(tls / "ca.crt"),
               "sslcert": str(tls / "tls.crt"), "sslkey": str(tls / "tls.key")}
    options.update(changes)
    return ("postgresql://asm_operator@localhost:5432/asm?" +
            "&".join(key + "=" + quote(value, safe="/") for key, value in options.items())).encode()


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asm-operator-prepare-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.tls = self.base / "tls"
        self.config = self.base / "config"
        for directory, files in ((self.tls, {"ca.crt": b"synthetic CA", "tls.crt": b"synthetic certificate",
                "tls.key": b"-----BEGIN PRIVATE KEY-----\nsynthetic test bytes\n"}),
                (self.config, {"database.url": source_url(self.tls)})):
            directory.mkdir(mode=0o750)
            os.chown(directory, -1, os.getegid())
            generation = directory / "..generation_one"
            generation.mkdir(mode=0o750)
            os.chown(generation, -1, os.getegid())
            for name, body in files.items():
                path = generation / name
                path.write_bytes(body)
                os.chown(path, -1, os.getegid())
                path.chmod(0o440)
            (directory / "..data").symlink_to(generation.name)
            os.lchown(directory / "..data", -1, os.getegid())
        if os.environ.get("ASM_OPERATOR_PROJECTION_FIXTURES"):
            self.psql = Path("/opt/asm/postgres/bin/psql")
        else:
            self.psql = self.base / "psql"
            self.psql.write_text("#!" + sys.executable + "\nprint('psql (PostgreSQL) 16.15')\n")
            self.psql.chmod(0o700)
        # Exercise the kernel snapshot operations on owned files locally.
        # Image qualification separately requires the real root:GID65532 policy.
        self.authority = patch.multiple(prepare, SOURCE_UID=os.geteuid(), SOURCE_GID=os.getegid())
        self.authority.start()
        self.addCleanup(self.authority.stop)

    def snapshot(self, destination=None, *, resolve=False):
        return prepare.prepare(self.config, self.tls, destination or self.base / "private", "asm_operator",
                               self.psql, resolve_dns=resolve)

    def test_snapshot_preserves_exact_tls_bytes_and_default_operator_policy(self):
        result = self.snapshot(resolve=True)
        destination = self.base / "private"
        self.assertEqual(result["status"], "prepared")
        self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
        for name in ("ca.crt", "tls.crt", "tls.key"):
            self.assertEqual((destination / name).read_bytes(), (self.tls / "..generation_one" / name).read_bytes())
            self.assertEqual((destination / name).stat().st_mode & 0o777, 0o600)
        value = (destination / "database.url").read_text().strip()
        options = dict(parse_qsl(urlsplit(value).query))
        self.assertEqual(urlsplit(value).hostname, "localhost")
        self.assertEqual(str(ipaddress.IPv4Address(options["hostaddr"])), options["hostaddr"])
        self.assertEqual(options["sslkey"], str(destination / "tls.key"))
        self.assertEqual((destination / "database.url").stat().st_mode & 0o777, 0o600)

    def test_url_policy_refuses_ambient_options_roles_paths_and_implicit_dns(self):
        for body in (source_url(self.tls, sslmode="disable"), source_url(self.tls, options="untrusted"),
                     source_url(self.tls, sslkey="/etc/unrelated.key"),
                     source_url(self.tls) + b"&sslmode=verify-full", source_url(self.tls).replace(b"asm_operator@", b"asm_reader@")):
            with self.subTest(body=body[:30]), self.assertRaises(AdminError):
                prepare.parse_source_url(body, "asm_operator", self.tls, self.base / "private", resolve_dns=True)
        with self.assertRaises(AdminError):
            self.snapshot()
        self.assertFalse((self.base / "private").exists())

    def test_existing_destination_symlink_and_rotated_missing_file_preserve_state(self):
        destination = self.base / "private"
        destination.mkdir()
        (destination / "keep").write_bytes(b"unrelated")
        with self.assertRaises(OSError):
            self.snapshot(destination, resolve=True)
        self.assertEqual((destination / "keep").read_bytes(), b"unrelated")
        target = self.tls / "..generation_one/tls.key"
        target.unlink()
        target.symlink_to(self.psql)
        with self.assertRaises((OSError, AdminError)):
            self.snapshot(self.base / "refused", resolve=True)
        self.assertFalse((self.base / "refused").exists())
        target.unlink()
        with self.assertRaises((OSError, AdminError)):
            self.snapshot(self.base / "rotated", resolve=True)
        self.assertFalse((self.base / "rotated").exists())

    def test_short_writes_are_completed_and_write_failure_removes_only_new_snapshot(self):
        real_write = os.write
        with patch.object(prepare.os, "write", side_effect=lambda fd, value: real_write(fd, value[:3])):
            self.snapshot(resolve=True)
        self.assertIn(b"synthetic test bytes", (self.base / "private/tls.key").read_bytes())
        with patch.object(prepare.os, "write", side_effect=OSError("synthetic disk failure")):
            with self.assertRaises(OSError):
                self.snapshot(self.base / "failed", resolve=True)
        self.assertFalse((self.base / "failed").exists())
        self.assertTrue((self.base / "private/database.url").is_file())

    def test_snapshot_is_private_until_atomic_no_replace_publication(self):
        destination = self.base / "private"
        real_write = prepare.write_private
        def filling(fd, name, body):
            self.assertFalse(destination.exists(), "The final destination must remain absent during staging.")
            return real_write(fd, name, body)
        with patch.object(prepare, "write_private", side_effect=filling):
            self.snapshot(resolve=True)
        self.assertTrue((destination / "database.url").is_file())
        self.assertEqual(list(self.base.glob(".asm-operator-*")), [])

    def test_parent_symlink_swap_is_refused_without_changing_foreign_files(self):
        parent = self.base / "output"
        parent.mkdir(mode=0o700)
        foreign = self.base / "foreign"
        foreign.mkdir(mode=0o700)
        (foreign / "keep").write_bytes(b"unrelated")
        real_write = prepare.write_private
        changed = False
        def swap(fd, name, body):
            nonlocal changed
            if not changed:
                changed = True
                parent.rename(self.base / "moved")
                parent.symlink_to(foreign, target_is_directory=True)
            return real_write(fd, name, body)
        with patch.object(prepare, "write_private", side_effect=swap), self.assertRaises((OSError, AdminError)):
            self.snapshot(parent / "private", resolve=True)
        self.assertEqual((foreign / "keep").read_bytes(), b"unrelated")
        self.assertFalse((foreign / "private").exists())
        self.assertFalse((self.base / "moved/private").exists())

    def test_late_directory_or_symlink_destination_is_never_replaced(self):
        real_publish = prepare.publish_snapshot
        foreign = self.base / "foreign"
        foreign.mkdir()
        (foreign / "keep").write_bytes(b"unrelated")
        for kind in ("directory", "symlink"):
            destination = self.base / kind
            def insert(parent_fd, staging_name, destination_name):
                if kind == "directory":
                    destination.mkdir()
                    (destination / "keep").write_bytes(b"existing")
                else:
                    destination.symlink_to(foreign, target_is_directory=True)
                real_publish(parent_fd, staging_name, destination_name)
            with self.subTest(kind=kind), patch.object(prepare, "publish_snapshot", side_effect=insert), self.assertRaises(OSError):
                self.snapshot(destination, resolve=True)
            if kind == "directory":
                self.assertEqual((destination / "keep").read_bytes(), b"existing")
            else:
                self.assertTrue(destination.is_symlink())
                self.assertEqual((foreign / "keep").read_bytes(), b"unrelated")
            self.assertEqual(list(self.base.glob(".asm-operator-*")), [])

    def test_one_generation_is_retained_or_rotation_failure_leaves_no_snapshot(self):
        original = prepare.read_projected
        old_key = (self.tls / "..generation_one/tls.key").read_bytes()
        second = self.tls / "..generation_two"
        second.mkdir(mode=0o750)
        for name in ("ca.crt", "tls.crt", "tls.key"):
            path = second / name
            path.write_bytes((self.tls / "..generation_one" / name).read_bytes() + b"replacement")
            path.chmod(0o440)
        rotated = False
        def rotate(fd, name, maximum):
            nonlocal rotated
            body = original(fd, name, maximum)
            if name == "ca.crt" and not rotated:
                rotated = True
                (self.tls / "..data").unlink()
                (self.tls / "..data").symlink_to(second.name)
            return body
        with patch.object(prepare, "read_projected", side_effect=rotate):
            self.snapshot(resolve=True)
        self.assertEqual((self.base / "private/tls.key").read_bytes(), old_key)
        def remove_during_snapshot(fd, name, maximum):
            body = original(fd, name, maximum)
            if name == "ca.crt":
                (second / "tls.key").unlink()
            return body
        with patch.object(prepare, "read_projected", side_effect=remove_during_snapshot), self.assertRaises(OSError):
            self.snapshot(self.base / "removed", resolve=True)
        self.assertFalse((self.base / "removed").exists())

    def test_dns_deadline_kills_and_reaps_its_credential_free_child(self):
        pidfile = self.base / "resolver.pid"
        code = "import os,time;open(" + repr(str(pidfile)) + ",'w').write(str(os.getpid()));time.sleep(20)"
        started = time.monotonic()
        with patch.object(prepare, "DNS_PROGRAM", code), self.assertRaises(AdminError):
            prepare.resolve_ipv4("localhost", timeout=0.3)
        self.assertLess(time.monotonic() - started, 3)
        pid = int(pidfile.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_system_tmp_ancestor_does_not_depend_on_ambient_tmpdir(self):
        system_tmp = Path("/tmp").resolve()
        with tempfile.TemporaryDirectory(prefix="asm-system-tmp-", dir=system_tmp) as name:
            private = Path(name).resolve()
            fd = prepare.open_protected_directory(private)
            os.close(fd)
        info = system_tmp.stat()
        if info.st_uid == 0 and info.st_mode & 0o1000 and not os.statvfs(system_tmp).f_flag & os.ST_RDONLY:
            # A shared root-owned sticky ancestor is permitted; a final shared parent is refused.
            with self.assertRaises(AdminError):
                prepare.open_protected_directory(system_tmp)

    def test_fsgroup_parent_does_not_leave_setgid_on_the_private_snapshot(self):
        parent = self.base / "fsgroup-output"
        parent.mkdir()
        os.chown(parent, -1, os.getegid())
        parent.chmod(0o2770)
        real_mkdir = os.mkdir
        def inherit_setgid(path, mode=0o777, *, dir_fd=None):
            real_mkdir(path, mode, dir_fd=dir_fd)
            # Reproduce Linux's setgid-directory inheritance on hosts with different defaults.
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)
            try:
                os.fchmod(fd, (os.fstat(fd).st_mode & 0o7777) | 0o2000)
            finally:
                os.close(fd)
        with patch.object(prepare.os, "mkdir", side_effect=inherit_setgid):
            self.snapshot(parent / "private", resolve=True)
        self.assertEqual((parent / "private").stat().st_mode & 0o7777, 0o700)

    def test_interruption_after_publication_preserves_the_complete_final_snapshot(self):
        real_publish = prepare.publish_snapshot
        def interrupted(parent, staging, destination):
            real_publish(parent, staging, destination)
            signal.raise_signal(signal.SIGINT)
        caught = None
        try:
            with patch.object(prepare, "publish_snapshot", side_effect=interrupted):
                self.snapshot(resolve=True)
        except BaseException as error:
            caught = error
        destination = self.base / "private"
        with self.subTest(outcome="original interruption"):
            self.assertIsInstance(caught, KeyboardInterrupt)
        with self.subTest(outcome="complete final files"):
            self.assertEqual({p.name for p in destination.iterdir()}, {"database.url", "ca.crt", "tls.crt", "tls.key"})
        if (destination / "tls.key").exists():
            self.assertEqual((destination / "tls.key").read_bytes(), (self.tls / "..generation_one/tls.key").read_bytes())

    def test_cleanup_fault_does_not_unlink_without_staging_inode_ownership(self):
        real_fsync, real_stat = os.fsync, os.stat
        failed = False
        def fail_directory_sync(fd):
            nonlocal failed
            if os.fstat(fd).st_mode & 0o170000 == 0o040000:
                failed = True
                raise OSError(errno.EIO, "synthetic directory sync failure")
            return real_fsync(fd)
        def unavailable_identity(path, *args, **kwargs):
            if failed and str(path).startswith(".asm-operator-"):
                raise OSError(errno.EIO, "synthetic cleanup identity failure")
            return real_stat(path, *args, **kwargs)
        with patch.object(prepare.os, "fsync", side_effect=fail_directory_sync), patch.object(prepare.os, "stat", side_effect=unavailable_identity):
            with self.assertRaisesRegex(OSError, "synthetic directory sync failure"):
                self.snapshot(resolve=True)
        self.assertFalse((self.base / "private").exists())
        staged = list(self.base.glob(".asm-operator-*"))
        self.assertEqual(len(staged), 1)
        self.assertEqual({p.name for p in staged[0].iterdir()}, {"database.url", "ca.crt", "tls.crt", "tls.key"})
        self.assertEqual(staged[0].stat().st_mode & 0o7777, 0o700)


class RootProjectedImageTests(unittest.TestCase):
    def test_real_root_gid65532_projection_and_policy_failures(self):
        path = os.environ.get("ASM_OPERATOR_PROJECTION_FIXTURES")
        if not path:
            self.skipTest("Requires the derived Linux image's synthetic root:GID65532 projection fixtures.")
        self.assertEqual(os.geteuid(), 65532)
        self.assertEqual(os.getegid(), 65532)
        base = Path(path)
        with tempfile.TemporaryDirectory(prefix="asm-root-projection-") as temp:
            private = Path(temp) / "private"
            result = subprocess.run(["/usr/bin/python3", "-I", "/app/tools/operator_entrypoint.py", "prepare-operator",
                "--config-directory", str(base / "valid/config"), "--tls-directory", str(base / "valid/tls"),
                "--destination-directory", str(private), "--role", "asm_operator", "--resolve-dns"],
                capture_output=True, timeout=15, env={"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1"})
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(json.loads(result.stdout)["status"], "prepared")
            self.assertEqual((private / "tls.key").read_bytes(), (base / "valid/tls/..generation_one/tls.key").read_bytes())
            for case in ("wrong-owner", "wrong-gid", "bad-mode", "symlink-key", "missing-key", "escaping-generation"):
                destination = Path(temp) / case
                with self.subTest(case=case), self.assertRaises((AdminError, OSError)):
                    prepare.prepare(base / case / "config", base / case / "tls", destination,
                                    "asm_operator", Path("/opt/asm/postgres/bin/psql"), resolve_dns=True)
                self.assertFalse(destination.exists())


class ImagePreparationFixtureTests(unittest.TestCase):
    def test_image_mode_selects_the_fixed_client_without_creating_a_writable_executable(self):
        case = PreparationTests("test_snapshot_preserves_exact_tls_bytes_and_default_operator_policy")
        with patch.dict(os.environ, {"ASM_OPERATOR_PROJECTION_FIXTURES": "/qualified/image/fixtures"}):
            case.setUp()
        try:
            self.assertEqual(case.psql, Path("/opt/asm/postgres/bin/psql"))
            self.assertFalse((case.base / "psql").exists())
        finally:
            case.doCleanups()


if __name__ == "__main__":
    unittest.main()
