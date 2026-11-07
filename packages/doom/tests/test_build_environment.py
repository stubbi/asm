#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build tools must reject ambient toolchain and configuration injection."""
import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

PACKAGE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("doom_build_sdl_environment", PACKAGE / "tools/build_sdl.py")
dependency = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dependency)


class BuildEnvironmentTests(unittest.TestCase):
    def test_poisoned_ambient_environment_builds_arm64_probe(self):
        with tempfile.TemporaryDirectory(prefix="doom-build-environment-") as temporary:
            base = Path(temporary)
            source = base / "probe.c"
            executable = base / "probe"
            source.write_text('#include <stdio.h>\nint main(void) { puts("native probe"); return 0; }\n')
            poison = {
                "PATH": "/asm-invalid-tools", "HOME": "/asm-invalid-home", "TMPDIR": "/asm-invalid-tmp",
                "SDKROOT": "/asm-invalid-sdk", "DEVELOPER_DIR": "/asm-invalid-developer",
                "CC": "/asm-invalid-compiler", "CFLAGS": "--asm-invalid-flag",
                "CPATH": "/asm-invalid-headers", "C_INCLUDE_PATH": "/asm-invalid-headers",
                "LIBRARY_PATH": "/asm-invalid-libraries", "MACOSX_DEPLOYMENT_TARGET": "1.0",
                "CCC_OVERRIDE_OPTIONS": "^--asm-invalid-driver-option", "CMAKE_TOOLCHAIN_FILE": "/asm-invalid-toolchain",
                "DYLD_INSERT_LIBRARIES": "/asm-invalid-loader", "GITHUB_TOKEN": "test-only-no-credential",
                "AWS_ACCESS_KEY_ID": "test-only-no-credential", "ASM_ENVIRONMENT_SECRET": "test-only-no-credential",
            }
            with patch.dict(os.environ, poison):
                environment = dependency.build_environment(base / "private")
                self.assertEqual(set(environment), {"PATH", "HOME", "TMPDIR", "LC_ALL", "LANG", "SDKROOT"})
                self.assertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
                self.assertEqual(environment["LC_ALL"], "C")
                self.assertEqual(environment["LANG"], "C")
                self.assertTrue(Path(environment["SDKROOT"]).is_dir())
                for name in ("HOME", "TMPDIR"):
                    private = Path(environment[name])
                    self.assertEqual(private.parent, base / "private")
                    self.assertFalse(private.is_symlink())
                    self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o700)
                subprocess.run(["/usr/bin/clang", "-arch", "arm64", "-mmacosx-version-min=15.0",
                                str(source), "-o", str(executable)], env=environment, check=True,
                               capture_output=True, text=True, timeout=30)
                description = subprocess.check_output(["/usr/bin/file", str(executable)], env=environment, text=True)
                self.assertIn("Mach-O 64-bit executable arm64", description)
                result = subprocess.run([str(executable)], env=environment, capture_output=True, text=True, timeout=5)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "native probe\n", ""))

    def test_environment_rejects_existing_links(self):
        with tempfile.TemporaryDirectory(prefix="doom-build-link-") as temporary:
            base = Path(temporary)
            target = base / "retain"
            target.mkdir(mode=0o700)
            marker = target / "marker"
            marker.write_text("preserve")
            linked = base / "linked"
            linked.symlink_to(target, target_is_directory=True)
            with self.assertRaisesRegex(ValueError,"private|symbolic|directory"):
                dependency.build_environment(linked)
            self.assertEqual(marker.read_text(), "preserve")
            private = base / "private"
            private.mkdir(mode=0o700)
            (private / "home").symlink_to(target, target_is_directory=True)
            with self.assertRaisesRegex(ValueError,"private|symbolic|directory"):
                dependency.build_environment(private)
            self.assertEqual(marker.read_text(), "preserve")

    def test_environment_rejects_public_existing_directory(self):
        with tempfile.TemporaryDirectory(prefix="doom-build-permissions-") as temporary:
            base = Path(temporary) / "public"
            base.mkdir(mode=0o755)
            base.chmod(0o755)
            with self.assertRaisesRegex(ValueError,"private|0700|permission"):
                dependency.build_environment(base)
            self.assertEqual(stat.S_IMODE(base.stat().st_mode),0o755)

    def test_supplied_environment_cannot_reintroduce_poison(self):
        with tempfile.TemporaryDirectory(prefix="doom-build-supplied-environment-") as temporary:
            base = Path(temporary)
            environment = dependency.build_environment(base / "private")
            for override in ({"CCC_OVERRIDE_OPTIONS":"^--asm-invalid-option"}, {"SDKROOT":"/asm-invalid-sdk"}):
                with self.subTest(override=list(override)):
                    with self.assertRaisesRegex(ValueError,"ambient|SDKROOT"):
                        dependency.build(base / "sdl", environment=dict(environment, **override))


if __name__ == "__main__":
    unittest.main()
