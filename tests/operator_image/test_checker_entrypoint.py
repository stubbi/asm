"""A checker image binds its receipt to immutable source and fixed input paths.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import contextlib
import io
import hashlib
from pathlib import Path
import subprocess
import sys
import unittest
import tempfile
import resource
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))


class CheckerEntrypointTests(unittest.TestCase):
    def test_ordinary_source_policy_command_does_not_require_process_limit_support(self):
        program = '''import builtins, sys
sys.path.insert(0, sys.argv[1])
original = builtins.__import__
def without_resource(name, *args, **kwargs):
    if name == "resource":
        raise ImportError("resource unavailable on this source host")
    return original(name, *args, **kwargs)
builtins.__import__ = without_resource
import publication_check
raise SystemExit(publication_check.main(["policy"]))
'''
        result = subprocess.run([sys.executable, "-I", "-c", program, str(ROOT / "tools")],
                                capture_output=True, timeout=5)
        self.assertEqual((result.returncode, result.stderr), (0, b""))
        self.assertRegex(result.stdout.decode(), r"^[0-9a-f]{64}\n$")

    def isolated(self, body):
        # Linux uses real procfs and no_new_privs. macOS has no Linux procfs;
        # only that unavailable mechanism is substituted, never set/getrlimit.
        program = '''import sys, os, resource, json
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, sys.argv[1])
import checker_entrypoint as entry
import publication_check as checker
if sys.platform == "linux":
    import ctypes
    if os.getuid() == 0:
        os.setgroups([])
        os.setgid(65532)
        os.setuid(65532)
    assert ctypes.CDLL(None).prctl(38, 1, 0, 0, 0) == 0
else:
    status = "Uid:\\t501\\t501\\t501\\t501\\nCapInh:\\t0\\nCapPrm:\\t0\\nCapEff:\\t0\\nCapAmb:\\t0\\nNoNewPrivs:\\t1\\n"
    patch.object(checker, "_checker_status", return_value=status, create=True).start()
''' + body
        return subprocess.run([sys.executable, "-I", "-c", program, str(ROOT / "tools")],
                              capture_output=True, timeout=5)

    def test_image_sets_exact_limit_before_source_access_and_cannot_raise_it(self):
        before = resource.getrlimit(resource.RLIMIT_NPROC)
        result = self.isolated('''
def observed():
    print(json.dumps(list(resource.getrlimit(resource.RLIMIT_NPROC))))
    try:
        resource.setrlimit(resource.RLIMIT_NPROC, (17, 17))
    except (ValueError, OSError):
        raise SystemExit(0)
    raise SystemExit(7)
entry.source_revision = observed
raise SystemExit(entry.main(["--task", "a" * 32]))
''')
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"[16, 16]\n", b""))
        self.assertEqual(resource.getrlimit(resource.RLIMIT_NPROC), before)

    def test_refused_setup_does_not_access_source_or_task_inputs(self):
        result = self.isolated('''
resource.setrlimit(resource.RLIMIT_NPROC, (8, 8))
def forbidden(*args):
    print("UNEXPECTED INPUT ACCESS")
    raise SystemExit(9)
entry.source_revision = forbidden
checker.check = forbidden
raise SystemExit(entry.main(["--task", "a" * 32]))
''')
        self.assertEqual((result.returncode, result.stdout), (1, b""))
        self.assertEqual(result.stderr, b"Asm checker: task limit is unavailable. Use a qualified isolated runtime.\n")

    def test_privilege_bypass_or_failed_readback_refuses_before_source_access(self):
        status = "Uid: 501 501 501 501\nCapInh: 0\nCapPrm: 0\nCapEff: 0\nCapAmb: 0\nNoNewPrivs: 1\n"
        invalid = [status.replace("501 501 501 501", value) for value in ("0 0 0 0", "501 0 501 501")]
        invalid.extend(status.replace(field + ": 0", field + ": 1000000")
                       for field in ("CapInh", "CapPrm", "CapEff", "CapAmb"))
        invalid.append(status.replace("NoNewPrivs: 1", "NoNewPrivs: 0"))
        setups = [f'patch.object(checker, "_checker_status", return_value={value!r}).start()' for value in invalid]
        setups.extend(('patch.object(resource, "getrlimit", return_value=(16, 17)).start()',
                       'patch.object(resource, "getrlimit", side_effect=OSError("private detail")).start()',
                       'patch.object(checker, "_checker_status", side_effect=OSError("private detail")).start()'))
        for setup in setups:
            with self.subTest(setup=setup):
                result = self.isolated(setup + '''
def forbidden(*args):
    print("UNEXPECTED INPUT ACCESS")
    raise SystemExit(9)
entry.source_revision = forbidden
checker.check = forbidden
raise SystemExit(entry.main(["--task", "a" * 32]))
''')
                self.assertEqual((result.returncode, result.stdout), (1, b""))
                self.assertEqual(result.stderr, b"Asm checker: task limit is unavailable. Use a qualified isolated runtime.\n")

    def test_checked_receipt_binds_source_and_corrupt_inputs_preserve_bytes(self):
        import checker_entrypoint
        import registry
        import publication_check
        with tempfile.TemporaryDirectory(prefix="asm-checker-entrypoint-") as directory:
            root = Path(directory).resolve()
            objects = root / "objects"
            objects.mkdir(mode=0o700)
            archive = registry.make_archive({"asm.toml": (b'[package]\nname="hello"\nversion="1.0.0"\n'
                b'[target.x86_64-linux]\nsource="src/main.s"\n', 0o644),
                "src/main.s": (b".global _start\n_start: nop\n", 0o644),
                "LICENSE": (b"Synthetic MIT fixture\n", 0o644), "README.md": (b"Fixture\n", 0o644)})
            digest, task = hashlib.sha256(archive).hexdigest(), "a" * 32
            value = {"schema": 2, "owner_id": "b" * 32, "name": "example/hello", "version": "1.0.0",
                "summary": "Synthetic image entrypoint fixture.", "license": "MIT", "source": {
                "commit": {"algorithm": "git-sha1", "digest": "c" * 40}, "path": ".",
                "archive": {"sha256": digest, "bytes": len(archive)}}, "artifacts": [{"kind": "source",
                "format": "tar.gz", "isa": "x86_64", "os": "linux", "abi": "sysv-amd64", "cpu_features": [],
                "sha256": digest, "bytes": len(archive)}]}
            raw = registry.json_bytes(value)
            (root / "manifest.json").write_bytes(raw)
            (root / "manifest.json").chmod(0o600)
            object_file = objects / (task + "-" + digest)
            object_file.write_bytes(archive)
            object_file.chmod(0o600)
            for corrupt, outcome in ((False, "pass"), (True, "error")):
                if corrupt:
                    object_file.write_bytes(b"!" + archive[1:])
                before = object_file.read_bytes()
                output = io.BytesIO()
                with patch.object(checker_entrypoint, "INPUT", root, create=True), \
                        patch.object(publication_check, "restrict_guest_tasks"), \
                        patch.object(checker_entrypoint, "source_revision", return_value="d" * 40), \
                        patch.object(sys, "stdout", SimpleNamespace(buffer=output)):
                    self.assertEqual(checker_entrypoint.main(["--task", task]), 0)
                receipt = registry.strict_json(output.getvalue())
                self.assertEqual(receipt["checker_revision"], "d" * 40)
                self.assertEqual(receipt["manifest_sha256"], hashlib.sha256(raw).hexdigest())
                self.assertEqual(receipt["policy_sha256"], publication_check.policy_digest())
                self.assertEqual(receipt["outcome"], outcome)
                self.assertEqual(object_file.read_bytes(), before)

    def test_help_is_available_without_inputs_and_overrides_fail(self):
        script = ROOT / "tools/checker_entrypoint.py"
        helped = subprocess.run([sys.executable, "-I", str(script), "--help"], capture_output=True, timeout=5)
        self.assertEqual(helped.returncode, 0, helped.stderr.decode())
        self.assertIn(b"--task", helped.stdout)
        for option in ("--manifest", "--objects", "--checker-revision", "--command"):
            result = subprocess.run([sys.executable, "-I", str(script), "--task", "a" * 32, option, "/untrusted"],
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, b"")

    def test_an_absent_image_source_marker_refuses_before_reading_input(self):
        import checker_entrypoint
        import image_source
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(image_source, "SOURCE", Path("/absent-image-source-marker")), \
                patch("publication_check.restrict_guest_tasks"), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(checker_entrypoint.main(["--task", "a" * 32]), 1)
        self.assertEqual(output.getvalue(), "")
        self.assertIn("image source", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
