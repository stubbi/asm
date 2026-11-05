# SPDX-License-Identifier: GPL-2.0-or-later
"""Observable command and native integration acceptance checks."""
import hashlib
import json
import pathlib
import os
import subprocess
import struct
import resource
import signal
import tempfile
import tarfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
GAME = ROOT / 'build' / 'asm-doom'


def make_wad(lumps):
    data = bytearray(b'IWAD' + bytes(8))
    records = []
    for name, payload in lumps:
        records.append((len(data), len(payload), name.encode().ljust(8, b'\0')))
        data += payload
    offset = len(data)
    for record in records:
        data += struct.pack('<II8s', *record)
    struct.pack_into('<II', data, 4, len(records), offset)
    return data


def room(name, exit_special=0, pickups=False):
    things = [(0, 0, 0, 1, 7)]
    if pickups:
        things += [(0, 0, 0, t, 7) for t in (2001, 2007, 2018, 5)]
    lines = [(0, 3, 1, 0, 0, 0, 65535), (3, 2, 1, 0, 0, 1, 65535),
             (2, 1, 1, exit_special, 0, 2, 65535), (1, 0, 1, 0, 0, 3, 65535)]
    return [(name, b''), ('THINGS', b''.join(struct.pack('<5h', *t) for t in things)),
            ('LINEDEFS', b''.join(struct.pack('<7H', *line) for line in lines)),
            ('SIDEDEFS', struct.pack('<hh8s8s8sH', 0, 0, b'-', b'-', b'WALL', 0) * 4),
            ('VERTEXES', struct.pack('<8h', -64, -64, 64, -64, 64, 64, -64, 64)),
            ('SEGS', b''.join(struct.pack('<6H', line[0], line[1], 0, i, 0, 0) for i, line in enumerate(lines))),
            ('SSECTORS', struct.pack('<HH', 4, 0)), ('NODES', b''),
            ('SECTORS', struct.pack('<hh8s8shhh', 0, 128, b'FLAT', b'CEIL', 160, 0, 0)),
            ('REJECT', b'\0'), ('BLOCKMAP', struct.pack('<4h', 0, 0, 0, 0))]


def input_file(records):
    return b'ASMINP1\0' + struct.pack('<II', len(records), 0) + b''.join(
        struct.pack('<3fI3iI', *record) for record in records)


class GameTests(unittest.TestCase):
    def run_game(self, *args, **kwargs):
        self.assertTrue(GAME.is_file(), 'Native game has not been built')
        return subprocess.run([str(GAME), *map(str, args)], capture_output=True,
                              timeout=kwargs.pop('timeout', 30), **kwargs)

    def test_help_names_host_and_controls(self):
        r = self.run_game('--help')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(b'Apple Silicon', r.stdout)
        self.assertIn(b'Freedoom', r.stdout)
        self.assertIn(b'WASD', r.stdout)

    def test_version_names_alpha_release(self):
        result = self.run_game('--version')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b'asm-doom 0.1.0 (alpha;', result.stdout)
        self.assertNotIn(b'-dev', result.stdout)
        self.assertEqual(result.stderr, b'')

    def test_license_prints_complete_notices_before_engine_initialization(self):
        environment = dict(os.environ, SDL_VIDEODRIVER='asm-license-invalid-video',
                           SDL_AUDIODRIVER='asm-license-invalid-audio')
        result = self.run_game('--license', env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b'')
        for notice in ('LICENSE', 'third_party/ENGINE-NOTICES.txt',
                       'third_party/COPYING.txt', 'third_party/CREDITS.txt',
                       'third_party/CREDITS-MUSIC.txt', 'third_party/sdl/LICENSE.txt',
                       'third_party/sdl/THIRD-PARTY-NOTICES.txt'):
            self.assertIn((ROOT / notice).read_bytes(), result.stdout, notice)
        self.assertIn(b'https://github.com/stubbi/asm/tree/doom-v0.1.0/packages/doom', result.stdout)
        sdl_record = json.loads((ROOT / 'third_party/sdl/source.json').read_text())
        with tarfile.open(ROOT / 'third_party/sdl' / sdl_record['source_file'], 'r:gz') as archive:
            prefix = f"SDL3-{sdl_record['version']}/"
            self.assertIn(archive.extractfile(prefix + 'src/video/yuv2rgb/LICENSE').read(), result.stdout)
            libm = archive.extractfile(prefix + 'src/libm/e_atan2.c').read()
            copyright_start = libm.index(b'Copyright (C) 1993 by Sun Microsystems')
            start = libm.rfind(b'/*', 0, copyright_start)
            sun_notice = libm[start:libm.index(b'*/', copyright_start) + 2]
            self.assertIn(sun_notice, result.stdout)
        self.assertIn(b'Copyright (c) 2017 Sean Barrett', result.stdout)
        self.assertIn(b'Copyright (C) 1993-1996 Id Software, Inc.', result.stdout)

        result_before_data = self.run_game('--iwad', '/asm-license-no-such-data.wad',
                                          '--license', env=environment)
        self.assertEqual(result_before_data.returncode, 0, result_before_data.stderr)
        self.assertEqual(result_before_data.stdout, result.stdout)
        self.assertEqual(result_before_data.stderr, b'')

    def test_unsupported_option_fails(self):
        r = self.run_game('--not-supported')
        self.assertEqual(r.returncode, 2)
        self.assertIn(b'--help', r.stderr)

    def test_headless_is_deterministic_and_renders_real_data(self):
        a = self.run_game('--headless', '--ticks', 2)
        b = self.run_game('--headless', '--ticks', 2)
        self.assertEqual(a.returncode, 0, a.stderr)
        self.assertEqual(a.stdout, b.stdout)
        state = json.loads(a.stdout)
        self.assertEqual(state['map'], 'E1M1')
        self.assertEqual(state['ticks'], 2)
        self.assertEqual(state['health'], 100)
        self.assertGreater(state['actors'], 10)

    def test_screenshot_and_existing_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'frame.ppm'
            r = self.run_game('--headless', '--ticks', 1, '--screenshot', path)
            self.assertEqual(r.returncode, 0, r.stderr)
            data = path.read_bytes()
            self.assertTrue(data.startswith(b'P6\n320 200\n255\n'))
            self.assertEqual(len(data), 15 + 320 * 200 * 3)
            self.assertGreater(len(set(data[15:])), 32)
            digest = hashlib.sha256(data).hexdigest()
            r = self.run_game('--headless', '--ticks', 1, '--screenshot', path)
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest)

    def test_failed_screenshot_write_leaves_no_final_or_staging_file(self):
        def small_file_limit():
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
            resource.setrlimit(resource.RLIMIT_FSIZE, (1024, 1024))
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'frame.ppm'
            r = self.run_game('--headless', '--ticks', 1, '--screenshot', path,
                              preexec_fn=small_file_limit)
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse(path.exists())
            self.assertEqual(list(path.parent.iterdir()), [])

    def test_bad_wad_and_invalid_map_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'bad.wad'
            path.write_bytes(b'not a WAD')
            for args in [('--iwad', path), ('--map', 'E9M9')]:
                r = self.run_game('--headless', '--ticks', 1, *args)
                self.assertNotEqual(r.returncode, 0)
                self.assertTrue(r.stderr)

    def test_scripted_exit_preserves_inventory_and_resets_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp)
            (path / 'map.wad').write_bytes(make_wad(room('E1M1', 11, True) + room('E1M2')))
            (path / 'input.bin').write_bytes(input_file([(0, 0, 0, 1, 0, 0, 0, 0)]))
            r = self.run_game('--headless', '--ticks', 1, '--iwad', path / 'map.wad', '--input', path / 'input.bin')
            self.assertEqual(r.returncode, 0, r.stderr)
            state = json.loads(r.stdout)
            self.assertEqual(state['map'], 'E1M2')
            self.assertTrue(state['owned_weapons'] & (1 << 3))
            self.assertGreaterEqual(state['bullets'], 60)
            self.assertEqual(state['armor'], 100)
            self.assertEqual(state['keys'], 0)

    def test_secret_map_returns_to_its_episode_route(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp)
            (path / 'input.bin').write_bytes(input_file([(0, 0, 0, 1, 0, 0, 0, 0)]))
            for episode, destination in enumerate((4, 6, 7, 3), 1):
                current, following = f'E{episode}M9', f'E{episode}M{destination}'
                (path / 'map.wad').write_bytes(make_wad(room(current, 11) + room(following)))
                r = self.run_game('--headless', '--ticks', 1, '--map', current,
                                  '--iwad', path / 'map.wad', '--input', path / 'input.bin')
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(json.loads(r.stdout)['map'], following)

    def test_corrupt_input_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'input.bin'
            for data in (b'wrong header' + bytes(36), input_file([(float('nan'), 0, 0, 0, 0, 0, 0, 0)])):
                path.write_bytes(data)
                r = self.run_game('--headless', '--ticks', 1, '--input', path)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn(b'input', r.stderr)

    def test_fifo_input_paths_fail_without_waiting_for_a_writer(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'pipe'
            os.mkfifo(path)
            for option in ('--iwad', '--input'):
                try:
                    r = self.run_game('--headless', '--ticks', 1, option, path, timeout=2)
                except subprocess.TimeoutExpired:
                    self.fail(f'{option} blocked before it could reject the FIFO')
                self.assertNotEqual(r.returncode, 0)
                self.assertTrue(r.stderr)


if __name__ == '__main__':
    unittest.main()
