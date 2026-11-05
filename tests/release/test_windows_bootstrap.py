"""Validate generated Windows bootstrap inputs without executing a candidate.

SPDX-License-Identifier: AGPL-3.0-or-later
Native PowerShell file and process checks belong to the Windows runtime suite.
"""
import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))


def executable(machine=0x8664, metadata=True):
    """Build a nonexecuted PE32+ fixture with independently encoded metadata."""
    data = bytearray(1536)
    pe, optional, sections = 128, 152, 392
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 60, pe)
    data[pe:pe + 4] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", data, pe + 4, machine, 2, 0, 0, 0, 240, 0x22)
    struct.pack_into("<H", data, optional, 0x20b)
    struct.pack_into("<II", data, optional + 16, 0x1000, 0x1000)
    struct.pack_into("<Q", data, optional + 24, 0x140000000)
    struct.pack_into("<II", data, optional + 32, 4096, 512)
    struct.pack_into("<II", data, optional + 56, 0x3000, 512)
    struct.pack_into("<HH", data, optional + 68, 3, 0x8160)
    struct.pack_into("<I", data, optional + 108, 16)
    struct.pack_into("<8sIIIIIIHHI", data, sections, b".text", 4, 0x1000, 512, 512, 0, 0, 0, 0, 0x60000020)
    data[512:516] = b"\xc3\0\0\0" if machine == 0x8664 else b"\xc0\x03\x5f\xd6"
    struct.pack_into("<8sIIIIIIHHI", data, sections + 40, b".asmmeta" if metadata else b".data",
                     64, 0x2000, 512, 1024, 0, 0, 0, 0, 0x40000040)
    data[1024:1088] = struct.pack("<8s10I16s", b"ASMCLI1\0", 1, 1, 1, 1, 0, 6, 1, 0, 6, 0, b"\0" * 16)
    return bytes(data)


def specification(script):
    match = re.search(rb"(?m)^\$AsmSpecBase64 = '([A-Za-z0-9+/=]+)'$", script)
    if match is None:
        raise AssertionError("The generated installer lacks its bounded data specification.")
    return json.loads(base64.b64decode(match[1], validate=True))


class WindowsBootstrapTests(unittest.TestCase):
    def setUp(self):
        source = ROOT / "tools/windows_bootstrap.py"
        self.assertTrue(source.is_file(), "The Windows bootstrap generator is absent.")
        spec = importlib.util.spec_from_file_location("windows_bootstrap", source)
        self.generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.generator)

    def test_source_installer_binds_actual_pe_bytes_and_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            for target, machine in (("x86_64-windows", 0x8664), ("aarch64-windows", 0xaa64)):
                artifact = Path(temporary) / (target + "-' space-\u00e9-\U0001f600.exe")
                image = executable(machine)
                artifact.write_bytes(image)
                script = self.generator.render_source_installer(artifact, target)
                script.decode("ascii")
                data = specification(script)
                self.assertEqual(data["mode"], "source")
                self.assertEqual(data["version"], "0.6.1")
                self.assertEqual(data["artifacts"], [{"target": target, "path": str(artifact.resolve()),
                    "bytes": 1536, "sha256": hashlib.sha256(image).hexdigest()}])
                self.assertEqual(artifact.read_bytes(), image)

    def test_fresh_python_process_can_import_the_build_api_as_a_package(self):
        result = subprocess.run([sys.executable, "-c", "from tools.windows_bootstrap import render_source_installer"],
                                cwd=ROOT, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))

    def test_invalid_cli_input_preserves_an_existing_output_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            artifact, output = Path(temporary) / "bad.exe", Path(temporary) / "install.ps1"
            artifact.write_bytes(b"not a PE artifact")
            output.write_bytes(b"previous installer")
            result = subprocess.run([sys.executable, str(ROOT / "tools/windows_bootstrap.py"),
                "--source-artifact", str(artifact), "--target", "x86_64-windows", "--output", str(output)],
                cwd=ROOT, capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")
            self.assertIn(b"Windows bootstrap:", result.stderr)
            self.assertEqual(output.read_bytes(), b"previous installer")

    def test_cli_generates_a_quiet_complete_source_installer(self):
        with tempfile.TemporaryDirectory() as temporary:
            artifact, output = Path(temporary) / "source-' \u00e9.exe", Path(temporary) / "install.ps1"
            image = executable()
            artifact.write_bytes(image)
            result = subprocess.run([sys.executable, str(ROOT / "tools/windows_bootstrap.py"),
                "--source-artifact", str(artifact), "--target", "x86_64-windows", "--output", str(output)],
                cwd=ROOT, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertEqual((result.stdout, result.stderr), (b"", b""))
            script = output.read_bytes()
            script.decode("ascii")
            self.assertEqual(specification(script), {"mode": "source", "version": "0.6.1", "artifacts": [
                {"target": "x86_64-windows", "path": str(artifact.resolve()), "bytes": 1536,
                 "sha256": hashlib.sha256(image).hexdigest()}]})
            self.assertEqual(artifact.read_bytes(), image)

    def test_runtime_pe_parser_uses_the_shared_bounded_container_profile(self):
        """Run the real parser on data; substitute only unrelated Windows identity.

        This host-only .NET 8 test does not call Windows APIs or execute a PE.
        The native PowerShell suite independently exercises the complete script.
        """
        dotnet = shutil.which("dotnet")
        if dotnet is None:
            self.skipTest("The optional host-only parser check requires an installed .NET 8 SDK.")
        environment = dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1")
        installed = subprocess.run([dotnet, "--list-sdks"], capture_output=True, text=True, timeout=10, env=environment)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        sdks = re.findall(r"(?m)^(8\.0\.[0-9]+) \[(.+)\]$", installed.stdout)
        if not sdks:
            self.skipTest("The optional host-only parser check requires an installed .NET 8 SDK.")
        version, directory = max(sdks, key=lambda item: tuple(map(int, item[0].split("."))))
        sdk = Path(directory) / version
        packs = list((sdk.parent.parent / "packs/Microsoft.NETCore.App.Ref").glob("8.*/ref/net8.0"))
        self.assertTrue(packs, "The installed .NET 8 SDK lacks its reference assemblies.")
        refs = max(packs, key=lambda p: tuple(map(int, p.parents[1].name.split("."))))
        cases = [("x64", executable(), "x86_64-windows", True),
                 ("arm64", executable(0xaa64), "aarch64-windows", True)]
        for label, offset, fmt, value, expected in (
                ("no_large_address_flag", 150, "H", 2, True),
                ("native_subsystem", 220, "H", 1, False),
                ("gui_cli_subsystem", 220, "H", 2, False),
                ("zero_image_base", 176, "Q", 0, False),
                ("image_above_two_gib", 208, "I", 0x90000000, False),
                ("text_zero_virtual_size", 400, "I", 0, True)):
            image = bytearray(executable())
            struct.pack_into("<" + fmt, image, offset, value)
            cases.append((label, bytes(image), "x86_64-windows", expected))
        for label, offset, address, size, expected in (("global_pointer", 328, 0x1000, 0, True),
                ("header_directory", 272, 64, 8, True), ("short_certificate", 296, 1536, 4, False)):
            image = bytearray(executable()) + (b"\x08\0\0\0\0\x02\x02\0" if label == "short_certificate" else b"")
            struct.pack_into("<II", image, offset, address, size)
            cases.append((label, bytes(image), "x86_64-windows", expected))
        gap = bytearray(executable())
        struct.pack_into("<I", gap, 444, 0x3000)
        struct.pack_into("<I", gap, 208, 0x4000)
        cases.append(("section_gap", bytes(gap), "x86_64-windows", False))
        header = bytearray(executable())
        header[132:476] = bytes(header[128:472])
        struct.pack_into("<I", header, 60, 132)
        cases.append(("unaligned_pe_header", bytes(header), "x86_64-windows", False))
        for label, image, target, expected in cases:
            with self.subTest(oracle=label):
                try:
                    self.generator.windows_layout.read_pe_metadata(image, target, expected_version="0.6.1")
                    accepted = True
                except ValueError:
                    accepted = False
                self.assertEqual(accepted, expected)
        template = (ROOT / "tools/windows-install.ps1.in").read_text(encoding="ascii")
        source = template.split("-TypeDefinition @'\n", 1)[1].split("\n'@", 1)[0]
        source = source.replace("WindowsIdentity.GetCurrent().User.Value", '"S-1-5-21-1"')
        source += '''
public static class ParserProbe {
    public static void Main(string[] args) {
        var parser = typeof(AsmBootstrapV1.Installer).GetMethod("Pe", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static);
        for (int i=0; i<args.Length; i+=2) {
            try { parser.Invoke(null, new object[] { System.IO.File.ReadAllBytes(args[i]), args[i+1], "0.6.1" }); System.Console.WriteLine("accept"); }
            catch (System.Reflection.TargetInvocationException) { System.Console.WriteLine("reject"); }
        }
    }
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            code = base / "Probe.cs"
            code.write_text(source)
            output = base / "Probe.dll"
            command = [dotnet, str(sdk / "Roslyn/bincore/csc.dll"), "/nologo", "/langversion:5", "/target:exe",
                       "/nostdlib+", "/out:" + str(output)]
            command.extend("/reference:" + str(path) for path in refs.glob("*.dll"))
            command.append(str(code))
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=30, env=environment)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            (base / "Probe.runtimeconfig.json").write_text(json.dumps({"runtimeOptions": {"tfm": "net8.0",
                "framework": {"name": "Microsoft.NETCore.App", "version": "8.0.0"}}}))
            arguments = [dotnet, str(output)]
            for label, image, target, _ in cases:
                path = base / (label + ".bin")
                path.write_bytes(image)
                arguments.extend((str(path), target))
            result = subprocess.run(arguments, capture_output=True, text=True, timeout=20, env=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(result.stdout.splitlines()), len(cases), result.stdout)
            for (label, _, _, expected), actual in zip(cases, result.stdout.splitlines()):
                with self.subTest(runtime=label):
                    self.assertEqual(actual, "accept" if expected else "reject")

    def test_source_generation_rejects_target_confusion_and_missing_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            artifact = Path(temporary) / "asm.exe"
            for data, target in ((executable(), "aarch64-windows"),
                                 (executable(), "x86_64-linux"),
                                 (executable(metadata=False), "x86_64-windows")):
                artifact.write_bytes(data)
                with self.subTest(target=target, metadata=data[432:440]), self.assertRaises(ValueError):
                    self.generator.render_source_installer(artifact, target)
                self.assertEqual(artifact.read_bytes(), data)

    def release(self):
        version = "0.6.1"
        base = "https://github.com/stubbi/asm/releases/download/v" + version
        return {"version": version, "source_commit": "a" * 40, "repository_id": 1441332955,
            "bundle_url": base + "/release-attestation.sigstore.json", "artifacts": [
                {"target": "x86_64-windows", "bytes": 1536, "sha256": "b" * 64,
                 "url": base + "/asm-0.6.1-x86_64-windows"}]}

    def test_published_generation_retains_exact_artifact_and_provenance_inputs(self):
        release = self.release()
        data = specification(self.generator.render_installer(release))
        self.assertEqual(data, {"mode": "published", **release})

    def test_published_generation_rejects_incomplete_or_ambiguous_records(self):
        original = self.release()
        changes = ({"source_commit": "0" * 40}, {"repository_id": 1}, {"bundle_url": "https://example.com/bundle"},
                   {"artifacts": []}, {"artifacts": original["artifacts"] * 2}, {"extra": "ignored"})
        for change in changes:
            release = {**copy.deepcopy(original), **change}
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.generator.render_installer(release)
        for field in original:
            release = copy.deepcopy(original)
            del release[field]
            with self.subTest(missing=field), self.assertRaises(ValueError):
                self.generator.render_installer(release)


if __name__ == "__main__":
    unittest.main()
