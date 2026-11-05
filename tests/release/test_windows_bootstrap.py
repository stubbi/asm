"""Validate generated Windows bootstrap inputs without executing a candidate.

SPDX-License-Identifier: AGPL-3.0-or-later
Native PowerShell file and process checks belong to the Windows runtime suite.
"""
import base64
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import re
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
