"""Projected credential snapshots and bounded DNS use owned synthetic fixtures.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import ipaddress
from functools import partial
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


def stable_stat(path, *, follow=True):
    info = path.stat() if follow else path.lstat()
    return tuple(getattr(info, name) for name in ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns"))


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

    def reader_source(self, **options):
        for name in prepare.TLS_FILES.values():
            link = self.base / "tls" / name
            if not link.is_symlink():
                link.symlink_to("..data/" + name)
                os.lchown(link, -1, os.getegid())
        path = self.config / "..generation_one/database.url"
        path.chmod(0o600)
        path.write_bytes(source_url(self.tls, **options).replace(b"asm_operator@", b"asm_reader@"))
        path.chmod(0o440)

    def reader(self, destination=None, *, resolve=False, reuse=False):
        self.assertTrue(callable(getattr(prepare, "prepare_reader", None)), "The fixed reader operation is missing.")
        return prepare.prepare_reader(self.config, self.tls, destination or self.base / "reader", self.psql,
                                      resolve_dns=resolve, **({"reuse_matching": True} if reuse else {}))

    def test_reader_reuse_matching_keeps_bytes_inodes_modes_and_cleans_staging(self):
        self.reader_source(hostaddr="127.0.0.1")
        self.reader(reuse=True)
        destination = self.base / "reader"
        url = destination / "database.url"
        before = (stable_stat(destination), stable_stat(url), url.read_bytes())
        result = self.reader(reuse=True)
        self.assertEqual(result, {"status": "prepared", "connection_file": str(url),
                                  "role": "asm_reader", "dns_resolved": False})
        self.assertEqual((stable_stat(destination), stable_stat(url), url.read_bytes()), before)
        self.assertEqual(destination.stat().st_mode & 0o7777, 0o700)
        self.assertEqual(url.stat().st_mode & 0o7777, 0o600)
        self.assertEqual(list(self.base.glob(".asm-operator-*")), [])
        with self.assertRaises(FileExistsError):
            self.reader()
        self.assertEqual(url.read_bytes(), before[2])

    def test_reader_reuse_matching_refuses_changed_url_or_resolved_address(self):
        self.reader_source()
        with patch.object(prepare, "resolve_ipv4", return_value="127.0.0.1"):
            self.reader(resolve=True)
        url = self.base / "reader/database.url"
        before = (stable_stat(url), url.read_bytes())
        with patch.object(prepare, "resolve_ipv4", return_value="127.0.0.2"), self.assertRaises(AdminError):
            self.reader(resolve=True, reuse=True)
        self.reader_source(hostaddr="127.0.0.1")
        source = self.config / "..generation_one/database.url"
        source.chmod(0o600)
        source.write_bytes(source.read_bytes().replace(b"/asm?", b"/other?"))
        source.chmod(0o440)
        with self.assertRaises(AdminError):
            self.reader(reuse=True)
        self.assertEqual((stable_stat(url), url.read_bytes()), before)
        self.assertEqual(list(self.base.glob(".asm-operator-*")), [])

    def test_reader_reuse_matching_still_validates_config_tls_dns_and_connection(self):
        self.reader_source()
        self.reader(resolve=True)
        url = self.base / "reader/database.url"
        before = (stable_stat(url), url.read_bytes())
        for operation in ("resolve_ipv4", "read_projected", "Connection"):
            with self.subTest(operation=operation), patch.object(prepare, operation, side_effect=AdminError("synthetic refusal")), \
                    self.assertRaises(AdminError):
                self.reader(resolve=True, reuse=True)
            self.assertEqual((stable_stat(url), url.read_bytes()), before)
            self.assertEqual(list(self.base.glob(".asm-operator-*")), [])
        (self.tls / "tls.key").unlink()
        with self.assertRaises((AdminError, OSError)):
            self.reader(resolve=True, reuse=True)
        self.assertEqual((stable_stat(url), url.read_bytes()), before)

    def test_reader_reuse_matching_accepts_new_valid_tls_generation(self):
        self.reader_source(hostaddr="127.0.0.1")
        self.reader()
        url = self.base / "reader/database.url"
        before = (stable_stat(url), url.read_bytes())
        generation = self.tls / "..generation_two"
        generation.mkdir(mode=0o750)
        for name in prepare.TLS_FILES.values():
            target = generation / name
            target.write_bytes((self.tls / "..generation_one" / name).read_bytes() + b"\nrotated")
            target.chmod(0o440)
        replacement = self.tls / "..next"
        replacement.symlink_to(generation.name)
        replacement.replace(self.tls / "..data")
        self.reader(reuse=True)
        self.assertEqual((stable_stat(url), url.read_bytes()), before)
        self.assertEqual(list(self.base.glob(".asm-operator-*")), [])

    def test_reader_reuse_matching_refuses_unsafe_destination_shapes_without_changes(self):
        self.reader_source(hostaddr="127.0.0.1")
        self.reader()
        valid = self.base / "reader"
        content = (valid / "database.url").read_bytes()
        for kind in ("file", "symlink", "url-symlink", "fifo", "nested", "extra", "hardlink", "directory-mode", "file-mode", "oversized", "truncated"):
            destination = self.base / kind
            if kind == "file":
                destination.write_bytes(content)
            elif kind == "symlink":
                destination.symlink_to(valid, target_is_directory=True)
            else:
                destination.mkdir(mode=0o700)
                url = destination / "database.url"
                if kind == "url-symlink":
                    url.symlink_to(valid / "database.url")
                elif kind == "fifo":
                    os.mkfifo(url, 0o600)
                elif kind == "nested":
                    url.mkdir(mode=0o700)
                elif kind == "hardlink":
                    os.link(valid / "database.url", url)
                else:
                    url.write_bytes(b"x" * 4097 if kind == "oversized" else content[:-1] if kind == "truncated" else content)
                    url.chmod(0o640 if kind == "file-mode" else 0o600)
                    if kind == "extra":
                        (destination / "keep").write_bytes(b"unrelated")
                    if kind == "directory-mode":
                        destination.chmod(0o750)
            # lstat does not follow any foreign link or block on the FIFO.
            before = stable_stat(destination, follow=False)
            with self.subTest(kind=kind), self.assertRaises((AdminError, OSError)):
                self.reader(destination, reuse=True)
            self.assertEqual(stable_stat(destination, follow=False), before)
            self.assertEqual((valid / "database.url").read_bytes(), content)
            if kind == "hardlink":
                (destination / "database.url").unlink()
            if kind == "extra":
                self.assertEqual((destination / "keep").read_bytes(), b"unrelated")
            self.assertEqual(list(self.base.glob(".asm-operator-*")), [])

    def test_reader_reuse_matching_refuses_foreign_ownership_and_acl(self):
        self.reader_source(hostaddr="127.0.0.1")
        self.reader()
        destination = self.base / "reader"
        url = destination / "database.url"
        before = (stable_stat(destination), stable_stat(url), url.read_bytes())
        real_fstat = os.fstat
        for target in (destination, url):
            inode = target.stat().st_ino
            def foreign(fd):
                info = real_fstat(fd)
                if info.st_ino == inode:
                    fields = list(info)
                    fields[4] = os.geteuid() + 1
                    return os.stat_result(fields)
                return info
            with self.subTest(target=target.name), patch.object(prepare.os, "fstat", side_effect=foreign), self.assertRaises(AdminError):
                self.reader(reuse=True)
        real_acl = prepare.reject_extended_acl
        for target in (destination, url):
            inode = target.stat().st_ino
            def grant(fd):
                if real_fstat(fd).st_ino == inode:
                    raise AdminError("synthetic ACL grant")
                return real_acl(fd)
            with self.subTest(acl=target.name), patch.object(prepare, "reject_extended_acl", side_effect=grant), self.assertRaises(AdminError):
                self.reader(reuse=True)
        self.assertEqual((stable_stat(destination), stable_stat(url), url.read_bytes()), before)
        if sys.platform == "darwin":
            for target in (destination, url):
                subprocess.run(["/bin/chmod", "+a", "everyone allow read", str(target)], check=True, timeout=5)
                try:
                    with self.subTest(real_acl=target.name), self.assertRaises(AdminError):
                        self.reader(reuse=True)
                    self.assertEqual(url.read_bytes(), before[2])
                finally:
                    subprocess.run(["/bin/chmod", "-N", str(target)], check=True, timeout=5)

    def test_reader_reuse_matching_refuses_short_or_changing_reads(self):
        self.reader_source(hostaddr="127.0.0.1")
        self.reader()
        url = self.base / "reader/database.url"
        before = (stable_stat(url), url.read_bytes())
        real_read = os.read
        inode = url.stat().st_ino
        with patch.object(prepare.os, "read", side_effect=lambda fd, maximum: real_read(fd, min(maximum, 3) if os.fstat(fd).st_ino == inode else maximum)):
            self.reader(reuse=True)
        self.assertEqual((stable_stat(url), url.read_bytes()), before)
        for kind in ("short", "changed"):
            def read(fd, maximum):
                if os.fstat(fd).st_ino == inode:
                    if kind == "short":
                        return b""
                    with url.open("r+b") as output:
                        output.write(b"x")
                return real_read(fd, maximum)
            with self.subTest(kind=kind), patch.object(prepare.os, "read", side_effect=read), self.assertRaises(AdminError):
                self.reader(reuse=True)
            self.assertEqual(url.stat().st_ino, before[0][1])
            if kind == "short":
                self.assertEqual(url.read_bytes(), before[1])
        self.assertEqual(list(self.base.glob(".asm-operator-*")), [])

    def test_reader_reuse_matching_only_handles_eexist_and_preserves_uncertain_cleanup(self):
        self.reader_source(hostaddr="127.0.0.1")
        self.reader()
        url = self.base / "reader/database.url"
        before = (stable_stat(url), url.read_bytes())
        with patch.object(prepare, "publish_snapshot", side_effect=OSError(errno.EIO, "synthetic publication error")), self.assertRaises(OSError) as error:
            self.reader(reuse=True)
        self.assertEqual(error.exception.errno, errno.EIO)
        self.assertEqual(list(self.base.glob(".asm-operator-*")), [])
        real_stat, real_publish = os.stat, prepare.publish_snapshot
        attempted = False
        def publish(*args):
            nonlocal attempted
            attempted = True
            return real_publish(*args)
        def uncertain(path, *args, **kwargs):
            if attempted and str(path).startswith(".asm-operator-"):
                raise OSError(errno.EIO, "synthetic uncertain cleanup")
            return real_stat(path, *args, **kwargs)
        with patch.object(prepare, "publish_snapshot", side_effect=publish), patch.object(prepare.os, "stat", side_effect=uncertain):
            self.reader(reuse=True)
        staged = list(self.base.glob(".asm-operator-*"))
        self.assertEqual(len(staged), 1)
        self.assertEqual((staged[0] / "database.url").read_bytes(), before[1])
        self.assertEqual((stable_stat(url), url.read_bytes()), before)

    def test_reader_postpublication_interruption_allows_explicit_matching_reentry(self):
        self.reader_source(hostaddr="127.0.0.1")
        real_publish = prepare.publish_snapshot
        def interrupted(*args):
            real_publish(*args)
            raise KeyboardInterrupt
        with patch.object(prepare, "publish_snapshot", side_effect=interrupted), self.assertRaises(KeyboardInterrupt):
            self.reader(reuse=True)
        url = self.base / "reader/database.url"
        before = (stable_stat(url), url.read_bytes())
        self.reader(reuse=True)
        self.assertEqual((stable_stat(url), url.read_bytes()), before)
        self.assertEqual(list(self.base.glob(".asm-operator-*")), [])

    def test_reader_emits_only_private_url_and_keeps_live_tls_generation_paths(self):
        self.reader_source()
        self.assertEqual(self.reader(resolve=True)["role"], "asm_reader")
        private = self.base / "reader"
        self.assertEqual({p.name for p in private.iterdir()}, {"database.url"})
        self.assertEqual(private.stat().st_mode & 0o7777, 0o700)
        self.assertEqual((private / "database.url").stat().st_mode & 0o7777, 0o600)
        options = dict(parse_qsl(urlsplit((private / "database.url").read_text()).query))
        self.assertEqual(options["hostaddr"], "127.0.0.1")
        for field, name in prepare.TLS_FILES.items():
            self.assertEqual(options[field], str(self.tls / name))
        generation = self.tls / "..generation_two"
        generation.mkdir(mode=0o750)
        for name in prepare.TLS_FILES.values():
            path = generation / name
            path.write_bytes(b"changed synthetic generation " + name.encode())
            path.chmod(0o440)
        replacement = self.tls / "..next"
        replacement.symlink_to(generation.name)
        replacement.replace(self.tls / "..data")
        for field, name in prepare.TLS_FILES.items():
            self.assertEqual(Path(options[field]).read_bytes(), b"changed synthetic generation " + name.encode())
        self.assertEqual({p.name for p in private.iterdir()}, {"database.url"})

    def test_reader_refuses_missing_or_redirected_live_tls_links(self):
        self.reader_source(hostaddr="127.0.0.1")
        link = self.tls / "tls.key"
        link.unlink()
        for target in (None, "..generation_one/tls.key", "/unrelated.key"):
            if target is not None:
                link.symlink_to(target)
            with self.subTest(target=target), self.assertRaises((AdminError, OSError)):
                self.reader()
            self.assertFalse((self.base / "reader").exists())
            if target is not None:
                link.unlink()

    def test_reader_refuses_other_authorities_and_psql_only_options_without_publication(self):
        for options in (None, {"gssencmode": "disable"}, {"connect_timeout": "2"},
                        {"ssl_min_protocol_version": "TLSv1.2"}, {"sslmode": "disable"},
                        {"sslkey": "/unrelated.key"}, {"hostaddr": "not-an-address"}):
            if options is not None:
                self.reader_source(**options)
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.reader(resolve=True)
            self.assertFalse((self.base / "reader").exists())
        self.reader_source(hostaddr="127.0.0.1")
        source = self.config / "..generation_one/database.url"
        source.chmod(0o600)
        source.write_bytes(source.read_bytes().replace(b":5432/", b":05432/"))
        source.chmod(0o440)
        with self.assertRaisesRegex(AdminError, "canonical reader port"):
            self.reader()
        self.assertFalse((self.base / "reader").exists())

    def test_reader_dns_failure_and_existing_destination_preserve_files(self):
        self.reader_source()
        with patch.object(prepare, "resolve_ipv4", side_effect=AdminError("synthetic deadline")), self.assertRaises(AdminError):
            self.reader(resolve=True)
        self.assertFalse((self.base / "reader").exists())
        destination = self.base / "reader"
        destination.mkdir()
        (destination / "keep").write_bytes(b"existing")
        with self.assertRaises(OSError):
            self.reader(resolve=True)
        self.assertEqual((destination / "keep").read_bytes(), b"existing")
        self.assertEqual({p.name for p in destination.iterdir()}, {"keep"})

    def test_reader_real_resolver_deadline_refuses_before_publication(self):
        self.reader_source()
        resolver = partial(prepare.resolve_ipv4, timeout=0.1)
        started = time.monotonic()
        with patch.object(prepare, "DNS_PROGRAM", "import time;time.sleep(2)"), \
                patch.object(prepare, "resolve_ipv4", side_effect=resolver), self.assertRaises(AdminError):
            self.reader(resolve=True)
        self.assertLess(time.monotonic() - started, 1)
        self.assertFalse((self.base / "reader").exists())

    def test_reader_rejects_tls_paths_beyond_the_native_profile_before_file_access(self):
        for path in ("/" + "x" * 1017, "/tls\t", "/tls\u00e9"):
            self.tls = Path(path)
            self.reader_source(hostaddr="127.0.0.1")
            with self.subTest(path=path), self.assertRaisesRegex(AdminError, "reader TLS path"):
                self.reader()
            self.assertFalse((self.base / "reader").exists())

    def test_reader_rejects_expanded_url_beyond_the_native_file_limit(self):
        # Percent encoding can exceed the native limit even when each decoded path fits.
        self.tls = Path("/" + " " * 500)
        self.reader_source(hostaddr="127.0.0.1")
        with self.assertRaisesRegex(AdminError, "reader connection file"):
            self.reader()
        self.assertFalse((self.base / "reader").exists())

    def test_reader_failure_removes_only_owned_staging_and_rejects_linked_projection(self):
        self.reader_source(hostaddr="127.0.0.1")
        with patch.object(prepare, "write_private", side_effect=OSError("synthetic failure")), self.assertRaises(OSError):
            self.reader()
        self.assertFalse((self.base / "reader").exists())
        self.assertFalse(list(self.base.glob(".asm-operator-*")))
        key = self.tls / "..generation_one/tls.key"
        key.unlink()
        key.symlink_to(self.psql)
        with self.assertRaises((AdminError, OSError)):
            self.reader()
        self.assertFalse((self.base / "reader").exists())

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

    def test_v2_certificate_roles_use_the_same_private_snapshot_policy(self):
        for role in ("asm_publisher", "asm_publication_worker", "asm_distributor"):
            body = source_url(self.tls, hostaddr="127.0.0.1").replace(b"asm_operator@", role.encode() + b"@")
            (self.config / "..generation_one/database.url").chmod(0o600)
            (self.config / "..generation_one/database.url").write_bytes(body)
            (self.config / "..generation_one/database.url").chmod(0o440)
            destination = self.base / role
            with self.subTest(role=role):
                result = prepare.prepare(self.config, self.tls, destination, role, self.psql)
                self.assertEqual(result["role"], role)
                self.assertEqual((destination / "tls.key").stat().st_mode & 0o7777, 0o600)
                self.assertEqual(urlsplit((destination / "database.url").read_text()).username, role)

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

    def test_real_reader_entrypoint_preserves_live_paths_and_refuses_unsafe_projections(self):
        path = os.environ.get("ASM_OPERATOR_PROJECTION_FIXTURES")
        if not path:
            self.skipTest("Requires the derived Linux image's synthetic root:GID65532 projection fixtures.")
        base = Path(path)
        with tempfile.TemporaryDirectory(prefix="asm-root-reader-") as temp:
            for case in ("valid", "wrong-owner", "wrong-gid", "bad-mode", "symlink-key", "missing-key", "escaping-generation",
                         "missing-live-key", "redirected-live-key", "wrong-live-owner", "wrong-live-gid"):
                destination = Path(temp) / case
                root = base / ("reader-" + case)
                argv = ["/usr/bin/python3", "-I", "/app/tools/operator_entrypoint.py", "prepare-reader",
                        "--config-directory", str(root / "config"), "--tls-directory", str(root / "tls"),
                        "--destination-directory", str(destination), "--resolve-dns"]
                result = subprocess.run(argv, capture_output=True, timeout=15,
                                        env={"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1"})
                with self.subTest(case=case):
                    if case == "valid":
                        self.assertEqual(result.returncode, 0, result.stderr.decode())
                        self.assertEqual(json.loads(result.stdout)["role"], "asm_reader")
                        self.assertEqual({p.name for p in destination.iterdir()}, {"database.url"})
                        self.assertEqual((destination / "database.url").stat().st_mode & 0o7777, 0o600)
                        options = dict(parse_qsl(urlsplit((destination / "database.url").read_text()).query))
                        self.assertEqual(options["hostaddr"], "127.0.0.1")
                        for field, name in prepare.TLS_FILES.items():
                            self.assertEqual(options[field], str(root / "tls" / name))
                            self.assertEqual(Path(options[field]).read_bytes(), (root / "tls/..generation_one" / name).read_bytes())
                        before = (destination / "database.url").read_bytes()
                        refused = subprocess.run(argv, capture_output=True, timeout=15)
                        self.assertEqual((refused.returncode, refused.stdout), (1, b""))
                        self.assertEqual((destination / "database.url").read_bytes(), before)
                    else:
                        self.assertEqual((result.returncode, result.stdout), (1, b""))
                        self.assertFalse(destination.exists())

    def test_real_reader_entrypoint_reuses_matching_output_and_preserves_refusals(self):
        path = os.environ.get("ASM_OPERATOR_PROJECTION_FIXTURES")
        if not path:
            self.skipTest("Requires the derived Linux image's synthetic root:GID65532 projection fixtures.")
        self.assertEqual((os.geteuid(), os.getegid()), (65532, 65532))
        base = Path(path)
        root = base / "reader-valid"
        with tempfile.TemporaryDirectory(prefix="asm-root-reader-rerun-") as temp:
            destination = Path(temp) / "reader"
            def run(*, reuse=False, source=root):
                result = subprocess.run(["/usr/bin/python3", "-I", "/app/tools/operator_entrypoint.py", "prepare-reader",
                    "--config-directory", str(source / "config"), "--tls-directory", str(source / "tls"),
                    "--destination-directory", str(destination), "--resolve-dns", *(["--reuse-matching"] if reuse else [])],
                    capture_output=True, timeout=15, env={"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1"})
                self.assertEqual(list(Path(temp).glob(".asm-operator-*")), [])
                return result
            first = run(reuse=True)
            self.assertEqual((first.returncode, first.stderr), (0, b""))
            url = destination / "database.url"
            before = (stable_stat(destination), stable_stat(url), url.read_bytes())
            second = run(reuse=True)
            self.assertEqual((second.returncode, second.stdout, second.stderr), (0, first.stdout, b""))
            self.assertEqual((stable_stat(destination), stable_stat(url), url.read_bytes()), before)
            self.assertEqual(destination.stat().st_mode & 0o7777, 0o700)
            self.assertEqual(url.stat().st_mode & 0o7777, 0o600)
            refused = run()
            self.assertEqual((refused.returncode, refused.stdout), (1, b""))
            self.assertIn(b"preparation refused", refused.stderr)
            for kind in ("changed-url", "file-mode", "directory-mode", "extra-entry", "linked-url", "symlink-url", "fifo", "oversized"):
                if kind == "changed-url":
                    url.write_bytes(before[2].replace(b"/asm?", b"/other?"))
                elif kind == "file-mode":
                    url.chmod(0o640)
                elif kind == "directory-mode":
                    destination.chmod(0o750)
                elif kind == "extra-entry":
                    (destination / "keep").write_bytes(b"unrelated")
                elif kind == "linked-url":
                    os.link(url, Path(temp) / "linked")
                elif kind == "symlink-url":
                    url.unlink()
                    url.symlink_to(root / "config/..generation_one/database.url")
                elif kind == "fifo":
                    url.unlink()
                    os.mkfifo(url, 0o600)
                else:
                    url.write_bytes(b"x" * 4097)
                current = (stable_stat(destination), stable_stat(url, follow=False))
                refused = run(reuse=True)
                with self.subTest(kind=kind):
                    self.assertEqual((refused.returncode, refused.stdout), (1, b""))
                    self.assertIn(b"preparation refused", refused.stderr)
                    self.assertEqual((stable_stat(destination), stable_stat(url, follow=False)), current)
                if kind == "extra-entry":
                    self.assertEqual((destination / "keep").read_bytes(), b"unrelated")
                    (destination / "keep").unlink()
                if kind == "linked-url":
                    (Path(temp) / "linked").unlink()
                if url.is_symlink() or kind == "fifo":
                    url.unlink()
                destination.chmod(0o700)
                url.write_bytes(before[2])
                url.chmod(0o600)
            # Even apparently matching old URL bytes cannot bypass current projection checks.
            invalid = base / "reader-bad-mode"
            url.write_bytes(before[2].replace(b"reader-valid", b"reader-bad-mode"))
            current = (stable_stat(url), url.read_bytes())
            refused = run(reuse=True, source=invalid)
            self.assertEqual((refused.returncode, refused.stdout), (1, b""))
            self.assertIn(b"preparation refused", refused.stderr)
            self.assertEqual((stable_stat(url), url.read_bytes()), current)


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
