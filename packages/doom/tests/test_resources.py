# SPDX-License-Identifier: GPL-2.0-or-later
"""Native black-box checks for the handwritten resource parser."""
import ctypes
import pathlib
import struct
import subprocess
import tempfile
import unittest
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]


def wad(lumps):
    data = bytearray(b'IWAD' + b'\0' * 8)
    directory = []
    for name, payload in lumps:
        directory.append((len(data), len(payload), name.encode().ljust(8, b'\0')))
        data += payload
    offset = len(data)
    for record in directory:
        data += struct.pack('<II8s', *record)
    struct.pack_into('<II', data, 4, len(directory), offset)
    return bytes(data)


class Lump(ctypes.Structure):
    _fields_ = [('data', ctypes.c_void_p), ('size', ctypes.c_uint64)]


class Texture(ctypes.Structure):
    _fields_ = [('width', ctypes.c_uint32), ('height', ctypes.c_uint32),
                ('pixels', ctypes.c_void_p), ('left', ctypes.c_int32), ('top', ctypes.c_int32),
                ('alpha', ctypes.c_void_p)]


class ResourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        sources = [ROOT / 'src' / name for name in ('wad.s', 'textures.s')]
        if not all(p.exists() for p in sources):
            raise AssertionError('Handwritten resource modules do not exist yet')
        output = pathlib.Path(cls.tmp.name) / 'resources.dylib'
        result = subprocess.run(['/usr/bin/clang', '-arch', 'arm64', '-dynamiclib',
                                 '-mmacosx-version-min=15.0', '-o', str(output),
                                 *map(str, sources)], capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        cls.lib = ctypes.CDLL(str(output))
        cls.lib.doom_wad_init.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        cls.lib.doom_wad_init.restype = ctypes.c_int
        cls.lib.doom_lump.argtypes = [ctypes.c_char_p]
        cls.lib.doom_lump.restype = Lump
        cls.lib.doom_lump_index.argtypes = [ctypes.c_int]
        cls.lib.doom_lump_index.restype = Lump
        cls.lib.doom_lump_number.argtypes = [ctypes.c_char_p]
        cls.lib.doom_lump_number.restype = ctypes.c_int
        cls.lib.doom_patch.argtypes = [ctypes.c_char_p]
        cls.lib.doom_patch.restype = ctypes.c_void_p
        cls.lib.doom_texture.argtypes = [ctypes.c_char_p]
        cls.lib.doom_texture.restype = ctypes.c_void_p
        cls.lib.doom_flat.argtypes = [ctypes.c_char_p]
        cls.lib.doom_flat.restype = ctypes.c_void_p
        cls.lib.doom_map_load.argtypes = [ctypes.c_char_p]
        cls.lib.doom_map_load.restype = ctypes.c_int

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.buffers = []

    def init(self, data):
        buf = ctypes.create_string_buffer(data)
        self.buffers.append(buf)
        return self.lib.doom_wad_init(buf, len(data))

    def tearDown(self):
        self.lib.doom_resources_free()

    def test_directory_lookup_and_last_duplicate(self):
        self.assertEqual(self.init(wad([('TEST', b'old'), ('TEST', b'new')])), 0)
        item = self.lib.doom_lump(b'TEST')
        self.assertEqual(ctypes.string_at(item.data, item.size), b'new')
        self.assertEqual(self.lib.doom_lump_number(b'TEST'), 1)
        self.assertFalse(self.lib.doom_lump(b'MISSING').data)
        self.assertFalse(self.lib.doom_lump_index(-1).data)
        self.assertFalse(self.lib.doom_lump_index(2).data)

    def test_truncation_and_out_of_range_directory(self):
        valid = wad([('A', b'x')])
        for n in range(len(valid)):
            self.assertEqual(self.init(valid[:n]), -1, n)
        for index, value in [(4, 0xffffffff), (8, 0xffffffff), (13, 0xffffffff), (17, 0xffffffff)]:
            bad = bytearray(valid)
            struct.pack_into('<I', bad, index, value)
            self.assertEqual(self.init(bytes(bad)), -1, index)

    def test_bad_wad_keeps_previous_directory(self):
        self.assertEqual(self.init(wad([('GOOD', b'unchanged')])), 0)
        self.assertEqual(self.init(b'bad'), -1)
        item = self.lib.doom_lump(b'GOOD')
        self.assertEqual(ctypes.string_at(item.data, item.size), b'unchanged')

    @staticmethod
    def patch():
        return struct.pack('<HHhhII', 2, 3, 1, 2, 16, 24) + bytes([0, 3, 0, 1, 2, 3, 0, 255, 1, 1, 0, 4, 0, 255])

    def test_patch_posts_and_transparency(self):
        self.assertEqual(self.init(wad([('PATCH', self.patch())])), 0)
        ptr = self.lib.doom_patch(b'PATCH')
        self.assertTrue(ptr)
        tex = Texture.from_address(ptr)
        self.assertEqual((tex.width, tex.height, tex.left, tex.top), (2, 3, 1, 2))
        self.assertEqual(ctypes.string_at(tex.pixels, 6), bytes([1, 255, 2, 4, 3, 255]))

    def test_palette_255_is_a_real_opaque_patch_color(self):
        column = bytes([0, 4, 0, 255, 255, 255, 255, 0, 255])
        patch = struct.pack('<HHhhII', 2, 4, 0, 0, 16, 25) + column * 2
        self.assertEqual(self.init(wad([('OPAQUE', patch)])), 0)
        ptr = self.lib.doom_patch(b'OPAQUE')
        self.assertTrue(ptr)
        tex = Texture.from_address(ptr)
        self.assertEqual(tex.alpha, tex.pixels + 8)
        self.assertEqual(ctypes.string_at(tex.pixels, 8), b'\xff' * 8)
        self.assertEqual(ctypes.string_at(tex.alpha, 8), b'\x01' * 8)

    def test_bad_patch_offsets_and_posts(self):
        for payload in [b'', self.patch()[:15], self.patch()[:-1],
                        struct.pack('<HHhhI', 1, 1, 0, 0, 0xffffffff)]:
            self.assertEqual(self.init(wad([('BAD', payload)])), 0)
            self.assertFalse(self.lib.doom_patch(b'BAD'))

    def test_texture_composes_named_patch(self):
        pnames = struct.pack('<I8s', 1, b'PATCH')
        definition = struct.pack('<8sIHHIHhhHHH', b'WALL', 0, 2, 3, 0, 1, 0, 0, 0, 0, 0)
        textures = struct.pack('<II', 1, 8) + definition
        self.assertEqual(self.init(wad([('PATCH', self.patch()), ('PNAMES', pnames), ('TEXTURE1', textures)])), 0)
        ptr = self.lib.doom_texture(b'WALL')
        self.assertTrue(ptr)
        tex = Texture.from_address(ptr)
        self.assertEqual((tex.width, tex.height), (2, 3))
        self.assertEqual(ctypes.string_at(tex.pixels, 6), bytes([1, 255, 2, 4, 3, 255]))

    def test_flat_requires_exact_size(self):
        self.assertEqual(self.init(wad([('FLAT', bytes([7]) * 4096), ('BAD', b'x')])), 0)
        self.assertTrue(self.lib.doom_flat(b'FLAT'))
        self.assertFalse(self.lib.doom_flat(b'BAD'))

    def test_map_rejects_malformed_record_and_preserves_globals(self):
        lumps = [('E1M1', b''), ('THINGS', struct.pack('<hhhhh', 0, 0, 0, 1, 7)),
                 ('LINEDEFS', struct.pack('<7H', 0, 1, 1, 0, 0, 0, 65535)),
                 ('SIDEDEFS', struct.pack('<hh8s8s8sH', 0, 0, b'-', b'-', b'WALL', 0)),
                 ('VERTEXES', struct.pack('<hhhh', 0, 0, 128, 0)),
                 ('SEGS', struct.pack('<6H', 0, 1, 0, 0, 0, 0)),
                 ('SSECTORS', struct.pack('<HH', 1, 0)), ('NODES', b''),
                 ('SECTORS', struct.pack('<hh8s8shhh', 0, 128, b'FLAT', b'CEIL', 160, 0, 0)),
                 ('REJECT', b'\0'), ('BLOCKMAP', struct.pack('<hhhh', 0, 0, 0, 0))]
        self.assertEqual(self.init(wad(lumps)), 0)
        self.assertEqual(self.lib.doom_map_load(b'E1M1'), 0)
        old = ctypes.c_void_p.in_dll(self.lib, 'doom_vertices').value
        self.assertEqual(self.lib.doom_map_load(b'E9M9'), -1)
        self.assertEqual(ctypes.c_void_p.in_dll(self.lib, 'doom_vertices').value, old)
        lumps[2] = ('LINEDEFS', b'x')
        self.assertEqual(self.init(wad(lumps)), 0)
        self.assertEqual(self.lib.doom_map_load(b'E1M1'), -1)

    def test_all_bundled_freedoom_maps_have_valid_topology(self):
        raw = zlib.decompress((ROOT / 'assets/freedoom1.wad.zlib').read_bytes())
        self.assertEqual(self.init(raw), 0)
        for episode in range(1, 5):
            for level in range(1, 10):
                name = f'E{episode}M{level}'.encode()
                self.assertEqual(self.lib.doom_map_load(name), 0, name)

    def test_all_bundled_wall_textures_decode(self):
        raw = zlib.decompress((ROOT / 'assets/freedoom1.wad.zlib').read_bytes())
        self.assertEqual(self.init(raw), 0)
        total = 0
        for lump_name in [b'TEXTURE1', b'TEXTURE2']:
            lump = self.lib.doom_lump(lump_name)
            if not lump.data:
                continue
            data = ctypes.string_at(lump.data, lump.size)
            count = struct.unpack_from('<I', data)[0]
            for i in range(count):
                off = struct.unpack_from('<I', data, 4 + i * 4)[0]
                name = data[off:off + 8]
                self.assertTrue(self.lib.doom_texture(name), name)
                total += 1
        self.assertGreater(total, 100)

    def test_resource_lifetime_clears_borrowed_map_and_palette(self):
        raw = zlib.decompress((ROOT / 'assets/freedoom1.wad.zlib').read_bytes())
        self.assertEqual(self.init(raw), 0)
        self.assertEqual(self.lib.doom_map_load(b'E1M1'), 0)
        self.assertTrue(ctypes.c_void_p.in_dll(self.lib, 'doom_vertices').value)
        self.assertEqual(self.init(wad([('OTHER', b'x')])), 0)
        self.assertFalse(ctypes.c_void_p.in_dll(self.lib, 'doom_vertices').value)
        self.lib.doom_resources_free()
        for name in ('doom_vertices', 'doom_palette', 'doom_colormap'):
            self.assertFalse(ctypes.c_void_p.in_dll(self.lib, name).value, name)

    def test_colormap_requires_all_renderer_light_ramps(self):
        for length in (0, 256, 8191):
            self.assertEqual(self.init(wad([('COLORMAP', b'\0' * length)])), 0)
            self.assertFalse(ctypes.c_void_p.in_dll(self.lib, 'doom_colormap').value, length)
        self.assertEqual(self.init(wad([('COLORMAP', b'\0' * 8192)])), 0)
        self.assertTrue(ctypes.c_void_p.in_dll(self.lib, 'doom_colormap').value)


if __name__ == '__main__':
    unittest.main()
