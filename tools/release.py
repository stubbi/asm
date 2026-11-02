#!/usr/bin/env python3
"""Build release files from an exact Git commit. Nothing is uploaded."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib

import registry


SOURCE_INCLUDES = [
    "AGENTS.md", "LICENSE", "README.md", "Makefile", "asm.toml", "design.md",
    ".editorconfig", ".gitignore", ".github", "CHANGELOG.md", "CONTRIBUTING.md",
    "SECURITY.md", "CODE_OF_CONDUCT.md", "LICENSING.md", "LICENSES", "cli", "docs", "examples",
    "registry", "site", "tests", "tools", "benchmarks", "verifier",
]
HELLO_TARGETS = {
    "x86_64-linux": ("examples/hello", "as", "ld", ["--64"], None),
    "aarch64-linux": ("examples/hello-aarch64", "aarch64-linux-gnu-as", "aarch64-linux-gnu-ld", [], "qemu-aarch64"),
    "riscv64-linux": ("examples/hello-riscv64", "riscv64-linux-gnu-as", "riscv64-linux-gnu-ld", ["-march=rv64i", "-mabi=lp64"], "qemu-riscv64"),
}
CLI_TARGETS = {
    "x86_64-linux": ("x86_64", "as", "ld", None),
    "aarch64-linux": ("aarch64", "aarch64-linux-gnu-as", "aarch64-linux-gnu-ld", "qemu-aarch64"),
}
NATIVE_CLI_TARGETS = {"aarch64-macos"}
NATIVE_EVIDENCE = "native-release.json"
MAX_NATIVE_EVIDENCE = 1024 * 1024


def resolve_commit(repo: Path, reference: str) -> str:
    registry.require(bool(reference) and len(reference) <= 256 and "\0" not in reference,
                     "source reference is invalid")
    commit = registry.git_output(repo, "rev-parse", "--verify", "--end-of-options", reference + "^{commit}").decode("ascii").strip()
    registry.require(registry.HEX40.fullmatch(commit) is not None, "source must resolve to a full Git commit")
    return commit


def output_path(value: Path) -> Path:
    path = value.absolute()
    registry.require(not path.is_symlink(), "output cannot be a symbolic link")
    registry.require(not path.exists(), "output already exists; choose a new output directory")
    registry.require(path.parent.is_dir() and not path.parent.is_symlink(), "output parent must be an existing directory")
    return path


def materialize(files: dict[str, tuple[bytes, int]], destination: Path) -> None:
    destination.mkdir()
    for relative, (data, mode) in sorted(files.items()):
        registry.portable_path(relative)
        path = destination / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)


def publish_directory(stage: Path, output: Path) -> None:
    """Publish a complete directory without replacing any concurrent destination."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        rename = getattr(libc, "renamex_np", None)
        registry.require(rename is not None, "atomic no-replace publication is unavailable on this system")
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        # Darwin SDK sys/stdio.h: RENAME_EXCL refuses an existing destination.
        result = rename(os.fsencode(stage), os.fsencode(output), 0x00000004)
    else:
        registry.require(sys.platform == "linux", "directory publication requires Linux or Darwin")
        rename = getattr(libc, "renameat2", None)
        registry.require(rename is not None, "atomic no-replace publication is unavailable on this system")
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(-100, os.fsencode(stage), -100, os.fsencode(output), 1)
    if result:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(output))


def build_environment() -> dict[str, str]:
    env = dict(os.environ)
    for key in ("MAKEFLAGS", "GNUMAKEFLAGS", "MFLAGS", "AS", "LD", "ASFLAGS", "LDFLAGS", "TRUSTED_DISTRIBUTION"):
        env.pop(key, None)
    env.update({"LC_ALL": "C", "TZ": "UTC", "SOURCE_DATE_EPOCH": "0"})
    return env


def command(arguments: list[str], cwd: Path, env: dict[str, str], timeout: int = 120,
            include_stderr: bool = False) -> bytes:
    try:
        result = subprocess.run(arguments, cwd=cwd, env=env, check=False,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise registry.RegistryError(f"could not run {arguments[0]}: {error}") from error
    if result.returncode:
        detail_limit = 64000 if include_stderr else 2000
        detail = result.stderr.decode("utf-8", "replace").strip()[-detail_limit:]
        raise registry.RegistryError(f"{arguments[0]} failed with exit {result.returncode}: {detail}")
    return result.stdout + result.stderr if include_stderr else result.stdout


def tool_version(name: str, cwd: Path, env: dict[str, str]) -> str:
    registry.require(shutil.which(name, path=env.get("PATH")) is not None, f"required tool is missing: {name}")
    output = command([name, "--version"], cwd, env, 15).decode("utf-8", "replace").splitlines()
    registry.require(bool(output), f"tool did not report its version: {name}")
    return output[0].strip()


def read_binary(path: Path, target: str) -> bytes:
    registry.require(path.is_file() and not path.is_symlink(), "build did not produce a regular executable")
    registry.require(0 < path.stat().st_size <= registry.MAX_ARTIFACT_BYTES, "executable size is out of range")
    data = path.read_bytes()
    registry.validate_executable(data, target)
    return data


def native_test_result(output: bytes) -> dict:
    """Require real, unskipped unittest execution, not an empty successful suite."""
    matches = re.findall(rb"(?:^|\n)Ran ([1-9][0-9]*) tests? in [0-9.]+s\r?\n", output)
    registry.require(len(matches) == 1 and output.rstrip().endswith(b"OK"),
                     "native tests must finish successfully without skips")
    return {"status": "pass", "command": ["make", "test"], "suite": "tests/macos",
            "tests_run": int(matches[0]), "skipped": 0, "exit_code": 0,
            "output_sha256": hashlib.sha256(output).hexdigest()}


def build_native_release(repo: Path, output: Path, reference: str = "HEAD",
                         target: str = "aarch64-macos", trusted: bool = False) -> dict:
    """Qualify native bytes; declaring a released host remains a separate gate."""
    registry.require(target in NATIVE_CLI_TARGETS, "unsupported native release target")
    registry.require(platform.system() == "Darwin" and platform.machine().lower() == "arm64",
                     "native macOS qualification requires an Apple Silicon macOS host")
    major = platform.mac_ver()[0].split(".")[0]
    registry.require(major.isdecimal() and int(major) >= 15, "native macOS qualification requires macOS 15 or later")
    output = output_path(output)
    commit = resolve_commit(repo, reference)
    files = registry.git_files(repo, commit, ".", SOURCE_INCLUDES)
    commands = registry.strict_json(files["cli/commands.json"][0])
    version = commands["version"]
    registry.version_tuple(version)
    env = build_environment()
    if trusted:
        env["TRUSTED_DISTRIBUTION"] = "1"
    with tempfile.TemporaryDirectory(prefix=".asm-native-release-", dir=output.parent) as temporary:
        work = Path(temporary)
        first, second = work / "first", work / "second"
        materialize(files, first)
        materialize(files, second)
        for snapshot in (first, second):
            command(["make", "build/asm"], snapshot, env, 600 if trusted else 120)
        binary = read_binary(first / "build/asm", target)
        registry.require(binary == read_binary(second / "build/asm", target),
                         "the two clean native CLI builds do not match")
        test_output = command(["make", "test"], first, env, 300, include_stderr=True)
        tests = native_test_result(test_output)
        registry.require(binary == read_binary(first / "build/asm", target),
                         "native tests changed the qualified executable")
        actual = command([str(first / "build/asm"), "version"], first, env, 15)
        registry.require(actual == f"asm {version} ({target})\n".encode("ascii"),
                         "the native CLI reports an unexpected version or host")
        targets = registry.strict_json(command([str(first / "build/asm"), "targets", "--json"], first, env, 15))
        registry.require(targets == {"host": target, "targets": [target]},
                         "the native CLI reports unexpected native build targets")
        command(["/usr/bin/codesign", "--verify", "--strict", str(first / "build/asm")], first, env, 15)
        filename = f"asm-{version}-{target}"
        evidence = {"schema": 1, "source_commit": commit, "version": version, "target": target,
                    "asset": {"file": filename, "bytes": len(binary), "sha256": hashlib.sha256(binary).hexdigest()},
                    "platform": {"system": "Darwin", "machine": "arm64", "version": platform.mac_ver()[0], "minimum": "15.0"},
                    "command": ["make", "build/asm"], "reproducibility": "Two clean builds produced identical bytes.",
                    "version_check": {"status": "pass", "runner": "native", "stdout": actual.decode("ascii"), "exit_code": 0},
                    "targets_check": {"status": "pass", "runner": "native", "result": targets, "exit_code": 0},
                    "tests": tests, "code_signature": "ad-hoc; verified with codesign --verify --strict",
                    "developer_id": "not-run", "notarization": "not-run",
                    "tool_versions": {"clang": command(["/usr/bin/clang", "--version"], first, env, 15).decode().splitlines()[0],
                                      "sdk": command(["/usr/bin/xcrun", "--show-sdk-version"], first, env, 15).decode().strip(),
                                      "python": platform.python_version()}}
        stage = work / "native"
        stage.mkdir()
        (stage / filename).write_bytes(binary)
        (stage / filename).chmod(0o755)
        if trusted:
            helper = read_binary(first / "build/asm-verify-aarch64-macos", target)
            registry.require(helper == read_binary(second / "build/asm-verify-aarch64-macos", target), "native verifier builds differ")
            helper_name = f"asm-verify-{version}-{target}"
            (stage / helper_name).write_bytes(helper)
            (stage / (helper_name + ".LICENSES.txt")).write_bytes((first / "build/asm-verify-aarch64-macos.LICENSES.txt").read_bytes())
            evidence["verifier"] = {"file": helper_name, "bytes": len(helper), "sha256": hashlib.sha256(helper).hexdigest()}
            evidence["trust_root_sha256"] = hashlib.sha256(files["verifier/trust/asm-root.json"][0]).hexdigest()
        (stage / NATIVE_EVIDENCE).write_bytes(registry.json_bytes(evidence))
        publish_directory(stage, output)
    return evidence


def read_native_release(directory: Path, commit: str, version: str, target: str = "aarch64-macos") -> tuple[bytes, dict]:
    """Validate a same-workflow native job's bytes and recorded runtime evidence."""
    registry.require(target in NATIVE_CLI_TARGETS, "unsupported native release target")
    registry.require(directory.is_dir() and not directory.is_symlink(), "native input must be a regular directory")
    evidence_path = directory / NATIVE_EVIDENCE
    registry.require(evidence_path.is_file() and not evidence_path.is_symlink() and
                     0 < evidence_path.stat().st_size <= MAX_NATIVE_EVIDENCE, "native evidence is missing or too large")
    evidence = registry.strict_json(evidence_path.read_bytes())
    registry.require(isinstance(evidence, dict) and type(evidence.get("schema")) is int and evidence["schema"] == 1 and
                     evidence.get("source_commit") == commit and evidence.get("version") == version and
                     evidence.get("target") == target, "native evidence has a different source, version, or target")
    filename = f"asm-{version}-{target}"
    asset = evidence.get("asset")
    registry.require(isinstance(asset, dict) and asset.get("file") == filename, "native asset name does not match")
    binary = read_binary(directory / filename, target)
    registry.require(type(asset.get("bytes")) is int and asset["bytes"] == len(binary) and
                     asset.get("sha256") == hashlib.sha256(binary).hexdigest(), "native asset digest or size does not match")
    registry.require(evidence.get("version_check") == {"status": "pass", "runner": "native",
                     "stdout": f"asm {version} ({target})\n", "exit_code": 0} and
                     type(evidence["version_check"]["exit_code"]) is int, "native version evidence did not pass")
    registry.require(evidence.get("targets_check") == {"status": "pass", "runner": "native",
                     "result": {"host": target, "targets": [target]}, "exit_code": 0} and
                     type(evidence["targets_check"]["exit_code"]) is int, "native target evidence did not pass")
    tests = evidence.get("tests")
    registry.require(isinstance(tests, dict) and tests.get("status") == "pass" and
                     tests.get("command") == ["make", "test"] and tests.get("suite") == "tests/macos" and
                     type(tests.get("tests_run")) is int and tests["tests_run"] > 0 and
                     type(tests.get("skipped")) is int and tests["skipped"] == 0 and
                     type(tests.get("exit_code")) is int and tests["exit_code"] == 0 and
                     isinstance(tests.get("output_sha256"), str) and registry.HEX64.fullmatch(tests["output_sha256"]),
                     "native test evidence is missing, skipped, or failed")
    host = evidence.get("platform")
    registry.require(isinstance(host, dict) and host.get("system") == "Darwin" and host.get("machine") == "arm64" and
                     host.get("minimum") == "15.0" and isinstance(host.get("version"), str) and
                     host["version"].split(".")[0].isdecimal() and int(host["version"].split(".")[0]) >= 15,
                     "native evidence did not run on the required macOS host")
    registry.require(evidence.get("command") == ["make", "build/asm"] and
                     evidence.get("reproducibility") == "Two clean builds produced identical bytes." and
                     evidence.get("code_signature") == "ad-hoc; verified with codesign --verify --strict",
                     "native build evidence is incomplete")
    tools = evidence.get("tool_versions")
    registry.require(isinstance(tools, dict) and all(isinstance(tools.get(name), str) and
                     0 < len(tools[name]) <= 1024 for name in ("clang", "sdk", "python")),
                     "native tool version evidence is missing")
    registry.require(evidence.get("developer_id") == "not-run" and evidence.get("notarization") == "not-run",
                     "native qualification cannot assert Developer ID or notarization")
    return binary, evidence


def target_runner(name: str | None, env: dict[str, str]) -> str | None:
    if name:
        for candidate in (name, name + "-static"):
            if shutil.which(candidate, path=env.get("PATH")):
                return candidate
    return None


def build_cli(snapshot: Path, env: dict[str, str], target: str = "x86_64-linux") -> bytes:
    architecture, assembler, linker, _ = CLI_TARGETS[target]
    command(["make", "build/asm", f"ARCH={architecture}", f"AS={assembler}", f"LD={linker}"], snapshot, env, 600 if env.get("TRUSTED_DISTRIBUTION") == "1" else 120)
    return read_binary(snapshot / "build/asm", target)


def check_cli(snapshot: Path, env: dict[str, str], target: str, version: str) -> dict:
    emulator_name = CLI_TARGETS[target][3]
    emulator = target_runner(emulator_name, env)
    registry.require(emulator_name is None or emulator is not None,
                     f"a runtime check is required before releasing the {target} CLI")
    runner = ([emulator] if emulator else []) + [str(snapshot / "build/asm")]
    actual = command([*runner, "version"], snapshot, env, 15)
    registry.require(actual == f"asm {version} ({target})\n".encode("ascii"),
                     "the built CLI reports an unexpected version or host")
    targets = registry.strict_json(command([*runner, "targets", "--json"], snapshot, env, 15))
    registry.require(targets == {"host": target, "targets": [target]},
                     "the built CLI reports unexpected native build targets")
    return {"status": "pass", "runner": emulator or "native", "stdout": actual.decode("ascii"), "exit_code": 0}


def compile_hello(snapshot: Path, target: str, env: dict[str, str]) -> tuple[bytes, dict]:
    source_path, assembler, linker, flags, emulator_name = HELLO_TARGETS[target]
    emulator = target_runner(emulator_name, env)
    project = snapshot / source_path
    manifest = tomllib.loads((project / "asm.toml").read_text())
    source = registry.portable_path(manifest["build"]["source"])
    registry.require(manifest["build"]["target"] == target, "example target does not match its build target")
    build = project / "build"
    build.mkdir()
    recipe = [assembler, *flags, "--fatal-warnings", "-o", "build/main.o", source]
    link_recipe = [linker, "-z", "noexecstack", "--build-id=none", "-o", "build/hello", "build/main.o"]
    command(recipe, project, env)
    command(link_recipe, project, env)
    binary = read_binary(build / "hello", target)
    runtime = {"status": "not-run", "reason": "No target runner is available."}
    runner = [str(build / "hello")]
    if target != "x86_64-linux":
        if emulator:
            runner.insert(0, emulator)
        else:
            runner = []
    if runner:
        actual = command(runner, project, env, 15)
        registry.require(actual == b"Hello from asm!\n", f"hello output is incorrect for {target}")
        runtime = {"status": "pass", "runner": emulator or "native", "stdout": "Hello from asm!\n", "exit_code": 0}
    return binary, {"assemble": recipe, "link": link_recipe, "runtime": runtime}


def artifact(data: bytes, filename: str, target: str, kind: str, base: str) -> dict:
    return {"target": target, "kind": kind, "sha256": hashlib.sha256(data).hexdigest(),
            "url": base + "/" + filename, "bytes": len(data)}


def core_license(files: dict[str, tuple[bytes, int]], commands: dict) -> str:
    """Read the declaration from the packaged source, preserving legacy MIT.

    These checks enforce the two supported Asm source layouts. They do not
    determine copyright ownership or replace a review of license scope.
    """
    text = files.get("LICENSE", (b"", 0))[0]
    declared = commands.get("license")
    if declared is None:
        registry.require(commands.get("version") == "0.1.0" and text.startswith(b"MIT License\n"),
                         "source command metadata must declare the Asm license")
        return "MIT"
    registry.require(declared in ("MIT", "AGPL-3.0-or-later"), "unsupported Asm source license declaration")
    if declared == "MIT":
        registry.require(text.startswith(b"MIT License\n"), "MIT declaration differs from the source license file")
    else:
        registry.require(text.lstrip().startswith(b"GNU AFFERO GENERAL PUBLIC LICENSE\n")
                         and b"Version 3, 19 November 2007" in text[:512],
                         "AGPL declaration differs from the source license file")
        registry.require(commands.get("template_license") == "MIT", "starter templates must retain their MIT declaration")
        registry.require("LICENSING.md" in files, "source archive needs its licensing scope document")
        template_text = files.get("LICENSES/MIT.txt", (b"", 0))[0]
        registry.require(template_text.startswith(b"MIT License\n"), "source archive needs the MIT template license")
    return declared


def require_mit_example(files: dict[str, tuple[bytes, int]], name: str) -> None:
    registry.require(files.get("LICENSE", (b"", 0))[0].startswith(b"MIT License\n"),
                     f"{name} must retain its separate MIT license file")


def build_release(repo: Path, output: Path, reference: str = "HEAD", version: str | None = None,
                  repository: str = "https://github.com/stubbi/asm",
                  hello_targets: list[str] | None = None, native_input: Path | None = None, trusted: bool = False) -> dict:
    registry.repository_url(repository)
    output = output_path(output)
    commit = resolve_commit(repo, reference)
    files = registry.git_files(repo, commit, ".", SOURCE_INCLUDES)
    registry.require("cli/commands.json" in files, "source commit is missing cli/commands.json")
    commands = registry.strict_json(files["cli/commands.json"][0])
    registry.require(isinstance(commands, dict), "CLI command metadata must be an object")
    source_version = commands.get("version")
    registry.version_tuple(source_version)
    license_id = core_license(files, commands)
    version = version or source_version
    registry.version_tuple(version)
    registry.require(version == source_version, "release version differs from the source CLI version")
    registry.require(platform.system() == "Linux" and platform.machine().lower() in {"x86_64", "amd64"},
                     "the release builder currently requires Linux x86_64")
    targets = sorted(set(hello_targets or ["x86_64-linux"]))
    registry.require(all(target in HELLO_TARGETS for target in targets), "unsupported hello target")
    cli_hosts = commands.get("hosts", ["x86_64-linux"])
    registry.require(isinstance(cli_hosts, list) and all(isinstance(target, str) for target in cli_hosts) and
                     len(cli_hosts) == len(set(cli_hosts)) and
                     "x86_64-linux" in cli_hosts and all(target in CLI_TARGETS.keys() | NATIVE_CLI_TARGETS for target in cli_hosts),
                     "source command metadata declares unsupported or duplicate CLI hosts")
    native = read_native_release(native_input, commit, version) if native_input is not None else None
    registry.require("aarch64-macos" not in cli_hosts or native is not None,
                     "a declared macOS CLI requires exact-commit native qualification input")
    owner = repository.split("/")[-2].lower()
    tag = "v" + version
    base = repository + "/releases/download/" + tag
    env = build_environment()
    if trusted:
        env["TRUSTED_DISTRIBUTION"] = "1"
    with tempfile.TemporaryDirectory(prefix=".asm-release-", dir=output.parent) as temporary:
        work = Path(temporary)
        first = work / "first"
        second = work / "second"
        materialize(files, first)
        materialize(files, second)
        stage = work / "release"
        stage.mkdir()
        tools = {name: tool_version(name, first, env) for name in ("make", "as", "ld", "git")}
        tools["python"] = platform.python_version()
        cli = build_cli(first, env)
        registry.require(cli == build_cli(second, env), "the two clean CLI builds do not match")
        # Older fixture/release sources expose only version; retain their format.
        cli_version_output = command([str(first / "build/asm"), "version"], first, env, 15)
        registry.require(cli_version_output == f"asm {version} (x86_64-linux)\n".encode("ascii"),
                         "the built CLI reports an unexpected version or host")

        cli_archive = registry.make_archive(files)
        registry.validate_project(registry.read_archive(cli_archive), owner + "/asm", version, "x86_64-linux")
        # Re-read Git blobs to test the archive path independently of file order.
        repeated = registry.make_archive(registry.git_files(repo, commit, ".", list(reversed(SOURCE_INCLUDES))))
        registry.require(cli_archive == repeated, "the two source archive builds do not match")
        payloads = {
            f"asm-{version}-x86_64-linux": cli,
            f"asm-{version}-source.tar.gz": cli_archive,
        }
        cli_record = {"schema": 1, "name": owner + "/asm", "version": version,
                      "summary": "A native assembly CLI for assembly projects and package records.",
                      "license": license_id, "source": {"repository": repository, "commit": commit, "path": "."},
                      "yanked": False, "artifacts": [
                          artifact(cli, f"asm-{version}-x86_64-linux", "x86_64-linux", "executable", base),
                          artifact(cli_archive, f"asm-{version}-source.tar.gz", "x86_64-linux", "source", base),
                      ]}
        hello_record = {"schema": 1, "name": owner + "/hello", "version": version,
                        "summary": "A small Linux assembly program that writes a greeting.",
                        "license": "MIT", "source": {"repository": repository, "commit": commit, "path": "examples"},
                        "yanked": False, "artifacts": []}
        builds = {"asm": {"target": "x86_64-linux", "command": ["make", "build/asm", "ARCH=x86_64", "AS=as", "LD=ld"],
                           "reproducibility": "Two clean builds produced identical bytes.",
                           "version_check": {"status": "pass", "stdout": cli_version_output.decode("ascii"), "exit_code": 0}}, "hello": {}}
        for target in targets:
            source_path, assembler, linker, _, emulator_name = HELLO_TARGETS[target]
            emulator = target_runner(emulator_name, env)
            for name in (assembler, linker):
                tools[name] = tool_version(name, first, env)
            if emulator:
                tools[emulator] = tool_version(emulator, first, env)
            binary, build_record = compile_hello(first, target, env)
            repeated_binary, _ = compile_hello(second, target, env)
            registry.require(binary == repeated_binary, f"the two hello builds do not match for {target}")
            sources = registry.git_files(repo, commit, source_path)
            require_mit_example(sources, "hello")
            archive = registry.make_archive(sources)
            registry.validate_project(registry.read_archive(archive), owner + "/hello", version, target)
            registry.require(archive == registry.make_archive(dict(reversed(list(sources.items())))),
                             f"the hello archive is not deterministic for {target}")
            filename = f"hello-{version}-{target}"
            payloads[filename] = binary
            payloads[filename + ".tar.gz"] = archive
            hello_record["artifacts"].extend([
                artifact(binary, filename, target, "executable", base),
                artifact(archive, filename + ".tar.gz", target, "source", base),
            ])
            builds["hello"][target] = {**build_record, "source_path": source_path,
                                        "reproducibility": "Two clean builds produced identical bytes."}

        records = [cli_record, hello_record]
        if "examples/math/asm.toml" in files:
            math_sources = registry.git_files(repo, commit, "examples/math")
            require_mit_example(math_sources, "math")
            math_archive = registry.make_archive(math_sources)
            registry.validate_project(registry.read_archive(math_archive), owner + "/math", version, "x86_64-linux")
            registry.require(math_archive == registry.make_archive(dict(reversed(list(math_sources.items())))),
                             "the math source archive is not deterministic")
            math_directory = first / "examples/math"
            math_output = command([str(first / "build/asm"), "run"], math_directory, env, 15)
            registry.require(math_output == b"min(12, 37) = 12\n", "math smoke test returned unexpected output")
            math_test_output = command([str(first / "build/asm"), "test"], math_directory, env, 15)
            filename = f"math-{version}-x86_64-linux-source.tar.gz"
            payloads[filename] = math_archive
            records.append({"schema": 1, "name": owner + "/math", "version": version,
                            "summary": "An unsigned 64-bit minimum routine for the System V AMD64 ABI.",
                            "license": "MIT", "source": {"repository": repository, "commit": commit, "path": "examples/math"},
                            "yanked": False, "artifacts": [artifact(math_archive, filename, "x86_64-linux", "source", base)]})
            builds["math"] = {"target": "x86_64-linux", "source_path": "examples/math",
                               "runtime": {"status": "pass", "runner": "asm from the source commit",
                                           "commands": [["asm", "run"], ["asm", "test"]],
                                           "stdout": math_output.decode("ascii"),
                                           "test_stdout": math_test_output.decode("utf-8"), "exit_code": 0}}
        # Build additional native implementations only after x86-only examples.
        # The source archive contains both implementations; its root project
        # manifest still declares the x86 reference build.
        builds["asm_targets"] = {"x86_64-linux": builds["asm"]}
        for target in cli_hosts:
            if target == "x86_64-linux":
                continue
            if target in NATIVE_CLI_TARGETS:
                binary, evidence = native
                filename = f"asm-{version}-{target}"
                payloads[filename] = binary
                cli_record["artifacts"].append(artifact(binary, filename, target, "executable", base))
                builds["asm_targets"][target] = evidence
                tools["native_" + target] = evidence["tool_versions"]
                continue
            architecture, assembler, linker, emulator_name = CLI_TARGETS[target]
            for name in (assembler, linker):
                tools[name] = tool_version(name, first, env)
            emulator = target_runner(emulator_name, env)
            registry.require(emulator is not None, f"missing runtime checker for {target}")
            tools[emulator] = tool_version(emulator, first, env)
            binary = build_cli(first, env, target)
            registry.require(binary == build_cli(second, env, target), f"the two clean CLI builds do not match for {target}")
            runtime = check_cli(first, env, target, version)
            filename = f"asm-{version}-{target}"
            payloads[filename] = binary
            cli_record["artifacts"].append(artifact(binary, filename, target, "executable", base))
            builds["asm_targets"][target] = {
                "target": target,
                "command": ["make", "build/asm", f"ARCH={architecture}", f"AS={assembler}", f"LD={linker}"],
                "reproducibility": "Two clean builds produced identical bytes.",
                "version_check": runtime,
            }
        records = registry.check_records(records)
        for record in records:
            for item in record["artifacts"]:
                filename = registry.artifact_url(item["url"])[2]
                registry.validate_artifact(payloads[filename], record, item)
            path = stage / "registry/packages" / record["name"] / (version + ".json")
            registry.write_atomic(path, registry.json_bytes(record))
        verifier_assets = []
        if trusted:
            for target in cli_hosts:
                filename = f"asm-verify-{version}-{target}"
                if target == "aarch64-macos":
                    helper = read_binary(native_input / filename, target)
                    expected = {"file": filename, "bytes": len(helper), "sha256": hashlib.sha256(helper).hexdigest()}
                    registry.require(native[1].get("verifier") == expected, "native verifier lacks exact-byte qualification")
                    registry.require(native[1].get("trust_root_sha256") == hashlib.sha256(files["verifier/trust/asm-root.json"][0]).hexdigest(), "native trust root differs")
                else:
                    helper = read_binary(first / f"build/asm-verify-{target}", target)
                    registry.require(helper == read_binary(second / f"build/asm-verify-{target}", target), "verifier builds differ")
                payloads[filename] = helper
                notices = native_input / (filename + ".LICENSES.txt") if target == "aarch64-macos" else first / f"build/asm-verify-{target}.LICENSES.txt"
                registry.require(notices.is_file() and not notices.is_symlink() and notices.stat().st_size <= 1 << 20, "verifier license notices are required")
                payloads[filename + ".LICENSES.txt"] = notices.read_bytes()
                verifier_assets.append({"target": target, "url": f"{base}/{filename}", "bytes": len(helper), "sha256": hashlib.sha256(helper).hexdigest()})
        assets = []
        for filename, data in sorted(payloads.items()):
            path = stage / filename
            path.write_bytes(data)
            path.chmod(0o644 if filename.endswith(".tar.gz") else 0o755)
            assets.append({"file": filename, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
        release = {"schema": 1, "project": "asm", "version": version, "tag": tag,
                   "repository": repository, "source_commit": commit,
                   "license": license_id, "template_license": "MIT",
                   "package_licenses": {record["name"]: record["license"] for record in records},
                   "cli_hosts": cli_hosts, "hello_targets": targets,
                   "tool_versions": tools, "builds": builds, "assets": assets,
                   "archive_format": "USTAR + gzip; sorted paths; zero timestamps; normalized ownership",
                   "provenance": "not-run", "formal_proofs": "not-run"}
        if trusted:
            import bootstrap
            import trusted_bootstrap
            release["distribution"] = {"profile": "asm-tuf-v1", "verifiers": verifier_assets,
                                       "root_sha256": hashlib.sha256(files["verifier/trust/asm-root.json"][0]).hexdigest()}
            selected = bootstrap.installer_release([cli_record], {(cli_record["name"], version)})
            registry.require(selected is not None, "trusted release needs an installer record")
            payloads["install.sh"] = trusted_bootstrap.render_installer(selected, verifier_assets)
            (stage / "install.sh").write_bytes(payloads["install.sh"])
            release["assets"].append({"file": "install.sh", "bytes": len(payloads["install.sh"]), "sha256": hashlib.sha256(payloads["install.sh"]).hexdigest()})
        metadata = registry.json_bytes(release)
        (stage / "release.json").write_bytes(metadata)
        checksums = {name: hashlib.sha256(data).hexdigest() for name, data in payloads.items()}
        checksums["release.json"] = hashlib.sha256(metadata).hexdigest()
        (stage / "SHA256SUMS").write_text("".join(f"{digest}  {name}\n" for name, digest in sorted(checksums.items())), encoding="ascii")
        publish_directory(stage, output)
    return release


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--commit", default="HEAD", help="Git reference to resolve to an exact commit")
    parser.add_argument("--version", help="must match cli/commands.json at the source commit")
    parser.add_argument("--repository", default="https://github.com/stubbi/asm")
    parser.add_argument("--output", type=Path, default=Path("dist"), help="new output directory")
    parser.add_argument("--hello-target", choices=sorted(HELLO_TARGETS), action="append", help="repeat for each hello target; default: x86_64-linux")
    parser.add_argument("--native-target", choices=sorted(NATIVE_CLI_TARGETS), help="build and test native qualification input on its own host")
    parser.add_argument("--native-input", type=Path, help="native job output from this exact source commit")
    parser.add_argument("--trusted-distribution", action="store_true", help="require the provisioned root and bundle the verifier")
    args = parser.parse_args(argv)
    try:
        if args.native_target:
            registry.require(args.native_input is None and args.version is None and args.hello_target is None,
                             "native qualification cannot override the source version or consume another build")
            evidence = build_native_release(args.repo, args.output, args.commit, args.native_target, args.trusted_distribution)
            print(f"Qualified {evidence['target']} from {evidence['source_commit']}.")
            print(f"Wrote native bytes and runtime evidence to {args.output}. No files were uploaded.")
            return 0
        release = build_release(args.repo, args.output, args.commit, args.version, args.repository,
                                args.hello_target, args.native_input, args.trusted_distribution)
        print(f"Built Asm {release['version']} from {release['source_commit']}.")
        print(f"Wrote {len(release['assets'])} artifacts, checksums, release metadata, and proposed registry records to {args.output}.")
        print("No files were uploaded. Review the records before publication.")
        return 0
    except (registry.RegistryError, OSError, UnicodeError, ValueError, KeyError) as error:
        print(f"release: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
