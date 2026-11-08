"""Online projections use deterministic SYNTHETIC TEST ONLY keys in temporary files.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import prepare_operator
import prepare_signers as signers
from registry_admin import AdminError


class SigningPreparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.synthetic = tempfile.TemporaryDirectory(prefix="asm-SYNTHETIC-online-keys-")
        cls.addClassCleanup(cls.synthetic.cleanup)
        cls.fixture = Path(cls.synthetic.name).resolve()
        cls.trust = Path(os.environ.get("ASM_TEST_TRUST_TOOL", str(cls.fixture / "asm-trust")))
        if not os.environ.get("ASM_TEST_TRUST_TOOL"):
            subprocess.run(["go", "build", "-trimpath", "-o", str(cls.trust), "./cmd/asm-trust"],
                           cwd=ROOT / "verifier", check=True, capture_output=True, timeout=180)
        cls.online = ("targets", "snapshot", "timestamp")
        cls.names = ("root1", "root2", "root3", *cls.online)
        for name in cls.names:
            private, public = cls.fixture / (name + ".pem"), cls.fixture / (name + ".pub")
            # RFC 8410 PKCS8 test container with an explicitly labelled fixed
            # seed. OpenSSL performs all key parsing and public-key derivation.
            seed = hashlib.sha256(("ASM SYNTHETIC ONLINE PROJECTION TEST ONLY " + name).encode()).digest()
            encoded = cls.fixture / (name + ".der")
            encoded.write_bytes(bytes.fromhex("302e020100300506032b657004220420") + seed)
            encoded.chmod(0o600)
            subprocess.run(["openssl", "pkey", "-inform", "DER", "-in", str(encoded), "-out", str(private)],
                           check=True, capture_output=True, timeout=10)
            private.chmod(0o600)
            subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)],
                           check=True, capture_output=True, timeout=10)
        unsigned, one, root = (cls.fixture / name for name in ("unsigned.json", "one.json", "root.json"))
        for arguments in (["prepare-root", str(unsigned), *(str(cls.fixture / (n + ".pub")) for n in cls.names)],
                          ["sign-root", str(unsigned), str(cls.fixture / "root1.pem"), str(one)],
                          ["sign-root", str(one), str(cls.fixture / "root2.pem"), str(root)]):
            subprocess.run([str(cls.trust), *arguments], check=True, capture_output=True, timeout=10)
        alternative = ("root1", "root2", "root3", "timestamp", "snapshot", "targets")
        for arguments in (["prepare-root", str(cls.fixture / "alternate-unsigned.json"),
                           *(str(cls.fixture / (n + ".pub")) for n in alternative)],
                          ["sign-root", str(cls.fixture / "alternate-unsigned.json"), str(cls.fixture / "root1.pem"),
                           str(cls.fixture / "alternate-one.json")],
                          ["sign-root", str(cls.fixture / "alternate-one.json"), str(cls.fixture / "root2.pem"),
                           str(cls.fixture / "alternate-root.json")]):
            subprocess.run([str(cls.trust), *arguments], check=True, capture_output=True, timeout=10)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asm-SYNTHETIC-signing-snapshot-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.source = self.base / "projection"
        self.source.mkdir(mode=0o750)
        self.generation = self.source / "..generation_one"
        self.generation.mkdir(mode=0o750)
        for role in self.online:
            destination = self.generation / (role + ".pem")
            destination.write_bytes((self.fixture / (role + ".pem")).read_bytes())
            destination.chmod(0o440)
        (self.source / "..data").symlink_to(self.generation.name)
        self.root = self.base / "root.json"
        self.root.write_bytes((self.fixture / "root.json").read_bytes())
        self.root.chmod(0o600)
        self.authority = patch.multiple(prepare_operator, SOURCE_UID=os.geteuid(), SOURCE_GID=os.getegid())
        self.authority.start()
        self.addCleanup(self.authority.stop)
        # macOS source fixtures exercise descriptors and crypto. Actual Linux
        # tmpfs and root:GID65532 policy remains a separate restricted-Pod gate.
        self.memory = patch.object(signers, "require_memory_parent")
        self.memory.start()
        self.addCleanup(self.memory.stop)

    def snapshot(self, destination=None):
        return signers.prepare(self.source, self.root, destination or self.base / "private", self.trust)

    def assert_no_snapshot(self):
        self.assertFalse((self.base / "private").exists())
        self.assertEqual(list(self.base.glob(".asm-signers-*")), [])

    def test_complete_private_snapshot_matches_selected_public_root(self):
        result = self.snapshot()
        directory = self.base / "private"
        self.assertEqual(result["status"], "prepared")
        self.assertEqual(result["root_sha256"], hashlib.sha256(self.root.read_bytes()).hexdigest())
        self.assertEqual({p.name for p in directory.iterdir()}, {r + ".pem" for r in self.online})
        self.assertEqual(directory.stat().st_mode & 0o7777, 0o700)
        for role in self.online:
            key = directory / (role + ".pem")
            self.assertEqual(key.read_bytes(), (self.fixture / key.name).read_bytes())
            self.assertEqual(key.stat().st_mode & 0o7777, 0o600)
            self.assertEqual(key.stat().st_uid, os.geteuid())
        subprocess.run([str(self.trust), "check-online-keys", str(self.root), str(directory)],
                       check=True, capture_output=True, timeout=10)

    def root_projection(self):
        projected = self.base / "root-projection"
        projected.mkdir(mode=0o750)
        generation = projected / "..generation_one"
        generation.mkdir(mode=0o750)
        root = generation / "registry-root.json"
        root.write_bytes(self.root.read_bytes())
        root.chmod(0o440)
        (projected / "..data").symlink_to(generation.name)
        # Normal AtomicWriter convenience links are never opened directly.
        (projected / "registry-root.json").symlink_to("..data/registry-root.json")
        return projected

    def test_projected_public_root_pins_one_generation_and_matches_the_online_keys(self):
        projected = self.root_projection()
        original = prepare_operator.read_projected
        second = projected / "..generation_two"
        second.mkdir(mode=0o750)
        replacement = second / "registry-root.json"
        replacement.write_bytes((self.fixture / "alternate-root.json").read_bytes())
        replacement.chmod(0o440)
        def rotate(fd, name, maximum):
            body = original(fd, name, maximum)
            if name == "registry-root.json":
                (projected / "..data").unlink()
                (projected / "..data").symlink_to(second.name)
            return body
        with patch.object(prepare_operator, "read_projected", side_effect=rotate):
            result = signers.prepare(self.source, None, self.base / "private", self.trust,
                                     trust_root_directory=projected)
        self.assertEqual(result["root_sha256"], hashlib.sha256(self.root.read_bytes()).hexdigest())
        # The new public root assigns other role keys. Do not mix generations.
        with self.assertRaises(AdminError):
            signers.prepare(self.source, None, self.base / "mismatch", self.trust, trust_root_directory=projected)
        self.assertFalse((self.base / "mismatch").exists())
        self.assertEqual((self.base / "private/targets.pem").read_bytes(), (self.fixture / "targets.pem").read_bytes())

    def test_raw_public_root_symlink_and_extra_projected_names_are_refused(self):
        projected = self.root_projection()
        with self.assertRaises((AdminError, OSError)):
            signers.prepare(self.source, projected / "registry-root.json", self.base / "raw", self.trust)
        self.assertFalse((self.base / "raw").exists())
        extra = projected / "..generation_one/unexpected.json"
        extra.write_bytes(b"SYNTHETIC UNSELECTED PUBLIC ROOT")
        extra.chmod(0o440)
        with self.assertRaises((AdminError, OSError)):
            signers.prepare(self.source, None, self.base / "private", self.trust, trust_root_directory=projected)
        self.assert_no_snapshot()

    def test_bad_roles_root_keys_extra_files_and_wrong_root_preserve_destination(self):
        for case in ("wrong-role", "root-key", "extra-root", "wrong-root"):
            with self.subTest(case=case):
                key = self.generation / "targets.pem"
                key.chmod(0o600)
                key.write_bytes((self.fixture / ("root1.pem" if case == "root-key" else
                                               "snapshot.pem" if case == "wrong-role" else "targets.pem")).read_bytes())
                key.chmod(0o440)
                if case == "extra-root":
                    extra = self.generation / "root.pem"
                    extra.write_bytes(b"SYNTHETIC ROOT MATERIAL MUST BE REFUSED")
                    extra.chmod(0o440)
                if case == "wrong-root":
                    self.root.write_bytes(b'{"signed":{},"signatures":[]}')
                with self.assertRaises((AdminError, OSError)):
                    self.snapshot()
                self.assert_no_snapshot()
                (self.generation / "root.pem").unlink(missing_ok=True)

    def test_projected_modes_symlinks_hardlinks_and_bounds_are_refused(self):
        key = self.generation / "targets.pem"
        body = key.read_bytes()
        for case in ("mode", "symlink", "hardlink", "empty", "oversized", "owner"):
            with self.subTest(case=case):
                key.unlink()
                key.write_bytes(body)
                key.chmod(0o440)
                if case == "mode":
                    key.chmod(0o444)
                elif case == "symlink":
                    key.unlink()
                    key.symlink_to(self.fixture / "targets.pem")
                elif case == "hardlink":
                    os.link(key, self.base / "second-link")
                elif case in ("empty", "oversized"):
                    key.chmod(0o600)
                    key.write_bytes(b"" if case == "empty" else b"x" * 16385)
                    key.chmod(0o440)
                with patch.object(prepare_operator, "SOURCE_UID", -1 if case == "owner" else os.geteuid()):
                    with self.assertRaises((AdminError, OSError)):
                        self.snapshot()
                self.assert_no_snapshot()
                (self.base / "second-link").unlink(missing_ok=True)

    def test_existing_and_late_destinations_are_never_replaced(self):
        directory = self.base / "private"
        directory.mkdir()
        (directory / "keep").write_bytes(b"unrelated")
        with self.assertRaises((AdminError, OSError)):
            self.snapshot()
        self.assertEqual((directory / "keep").read_bytes(), b"unrelated")
        real_publish = prepare_operator.publish_snapshot
        def insert(parent, staging, name):
            target = self.base / name
            target.symlink_to(directory, target_is_directory=True)
            real_publish(parent, staging, name)
        with patch.object(prepare_operator, "publish_snapshot", side_effect=insert):
            with self.assertRaises((AdminError, OSError)):
                self.snapshot(self.base / "late")
        self.assertTrue((self.base / "late").is_symlink())
        self.assertEqual((directory / "keep").read_bytes(), b"unrelated")

    def test_rotation_pins_one_generation_and_requires_a_new_destination(self):
        second = self.source / "..generation_two"
        shutil.copytree(self.generation, second)
        for role in self.online:
            key = second / (role + ".pem")
            key.chmod(0o600)
            key.write_bytes((self.fixture / "root1.pem").read_bytes())
            key.chmod(0o440)
        real_read = prepare_operator.read_projected
        rotated = False
        def rotate(fd, name, maximum):
            nonlocal rotated
            body = real_read(fd, name, maximum)
            if name == "targets.pem" and not rotated:
                rotated = True
                (self.source / "..data").unlink()
                (self.source / "..data").symlink_to(second.name)
            return body
        with patch.object(prepare_operator, "read_projected", side_effect=rotate):
            self.snapshot()
        self.assertEqual((self.base / "private/snapshot.pem").read_bytes(), (self.fixture / "snapshot.pem").read_bytes())
        previous = (self.base / "private/targets.pem").read_bytes()
        with self.assertRaises((AdminError, OSError)):
            self.snapshot()
        self.assertEqual((self.base / "private/targets.pem").read_bytes(), previous)
        with self.assertRaises((AdminError, OSError)):
            self.snapshot(self.base / "rotated")
        self.assertFalse((self.base / "rotated").exists())

    def test_generation_or_key_removal_during_snapshot_exposes_no_partial_result(self):
        original = prepare_operator.read_projected
        def remove(fd, name, maximum):
            body = original(fd, name, maximum)
            if name == "targets.pem":
                (self.generation / "snapshot.pem").unlink()
            return body
        with patch.object(prepare_operator, "read_projected", side_effect=remove):
            with self.assertRaises((AdminError, OSError)):
                self.snapshot()
        self.assert_no_snapshot()

    def test_non_memory_destination_is_refused_before_any_private_write(self):
        with patch.object(signers, "require_memory_parent", side_effect=AdminError("not a memory mount")):
            with self.assertRaises(AdminError):
                self.snapshot()
        self.assert_no_snapshot()


class RealSigningProjectionImageTests(unittest.TestCase):
    def test_real_projected_signers_use_tmpfs_and_preserve_destinations_on_refusal(self):
        fixture = os.environ.get("ASM_OPERATOR_PROJECTION_FIXTURES")
        if not fixture:
            self.skipTest("Requires the derived Linux image's synthetic root:GID65532 signing projection fixtures.")
        self.assertEqual(sys.platform, "linux")
        self.assertEqual((os.geteuid(), os.getegid()), (65532, 65532))
        base = Path(fixture)
        with tempfile.TemporaryDirectory(prefix="asm-SYNTHETIC-real-signers-", dir="/tmp") as name:
            parent = Path(name)
            fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                signers.require_memory_parent(fd)
            finally:
                os.close(fd)

            def prepare(case, destination):
                return subprocess.run(["/usr/bin/python3", "-I", "/app/tools/operator_entrypoint.py", "prepare-signers",
                    "--keys-directory", str(base / case / "keys"),
                    "--trust-root-directory", str(base / case / "root"),
                    "--destination-directory", str(destination)], capture_output=True, timeout=25,
                    env={"PATH": os.defpath, "PYTHONDONTWRITEBYTECODE": "1"})

            destination = parent / "private"
            result = prepare("signers-valid", destination)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            receipt = json.loads(result.stdout)
            root = base / "signers-valid/root/..generation_one/registry-root.json"
            self.assertEqual(receipt["root_sha256"], hashlib.sha256(root.read_bytes()).hexdigest())
            self.assertEqual({p.name for p in destination.iterdir()}, set(signers.KEYS))
            self.assertEqual((destination.stat().st_uid, destination.stat().st_mode & 0o7777), (65532, 0o700))
            original = {}
            for key in signers.KEYS:
                path = destination / key
                info = path.stat()
                self.assertEqual((info.st_uid, info.st_nlink, info.st_mode & 0o7777), (65532, 1, 0o600))
                original[key] = path.read_bytes()
                self.assertEqual(original[key], (base / "signers-valid/keys/..generation_one" / key).read_bytes())
            # The maintained parser derives each public-key ID from the actual
            # private output and checks its authorized role in the public root.
            checked = subprocess.run(["/app/bin/asm-trust", "check-online-keys", str(root), str(destination)],
                                     capture_output=True, timeout=20)
            self.assertEqual(checked.returncode, 0, checked.stderr.decode())
            self.assertEqual(checked.stdout, b"")
            repeated = prepare("signers-valid", destination)
            self.assertEqual(repeated.returncode, 1)
            self.assertEqual(repeated.stdout, b"")
            self.assertIn(b"preparation refused", repeated.stderr)
            self.assertEqual({p.name: p.read_bytes() for p in destination.iterdir()}, original)
            for case in ("signers-wrong-role", "signers-symlink-key", "signers-bad-mode"):
                with self.subTest(case=case):
                    refused = parent / case
                    result = prepare(case, refused)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stdout, b"")
                    self.assertIn(b"preparation refused", result.stderr)
                    self.assertFalse(refused.exists())
                    self.assertEqual({p.name: p.read_bytes() for p in destination.iterdir()}, original)
            self.assertEqual(list(parent.glob(".asm-signers-*")), [])


if __name__ == "__main__":
    unittest.main()
