"""Native Mach-O installation must reject mismatched or malformed containers."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
import registry
ROOT = Path(__file__).resolve().parents[2]
ASM = ROOT / 'build/asm'

class MachoTests(unittest.TestCase):
    def test_registry_accepts_native_and_rejects_corruption(self):
        original = ASM.read_bytes()
        registry.validate_executable(original, 'aarch64-macos')
        for offset, value in [(0, 0x464c457f), (4, 0x1000007), (12, 1), (16, 129),
                              (20, 0xffffffff), (28, 1), (36, 4), (24, 0x220000)]:
            data = bytearray(original)
            struct.pack_into('<I', data, offset, value)
            with self.subTest(offset=offset), self.assertRaises(registry.RegistryError):
                registry.validate_executable(data, 'aarch64-macos')

    def test_cli_installs_native_without_executing_and_rejects_corruption(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as directory:
            work = Path(directory)
            payload = work / 'payload'
            index = work / 'index.tsv'
            destination = work / 'installed'
            original = ASM.read_bytes()
            candidates = [original]
            for offset, value in [(0, 0x464c457f), (4, 0x1000007), (12, 1), (16, 129), (20, 0xffffffff), (28, 1), (36, 4)]:
                data = bytearray(original)
                struct.pack_into('<I', data, offset, value)
                candidates.append(data)
            candidates += [b'#!/bin/sh\necho forbidden\n']
            for data in candidates:
                payload.write_bytes(data)
                index.write_text('# asm-registry-v1\nstubbi/test\t0.1.0\taarch64-macos\texecutable\t'
                                 + hashlib.sha256(data).hexdigest() + '\thttps://github.com/stubbi/asm/releases/download/v0.1.0/payload\t'
                                 + str(len(data)) + '\tNative test\n')
                result = subprocess.run([str(ASM), 'install', 'stubbi/test', '--index', str(index), '--artifact', str(payload),
                                         '--output', str(destination)], cwd=work, capture_output=True, timeout=15)
                with self.subTest(prefix=data[:32]):
                    self.assertEqual(result.returncode, 0 if data == original else 1, result.stderr)
                    if data == original:
                        self.assertEqual(destination.read_bytes(), original)
                        destination.unlink()
                    else:
                        self.assertFalse(destination.exists())

    def test_invalid_signature_preserves_structured_json_error(self):
        data = bytearray(ASM.read_bytes())
        offset = 32
        for _ in range(struct.unpack_from('<I', data, 16)[0]):
            command, length = struct.unpack_from('<II', data, offset)
            if command == 0x80000028:
                entry = struct.unpack_from('<Q', data, offset + 8)[0]
                data[entry] ^= 1
                break
            offset += length
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as directory:
            work = Path(directory)
            (work / 'payload').write_bytes(data)
            (work / 'index.tsv').write_text('# asm-registry-v1\nstubbi/test\t0.1.0\taarch64-macos\texecutable\t'
                + hashlib.sha256(data).hexdigest() + '\thttps://github.com/stubbi/asm/releases/download/v0.1.0/payload\t'
                + str(len(data)) + '\tInvalid signature\n')
            result = subprocess.run([str(ASM), 'install', 'stubbi/test', '--index', 'index.tsv', '--artifact', 'payload',
                '--output', 'installed', '--json'], cwd=work, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 1)
            self.assertFalse(json.loads(result.stderr)['ok'])
            self.assertFalse((work / 'installed').exists())
