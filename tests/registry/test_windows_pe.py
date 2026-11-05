"""Bounded Windows executable container checks; these tests do not run images."""
from pathlib import Path
import copy
import hashlib
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
import registry

PE = 128
OPTIONAL = PE + 24
SECTIONS = OPTIONAL + 240


def image(machine=0x8664, second=False):
    data = bytearray(1536 if second else 1024)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 60, PE)
    data[PE:PE + 4] = b'PE\0\0'
    struct.pack_into('<HHIIIHH', data, PE + 4, machine, 2 if second else 1, 0, 0, 0, 240, 0x22)
    struct.pack_into('<H', data, OPTIONAL, 0x20b)
    struct.pack_into('<II', data, OPTIONAL + 16, 0x1000, 0x1000)
    struct.pack_into('<Q', data, OPTIONAL + 24, 0x140000000)
    struct.pack_into('<II', data, OPTIONAL + 32, 4096, 512)
    struct.pack_into('<II', data, OPTIONAL + 56, 0x3000 if second else 0x2000, 512)
    struct.pack_into('<HH', data, OPTIONAL + 68, 3, 0x8160)
    struct.pack_into('<I', data, OPTIONAL + 108, 16)
    struct.pack_into('<8sIIIIIIHHI', data, SECTIONS, b'.text', 4, 0x1000, 512, 512, 0, 0, 0, 0, 0x60000020)
    data[512:516] = b'\xc3\0\0\0' if machine == 0x8664 else b'\xc0\x03\x5f\xd6'
    if second:
        struct.pack_into('<8sIIIIIIHHI', data, SECTIONS + 40, b'.data', 4, 0x2000, 512, 1024, 0, 0, 0, 0, 0xc0000040)
    return data


def record(artifacts):
    return {'schema': 1, 'name': 'owner/program', 'version': '0.6.0',
            'summary': 'A container validation fixture.', 'license': 'MIT',
            'source': {'repository': 'https://github.com/owner/program', 'commit': 'a' * 40, 'path': '.'},
            'artifacts': artifacts, 'yanked': False}


def artifact(target, kind='executable'):
    suffix = '.tar.gz' if kind == 'source' else '.exe'
    return {'target': target, 'kind': kind, 'bytes': 1024, 'sha256': 'a' * 64,
            'url': f'https://github.com/owner/program/releases/download/v0.6.0/program-{target}-{kind}{suffix}'}


class WindowsContainerTests(unittest.TestCase):
    def rejects(self, data, target='x86_64-windows'):
        with self.assertRaises(registry.RegistryError):
            registry.validate_executable(bytes(data), target)

    def test_accepts_both_native_machine_containers_and_artifact_binding(self):
        for target, machine in (('x86_64-windows', 0x8664), ('aarch64-windows', 0xaa64)):
            with self.subTest(target=target):
                data = bytes(image(machine))
                item = artifact(target)
                item.update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
                release = record([item])
                registry.validate_manifest(release)
                registry.validate_artifact(data, release, item)
                registry.validate_executable(bytes(image(machine, second=True)), target)

    def test_rejects_every_truncation(self):
        data = image()
        for end in range(len(data)):
            with self.subTest(end=end):
                self.rejects(data[:end])

    def test_rejects_machine_confusion_and_non_program_images(self):
        for machine in (0x14c, 0xaa64, 0xa641, 0xa64e):
            with self.subTest(machine=machine):
                self.rejects(image(machine))
        for flags in (0, 0x2022, 0x1022, 0x122):
            data = image()
            struct.pack_into('<H', data, PE + 22, flags)
            self.rejects(data)
        data = image()
        struct.pack_into('<H', data, OPTIONAL, 0x10b)
        self.rejects(data)

    def test_rejects_header_and_alignment_bounds(self):
        for offset, value in ((60, 0xffffffff), (OPTIONAL + 32, 0),
                              (OPTIONAL + 32, 3072), (OPTIONAL + 36, 1),
                              (OPTIONAL + 36, 768), (OPTIONAL + 36, 131072),
                              (OPTIONAL + 56, 0x1000), (OPTIONAL + 56, 0x2001),
                              (OPTIONAL + 60, 256), (OPTIONAL + 60, 1536)):
            with self.subTest(offset=offset, value=value):
                data = image()
                struct.pack_into('<I', data, offset, value)
                self.rejects(data)
        for count in (0, 97):
            data = image()
            struct.pack_into('<H', data, PE + 6, count)
            self.rejects(data)
        for optional_size in (0, 111, 65535):
            data = image()
            struct.pack_into('<H', data, PE + 20, optional_size)
            self.rejects(data)

    def test_rejects_writable_code_and_executable_stack_policy(self):
        data = image()
        struct.pack_into('<I', data, SECTIONS + 36, 0xe0000020)
        self.rejects(data)
        data = image()
        struct.pack_into('<H', data, OPTIONAL + 70, 0x8060)
        self.rejects(data)

    def test_rejects_entry_outside_initialized_executable_section(self):
        for entry in (0, 128, 0x1004, 0x1200, 0xffffffff):
            data = image()
            struct.pack_into('<I', data, OPTIONAL + 16, entry)
            self.rejects(data)
        data = image(second=True)
        struct.pack_into('<I', data, OPTIONAL + 16, 0x2000)
        self.rejects(data)
        data = image()
        struct.pack_into('<I', data, SECTIONS + 8, 1024)
        struct.pack_into('<I', data, OPTIONAL + 16, 0x1200)
        self.rejects(data)

    def test_rejects_section_overlap_and_out_of_bounds(self):
        for offset, value in ((SECTIONS + 12, 0), (SECTIONS + 12, 0xfffff000),
                              (SECTIONS + 16, 1024), (SECTIONS + 20, 0),
                              (SECTIONS + 20, 513)):
            data = image()
            struct.pack_into('<I', data, offset, value)
            self.rejects(data)
        for offset, value in ((SECTIONS + 40 + 12, 0x1000),
                              (SECTIONS + 40 + 20, 512)):
            data = image(second=True)
            struct.pack_into('<I', data, offset, value)
            self.rejects(data)

    def test_rejects_unmapped_directories_and_certificate_overlap(self):
        data = image()
        struct.pack_into('<I', data, OPTIONAL + 108, 17)
        self.rejects(data)
        for address, size in ((0, 1), (0xffffffff, 8), (0x1003, 8), (0x2000, 8)):
            data = image()
            struct.pack_into('<II', data, OPTIONAL + 112 + 8, address, size)
            self.rejects(data)
        data = image()
        struct.pack_into('<II', data, OPTIONAL + 112 + 4 * 8, 512, 8)
        self.rejects(data)
        data = image() + b'\x08\0\0\0\0\x02\x02\0'
        struct.pack_into('<II', data, OPTIONAL + 112 + 4 * 8, 1024, 8)
        registry.validate_executable(bytes(data), 'x86_64-windows')

    def test_rejects_unordered_or_nonadjacent_virtual_sections(self):
        data = image(second=True)
        first = bytes(data[SECTIONS:SECTIONS + 40])
        data[SECTIONS:SECTIONS + 40] = data[SECTIONS + 40:SECTIONS + 80]
        data[SECTIONS + 40:SECTIONS + 80] = first
        self.rejects(data)
        data = image(second=True)
        struct.pack_into('<I', data, SECTIONS + 40 + 12, 0x3000)
        struct.pack_into('<I', data, OPTIONAL + 56, 0x4000)
        self.rejects(data)
        # Header-to-first-section padding does not make successive sections nonadjacent.
        data = image()
        struct.pack_into('<I', data, SECTIONS + 12, 0x2000)
        struct.pack_into('<I', data, OPTIONAL + 16, 0x2000)
        struct.pack_into('<I', data, OPTIONAL + 56, 0x3000)
        registry.validate_executable(bytes(data), 'x86_64-windows')

    def test_global_pointer_directory_requires_zero_size_and_mapped_address(self):
        data = image()
        struct.pack_into('<II', data, OPTIONAL + 112 + 8 * 8, 0x1000, 0)
        registry.validate_executable(bytes(data), 'x86_64-windows')
        for address, size in ((0x1000, 1), (0x2000, 0), (0, 1)):
            data = image()
            struct.pack_into('<II', data, OPTIONAL + 112 + 8 * 8, address, size)
            self.rejects(data)

    def test_registry_accepts_twelve_unique_target_kind_records_with_fixed_bound(self):
        labels = ('x86_64-linux', 'aarch64-linux', 'riscv64-linux', 'aarch64-macos',
                  'x86_64-windows', 'aarch64-windows')
        entries = [artifact(target, kind) for target in labels for kind in ('source', 'executable')]
        registry.validate_manifest(record(entries))
        too_many = copy.deepcopy(entries) + [copy.deepcopy(entries[0]) for _ in range(3)]
        with self.assertRaisesRegex(registry.RegistryError, 'fourteen'):
            registry.validate_manifest(record(too_many))


if __name__ == '__main__':
    unittest.main()
