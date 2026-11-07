"""Build the Windows reference packages and run them on matching Windows hosts.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import tempfile
import tomllib
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[2]
VERSION = json.loads((ROOT / "cli/commands.json").read_text())["version"]
TARGETS = (
    ("hello", "x86_64-windows", "x86_64-pc-windows-msvc", "x64", 0x8664),
    ("hello", "aarch64-windows", "aarch64-pc-windows-msvc", "arm64", 0xAA64),
)


def find_linker():
    explicit = os.environ.get("LLD_LINK")
    if explicit:
        return explicit
    located = shutil.which("lld-link")
    if located:
        return located
    rustup = Path(os.environ.get("RUSTUP_HOME", Path.home() / ".rustup"))
    candidates = sorted(rustup.glob("toolchains/*/lib/rustlib/*/bin/gcc-ld/lld-link*"))
    return str(candidates[0]) if candidates else None


def native_windows_machine(kernel32=None):
    """Return the OS ISA even when Python runs under Windows emulation.

    Microsoft IsWow64Process2 documentation, reviewed 2026-11-05:
    https://learn.microsoft.com/en-us/windows/win32/api/wow64apiset/nf-wow64apiset-iswow64process2
    GetNativeSystemInfo can report the emulated ISA on ARM64; do not use it.
    https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getnativesysteminfo
    The native qualification check requires Windows 10 version 1709 or later.
    """
    if kernel32 is None:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    try:
        probe = kernel32.IsWow64Process2
    except AttributeError:
        raise unittest.SkipTest("Native Windows qualification requires IsWow64Process2") from None
    probe.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ushort), ctypes.POINTER(ctypes.c_ushort)]
    probe.restype = ctypes.c_int
    current_process = kernel32.GetCurrentProcess
    current_process.argtypes = []
    current_process.restype = ctypes.c_void_p
    process_machine = ctypes.c_ushort()
    native_machine = ctypes.c_ushort()
    if not probe(current_process(), ctypes.byref(process_machine), ctypes.byref(native_machine)):
        raise OSError(ctypes.get_last_error(), "IsWow64Process2 failed")
    machine = {0x8664: "x64", 0xAA64: "arm64"}.get(native_machine.value)
    if machine is None:
        raise unittest.SkipTest(f"Unsupported native Windows ISA: {native_machine.value:#06x}")
    return machine


def record_native_execution(target, source, executable, case, exit_status):
    print(json.dumps({"phase": "native-execution", "target": target[1], "source": source,
                      "case": case, "exit_status": exit_status,
                      "artifact_sha256": hashlib.sha256(executable.read_bytes()).hexdigest()},
                     sort_keys=True), flush=True)


class WindowsHelloTests(unittest.TestCase):
    def test_native_target_uses_os_isa_even_for_emulated_python(self):
        # An x64 Python process on ARM64 must qualify the ARM64 executable.
        for process_isa, os_isa, expected in ((0, 0x8664, "x64"), (0x8664, 0xAA64, "arm64"),
                                              (0x014C, 0xAA64, "arm64")):
            def probe(_handle, process, native):
                ctypes.cast(process, ctypes.POINTER(ctypes.c_ushort))[0] = process_isa
                ctypes.cast(native, ctypes.POINTER(ctypes.c_ushort))[0] = os_isa
                return 1

            api = SimpleNamespace(IsWow64Process2=probe, GetCurrentProcess=lambda: -1)
            with self.subTest(process_isa=process_isa, os_isa=os_isa):
                self.assertEqual(native_windows_machine(api), expected)
        with self.assertRaisesRegex(unittest.SkipTest, "requires IsWow64Process2"):
            native_windows_machine(SimpleNamespace())
        os_isa = 0x014C
        with self.assertRaisesRegex(unittest.SkipTest, "Unsupported native Windows ISA"):
            native_windows_machine(api)

    def run_tool(self, arguments, directory):
        result = subprocess.run(arguments, cwd=directory, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
        return result

    def build(self, directory, target, source):
        package_name, _, triple, machine, _ = target
        package = ROOT / "examples" / package_name
        target_path = Path("targets") / target[1]
        source_path = target_path / source
        self.assertTrue((package / source_path).is_file(), f"Missing package source: {package / source_path}")
        clang = os.environ.get("CLANG", shutil.which("clang"))
        linker = find_linker()
        if not clang or not linker:
            self.skipTest("Cross-build requires clang and lld-link; set CLANG and LLD_LINK if needed")
        obj = directory / ("test.obj" if source.startswith("tests/") else "hello.obj")
        exe = obj.with_suffix(".exe")
        library = directory / "kernel32.lib"
        self.run_tool([linker, "/lib", f"/machine:{machine}", f"/def:{package / target_path / 'kernel32.def'}",
                       f"/out:{library}"], package)
        self.run_tool([clang, f"--target={triple}", "-c", str(source_path), "-o", str(obj)], package)
        self.run_tool([linker, f"/machine:{machine}", "/entry:mainCRTStartup", "/subsystem:console",
                       "/nodefaultlib", "/dynamicbase", "/nxcompat", "/timestamp:0", "/WX",
                       f"/out:{exe}", str(obj), str(library)], package)
        sources = {package / source_path, *(package / target_path / "src").glob("*.s")}
        print(json.dumps({"phase": "build", "package": package_name, "target": target[1], "source": source,
                          "source_sha256": hashlib.sha256((package / source_path).read_bytes()).hexdigest(),
                          "assembly_sources_sha256": {path.relative_to(package).as_posix():
                              hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(sources)},
                          "artifact_sha256": hashlib.sha256(exe.read_bytes()).hexdigest(),
                          "build_host": {"system": platform.system(), "release": platform.release(),
                                         "python_process_machine": platform.machine()}}, sort_keys=True), flush=True)
        return obj, exe

    def assert_pe(self, path, machine):
        data = path.read_bytes()
        self.assertEqual(data[:2], b"MZ")
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        self.assertEqual(data[pe:pe + 4], b"PE\0\0")
        self.assertEqual(struct.unpack_from("<H", data, pe + 4)[0], machine)
        optional = pe + 24
        self.assertEqual(struct.unpack_from("<H", data, optional)[0], 0x20B)
        self.assertEqual(struct.unpack_from("<H", data, optional + 68)[0], 3)
        self.assertEqual(struct.unpack_from("<H", data, optional + 70)[0] & 0x140, 0x140)
        sections = struct.unpack_from("<H", data, pe + 6)[0]
        start = optional + struct.unpack_from("<H", data, pe + 20)[0]
        entry = struct.unpack_from("<I", data, optional + 16)[0]
        executable_entry = False
        mappings = []
        for number in range(sections):
            header = start + number * 40
            size, address = struct.unpack_from("<II", data, header + 8)
            raw_size, raw_offset = struct.unpack_from("<II", data, header + 16)
            mappings.append((address, raw_size, raw_offset))
            flags = struct.unpack_from("<I", data, header + 36)[0]
            self.assertNotEqual(flags & 0xA0000000, 0xA0000000, "Writable executable section")
            if address <= entry < address + size:
                executable_entry = bool(flags & 0x20000000)
        self.assertTrue(executable_entry, "Entry point must be executable")

        def offset(rva):
            for address, size, raw in mappings:
                if address <= rva < address + size:
                    return raw + rva - address
            self.fail(f"Unmapped relative virtual address: {rva:#x}")

        def string_at(rva):
            position = offset(rva)
            return data[position:data.index(b"\0", position)].decode("ascii")

        imports_rva = struct.unpack_from("<I", data, optional + 120)[0]
        self.assertNotEqual(imports_rva, 0, "Executable must import its Windows APIs")
        descriptor = offset(imports_rva)
        libraries = {}
        while any(data[descriptor:descriptor + 20]):
            lookup, _, _, name, _ = struct.unpack_from("<IIIII", data, descriptor)
            thunk = offset(lookup)
            functions = set()
            while (symbol := struct.unpack_from("<Q", data, thunk)[0]):
                self.assertFalse(symbol & (1 << 63), "Imports must use named Windows APIs")
                functions.add(string_at(symbol + 2))
                thunk += 8
            libraries[string_at(name).lower()] = functions
            descriptor += 20
        expected = {"ExitProcess"} if path.name == "test.exe" else {"GetStdHandle", "WriteFile", "ExitProcess"}
        self.assertEqual(libraries, {"kernel32.dll": expected})
        unwind_rva, unwind_size = struct.unpack_from("<II", data, optional + 136)
        self.assertNotEqual(unwind_rva, 0, "Nonleaf Windows functions require unwind metadata")
        self.assertGreater(unwind_size, 0)
        return hashlib.sha256(data).hexdigest()

    def test_manifest_identity_and_target_match_each_package(self):
        # A manifest that selects the wrong target can publish incompatible source.
        for name, target, *_ in TARGETS:
            with self.subTest(target=target):
                package = ROOT / "examples" / name
                self.assertTrue((package / "asm.toml").is_file(), f"Missing package: {name}")
                manifest = tomllib.loads((package / "asm.toml").read_text())
                self.assertEqual(manifest["package"], {"name": "hello", "version": VERSION})
                self.assertEqual(manifest["target"][target], {"source": f"targets/{target}/src/main.s",
                                                             "test": f"targets/{target}/tests/main.s"})
                self.assertEqual((package / "LICENSE").read_bytes(), (ROOT / "examples/hello/LICENSE").read_bytes())

    def test_main_and_assembly_contract_tests_build_for_each_windows_target(self):
        # Incorrect imports, assembly, ABI metadata, or PE permissions break the package build.
        for target in TARGETS:
            for source in ("src/main.s", "tests/main.s"):
                with self.subTest(target=target[1], source=source), tempfile.TemporaryDirectory() as temporary:
                    obj, exe = self.build(Path(temporary), target, source)
                    self.assertEqual(struct.unpack_from("<H", obj.read_bytes())[0], target[4])
                    self.assert_pe(exe, target[4])

    @unittest.skipUnless(platform.system() == "Windows", "Native Windows runtime check requires Windows")
    def test_native_output_write_failure_and_assembly_contract(self):
        # Truncated output, ignored WriteFile errors, and broken short-write handling must fail.
        native = native_windows_machine()
        target = next(item for item in TARGETS if item[3] == native)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            _, exe = self.build(directory, target, "src/main.s")
            result = subprocess.run([str(exe)], capture_output=True, timeout=10)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"Hello from asm!\n", b""))
            record_native_execution(target, "src/main.s", exe, "stdout", result.returncode)
            destination = directory / "read-only-stdout"
            destination.write_bytes(b"Preserve existing content.\n")
            with destination.open("rb") as output:
                result = subprocess.run([str(exe)], stdout=output, stderr=subprocess.PIPE, timeout=10)
            self.assertEqual((result.returncode, result.stderr), (1, b""))
            self.assertEqual(destination.read_bytes(), b"Preserve existing content.\n")
            record_native_execution(target, "src/main.s", exe, "read-only-stdout", result.returncode)
            _, harness = self.build(directory, target, "tests/main.s")
            result = subprocess.run([str(harness)], capture_output=True, timeout=10)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
            record_native_execution(target, "tests/main.s", harness, "writer-contract", result.returncode)


if __name__ == "__main__":
    unittest.main()
