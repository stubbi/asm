# SPDX-License-Identifier: GPL-2.0-or-later
"""Run the actual assembly main loop with bounded native device/time fixtures."""
import json
import os
import pathlib
import platform
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64',
                     'Native Apple arm64 test')
class MainLoopTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.executable = pathlib.Path(cls.tmp.name) / 'main-loop'
        sources = [ROOT / 'tests/main_driver.c']
        sources += [ROOT / 'src' / name for name in ('main.s', 'clock.s', 'wad.s', 'textures.s')]
        subprocess.run(['/usr/bin/clang', '-arch', 'arm64', '-mmacosx-version-min=15.0',
                        '-Wall', '-Wextra', '-Werror', *map(str, sources), '-lz',
                        '-o', str(cls.executable)], cwd=ROOT, check=True, capture_output=True)

    def observe(self, scenario):
        env = dict(os.environ, ASM_DOOM_MAIN_SCENARIO=scenario)
        result = subprocess.run([str(self.executable)], env=env, capture_output=True,
                                text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        state = json.loads(result.stdout)
        self.assertEqual(state['frames'], state['presents'])
        self.assertEqual(state['captured_ticks'], state['ticks'])
        self.assertEqual(state['paused_ticks'], 0)
        self.assertEqual(state['captured_menu_frames'], 0)
        return state

    def test_actual_main_schedules_35_simulation_ticks_per_second(self):
        state = self.observe('clock')
        self.assertEqual(state['ticks'], 35)
        self.assertEqual(state['tick_times_ms'], [1000 * tick // 35 for tick in range(1, 36)])
        self.assertGreater(state['sleep_calls'], 0)
        self.assertEqual(state['max_ticks_between_frames'], 1)

    def test_keyboard_menu_wrap_resume_and_escape_capture(self):
        state = self.observe('menu')
        self.assertEqual(state['ticks'], 2)
        self.assertEqual(state['menu_selections'], [0, 4, 0, 0])
        self.assertEqual(state['capture_history'], [0, 1, 0, 1])
        self.assertEqual(state['capture'], 1)

    def test_focus_loss_stops_simulation_until_explicit_resume(self):
        state = self.observe('focus')
        self.assertEqual(state['ticks'], 2)
        self.assertEqual(state['menu_selections'], [0, 0])
        self.assertEqual(state['capture_history'], [0, 1, 0, 1])
        self.assertEqual(state['paused'], 0)
        self.assertEqual(state['capture'], 1)

    def test_overloaded_simulation_keeps_presenting_frames(self):
        state = self.observe('overload')
        self.assertEqual(state['ticks'], 20)
        self.assertGreaterEqual(state['frames'], 6)
        self.assertLessEqual(state['max_ticks_between_frames'], 4)


if __name__ == '__main__':
    unittest.main()
