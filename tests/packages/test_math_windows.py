"""Build Windows callable math examples and run their ABI tests natively.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

from pathlib import Path
import platform
import subprocess
import tempfile
import tomllib
import unittest

if __package__:
    from . import test_hello_windows as windows
else:
    import test_hello_windows as windows


TARGETS = tuple((name.replace("hello", "math"), *rest) for name, *rest in windows.TARGETS)


class WindowsMathTests(unittest.TestCase):
    def test_manifest_identity_and_target_match_each_package(self):
        for name, target, *_ in TARGETS:
            with self.subTest(target=target):
                package = windows.ROOT / "examples" / name
                self.assertTrue((package / "asm.toml").is_file(), f"Missing package: {name}")
                manifest = tomllib.loads((package / "asm.toml").read_text())
                self.assertEqual(manifest["package"], {"name": "math", "version": windows.VERSION})
                self.assertEqual(manifest["target"][target], {"source": f"targets/{target}/src/main.s",
                                                             "test": f"targets/{target}/tests/main.s"})
                self.assertEqual((package / "LICENSE").read_bytes(), (windows.ROOT / "examples/math/LICENSE").read_bytes())

    def test_main_and_callable_assembly_abi_tests_build_for_each_windows_target(self):
        # A wrong target, missing callable source, or broken import/unwind contract must fail.
        fixture = windows.WindowsHelloTests()
        for target in TARGETS:
            for source in ("src/main.s", "tests/main.s", "tests/io.s"):
                with self.subTest(target=target[1], source=source), tempfile.TemporaryDirectory() as temporary:
                    _, exe = fixture.build(Path(temporary), target, source)
                    fixture.assert_pe(exe, target[4])

    @unittest.skipUnless(platform.system() == "Windows", "Native Windows runtime check requires Windows")
    def test_native_example_and_unsigned_callee_saved_register_contract(self):
        # Signed comparisons, incorrect results, and damaged nonvolatile registers must fail.
        native = windows.native_windows_machine()
        target = next(item for item in TARGETS if item[3] == native)
        fixture = windows.WindowsHelloTests()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            _, exe = fixture.build(directory, target, "src/main.s")
            result = subprocess.run([str(exe)], capture_output=True, timeout=10)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"min(12, 37) = 12\n", b""))
            windows.record_native_execution(target, "src/main.s", exe, "stdout", result.returncode)
            destination = directory / "read-only-stdout"
            destination.write_bytes(b"Preserve existing content.\n")
            with destination.open("rb") as output:
                result = subprocess.run([str(exe)], stdout=output, stderr=subprocess.PIPE, timeout=10)
            self.assertEqual((result.returncode, result.stderr), (1, b""))
            self.assertEqual(destination.read_bytes(), b"Preserve existing content.\n")
            windows.record_native_execution(target, "src/main.s", exe, "read-only-stdout", result.returncode)
            for source in ("tests/main.s", "tests/io.s"):
                with self.subTest(source=source):
                    _, harness = fixture.build(directory, target, source)
                    result = subprocess.run([str(harness)], capture_output=True, timeout=10)
                    self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
                    windows.record_native_execution(target, source, harness, "assembly-contract", result.returncode)


if __name__ == "__main__":
    unittest.main()
