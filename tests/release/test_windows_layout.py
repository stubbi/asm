"""Check the Windows CLI wire contract without loading candidate executables.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
import windows_layout as layout


TARGET = 'x86_64-windows'
DIGEST = '0123456789abcdef' * 4
RECORD = (b'# asm-cli-current-v1\n1.2.3\tx86_64-windows\t1234\t'
          b'0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\t1\t0.6.0\n')
# Literal wire bytes, independent of the implementation's packer.
METADATA = bytes.fromhex(
    '41534d434c493100 01000000 01000000 01000000 01000000 '
    '01000000 02000000 03000000 00000000 06000000 00000000 '
    '00000000000000000000000000000000')
PE = 0x80
OPTIONAL = PE + 24
TABLE = OPTIONAL + 240
META_SECTION = TABLE + 40
META_RAW = 0x400


def image(target=TARGET):
    """Construct an independent, minimal two-section PE32+ fixture."""
    data = bytearray(0x600)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 0x3c, PE)
    data[PE:PE + 4] = b'PE\0\0'
    machine = {'x86_64-windows': 0x8664, 'aarch64-windows': 0xaa64}[target]
    struct.pack_into('<HHIIIHH', data, PE + 4, machine, 2, 0, 0, 0, 240, 0x22)
    struct.pack_into('<H', data, OPTIONAL, 0x20b)
    struct.pack_into('<I', data, OPTIONAL + 16, 0x1000)
    struct.pack_into('<Q', data, OPTIONAL + 24, 0x140000000)
    struct.pack_into('<II', data, OPTIONAL + 32, 0x1000, 0x200)
    struct.pack_into('<II', data, OPTIONAL + 56, 0x3000, 0x200)
    struct.pack_into('<HH', data, OPTIONAL + 68, 3, 0x100)
    struct.pack_into('<I', data, OPTIONAL + 108, 16)
    for offset, name, virtual, rva, raw, flags in (
            (TABLE, b'.text\0\0\0', 1, 0x1000, 0x200, 0x60000020),
            (META_SECTION, b'.asmmeta', 64, 0x2000, META_RAW, 0x40000040)):
        struct.pack_into('<8sIIIIIIHHI', data, offset, name, virtual, rva,
                         0x200, raw, 0, 0, 0, 0, flags)
    data[0x200] = 0xc3
    data[META_RAW:META_RAW + 64] = METADATA
    return data


class RecordTests(unittest.TestCase):
    def test_exact_record_and_round_trip(self):
        self.assertEqual(layout.encode_record('1.2.3', TARGET, 1234, DIGEST), RECORD)
        self.assertEqual(layout.decode_record(RECORD, TARGET), {
            'version': '1.2.3', 'target': TARGET, 'size': 1234, 'sha256': DIGEST,
            'protocol': 1, 'minimum_launcher': '0.6.0'})

    def test_both_targets_and_bounds(self):
        for target in (TARGET, 'aarch64-windows'):
            for size in (1, 67108864):
                with self.subTest(target=target, size=size):
                    encoded = layout.encode_record('2147483647.2147483647.2147483647', target,
                                                   size, DIGEST, '1.0.0')
                    decoded = layout.decode_record(encoded, target)
                    self.assertEqual(decoded['size'], size)
                    self.assertEqual(decoded['version'], '2147483647.2147483647.2147483647')
                    self.assertEqual(decoded['minimum_launcher'], '1.0.0')

    def test_every_truncation_is_rejected(self):
        for length in range(len(RECORD)):
            with self.subTest(length=length), self.assertRaises(ValueError):
                layout.decode_record(RECORD[:length], TARGET)

    def test_ambiguous_encoding_and_extra_data_are_rejected(self):
        cases = [b'\xef\xbb\xbf' + RECORD, RECORD.replace(b'\n', b'\r\n'),
                 RECORD.replace(b'1.2.3', b'1\x00.2.3'), RECORD + b'\n',
                 RECORD + RECORD.split(b'\n')[1] + b'\n', RECORD + b'x', b'x' * 257,
                 RECORD.replace(b'current-v1', b'current-v2'),
                 RECORD.replace(b'\t1\t0.6.0', b'\t1\textra\t0.6.0'),
                 RECORD.replace(b'\t1\t0.6.0', b'\t0.6.0'),
                 RECORD.replace(b'\t1\t0.6.0', b'\t2\t0.6.0'),
                 RECORD.replace(b'1234', b'\xff')]
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):
                layout.decode_record(value, TARGET)

    def test_noncanonical_versions_and_sizes_are_rejected(self):
        for field in (0, 5):
            for value in (b'01.2.3', b'1.2', b'1.2.3.4', b'+1.2.3', b'1.2.3 ',
                          b'2147483648.0.0', b'1.2.3-beta', b'1.2.\xd9\xa3', b''):
                fields = RECORD.split(b'\n')[1].split(b'\t')
                fields[field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    layout.decode_record(b'# asm-cli-current-v1\n' + b'\t'.join(fields) + b'\n', TARGET)
        for value in (b'0', b'01234', b'+1234', b'1234 ', b'-1', b'67108865', b'1.0', b''):
            with self.subTest(value=value), self.assertRaises(ValueError):
                layout.decode_record(RECORD.replace(b'1234', value), TARGET)

    def test_invalid_digest_and_target_are_rejected(self):
        for digest in ('A' * 64, 'g' * 64, 'a' * 63, 'a' * 65, '../payload'):
            with self.subTest(digest=digest), self.assertRaises(ValueError):
                layout.decode_record(RECORD.replace(DIGEST.encode(), digest.encode()), TARGET)
        for target in ('aarch64-windows', 'x86_64-linux', 'X86_64-windows', ''):
            with self.subTest(target=target), self.assertRaises(ValueError):
                layout.decode_record(RECORD, target)

    def test_encoder_rejects_invalid_fields(self):
        valid = ['1.2.3', TARGET, 1234, DIGEST, '0.6.0']
        for field, values in ((0, ('01.2.3', '2147483648.0.0', None)),
                              (1, ('x86_64-linux', 'X86_64-windows', None)),
                              (2, (0, 67108865, True, 1.5, '1234', None)),
                              (3, ('A' * 64, 'g' * 64, None)),
                              (4, ('0.06.0', '2147483648.0.0', None))):
            for value in values:
                args = valid.copy()
                args[field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    layout.encode_record(*args)


class MetadataTests(unittest.TestCase):
    def test_fresh_build_callers_can_import_as_package_or_tool(self):
        root = Path(__file__).resolve().parents[2]
        for directory, module in ((root, 'tools.windows_layout'), (root / 'tools', 'windows_layout')):
            code = ('import importlib, sys; '
                    'assert "registry" not in sys.modules; '
                    f'assert {str(root / "tools")!r} not in sys.path; '
                    f'layout = importlib.import_module({module!r}); '
                    'print(layout.metadata_bytes("1.2.3").hex())')
            with self.subTest(module=module):
                result = subprocess.run([sys.executable, '-E', '-c', code], cwd=directory,
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, METADATA.hex() + '\n')

    def test_literal_metadata(self):
        self.assertEqual(layout.metadata_bytes('1.2.3'), METADATA)
        self.assertEqual(len(METADATA), 64)
        changed = bytearray(METADATA)
        struct.pack_into('<III', changed, 36, 2, 7, 1)
        self.assertEqual(layout.metadata_bytes('1.2.3', '2.7.1'), bytes(changed))

    def test_metadata_version_bounds(self):
        for version in ('01.2.3', '2147483648.0.0', '-1.0.0', '1.2', None):
            with self.subTest(version=version), self.assertRaises(ValueError):
                layout.metadata_bytes(version)
        for minimum in ('0.06.0', '2147483648.0.0', None):
            with self.subTest(minimum=minimum), self.assertRaises(ValueError):
                layout.metadata_bytes('1.2.3', minimum)

    def test_read_both_exact_targets(self):
        expected = {'schema': 1, 'protocol': 1, 'minimum_protocol': 1, 'maximum_protocol': 1,
                    'version': '1.2.3', 'minimum_launcher': '0.6.0'}
        for target in (TARGET, 'aarch64-windows'):
            with self.subTest(target=target):
                self.assertEqual(layout.read_pe_metadata(bytes(image(target)), target), expected)

    def test_release_version_must_match_metadata(self):
        self.assertEqual(layout.read_pe_metadata(bytes(image()), TARGET,
                                               expected_version='1.2.3')['version'], '1.2.3')
        with self.assertRaises(ValueError):
            layout.read_pe_metadata(bytes(image()), TARGET, expected_version='1.2.4')
        for version in ('01.2.3', '2147483648.0.0', '', 123):
            with self.subTest(version=version), self.assertRaises(ValueError):
                layout.read_pe_metadata(bytes(image()), TARGET, expected_version=version)

    def test_every_pe_truncation_is_rejected(self):
        data = bytes(image())
        for length in range(len(data)):
            with self.subTest(length=length), self.assertRaises(ValueError):
                layout.read_pe_metadata(data[:length], TARGET)

    def test_missing_and_duplicate_sections_are_rejected(self):
        for offset, name in ((META_SECTION, b'.other\0\0'), (TABLE, b'.asmmeta')):
            data = image()
            data[offset:offset + 8] = name
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                layout.read_pe_metadata(bytes(data), TARGET)

    def test_metadata_access_and_storage_flags(self):
        for flags in (0xC0000040, 0x60000040, 0x00000040, 0x40000000, 0x400000c0, 0x40000060):
            data = image()
            struct.pack_into('<I', data, META_SECTION + 36, flags)
            with self.subTest(flags=flags), self.assertRaises(ValueError):
                layout.read_pe_metadata(bytes(data), TARGET)

    def test_metadata_sizes_and_offsets(self):
        for offset, value in ((8, 0), (8, 63), (8, 65), (12, 0), (12, 0xfffff000),
                              (16, 0), (16, 63), (16, 0xfffffe00),
                              (20, 0), (20, 0x200), (20, 0x600), (20, 0xfffffe00)):
            data = image()
            struct.pack_into('<I', data, META_SECTION + offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                layout.read_pe_metadata(bytes(data), TARGET)

    def test_metadata_overlap_with_other_sections(self):
        # Both orderings matter: the metadata can precede or follow the alias.
        for swap in (False, True):
            for offset in (12, 20):
                data = image()
                if swap:
                    first = bytes(data[TABLE:TABLE + 40])
                    data[TABLE:TABLE + 40] = data[META_SECTION:META_SECTION + 40]
                    data[META_SECTION:META_SECTION + 40] = first
                    struct.pack_into('<II', data, TABLE + 12, 0x1000, 0x200)
                    struct.pack_into('<I', data, TABLE + 20, 0x200)
                    struct.pack_into('<II', data, META_SECTION + 12, 0x2000, 0x200)
                    struct.pack_into('<I', data, META_SECTION + 20, META_RAW)
                    struct.pack_into('<I', data, OPTIONAL + 16, 0x2000)
                    data[0x200:0x400], data[0x400:0x600] = data[0x400:0x600], data[0x200:0x400]
                self.assertEqual(layout.read_pe_metadata(bytes(data), TARGET)['version'], '1.2.3')
                value = (0x1000 if swap else 0x2000) if offset == 12 else (0x200 if swap else META_RAW)
                # Make the non-metadata section overlap metadata's virtual or file span.
                other = META_SECTION if swap else TABLE
                struct.pack_into('<I', data, other + offset, value)
                with self.subTest(swap=swap, offset=offset), self.assertRaises(ValueError):
                    layout.read_pe_metadata(bytes(data), TARGET)

    def test_metadata_magic_schema_protocols_reserved_and_versions(self):
        for offset, value in ((0, 0), (8, 2), (12, 0), (12, 2), (16, 0), (16, 2),
                              (20, 0), (20, 2), (24, 2147483648), (36, 2147483648),
                              (48, 1), (60, 1)):
            data = image()
            struct.pack_into('<I', data, META_RAW + offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                layout.read_pe_metadata(bytes(data), TARGET)

    def test_malformed_pe_headers(self):
        for offset, fmt, value in ((0, '<H', 0), (0x3c, '<I', 0xfffffff8),
                                   (PE, '<I', 0), (PE + 4, '<H', 0x14c),
                                   (PE + 6, '<H', 0), (PE + 6, '<H', 97),
                                   (PE + 20, '<H', 111), (PE + 20, '<H', 4097),
                                   (PE + 22, '<H', 0x2022),
                                   (OPTIONAL, '<H', 0x10b),
                                   (OPTIONAL + 60, '<I', 0x100),
                                   (OPTIONAL + 108, '<I', 17)):
            data = image()
            struct.pack_into(fmt, data, offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                layout.read_pe_metadata(bytes(data), TARGET)

    def test_exact_pe_target_and_artifact_bound(self):
        for target in ('aarch64-windows', 'x86_64-linux', 'X86_64-windows', ''):
            with self.subTest(target=target), self.assertRaises(ValueError):
                layout.read_pe_metadata(bytes(image()), target)
        with self.assertRaises(ValueError):
            layout.read_pe_metadata(bytes(67108865), TARGET)

    def test_emitted_coff_section_has_literal_bytes_and_read_only_flags(self):
        clang = shutil.which('clang')
        if not clang:
            self.skipTest('clang is required to check emitted COFF objects')
        for syntax, target in (('x86_64', 'x86_64-pc-windows-msvc'),
                                ('aarch64', 'aarch64-pc-windows-msvc')):
            with self.subTest(syntax=syntax), tempfile.TemporaryDirectory() as temporary:
                source = Path(temporary) / 'metadata.s'
                output = Path(temporary) / 'metadata.obj'
                source.write_text(layout.metadata_assembly('1.2.3', syntax))
                subprocess.run([clang, '--no-default-config', '--target=' + target, '-c',
                                str(source), '-o', str(output)], check=True,
                               capture_output=True, timeout=30)
                data = output.read_bytes()
                count = struct.unpack_from('<H', data, 2)[0]
                sections = [20 + index * 40 for index in range(count)
                            if data[20 + index * 40:28 + index * 40] == b'.asmmeta']
                self.assertEqual(len(sections), 1)
                section = sections[0]
                size, raw = struct.unpack_from('<II', data, section + 16)
                flags = struct.unpack_from('<I', data, section + 36)[0]
                self.assertEqual(size, 64)
                self.assertEqual(data[raw:raw + size], METADATA)
                self.assertEqual(flags & 0xe00000e0, 0x40000040)

    def test_emitter_requires_known_syntax_and_actual_version(self):
        for syntax in ('', 'riscv64', None):
            with self.subTest(syntax=syntax), self.assertRaises(ValueError):
                layout.metadata_assembly('1.2.3', syntax)
        with self.assertRaises(ValueError):
            layout.metadata_assembly('1.02.3', 'x86_64')


if __name__ == '__main__':
    unittest.main()
