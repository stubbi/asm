#!/usr/bin/env python3
"""Compile and run native platform tests with SDL's test devices."""
import importlib.util
import hashlib
import os
from pathlib import Path
import subprocess
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib

PACKAGE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_sdl", PACKAGE / "tools/build_sdl.py")
dependency = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dependency)


def main():
    sdl = dependency.build(PACKAGE / "build/sdl")
    with tempfile.TemporaryDirectory(prefix="asm-doom-platform-") as temporary:
        executable = str(Path(temporary) / "platform-test")
        build_environment = dependency.build_environment(Path(temporary) / "environment")
        subprocess.run(["/usr/bin/clang", "-arch", "arm64", "-mmacosx-version-min=15.0", "-Wl,-no_uuid", "-Wall", "-Wextra",
                        "-I", sdl["include"], str(PACKAGE / "tests/platform_driver.c"),
                        str(PACKAGE / "tests/platform_abi.s"),
                        str(PACKAGE / "src/platform.s"), sdl["library"], *sdl["link_args"], "-o", executable],
                       check=True, env=build_environment)
        native = os.environ.get("ASM_DOOM_NATIVE_PLATFORM_TEST") == "1"
        env = dict(build_environment, SDL_VIDEO_DRIVER="cocoa" if native else "dummy",
                   SDL_AUDIO_DRIVER="coreaudio" if native else "dummy",
                   SDL_RENDER_DRIVER="metal" if native else "software")
        print("platform test artifact SHA-256:",hashlib.sha256(Path(executable).read_bytes()).hexdigest())
        print("platform test drivers:",env["SDL_VIDEO_DRIVER"],env["SDL_AUDIO_DRIVER"],env["SDL_RENDER_DRIVER"])
        subprocess.run([executable,"--headless"], check=True, env=env, timeout=10)
        subprocess.run([executable], check=True, env=env, timeout=20)
        wad_path = PACKAGE / "assets/freedoom1.wad.zlib"
        if wad_path.exists():
            wad = zlib.decompress(wad_path.read_bytes())
            count, directory = struct.unpack_from("<II", wad, 4)
            for index in range(count):
                offset, size, name = struct.unpack_from("<II8s", wad, directory+index*16)
                if name.rstrip(b"\0") == b"D_E1M1":
                    score = Path(temporary) / "e1m1.mid"
                    score.write_bytes(wad[offset:offset+size])
                    subprocess.run([executable,"--music",str(score)],check=True,env=env,timeout=20)
                    break
            else:
                raise AssertionError("bundled E1M1 music is missing")
        env["SDL_VIDEO_DRIVER"]="asm-invalid-driver"
        subprocess.run([executable,"--failure"], check=True, env=env, timeout=10)
        env["SDL_VIDEO_DRIVER"]="dummy"
        env["SDL_AUDIO_DRIVER"]="asm-invalid-driver"
        env["SDL_RENDER_DRIVER"]="software"
        subprocess.run([executable,"--muted"], check=True, env=env, timeout=10)


class PlatformTests(unittest.TestCase):
    def test_native_platform_contract(self):
        main()

    def test_dependency_rejects_unsupported_host(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(dependency.platform, "machine", return_value="x86_64"):
            with self.assertRaisesRegex(ValueError,"Apple Silicon"):
                dependency.build(Path(temporary))

    def test_dependency_rejects_corrupt_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            base=Path(temporary)
            archive=base / "wrong.tar.gz"
            archive.write_bytes(b"corrupt SDL source")
            output=base / "output"
            output.mkdir()
            retained=output / f"SDL3-{dependency.VERSION}.tar.gz"
            retained.write_bytes(b"retain existing cache on failure")
            with self.assertRaisesRegex(ValueError,"checksum"):
                dependency.build(output,archive)
            self.assertEqual(retained.read_bytes(),b"retain existing cache on failure")


if __name__ == "__main__":
    unittest.main()
