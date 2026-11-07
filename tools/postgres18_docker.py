#!/usr/bin/env python3
"""Use only the fixed local Linux Docker daemon for qualification.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import platform
import re
import stat
from subprocess import SubprocessError
import sys
import tempfile

LOCAL_SOCKET = Path("/var/run/docker.sock")
EXECUTABLE = Path("/usr/bin/docker")
LOCAL_UID = 0
SELECTION_PREFIXES = ("DOCKER_", "BUILDX_", "BUILDKIT_")
SELECTION_FLAGS = ("--host", "--context", "--config", "--tls", "--tlsverify", "--tlscacert", "--tlscert", "--tlskey", "--builder")
OPERATIONS = {"version", "info", "build", "pull", "image", "container", "create", "start", "exec", "logs", "rm", "buildx"}


def need(condition, message):
    if not condition:
        raise ValueError(message)


def ambient_environment():
    environment = dict(os.environ)
    need(not any(key.startswith(SELECTION_PREFIXES) for key in environment),
         "Ambient Docker or builder selection is unsupported. Remove its environment settings before qualification.")
    return environment


def local_endpoint():
    need(platform.system() == "Linux", "The fixed Docker endpoint requires Linux.")
    socket = LOCAL_SOCKET.lstat()
    executable = EXECUTABLE.lstat()
    need(stat.S_ISSOCK(socket.st_mode) and socket.st_uid == LOCAL_UID,
         "The fixed local Docker socket is unavailable or has an unexpected owner.")
    need(stat.S_ISREG(executable.st_mode) and executable.st_uid == LOCAL_UID and
         executable.st_mode & 0o111 and not executable.st_mode & 0o022,
         "The fixed Docker executable is unavailable or writable by another identity.")


@contextmanager
def invocation(arguments):
    """Yield one fixed endpoint and a new private configuration until the child is reaped."""
    arguments = list(arguments)
    if not arguments or Path(arguments[0]).name != "docker":
        yield arguments, None
        return
    environment = ambient_environment()
    need(len(arguments) > 1 and arguments[1] in OPERATIONS, "The Docker operation is not a qualification operation.")
    need(not any(argument.startswith("-H") or any(argument == flag or argument.startswith(flag + "=")
             for flag in SELECTION_FLAGS) for argument in arguments[1:]),
         "Docker endpoint, configuration, and builder overrides are not qualification arguments.")
    need(arguments[1] != "buildx" or arguments[2:] == ["version"], "Only fixed builder version inspection is supported.")
    local_endpoint()
    with tempfile.TemporaryDirectory(prefix="asm-postgres18-docker-") as temporary:
        configuration = Path(temporary)
        configuration.chmod(0o700)
        environment.update(DOCKER_CONFIG=str(configuration), BUILDX_CONFIG=str(configuration / "buildx"), DOCKER_BUILDKIT="1")
        yield [str(EXECUTABLE), "--host", "unix://" + str(LOCAL_SOCKET), "--config", str(configuration), *arguments[1:]], environment


def workflow_stage(stage, revision, output, runner):
    """Run only reviewed environment or build operations through the bounded command runner."""
    need(stage in {"environment", "build"}, "Select a fixed qualification workflow stage.")
    need(re.fullmatch(r"[0-9a-f]{40}", revision or "") and revision != "0" * 40, "Supply an exact source revision.")
    ambient_environment()
    local_endpoint()
    output = Path(output)
    output.mkdir(mode=0o700, exist_ok=True)
    info = output.lstat()
    need(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o700,
         "The workflow evidence directory must be private and owned.")

    def run(name, arguments, timeout=20):
        try:
            result = runner(["docker", *arguments], timeout=timeout)
        except BaseException as error:
            (output / (name + ".stdout.log")).write_bytes(getattr(error, "stdout", None) or b"")
            (output / (name + ".stderr.log")).write_bytes(getattr(error, "stderr", None) or b"")
            raise
        (output / (name + ".stdout.log")).write_bytes(result.stdout)
        (output / (name + ".stderr.log")).write_bytes(result.stderr)

    if stage == "environment":
        run("docker-version", ["version"])
        run("buildx-version", ["buildx", "version"])
        return
    for application in ("operator", "server"):
        for target in ("runtime", "qualification"):
            run("build-" + application + "-" + target,
                ["build", "--platform", "linux/amd64", "--file", "containers/" + application + ".Dockerfile",
                 "--build-arg", "ASM_SOURCE_REVISION=" + revision, "--target", target,
                 "--tag", "asm-" + application + ":" + target + "-amd64", "."], timeout=1200)
    import postgres18_fixture
    run("database-pull", ["pull", "--platform", "linux/amd64", postgres18_fixture.DATABASE_IMAGE], timeout=180)
    for target in ("operator", "http", "database"):
        run("build-postgres18-" + target,
            ["build", "--platform", "linux/amd64", "--file", "containers/postgres18.Dockerfile",
             "--target", target, "--tag", "asm-postgres18:" + target, "."], timeout=1200)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("environment", "build"))
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from test_postgres18_image import command, termination_guard
    with termination_guard():
        workflow_stage(args.stage, args.revision, args.output, command)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, SubprocessError) as error:
        if isinstance(error, ValueError):
            print(str(error), file=sys.stderr)
        print("Local Docker qualification did not run successfully. Inspect the retained stage evidence.", file=sys.stderr)
        raise SystemExit(1)
