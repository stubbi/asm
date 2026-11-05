"""Native observable framebuffer and Apple ABI checks."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class RenderTests(unittest.TestCase):
    def test_native_synthetic_geometry_masking_dynamic_heights_and_abi(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = pathlib.Path(tmp) / 'render-test'
            subprocess.run(['/usr/bin/clang', '-arch', 'arm64', '-O2',
                            '-I', str(ROOT / 'src'), '-mmacosx-version-min=15.0', '-o', str(binary),
                            str(ROOT / 'tests/render_test.c'),
                            str(ROOT / 'tests/render_abi.s'),
                            str(ROOT / 'src/render.s')], check=True, timeout=60)
            result = subprocess.run([str(binary)], capture_output=True,
                                    text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('native render tests passed', result.stdout)

    def test_all_36_native_campaign_start_frames(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = pathlib.Path(tmp) / 'render-campaign'
            sources = [ROOT / 'tests/render_campaign.c']
            sources += [ROOT / 'src' / name for name in
                        ('render.s', 'world.s', 'wad.s', 'textures.s')]
            subprocess.run(['/usr/bin/clang', '-arch', 'arm64', '-O2',
                            '-I', str(ROOT / 'src'), '-mmacosx-version-min=15.0', '-o', str(binary),
                            *map(str, sources), '-lz'], check=True, timeout=60)
            result = subprocess.run([str(binary),
                                     str(ROOT / 'assets/freedoom1.wad.zlib'), tmp, 'E1M1'],
                                    capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('36 native campaign framebuffers passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
