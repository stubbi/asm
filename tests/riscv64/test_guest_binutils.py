"""Guest cross-tools must be actual RISC-V binaries bound to reviewed bytes.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import importlib.util
import io
import json
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def module():
    spec = importlib.util.spec_from_file_location("guest_binutils", ROOT / "tools/riscv64_guest_binutils.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def elf():
    result = bytearray(64)
    result[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HH", result, 16, 3, 243)
    struct.pack_into("<I", result, 48, 5)
    return result


class GuestBinutilsTests(unittest.TestCase):
    def test_host_cross_tool_or_wrong_abi_cannot_be_a_guest_tool(self):
        provider = module()
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "as"
            path.write_bytes(elf())
            self.assertEqual(provider.tool_contract(path)["elf_machine"], 243)
            for offset, value in ((18, 62), (16, 1), (48, 0)):
                changed = elf()
                struct.pack_into("<H" if offset != 48 else "<I", changed, offset, value)
                path.write_bytes(changed)
                with self.subTest(offset=offset), self.assertRaises(ValueError):
                    provider.tool_contract(path)

    def test_source_extraction_rejects_traversal_links_and_oversized_members(self):
        provider = module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "source.tar"
            for number, (name, kind, size) in enumerate((
                    ("binutils-2.47/configure", tarfile.REGTYPE, 2),
                    ("binutils-2.47/../escape", tarfile.REGTYPE, 2),
                    ("binutils-2.47/link", tarfile.SYMTYPE, 0),
                    ("binutils-2.47/huge", tarfile.REGTYPE, 33554433))):
                with tarfile.open(archive, "w") as output:
                    entry = tarfile.TarInfo(name)
                    entry.type, entry.size, entry.linkname = kind, size, "/etc/passwd"
                    if size <= 2:
                        output.addfile(entry, io.BytesIO(b"ok") if size else None)
                    else:
                        output.fileobj.write(entry.tobuf())
                destination = root / str(number)
                destination.mkdir()
                if number == 0:
                    provider.extract_source(archive, destination)
                    self.assertEqual((destination / "binutils-2.47/configure").read_bytes(), b"ok")
                else:
                    with self.subTest(name=name), self.assertRaises((ValueError, tarfile.TarError)):
                        provider.extract_source(archive, destination)

    def test_guest_manifest_requires_all_four_exact_tool_files(self):
        provider = module()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "bin").mkdir()
            tools = {}
            for name in provider.TOOL_NAMES:
                path = directory / "bin" / name
                path.write_bytes(elf())
                tools[name] = {"file": "bin/" + name, **provider.tool_contract(path)}
            report = {"schema": 1, "scope": "riscv64-guest-binutils", "outcome": "pass",
                      "host": "riscv64-linux-gnu", "source": {"version": provider.VERSION,
                        "sha256": provider.SOURCE_SHA256}, "tools": tools}
            manifest = directory / "manifest.json"
            manifest.write_text(json.dumps(report))
            self.assertEqual(set(provider.validate_manifest(directory)["tools"]), set(provider.TOOL_NAMES))
            first = next(iter(tools))
            (directory / tools[first]["file"]).write_bytes(b"changed")
            with self.assertRaises(ValueError):
                provider.validate_manifest(directory)
            del tools[first]
            manifest.write_text(json.dumps(report))
            with self.assertRaises(ValueError):
                provider.validate_manifest(directory)


if __name__ == "__main__":
    unittest.main()
