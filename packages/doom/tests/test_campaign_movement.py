"""Actual campaign start movement, separate from spawn/render checks.

All 36 maps get eight fresh starts. Only camera orientation changes before
four ordinary forward ticks. Native world collision and actors remain active.
This gate does not establish traversability or complete campaign progression.
"""
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class CampaignMovementTests(unittest.TestCase):
    def test_all_36_starts_permit_ordinary_movement_with_finite_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = pathlib.Path(tmp) / 'campaign-movement'
            sources = [ROOT / 'tests/campaign_movement.c']
            sources += [ROOT / 'src' / name for name in ('world.s', 'wad.s', 'textures.s')]
            build = subprocess.run(['/usr/bin/clang', '-arch', 'arm64', '-O2',
                                    '-I', str(ROOT / 'src'), '-mmacosx-version-min=15.0', '-Wall', '-Wextra',
                                    '-Werror', '-o', str(binary), *map(str, sources), '-lz'],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary), str(ROOT / 'assets/freedoom1.wad.zlib')],
                                    capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            maps = re.findall(r'^PASS (E[1-4]M[1-9]) moved=([1-8])/8 ', result.stdout, re.M)
            self.assertEqual({name for name, _ in maps},
                             {f'E{episode}M{level}' for episode in range(1, 5)
                              for level in range(1, 10)}, result.stdout)
            self.assertEqual(len(maps), 36, result.stdout)
            self.assertIn('maps=36 attempts=288 forward_ticks=1152 skill=3 failed_maps=0',
                          result.stdout)


if __name__ == '__main__':
    unittest.main()
