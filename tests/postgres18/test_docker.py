"""Docker selection cannot redirect an owned fixture to another daemon.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import json
import os
from pathlib import Path
import shlex
import socket
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import postgres18_docker as docker


class DockerIsolationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.socket_path = self.base / "docker.sock"
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(self.socket_path))
        self.addCleanup(self.listener.close)
        self.executable = self.base / "docker"
        self.executable.write_bytes(b"#!/bin/sh\nexit 99\n")
        self.executable.chmod(0o500)

    def local_policy(self):
        from contextlib import ExitStack
        scope = ExitStack()
        scope.enter_context(patch.object(docker, "LOCAL_SOCKET", self.socket_path))
        scope.enter_context(patch.object(docker, "EXECUTABLE", self.executable))
        scope.enter_context(patch.object(docker, "LOCAL_UID", os.geteuid()))
        scope.enter_context(patch.object(docker.platform, "system", return_value="Linux"))
        return scope

    def test_ambient_endpoint_config_context_and_builder_fail_before_any_resource(self):
        for key, value in (("DOCKER_HOST", "tcp://production.invalid:2376"), ("DOCKER_CONTEXT", "production"),
                           ("DOCKER_CONFIG", str(self.base / "foreign-config")), ("DOCKER_TLS_VERIFY", "1"),
                           ("BUILDX_CONFIG", str(self.base / "foreign-builder")), ("BUILDX_BUILDER", "remote"),
                           ("BUILDKIT_HOST", "tcp://builder.invalid:1234")):
            with self.subTest(key=key), patch.dict(os.environ, {key: value}, clear=True), \
                    patch.object(docker.tempfile, "TemporaryDirectory", side_effect=AssertionError("No configuration may be created")):
                with self.assertRaises(ValueError):
                    with docker.invocation(["docker", "create", "fixture"]):
                        self.fail("An ambient Docker selection reached resource creation.")
                calls = []
                with self.assertRaises(ValueError):
                    docker.workflow_stage("build", "a" * 40, self.base / "evidence", lambda *args, **kwargs: calls.append(args))
                self.assertEqual(calls, [])
                self.assertFalse((self.base / "evidence").exists())

    def test_private_empty_config_ignores_saved_current_context_and_is_removed_after_failure(self):
        home = self.base / "home"
        configuration = home / ".docker/config.json"
        configuration.parent.mkdir(parents=True)
        saved = b'{"currentContext":"production","auths":{"private.invalid":{"auth":"synthetic"}}}'
        configuration.write_bytes(saved)
        with self.local_policy(), patch.dict(os.environ, {"HOME": str(home), "PATH": os.defpath}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "controlled failure"):
                with docker.invocation(["docker", "info"]) as (arguments, environment):
                    self.assertEqual(arguments[:3], [str(self.executable), "--host", "unix://" + str(self.socket_path)])
                    private = Path(arguments[4])
                    self.assertEqual(arguments[3], "--config")
                    self.assertEqual(arguments[5:], ["info"])
                    self.assertEqual(list(private.iterdir()), [])
                    self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o700)
                    self.assertEqual(environment["DOCKER_CONFIG"], str(private))
                    self.assertEqual(environment["BUILDX_CONFIG"], str(private / "buildx"))
                    self.assertEqual(environment["DOCKER_BUILDKIT"], "1")
                    self.assertNotIn("DOCKER_HOST", environment)
                    (private / "created-by-fake-cli").write_bytes(b"owned temporary state")
                    raise RuntimeError("controlled failure")
            self.assertFalse(private.exists())
        self.assertEqual(configuration.read_bytes(), saved)

    def test_global_connection_flags_and_remote_builder_arguments_are_rejected(self):
        for arguments in (["docker", "--host", "tcp://production.invalid", "info"],
                          ["docker", "info", "--context=production"], ["docker", "info", "-Htcp://production.invalid"],
                          ["docker", "build", "--builder", "production", "."], ["docker", "context", "use", "production"],
                          ["docker", "--config=/foreign", "info"], ["/usr/bin/docker", "--host=tcp://production.invalid", "info"]):
            with self.subTest(arguments=arguments), patch.dict(os.environ, {}, clear=True):
                with self.assertRaises(ValueError):
                    with docker.invocation(arguments):
                        self.fail("An explicit remote Docker selector reached execution.")

    def test_fixed_local_endpoint_requires_a_socket_and_protected_executable(self):
        with self.local_policy(), patch.dict(os.environ, {}, clear=True):
            self.socket_path.unlink()
            self.socket_path.write_bytes(b"not a socket")
            with self.assertRaises(ValueError):
                with docker.invocation(["docker", "info"]):
                    self.fail("A regular file selected a Docker endpoint.")
            self.socket_path.unlink()
            self.socket_path.symlink_to(self.executable)
            with self.assertRaises(ValueError):
                with docker.invocation(["docker", "info"]):
                    self.fail("A symbolic link selected a Docker endpoint.")

    def test_non_docker_commands_preserve_their_existing_execution_contract(self):
        arguments = [sys.executable, "-c", "print('local child')"]
        with patch.dict(os.environ, {"DOCKER_HOST": "tcp://production.invalid"}, clear=True):
            with docker.invocation(arguments) as (actual, environment):
                self.assertEqual(actual, arguments)
                self.assertIsNone(environment)

    def test_fake_executable_observes_only_the_fixed_endpoint_and_empty_config(self):
        import test_postgres18_image as gate
        marker = self.base / "executed"
        self.executable.chmod(0o700)
        self.executable.write_text("#!/bin/sh\nset -eu\nprintf executed > " + shlex.quote(str(marker)) + "\n"
            "configuration=$4\n"
            "for entry in \"$configuration\"/* \"$configuration\"/.[!.]* \"$configuration\"/..?*; do\n"
            "  if test -e \"$entry\" || test -L \"$entry\"; then exit 91; fi\n"
            "done\n"
            "printf '%s\\000' \"$@\" empty \"$DOCKER_CONFIG\" \"$BUILDX_CONFIG\"\n")
        self.executable.chmod(0o500)
        with self.local_policy(), patch.dict(os.environ, {"HOME": str(self.base), "PATH": os.defpath}, clear=True):
            with docker.invocation(["docker", "info"]) as (arguments, environment):
                result = gate.bounded_result(arguments, timeout=3, environment=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            fields = result.stdout.decode().split("\0")
            self.assertEqual(fields.pop(), "")
            self.assertEqual(len(fields), 8)
            self.assertEqual(fields[:2], ["--host", "unix://" + str(self.socket_path)])
            self.assertEqual(fields[2], "--config")
            self.assertEqual(fields[4:6], ["info", "empty"])
            configuration = Path(fields[6])
            self.assertEqual(fields[3], str(configuration))
            self.assertEqual(fields[7], str(configuration / "buildx"))
            self.assertFalse(configuration.exists())
        self.assertTrue(marker.exists())
        marker.unlink()
        with self.local_policy(), patch.dict(os.environ, {"DOCKER_HOST": "tcp://production.invalid:2376"}, clear=True):
            with self.assertRaises(ValueError):
                with docker.invocation(["docker", "create", "fixture"]) as (arguments, environment):
                    gate.bounded_result(arguments, timeout=3, environment=environment)
        self.assertFalse(marker.exists())

    def test_workflow_build_stage_uses_only_the_fixed_local_targets(self):
        import test_postgres18_image as gate
        record = self.base / "operations.jsonl"
        self.executable.chmod(0o700)
        self.executable.write_text("#!" + sys.executable + "\nimport json,os,pathlib,sys\n"
            "with pathlib.Path(" + repr(str(record)) + ").open('a') as output: output.write(json.dumps(sys.argv[1:])+'\\n')\n"
            "assert os.listdir(sys.argv[4]) == []\nprint('fixed operation')\n")
        self.executable.chmod(0o500)
        def run(arguments, *, timeout):
            with docker.invocation(arguments) as (actual, environment):
                result = gate.bounded_result(actual, timeout=3, environment=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result
        with self.local_policy(), patch.dict(os.environ, {}, clear=True):
            docker.workflow_stage("build", "a" * 40, self.base / "evidence", run)
        operations = [json.loads(line) for line in record.read_text().splitlines()]
        self.assertEqual([value[4] for value in operations], ["build"] * 4 + ["pull"] + ["build"] * 3)
        tags = [value[value.index("--tag") + 1] for value in operations if "--tag" in value]
        self.assertEqual(tags, ["asm-operator:runtime-amd64", "asm-operator:qualification-amd64",
                               "asm-server:runtime-amd64", "asm-server:qualification-amd64",
                               "asm-postgres18:operator", "asm-postgres18:http", "asm-postgres18:database"])
        self.assertEqual(operations[4][-1], "ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie@sha256:39add80f5b1e573e2f6b641c66fd1a2f8dede67ca0330e870285bc1078551390")
        for arguments in operations:
            self.assertEqual(arguments[:2], ["--host", "unix://" + str(self.socket_path)])
            self.assertFalse(Path(arguments[3]).exists())
        self.assertEqual(len(list((self.base / "evidence").glob("*.log"))), 16)

    def test_workflow_termination_removes_the_invocations_private_configuration(self):
        import test_postgres18_image as gate
        record = self.base / "private-config.json"
        self.executable.chmod(0o700)
        self.executable.write_text("#!" + sys.executable + "\nimport json,os,pathlib,signal,sys,time\n"
            "pathlib.Path(" + repr(str(record)) + ").write_text(json.dumps(sys.argv[4]))\n"
            "os.kill(os.getppid(),signal.SIGTERM)\ntime.sleep(0.2)\n")
        self.executable.chmod(0o500)
        script = ("import os,pathlib,signal,sys;signal.pthread_sigmask(signal.SIG_UNBLOCK,{signal.SIGTERM});"
                  "sys.path.insert(0," + repr(str(ROOT / "tools")) + ");"
                  "import postgres18_docker as docker;docker.LOCAL_SOCKET=pathlib.Path(" + repr(str(self.socket_path)) + ");"
                  "docker.EXECUTABLE=pathlib.Path(" + repr(str(self.executable)) + ");docker.LOCAL_UID=os.geteuid();"
                  "docker.platform.system=lambda:'Linux';"
                  "sys.argv=['postgres18_docker.py','environment','--revision','" + "a" * 40 + "','--output'," +
                  repr(str(self.base / "evidence")) + "];\n"
                  "try: docker.main()\nexcept ValueError: sys.exit(1)\n")
        with patch.dict(os.environ, {}, clear=True):
            result = gate.bounded_result([sys.executable, "-c", script], timeout=5)
        configuration = Path(json.loads(record.read_text()))
        try:
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertFalse(configuration.exists())
        finally:
            if configuration.exists():
                configuration.rmdir()


if __name__ == "__main__":
    unittest.main()
