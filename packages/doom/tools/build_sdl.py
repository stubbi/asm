#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build the pinned SDL platform library. No game code is compiled from C."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

VERSION = "3.4.18"
URL = f"https://www.libsdl.org/release/SDL3-{VERSION}.tar.gz"
SHA256 = "9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3"
SOURCE_BYTES = 15651004
PACKAGE = Path(__file__).resolve().parents[1]
BUNDLED_ARCHIVE = PACKAGE / "third_party" / "sdl" / f"SDL3-{VERSION}.tar.gz"
BUILD_PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
ENVIRONMENT_KEYS = {"PATH", "LC_ALL", "LANG", "HOME", "TMPDIR", "SDKROOT"}
# SDL's generated SDL3.pc records these dependencies for this minimal build.
LINK_ARGS = [
    "-framework", "CoreMedia", "-framework", "CoreVideo",
    "-framework", "Cocoa", "-weak_framework", "UniformTypeIdentifiers",
    "-framework", "IOKit", "-framework", "Carbon", "-framework", "CoreAudio",
    "-framework", "AudioToolbox", "-framework", "AVFoundation",
    "-framework", "Foundation", "-framework", "Metal", "-framework", "QuartzCore",
    "-lpthread", "-lm",
]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _private_directory(path, *, parent=None, create=False):
    """Open one owned 0700 directory without following its final component."""
    if create:
        try:
            os.mkdir(path, mode=0o700, dir_fd=parent)
        except FileExistsError:
            pass
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    except OSError as error:
        raise ValueError("Build environment requires a private directory without symbolic links") from error
    details = os.fstat(descriptor)
    if details.st_uid != os.geteuid() or stat.S_IMODE(details.st_mode) != 0o700:
        os.close(descriptor)
        raise ValueError("Build environment directories must be owned by the builder with permissions 0700")
    return descriptor


def _sdk_path(environment):
    path = subprocess.check_output(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
        env=environment, text=True, timeout=30).strip()
    sdk = Path(path).resolve(strict=True)
    if not sdk.is_dir():
        raise ValueError("Apple xcrun did not select a macOS SDK directory")
    return str(sdk)


def build_environment(directory):
    """Return a clean tool environment with private HOME/TMPDIR below directory.

    The parent must exist. Existing container, home, and tmp directories must
    be builder-owned 0700 directories. Final-component symlinks are rejected.
    The returned directories remain owned by the caller until its stage ends.
    """
    directory = Path(directory).absolute()
    descriptor = _private_directory(directory, create=True)
    try:
        for name in ("home", "tmp"):
            child = _private_directory(name, parent=descriptor, create=True)
            os.close(child)
    finally:
        os.close(descriptor)
    environment = {"PATH": BUILD_PATH, "LC_ALL": "C", "LANG": "C",
                   "HOME": str(directory / "home"), "TMPDIR": str(directory / "tmp")}
    environment["SDKROOT"] = _sdk_path(environment)
    return environment


def _validated_environment(environment):
    """Require the same allowlist for a caller-supplied build stage."""
    environment = dict(environment)
    if (set(environment) != ENVIRONMENT_KEYS or environment["PATH"] != BUILD_PATH
            or environment["LC_ALL"] != "C" or environment["LANG"] != "C"):
        raise ValueError("Build environment must use the fixed tool path and exclude ambient variables")
    home, temporary = Path(environment["HOME"]), Path(environment["TMPDIR"])
    if not home.is_absolute() or not temporary.is_absolute() or home.parent != temporary.parent or home == temporary:
        raise ValueError("Build environment requires separate private HOME and TMPDIR directories")
    for path in (home.parent, home, temporary):
        descriptor = _private_directory(path)
        os.close(descriptor)
    base = {name: value for name, value in environment.items() if name != "SDKROOT"}
    if environment["SDKROOT"] != _sdk_path(base):
        raise ValueError("Build SDKROOT must match the SDK selected by Apple xcrun")
    return environment


def _tool_identity(path, environment):
    executable = Path(path).resolve(strict=True)
    return {"path": str(executable), "sha256": digest(executable),
            "version": subprocess.check_output([str(executable), "--version"],
                                                env=environment, text=True, timeout=30).splitlines()[0]}


def extract(archive, parent):
    """Extract only regular files and directories below the expected root."""
    with tarfile.open(archive, "r:gz") as source:
        for member in source.getmembers():
            name = Path(member.name)
            if (name.is_absolute() or ".." in name.parts or not name.parts
                    or name.parts[0] != f"SDL3-{VERSION}"
                    or not (member.isfile() or member.isdir())):
                raise ValueError(f"unsupported SDL archive entry: {member.name}")
        source.extractall(parent, filter="data")


def verify_source(archive, source_path):
    """Reject altered extracted cache files before compiling them."""
    actual = set()
    if source_path.is_symlink():
        raise ValueError("SDL source cache must not be a symbolic link")
    for path in source_path.rglob("*"):
        if path.is_symlink():
            raise ValueError("SDL source cache contains a symbolic link")
        if path.is_file():
            actual.add(path.relative_to(source_path).as_posix())
    expected = set()
    with tarfile.open(archive, "r:gz") as source:
        for member in source.getmembers():
            if not member.isfile():
                continue
            relative = Path(member.name).relative_to(f"SDL3-{VERSION}")
            expected.add(relative.as_posix())
            path = source_path / relative
            if not path.is_file() or path.stat().st_size != member.size:
                raise ValueError("SDL source cache differs from the pinned archive; remove the source cache")
            with source.extractfile(member) as original:
                if hashlib.file_digest(original,"sha256").hexdigest() != digest(path):
                    raise ValueError("SDL source cache differs from the pinned archive; remove the source cache")
    if actual != expected:
        raise ValueError("SDL source cache differs from the pinned archive; remove the source cache")


def build(output, archive=None, environment=None):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("SDL build requires Apple Silicon macOS")
    output = Path(output).absolute()
    output.mkdir(parents=True, exist_ok=True)
    if environment is None:
        with tempfile.TemporaryDirectory(prefix=".environment-", dir=output) as private:
            return build(output, archive, environment=build_environment(private))
    environment = _validated_environment(environment)
    cmake_path = shutil.which("cmake", path=environment["PATH"])
    if not cmake_path:
        raise ValueError("CMake is required in the fixed build tool path")
    cmake = _tool_identity(cmake_path, environment)
    compiler_path = subprocess.check_output(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--find", "clang"],
        env=environment, text=True, timeout=30).strip()
    compiler = _tool_identity(compiler_path, environment)
    sdk = {"path": environment["SDKROOT"],
           "version": subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"],
                                              env=environment, text=True, timeout=30).strip(),
           "settings_sha256": digest(Path(environment["SDKROOT"]) / "SDKSettings.json")}
    if archive is None and BUNDLED_ARCHIVE.exists():
        archive = BUNDLED_ARCHIVE
    archive_path = output / f"SDL3-{VERSION}.tar.gz"
    if archive:
        if digest(archive) != SHA256:
            raise ValueError("SDL source checksum does not match the pinned release")
        if archive.resolve() != archive_path.resolve():
            shutil.copyfile(archive, archive_path)
    elif not archive_path.exists():
        temporary = output / "source-download.tmp"
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(URL, timeout=60) as response, temporary.open("wb") as target:
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > SOURCE_BYTES:
                        raise ValueError("SDL source exceeds the pinned release size")
                    target.write(chunk)
            if digest(temporary) != SHA256:
                raise ValueError("SDL source checksum does not match the pinned release")
            temporary.replace(archive_path)
        finally:
            temporary.unlink(missing_ok=True)
    if digest(archive_path) != SHA256:
        raise ValueError("cached SDL source checksum does not match; remove the source cache")
    source_path = output / f"SDL3-{VERSION}"
    if not source_path.exists():
        extract(archive_path, output)
    verify_source(archive_path, source_path)
    build_path = output / "static"
    library = build_path / "libSDL3.a"
    options = {
        "CMAKE_BUILD_TYPE": "Release", "CMAKE_OSX_ARCHITECTURES": "arm64",
        "CMAKE_C_COMPILER": compiler["path"], "CMAKE_OBJC_COMPILER": compiler["path"],
        "CMAKE_OSX_SYSROOT": sdk["path"], "CMAKE_MAKE_PROGRAM": "/usr/bin/make",
        "CMAKE_C_FLAGS": "", "CMAKE_OBJC_FLAGS": "",
        "CMAKE_EXE_LINKER_FLAGS": "", "CMAKE_SHARED_LINKER_FLAGS": "",
        "CMAKE_OSX_DEPLOYMENT_TARGET": "15.0", "SDL_SHARED": "OFF", "SDL_STATIC": "ON",
        "SDL_TEST_LIBRARY": "OFF", "SDL_TESTS": "OFF", "SDL_EXAMPLES": "OFF",
        "SDL_GPU": "OFF", "SDL_RENDER_GPU": "OFF", "SDL_CAMERA": "OFF",
        "SDL_JOYSTICK": "OFF", "SDL_HAPTIC": "OFF", "SDL_SENSOR": "OFF",
        "SDL_HIDAPI": "OFF", "SDL_TRAY": "OFF", "SDL_DIALOG": "OFF",
        "SDL_POWER": "OFF", "SDL_OPENGL": "OFF", "SDL_OPENGLES": "OFF",
        "SDL_VULKAN": "OFF", "SDL_RENDER_METAL": "ON",
    }
    marker = output / "build-options.json"
    identity = {"options": options, "recipe_sha256": digest(Path(__file__)),
                "compiler": compiler, "cmake": cmake, "sdk": sdk,
                "environment_keys": sorted(ENVIRONMENT_KEYS), "tool_path": BUILD_PATH}
    recorded = dict(identity, library_sha256=digest(library)) if library.exists() else None
    if not recorded or not marker.exists() or marker.read_text() != json.dumps(recorded,sort_keys=True):
        # Rebuild a mismatched cache from verified source, including its objects.
        if build_path.is_symlink():
            raise ValueError("SDL build cache must not be a symbolic link")
        if build_path.exists():
            shutil.rmtree(build_path)
        command = [cmake["path"], "-S", str(source_path), "-B", str(build_path)]
        command += [f"-D{key}={value}" for key, value in options.items()]
        subprocess.run(command, check=True, stdout=sys.stderr, env=environment)
        subprocess.run([cmake["path"], "--build", str(build_path), "--parallel", str(min(os.cpu_count() or 2, 8))],
                       check=True, stdout=sys.stderr, env=environment)
        recorded = dict(identity, library_sha256=digest(library))
        marker.write_text(json.dumps(recorded,sort_keys=True))
    return {"version": VERSION, "source": URL, "source_sha256": SHA256,
            "library": str(library.resolve()), "include": str((source_path / "include").resolve()),
            "library_sha256": digest(library), "build": identity, "link_args": LINK_ARGS}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=PACKAGE / "build" / "sdl")
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(build(args.output_dir.resolve(), args.archive)))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"SDL build failed: {error}", file=sys.stderr)
        sys.exit(1)
