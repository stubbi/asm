"""Native self-update tests with deterministic transport/verifier fixtures.

The test-only source copy changes two fixed tool paths. No runtime override is
added to Asm. The fixtures check real child argv and the explicit environment.
These tests do not claim to perform Sigstore cryptographic verification.
The oversized-write fixture ignores curl's size flag and uses real file writes.
It tests the kernel limit independently of HTTP or a specific curl version.
"""

import hashlib
import json
import os
from pathlib import Path
import resource
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from host import IS_MACOS, TARGET, OTHER_TARGET, IS_ARM64, IS_RISCV64, ASM_FLAGS, CLI_ASM_FLAGS, CLI_SOURCE, CLI_DIRECTORY
from host import SYS_RENAMEAT, SYS_SIGPROCMASK, SYS_GETRLIMIT, SYS_SETRLIMIT, program


ROOT = Path(__file__).resolve().parents[1]
CURRENT = json.loads((ROOT / "cli/commands.json").read_text())["version"]
NEXT = f"{int(CURRENT.split('.')[0]) + 1}.10.0"
HELD_FIXTURE_READY_SECONDS = 30
OLDER = "0.0.0"
COMMIT = "a" * 40
INDEX = "https://asm.build/registry/v1/index-macos.tsv" if IS_MACOS else "https://asm.build/registry/v1/index.tsv"
IDENTITY = "https://github.com/stubbi/asm/.github/workflows/release.yml@refs/heads/main"
REPO_ID = "1441332955"
BUNDLE = "release-attestation.sigstore.json"

def deny_syscall(number):
    """Inject a real kernel EACCES at one syscall; no production hook."""
    import ctypes
    import errno

    class Filter(ctypes.Structure):
        _fields_ = [("code", ctypes.c_ushort), ("jt", ctypes.c_ubyte),
                    ("jf", ctypes.c_ubyte), ("value", ctypes.c_uint)]

    class Program(ctypes.Structure):
        _fields_ = [("length", ctypes.c_ushort), ("filters", ctypes.POINTER(Filter))]

    filters = (Filter * 4)(
        Filter(0x20, 0, 0, 0),       # Load syscall number.
        Filter(0x15, 0, 1, number),
        Filter(0x06, 0, 0, 0x00050000 | errno.EACCES),
        Filter(0x06, 0, 0, 0x7FFF0000),
    )
    program = Program(4, filters)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(38, 1, 0, 0, 0) or libc.prctl(22, 2, ctypes.byref(program)):
        raise OSError(ctypes.get_errno(), "cannot install the test syscall filter")


def deny_renameat():
    deny_syscall(SYS_RENAMEAT)


def deny_sigprocmask():
    deny_syscall(SYS_SIGPROCMASK)


def become(uid):
    """Demote only the test child; do not change the test runner or accounts."""
    def apply():
        os.setgroups([])
        os.setgid(uid)
        os.setuid(uid)
    return apply


TRANSPORT = r'''
import json, os, pathlib, resource, signal, socket, sys, time
root = pathlib.Path(__file__).resolve().parent
state = json.loads((root / "state.json").read_text())
args = sys.argv[1:]
def option(name):
    return args[args.index(name) + 1]
assert args[0] == "--disable"
assert option("--proto") == "=https"
assert option("--proto-redir") == "=https"
assert args[-2] == "--"
url = args[-1]
# Record through a separate test-only logger. A tiny artifact cap must not
# constrain the fixture's cumulative diagnostic file and change its behavior.
with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as log:
    log.connect(str(root / "calls.sock"))
    log.sendall(json.dumps({"tool": "curl", "args": args, "env": dict(os.environ),
                           "fsize_limit": resource.getrlimit(resource.RLIMIT_FSIZE),
                           "nofile_limit": resource.getrlimit(resource.RLIMIT_NOFILE)}).encode())
    assert log.recv(2) == b"ok"
if state.get("hold") and url == state["index_url"]:
    (root / "entered").write_text("ready")
    deadline = time.monotonic() + 8
    while not (root / "continue").exists():
        if time.monotonic() >= deadline:
            sys.exit(28)
        time.sleep(0.01)
if state.get("network_failure"):
    sys.exit(22)
if url == state.get("stream_url"):
    # Do not inspect --max-filesize in this branch. Stream past the requested
    # bound and record the kernel's actual result while ignoring SIGXFSZ.
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
    destination = pathlib.Path(option("--output"))
    target = state["stream_bytes"]
    written = 0
    error = None
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        while written < target:
            written += os.write(fd, b"x" * min(32768, target - written))
    except OSError as failure:
        error = failure.errno
    finally:
        os.close(fd)
    (root / "stream-result.json").write_text(json.dumps({
        "url": url, "requested_write_bytes": target, "written_bytes": written,
        "file_bytes": destination.stat().st_size, "errno": error,
        "fsize_limit": resource.getrlimit(resource.RLIMIT_FSIZE),
    }))
    sys.exit(23 if error is not None else 0)
entry = state["downloads"].get(url)
if entry is None:
    sys.exit(22)
data = (root / entry).read_bytes()
if len(data) > int(option("--max-filesize")):
    sys.exit(63)
pathlib.Path(option("--output")).write_bytes(data)
'''


CALL_LOGGER = r'''
import json, pathlib, socket, sys
root = pathlib.Path(sys.argv[1])
with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as server:
    server.bind(str(root / "calls.sock"))
    server.listen(4)
    print("ready", flush=True)
    while True:
        connection, _ = server.accept()
        with connection:
            data = connection.recv(65537)
            assert 0 < len(data) <= 65536
            record = json.loads(data)
            with (root / "calls.jsonl").open("a") as out:
                out.write(json.dumps(record) + "\n")
            connection.sendall(b"ok")
'''


VERIFIER = r'''
import json, os, pathlib, resource, sys, time
root = pathlib.Path(__file__).resolve().parent
state = json.loads((root / "state.json").read_text())
args = sys.argv[1:]
allowed = {"HOME", "GH_CONFIG_DIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME",
           "GH_HOST", "GH_PROMPT_DISABLED", "GH_NO_UPDATE_NOTIFIER",
           "GH_NO_EXTENSION_UPDATE_NOTIFIER", "LC_ALL", "LANG",
           "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy",
           "NO_PROXY", "no_proxy", "ALL_PROXY", "all_proxy"}
assert set(os.environ) <= allowed, dict(os.environ)
assert os.environ["GH_HOST"] == "github.com"
assert os.environ["GH_PROMPT_DISABLED"] == "1"
assert ".asm-registry-" in os.environ["HOME"]
assert os.environ["HOME"] == os.environ["GH_CONFIG_DIR"]
assert pathlib.Path(os.environ["HOME"]).is_dir()
with (root / "calls.jsonl").open("a") as out:
    out.write(json.dumps({"tool": "gh", "args": args, "env": dict(os.environ),
                          "fsize_limit": resource.getrlimit(resource.RLIMIT_FSIZE),
                          "nofile_limit": resource.getrlimit(resource.RLIMIT_NOFILE)}) + "\n")
if state.get("cache_probe_bytes"):
    cache = pathlib.Path(os.environ["HOME"]) / "cache-size-probe"
    cache.write_bytes(b"c" * state["cache_probe_bytes"])
    assert cache.stat().st_size == state["cache_probe_bytes"]
if args == ["--version"]:
    if state.get("version_delay"):
        time.sleep(state["version_delay"])
        (root / "verifier-delay-finished").write_text("completed")
    print("gh version " + state.get("gh_version", "2.93.0") + " (test fixture)")
    sys.exit(0)
assert args[:2] == ["attestation", "verify"]
def option(name):
    return args[args.index(name) + 1]
assert option("--repo") == "stubbi/asm"
assert option("--cert-identity") == state["identity"]
assert option("--cert-oidc-issuer") == "https://token.actions.githubusercontent.com"
assert option("--source-ref") == "refs/heads/main"
assert "--deny-self-hosted-runners" in args
assert option("--predicate-type") == "https://slsa.dev/provenance/v1"
assert option("--hostname") == "github.com"
assert option("--format") == "json"
assert option("--jq") == ".[].verificationResult.signature.certificate.sourceRepositoryIdentifier"
assert pathlib.Path(option("--bundle")).read_bytes() == b"test-only signed bundle fixture\n"
assert "--custom-trusted-root" not in args
artifact = pathlib.Path(args[2])
assert artifact.is_file()
if "--source-digest" in args:
    if option("--source-digest") != state["signed_commit"]:
        sys.exit(1)
    assert option("--signer-digest") == state["signed_commit"]
    if artifact.name == "payload":
        assert artifact.read_bytes() == (root / "artifact").read_bytes()
else:
    assert artifact.name == "release.json"
if state.get("hold_verifier") and artifact.name == "payload":
    (root / "entered-verifier").write_text("ready")
    deadline = time.monotonic() + 8
    while not (root / "continue-verifier").exists():
        if time.monotonic() >= deadline:
            sys.exit(1)
        time.sleep(0.01)
if state.get("verification_failure"):
    sys.exit(1)
sys.stdout.write(state.get("repository_output", "1441332955\n"))
'''


class SelfUpdateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Use the OS temporary filesystem: the test exercises native inode and
        # rename semantics, not a development workspace's synchronization layer.
        cls.suite_temp = tempfile.TemporaryDirectory(prefix="asm-self-update-suite-", dir="/tmp")
        cls.fixture = Path(cls.suite_temp.name)
        # Use a separate process, not a thread: several tests require a
        # bounded preexec_fn, which must not fork a multithreaded test runner.
        cls.logger = subprocess.Popen(
            [sys.executable, "-u", "-c", CALL_LOGGER, str(cls.fixture)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        ready, _, _ = select.select([cls.logger.stdout], [], [], 5)
        if not ready or cls.logger.stdout.readline() != "ready\n":
            cls.logger.kill()
            stdout, stderr = cls.logger.communicate(timeout=5)
            cls.suite_temp.cleanup()
            raise RuntimeError(("fixture logger did not start", stdout, stderr))
        cls.source = cls.fixture / "source"
        shutil.copytree(ROOT / "cli", cls.source / "cli")
        for name, body in (("curl-fixture", TRANSPORT), ("gh-fixture", VERIFIER)):
            path = cls.fixture / name
            path.write_text(f"#!{sys.executable}\n" + body)
            path.chmod(0o755)
        source_directory = cls.source / CLI_DIRECTORY.relative_to(ROOT)
        registry = source_directory / "registry.s"
        registry.write_text(registry.read_text().replace(
            'registry_curl: .asciz "/usr/bin/curl"',
            f'registry_curl: .asciz "{cls.fixture}/curl-fixture"'))
        verifier = source_directory / "self_update_verify.s"
        verifier.write_text(verifier.read_text().replace(
            'self_gh_path: .asciz "/usr/bin/gh"',
            f'self_gh_path: .asciz "{cls.fixture}/gh-fixture"'))
        cls.original_source = (cls.source / CLI_SOURCE).read_text()
        cls.current_bytes = cls.compile_version(CURRENT)
        cls.next_bytes = cls.compile_version(NEXT)
        # Change only the named deadline in an isolated fixture build. The
        # signal disposition, mask, child capture, and failure paths stay real.
        original_verifier = verifier.read_text()
        deadline = ".equ SELF_VERIFIER_DEADLINE_SECONDS, 120"
        assert original_verifier.count(deadline) == 1
        verifier.write_text(original_verifier.replace(
            deadline, ".equ SELF_VERIFIER_DEADLINE_SECONDS, 1"))
        try:
            cls.short_deadline_bytes = cls.compile_version(CURRENT)
        finally:
            verifier.write_text(original_verifier)
        (cls.source / CLI_SOURCE).write_text(cls.original_source)

    @classmethod
    def tearDownClass(cls):
        cls.logger.terminate()
        _, stderr = cls.logger.communicate(timeout=5)
        cls.suite_temp.cleanup()
        if stderr:
            raise RuntimeError(("fixture logger failed", stderr))

    @classmethod
    def compile_version(cls, version):
        (cls.source / CLI_SOURCE).write_text(cls.original_source.replace(CURRENT, version))
        subprocess.run(["as", *CLI_ASM_FLAGS, "--fatal-warnings", "-o", "asm.o", CLI_SOURCE],
                       cwd=cls.source, check=True, capture_output=True)
        subprocess.run(["ld", "-z", "noexecstack", "-z", "relro", "-z", "now",
                        "--build-id=none", "-o", "asm", "asm.o"],
                       cwd=cls.source, check=True, capture_output=True)
        return (cls.source / "asm").read_bytes()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="case-", dir=self.fixture)
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.home = self.work / "home with spaces"
        self.bin_dir = self.home / ".local/bin"
        self.bin_dir.mkdir(parents=True)
        self.installed = self.bin_dir / "asm"
        self.installed.write_bytes(self.current_bytes)
        self.installed.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home),
                        GH_TOKEN="test-secret-must-not-reach-tools",
                        GH_HOST="untrusted.invalid", GH_CONFIG_DIR="/untrusted",
                        CURL_CA_BUNDLE="/untrusted", HTTPS_PROXY="https://untrusted.invalid")
        for key in ("HTTP_PROXY", "http_proxy", "https_proxy", "NO_PROXY", "no_proxy", "ALL_PROXY", "all_proxy"):
            self.env.pop(key, None)
        for name in ("calls.jsonl", "entered", "continue", "entered-verifier",
                     "continue-verifier", "verifier-delay-finished", "stream-result.json"):
            (self.fixture / name).unlink(missing_ok=True)
        self.release_base = f"https://github.com/stubbi/asm/releases/download/v{NEXT}"
        self.filename = f"asm-{NEXT}-{TARGET}"
        self.artifact_url = f"{self.release_base}/{self.filename}"
        self.digest = hashlib.sha256(self.next_bytes).hexdigest()
        self.record = {
            "schema": 1, "project": "asm", "version": NEXT, "tag": "v" + NEXT,
            "repository": "https://github.com/stubbi/asm", "source_commit": COMMIT,
            "license": "AGPL-3.0-or-later", "template_license": "MIT",
            "assets": [{"file": self.filename, "bytes": len(self.next_bytes), "sha256": self.digest}],
            "tool_versions": {"as": "GNU assembler"}, "builds": {"asm": {"target": TARGET}},
        }
        self.state = {
            "index_url": INDEX, "identity": IDENTITY, "signed_commit": COMMIT,
            "downloads": {
                INDEX: "index.tsv", self.artifact_url: "artifact",
                f"{self.release_base}/release.json": "release.json",
                f"{self.release_base}/{BUNDLE}": "bundle",
            },
        }
        (self.fixture / "artifact").write_bytes(self.next_bytes)
        (self.fixture / "bundle").write_bytes(b"test-only signed bundle fixture\n")
        self.write_index()
        self.save()

    def save(self):
        (self.fixture / "state.json").write_text(json.dumps(self.state))
        (self.fixture / "release.json").write_text(json.dumps(self.record, indent=2) + "\n")

    def row(self, version=NEXT, target=TARGET, digest=None, size=None, url=None):
        return "\t".join(("stubbi/asm", version, target, "executable", digest or self.digest,
                          url or self.artifact_url, str(size or len(self.next_bytes)), "asm CLI")) + "\n"

    def write_index(self, *rows):
        (self.fixture / "index.tsv").write_text("# asm-registry-v1\n" + "".join(rows or [self.row()]))

    def cli(self, *args, code=0, executable=None):
        result = subprocess.run([str(executable or self.installed), *args], cwd=self.work, env=self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, code, (result.args, result.stdout, result.stderr))
        self.assertEqual(list(self.bin_dir.glob(".asm-registry-*")), [], "private update files remain")
        return result

    def unchanged(self):
        self.assertEqual(self.installed.read_bytes(), self.current_bytes)

    def calls(self):
        path = self.fixture / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_real_replacement_has_three_verified_bindings_and_no_token_inheritance(self):
        result = json.loads(self.cli("self", "update", "--json").stdout)
        self.assertEqual(result, {"updated": True, "version": NEXT,
                                 "integrity_verified": True, "provenance_verified": True})
        self.assertEqual(self.installed.read_bytes(), self.next_bytes)
        self.assertEqual(self.installed.stat().st_mode & 0o777, 0o755)
        self.assertIn(f"asm {NEXT}", self.cli("--version").stdout)
        calls = self.calls()
        verifications = [c for c in calls if c["tool"] == "gh" and c["args"][:2] == ["attestation", "verify"]]
        self.assertEqual(len(verifications), 3)
        self.assertNotIn("--source-digest", verifications[0]["args"])
        for call in verifications[1:]:
            self.assertIn("--source-digest", call["args"])
            self.assertIn("--signer-digest", call["args"])
        for call in calls:
            self.assertNotIn("GH_TOKEN", call["env"])
            self.assertEqual(call["env"].get("HTTPS_PROXY"), "https://untrusted.invalid")
            self.assertNotIn("CURL_CA_BUNDLE", call["env"])

    def test_exact_version_and_preserved_private_executable_mode(self):
        self.installed.chmod(0o700)
        self.cli("self", "update", NEXT)
        self.assertEqual(self.installed.read_bytes(), self.next_bytes)
        self.assertEqual(self.installed.stat().st_mode & 0o777, 0o700)

    def test_equal_version_is_a_noop_and_downgrade_is_refused_without_network(self):
        result = json.loads(self.cli("self", "update", CURRENT, "--json").stdout)
        self.assertFalse(result["updated"])
        self.cli("self", "update", OLDER, code=1)
        self.unchanged()
        self.assertEqual(self.calls(), [])

    def test_latest_does_not_claim_freshness_and_refuses_stale_lower_version(self):
        self.write_index(self.row(version=CURRENT))
        result = self.cli("self", "update")
        self.assertIn("No newer version was selected", result.stdout)
        self.unchanged()
        self.write_index(self.row(version=OLDER))
        self.cli("self", "update", code=1)
        self.unchanged()

    def test_invalid_syntax_and_runtime_override_options_are_rejected(self):
        for args in (("self", "install"), ("self", "update", "01.2.3"),
                     ("self", "update", NEXT, NEXT), ("self", "update", "--registry", "https://other.invalid"),
                     ("self", "update", "--artifact", "/tmp/file"), ("self", "update", "--force")):
            with self.subTest(args=args):
                self.cli(*args, code=2)
                self.unchanged()
        self.assertEqual(self.calls(), [])
        self.assertIn("Usage: asm self update", self.cli("self", "--help").stdout)
        self.assertIn("No unattended update", self.cli("self", "update", "--help").stdout)

    def test_requires_direct_installation_and_refuses_hardlinks_or_unsafe_permissions(self):
        other = self.work / "asm"
        other.write_bytes(self.current_bytes)
        other.chmod(0o755)
        self.cli("self", "update", executable=other, code=1)
        link = self.work / "hardlink"
        os.link(self.installed, link)
        self.cli("self", "update", code=1)
        link.unlink()
        self.bin_dir.chmod(0o777)
        try:
            self.cli("self", "update", code=1)
        finally:
            self.bin_dir.chmod(0o755)
        self.installed.chmod(0o775)
        self.cli("self", "update", code=1)
        self.installed.chmod(0o755)
        self.unchanged()
        self.assertEqual(self.calls(), [])

    def test_symlink_installation_is_refused_without_replacing_target(self):
        real = self.work / "real-asm"
        self.installed.rename(real)
        self.installed.symlink_to(real)
        self.cli("self", "update", code=1)
        self.assertTrue(self.installed.is_symlink())
        self.assertEqual(real.read_bytes(), self.current_bytes)
        self.assertEqual(self.calls(), [])

    def test_every_ancestor_requires_safe_writes_and_sticky_is_not_generic(self):
        # The suite directory is the protected immediate child of /tmp.
        # The case directory is a separate ancestor above HOME.
        for directory, mode in ((self.fixture, 0o777), (self.work, 0o777),
                                (self.work, 0o1777)):
            with self.subTest(directory=directory.name, mode=oct(mode)):
                previous_mode = directory.stat().st_mode & 0o7777
                directory.chmod(mode)
                try:
                    result = self.cli("self", "update", code=1)
                    self.assertIn("protected path ancestors", result.stderr)
                    self.unchanged()
                    self.assertEqual(self.calls(), [])
                finally:
                    directory.chmod(previous_mode)

    def test_exact_root_owned_sticky_tmp_accepts_protected_user_child(self):
        tmp = Path("/tmp").stat()
        child = self.fixture.stat()
        self.assertEqual(self.fixture.parent, Path("/tmp"))
        self.assertEqual(tmp.st_uid, 0)
        self.assertTrue(tmp.st_mode & 0o1000)
        self.assertTrue(tmp.st_mode & 0o022)
        self.assertEqual(child.st_uid, os.geteuid())
        self.assertFalse(child.st_mode & 0o022)
        self.cli("self", "update")
        self.assertEqual(self.installed.read_bytes(), self.next_bytes)

    @unittest.skipUnless(os.geteuid() == 0, "cross-UID regression requires a root test runner")
    def test_cross_uid_writable_ancestor_attack_stops_before_any_tool(self):
        victim, attacker = 65532, 65533
        with tempfile.TemporaryDirectory(prefix="asm-self-update-uids-", dir="/tmp") as temporary:
            protected = Path(temporary)
            protected.chmod(0o755)
            os.chown(protected, victim, victim)
            ancestor = protected / "attacker-owned"
            ancestor.mkdir()
            os.chown(ancestor, attacker, attacker)
            ancestor.chmod(0o777)
            home = ancestor / "victim-home"
            install_dir = home / ".local/bin"
            install_dir.mkdir(parents=True)
            installed = install_dir / "asm"
            installed.write_bytes(self.current_bytes)
            installed.chmod(0o755)
            for path in (home, *home.rglob("*")):
                os.chown(path, victim, victim)
            home.chmod(0o700)
            # Establish the actual cross-UID rename capability. Sticky /tmp
            # protects the outer user directory, not this attacker-owned one.
            moved = ancestor / "displaced-home"
            subprocess.run(
                [sys.executable, "-c", "import os,sys; os.rename(sys.argv[1],sys.argv[2]); "
                 "os.rename(sys.argv[2],sys.argv[1])", str(home), str(moved)],
                cwd=protected, preexec_fn=become(attacker), check=True,
                capture_output=True, text=True, timeout=5)
            result = subprocess.run(
                [str(installed), "self", "update"], cwd=protected,
                env=dict(self.env, HOME=str(home)), preexec_fn=become(victim),
                capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1, (result.stdout, result.stderr))
            self.assertIn("protected path ancestors", result.stderr)
            self.assertEqual(installed.read_bytes(), self.current_bytes)
            self.assertEqual(list(install_dir.glob(".asm-registry-*")), [])
            self.assertEqual(self.calls(), [])

    def test_verifier_deadline_resets_ignored_and_unblocks_inherited_alarm(self):
        self.installed.write_bytes(self.short_deadline_bytes)
        self.state["version_delay"] = 3
        self.save()
        for ignored, blocked in ((True, False), (False, True), (True, True)):
            with self.subTest(ignored=ignored, blocked=blocked):
                def inherit_signal_state():
                    if ignored:
                        signal.signal(signal.SIGALRM, signal.SIG_IGN)
                    if blocked:
                        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
                started = time.monotonic()
                result = subprocess.run(
                    [str(self.installed), "self", "update"], cwd=self.work, env=self.env,
                    capture_output=True, text=True, timeout=5, preexec_fn=inherit_signal_state)
                elapsed = time.monotonic() - started
                self.assertEqual(result.returncode, 1, (result.stdout, result.stderr))
                self.assertLess(elapsed, 2.5, "the one-second child deadline did not stop the verifier")
                self.assertFalse((self.fixture / "verifier-delay-finished").exists())
                self.assertEqual(self.installed.read_bytes(), self.short_deadline_bytes)
                self.assertEqual(list(self.bin_dir.glob(".asm-registry-*")), [])
        self.assertFalse(any(call["tool"] == "curl" for call in self.calls()))

    def test_signal_mask_syscall_failure_stops_before_verifier_exec(self):
        result = subprocess.run(
            [str(self.installed), "self", "update"], cwd=self.work, env=self.env,
            capture_output=True, text=True, timeout=5, preexec_fn=deny_sigprocmask)
        self.assertEqual(result.returncode, 1, (result.stdout, result.stderr))
        self.unchanged()
        self.assertEqual(self.calls(), [])
        self.assertEqual(list(self.bin_dir.glob(".asm-registry-*")), [])

    def test_missing_or_old_verifier_fails_closed_before_network(self):
        for version in ("2.92.9", "2.93.0-pre", "invalid"):
            with self.subTest(version=version):
                self.state["gh_version"] = version
                self.save()
                result = self.cli("self", "update", code=1)
                self.assertIn("2.93.0", result.stderr)
                self.unchanged()
        self.assertFalse(any(c["tool"] == "curl" for c in self.calls()))
        helper = self.fixture / "gh-fixture"
        hidden = self.fixture / "gh-fixture-absent"
        helper.rename(hidden)
        try:
            self.cli("self", "update", code=1)
            self.unchanged()
        finally:
            hidden.rename(helper)

    def test_proxy_values_are_bounded_before_any_child_tool(self):
        self.env["HTTPS_PROXY"] = "x" * 4096
        self.cli("self", "update", code=2)
        self.unchanged()
        self.assertEqual(self.calls(), [])

    def test_network_and_integrity_failures_keep_old_binary(self):
        self.state["network_failure"] = True
        self.save()
        self.cli("self", "update", code=1)
        self.unchanged()
        self.state["network_failure"] = False
        self.save()
        (self.fixture / "artifact").write_bytes(self.next_bytes + b"tampered")
        self.cli("self", "update", code=1)
        self.unchanged()
        (self.fixture / "artifact").write_bytes(self.next_bytes)
        self.write_index(self.row(digest="0" * 64))
        self.cli("self", "update", code=1)
        self.unchanged()

    def test_kernel_limit_stops_oversized_writes_independent_of_curl_size_flags(self):
        import errno
        cases = ((INDEX, 1048576), (self.artifact_url, len(self.next_bytes)),
                 (f"{self.release_base}/release.json", 1048576),
                 (f"{self.release_base}/{BUNDLE}", 1048576))
        for url, cap in cases:
            with self.subTest(url=url):
                self.state.update(stream_url=url, stream_bytes=2 * 1048576)
                self.save()
                result = self.cli("self", "update", code=1)
                self.assertIn("could not download", result.stderr)
                record = json.loads((self.fixture / "stream-result.json").read_text())
                self.assertEqual(record["url"], url)
                self.assertEqual(record["errno"], errno.EFBIG)
                self.assertEqual(record["written_bytes"], cap)
                self.assertEqual(record["file_bytes"], cap)
                self.assertEqual(record["fsize_limit"], [cap, cap])
                self.assertGreater(record["requested_write_bytes"], cap)
                self.unchanged()

    def test_registry_fetch_has_the_same_kernel_download_bound(self):
        import errno
        self.state.update(stream_url=self.artifact_url, stream_bytes=2 * 1048576)
        self.save()
        output = self.work / "must-not-exist"
        self.cli("fetch", f"stubbi/asm@{NEXT}", "--kind", "executable",
                 "--output", str(output), code=1)
        record = json.loads((self.fixture / "stream-result.json").read_text())
        self.assertEqual(record["errno"], errno.EFBIG)
        self.assertEqual(record["file_bytes"], len(self.next_bytes))
        self.assertFalse(output.exists())
        self.assertEqual(list(self.work.glob(".asm-registry-*")), [])
        self.unchanged()

    def test_download_preserves_stricter_inherited_soft_and_hard_limits(self):
        import errno
        for soft, hard in ((65536, resource.RLIM_INFINITY), (16384, 32768)):
            with self.subTest(soft=soft, hard=hard):
                (self.fixture / "calls.jsonl").unlink(missing_ok=True)
                self.state.update(stream_url=self.artifact_url, stream_bytes=2 * 1048576)
                self.save()
                result = subprocess.run(
                    [str(self.installed), "self", "update"], cwd=self.work, env=self.env,
                    capture_output=True, text=True, timeout=10,
                    preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_FSIZE, (soft, hard)))
                self.assertEqual(result.returncode, 1, (result.stdout, result.stderr))
                record = json.loads((self.fixture / "stream-result.json").read_text())
                self.assertEqual(record["errno"], errno.EFBIG)
                self.assertEqual(record["file_bytes"], soft)
                expected_hard = len(self.next_bytes) if hard == resource.RLIM_INFINITY else hard
                self.assertEqual(record["fsize_limit"], [soft, expected_hard])
                version_call = next(call for call in self.calls() if call["tool"] == "gh")
                self.assertEqual(version_call["fsize_limit"], [soft, hard])
                self.unchanged()
                self.assertEqual(list(self.bin_dir.glob(".asm-registry-*")), [])

    def test_download_limit_setup_errors_stop_before_curl_exec(self):
        for syscall in (SYS_GETRLIMIT, SYS_SETRLIMIT):
            with self.subTest(syscall=syscall):
                (self.fixture / "calls.jsonl").unlink(missing_ok=True)
                result = subprocess.run(
                    [str(self.installed), "self", "update"], cwd=self.work, env=self.env,
                    capture_output=True, text=True, timeout=5,
                    preexec_fn=lambda: deny_syscall(syscall))
                self.assertEqual(result.returncode, 1, (result.stdout, result.stderr))
                self.assertIn("could not download", result.stderr)
                self.assertEqual([call["tool"] for call in self.calls()], ["gh"])
                self.unchanged()
                self.assertEqual(list(self.bin_dir.glob(".asm-registry-*")), [])

    def test_download_limit_does_not_restrict_parent_or_verifier_cache(self):
        self.state["cache_probe_bytes"] = 2 * 1048576
        self.save()
        self.cli("self", "update")
        self.assertEqual(self.installed.read_bytes(), self.next_bytes)
        parent_fsize = list(resource.getrlimit(resource.RLIMIT_FSIZE))
        parent_nofile = list(resource.getrlimit(resource.RLIMIT_NOFILE))
        calls = self.calls()
        verifiers = [call for call in calls if call["tool"] == "gh"]
        self.assertEqual(len(verifiers), 4)
        for call in calls:
            self.assertEqual(call["nofile_limit"], parent_nofile)
            if call["tool"] == "gh":
                self.assertEqual(call["fsize_limit"], parent_fsize)
            else:
                cap = int(call["args"][call["args"].index("--max-filesize") + 1])
                expected = [cap if inherited == resource.RLIM_INFINITY else min(inherited, cap)
                            for inherited in parent_fsize]
                self.assertEqual(call["fsize_limit"], expected)

    def test_attestation_failure_or_wrong_absent_multiple_id_keeps_old_binary(self):
        for output in ("", "1\n", REPO_ID + "\n" + REPO_ID + "\n", REPO_ID + "\n\0extra"):
            with self.subTest(output=output):
                self.state["repository_output"] = output
                self.save()
                self.cli("self", "update", code=1)
                self.unchanged()
        self.state.pop("repository_output")
        self.state["verification_failure"] = True
        self.save()
        self.cli("self", "update", code=1)
        self.unchanged()

    def test_attested_metadata_and_source_binding_must_match(self):
        for key, value in (("version", CURRENT), ("tag", "v" + CURRENT),
                           ("repository", "https://github.com/another/asm"),
                           ("source_commit", "b" * 40)):
            with self.subTest(field=key):
                old = self.record[key]
                self.record[key] = value
                self.save()
                self.cli("self", "update", code=1)
                self.unchanged()
                self.record[key] = old
        self.record["assets"][0]["sha256"] = "0" * 64
        self.save()
        self.cli("self", "update", code=1)
        self.unchanged()

    def test_malformed_manifest_and_wrong_host_or_origin_keep_old_binary(self):
        (self.fixture / "release.json").write_bytes(b'{"schema": 1,')
        self.cli("self", "update", code=1)
        self.unchanged()
        self.save()
        self.write_index(self.row(target=OTHER_TARGET))
        self.cli("self", "update", code=1)
        self.unchanged()
        self.write_index(self.row(url="https://github.com/another/asm/releases/download/v1/asm"))
        self.cli("self", "update", code=1)
        self.unchanged()

    def test_invalid_elf_is_rejected_even_with_matching_size_and_digest(self):
        payload = b"not an executable" * 10
        (self.fixture / "artifact").write_bytes(payload)
        self.write_index(self.row(digest=hashlib.sha256(payload).hexdigest(), size=len(payload)))
        result = self.cli("self", "update", code=1)
        self.assertIn("artifact is not a supported", result.stderr)
        self.assertIn("ELF", result.stderr)
        self.unchanged()
        self.assertFalse(any(c["args"][:2] == ["attestation", "verify"] for c in self.calls()))

    def test_candidate_is_not_executed_during_update(self):
        marker = self.work / "candidate-ran"
        source = self.work / "candidate.s"
        body = ("mov x0, #-100\nadr x1, path\nmov x2, #65\nmov x3, #384\n"
                "mov x8, #56\nsvc #0\nmov x0, #73\nmov x8, #93\nsvc #0\n") if IS_ARM64 else (
                "mov eax,257\nmov edi,-100\nlea rsi,[rip+path]\nmov edx,65\n"
                "mov r10d,384\nsyscall\nmov eax,60\nmov edi,73\nsyscall\n")
        if IS_RISCV64:
            body = ("li a0, -100\nla a1, path\nli a2, 65\nli a3, 384\n"
                    "li a7, 56\necall\nli a0, 73\nli a7, 93\necall\n")
        source.write_text(program(body) + f'.section .rodata\npath: .asciz "{marker}"\n')
        subprocess.run(["as", *ASM_FLAGS, "-o", str(self.work / "candidate.o"), str(source)], check=True)
        subprocess.run(["ld", "-z", "noexecstack", "-o", str(self.work / "candidate"),
                        str(self.work / "candidate.o")], check=True)
        payload = (self.work / "candidate").read_bytes()
        digest = hashlib.sha256(payload).hexdigest()
        (self.fixture / "artifact").write_bytes(payload)
        self.record["assets"][0].update(bytes=len(payload), sha256=digest)
        self.write_index(self.row(digest=digest, size=len(payload)))
        self.save()
        self.cli("self", "update")
        self.assertEqual(self.installed.read_bytes(), payload)
        self.assertFalse(marker.exists())

    def test_failed_atomic_rename_preserves_the_old_executable(self):
        result = subprocess.run([str(self.installed), "self", "update"], cwd=self.work, env=self.env,
                                capture_output=True, text=True, timeout=15, preexec_fn=deny_renameat)
        self.assertEqual(result.returncode, 1, (result.stdout, result.stderr))
        self.assertIn("previous binary remains", result.stderr)
        self.unchanged()
        self.assertEqual(list(self.bin_dir.glob(".asm-registry-*")), [])

    def hold_update(self, at_verifier=False):
        self.state["hold_verifier" if at_verifier else "hold"] = True
        self.save()
        process = subprocess.Popen([str(self.installed), "self", "update"], cwd=self.work, env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        # Wait for the explicit marker after the fixture tools start. A full
        # system guest can take several seconds to start their interpreters.
        # This bounds only setup; the displacement assertions stay unchanged.
        deadline = time.monotonic() + HELD_FIXTURE_READY_SECONDS
        marker = self.fixture / ("entered-verifier" if at_verifier else "entered")
        while not marker.exists():
            if process.poll() is not None:
                self.fail(("update stopped before the held download", process.communicate()))
            if time.monotonic() >= deadline:
                self.fail("update did not reach the held download")
            time.sleep(0.01)
        return process

    def assert_displaced_installation_is_refused(self, at_verifier):
        process = self.hold_update(at_verifier=at_verifier)
        moved = self.work / "displaced-original-home"
        self.home.rename(moved)
        self.bin_dir.mkdir(parents=True)
        unrelated = b"an unrelated command in the replacement home\n"
        self.installed.write_bytes(unrelated)
        self.installed.chmod(0o755)
        marker = self.fixture / ("continue-verifier" if at_verifier else "continue")
        marker.write_text("go")
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1, (stdout, stderr))
        self.assertIn("installation path or executable changed", stderr)
        self.assertEqual(self.installed.read_bytes(), unrelated)
        original_bin = moved / ".local/bin"
        self.assertEqual((original_bin / "asm").read_bytes(), self.current_bytes)
        self.assertEqual(list(original_bin.glob(".asm-registry-*")), [])
        self.assertEqual(list(self.bin_dir.glob(".asm-registry-*")), [])
        verifications = [call for call in self.calls()
                         if call["tool"] == "gh" and call["args"][:2] == ["attestation", "verify"]]
        self.assertEqual(len(verifications), 3 if at_verifier else 0)

    def test_displaced_home_is_refused_before_attestation_verifier(self):
        self.assert_displaced_installation_is_refused(at_verifier=False)

    def test_displaced_home_is_refused_before_final_commit(self):
        self.assert_displaced_installation_is_refused(at_verifier=True)

    def test_concurrent_updates_are_serialized_without_interrupting_normal_commands(self):
        process = self.hold_update()
        result = subprocess.run([str(self.installed), "self", "update"], cwd=self.work, env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn("lock", result.stderr)
        self.unchanged()
        normal = subprocess.run([str(self.installed), "--version"], capture_output=True, text=True, check=True)
        self.assertIn(CURRENT, normal.stdout)
        (self.fixture / "continue").write_text("go")
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, (stdout, stderr))
        self.assertEqual(self.installed.read_bytes(), self.next_bytes)
        self.assertEqual(list(self.bin_dir.glob(".asm-registry-*")), [])

    def test_changed_destination_is_not_overwritten_after_download(self):
        process = self.hold_update()
        foreign = self.work / "foreign"
        foreign.write_bytes(b"an unrelated command\n")
        foreign.chmod(0o755)
        foreign.replace(self.installed)
        (self.fixture / "continue").write_text("go")
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 1, (stdout, stderr))
        self.assertIn("changed", stderr)
        self.assertEqual(self.installed.read_bytes(), b"an unrelated command\n")
        self.assertEqual(list(self.bin_dir.glob(".asm-registry-*")), [])


if __name__ == "__main__":
    unittest.main()
