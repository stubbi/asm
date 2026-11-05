# SPDX-License-Identifier: GPL-2.0-or-later
"""Native real-resource world behavior checks with bundled Freedoom Phase 1."""
import pathlib, platform, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
@unittest.skipUnless(platform.system()=='Darwin' and platform.machine()=='arm64','Native Apple arm64 test')
class CampaignWorldTests(unittest.TestCase):
    def test_all_maps_tick_and_cross_map_save_restores(self):
        with tempfile.TemporaryDirectory(prefix='asm-doom-campaign-') as tmp:
            exe=pathlib.Path(tmp)/'world-campaign'
            subprocess.run(['clang','-I',str(ROOT/'src'),'-arch','arm64','-mmacosx-version-min=15.0','-Wall','-Wextra','-Werror',str(ROOT/'tests/world_campaign.c'),str(ROOT/'src/world.s'),str(ROOT/'src/wad.s'),str(ROOT/'src/textures.s'),'-lz','-o',str(exe)],check=True)
            result=subprocess.run([str(exe),str(ROOT/'assets/freedoom1.wad.zlib')],capture_output=True,text=True,timeout=90)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
if __name__=='__main__':unittest.main()
