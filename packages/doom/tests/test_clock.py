"""The user-visible simulation clock must schedule exactly35 ticks per second."""
import ctypes
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class Step(ctypes.Structure):
    _fields_ = [('milliseconds', ctypes.c_uint64), ('remainder', ctypes.c_uint64)]


class ClockTests(unittest.TestCase):
    def test_fixed_tick_schedule_has_no_millisecond_drift(self):
        source = ROOT / 'src/clock.s'
        self.assertTrue(source.exists(), 'The fixed35Hz scheduling routine is missing')
        with tempfile.TemporaryDirectory() as tmp:
            library = pathlib.Path(tmp) / 'clock.dylib'
            subprocess.run(['/usr/bin/clang', '-arch', 'arm64', '-dynamiclib', str(source),
                            '-o', str(library)], check=True, capture_output=True)
            lib = ctypes.CDLL(str(library))
            lib.doom_clock_step.argtypes = [ctypes.c_uint64, ctypes.c_uint32]
            lib.doom_clock_step.restype = Step
            state = Step(0, 0)
            deadlines = []
            for tick in range(35000):
                state = lib.doom_clock_step(state.milliseconds, state.remainder)
                if tick < 7:
                    deadlines.append(state.milliseconds)
            self.assertEqual(deadlines, [28, 57, 85, 114, 142, 171, 200])
            self.assertEqual((state.milliseconds, state.remainder), (1000000, 0))


if __name__ == '__main__':
    unittest.main()
