"""Retain target-report checks for recorded and selected-target CLI snapshots."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
import registry
import release


class BuildTargetCompatibilityTests(unittest.TestCase):
    def check(self, mode, reported):
        with tempfile.TemporaryDirectory() as temporary:
            snapshot = Path(temporary)
            (snapshot / 'cli').mkdir()
            (snapshot / 'cli/commands.json').write_text(json.dumps({'build_mode': mode}))
            outputs = [b'asm 0.5.0 (x86_64-linux)\n',
                       json.dumps({'host': 'x86_64-linux', 'targets': reported}).encode()]
            with patch.object(release, 'command', side_effect=outputs):
                return release.check_cli(snapshot, {}, 'x86_64-linux', '0.5.0')

    def test_recorded_native_snapshot_keeps_its_original_target_contract(self):
        result = self.check('native host', ['x86_64-linux'])
        self.assertEqual(result['status'], 'pass')
        with self.assertRaises(registry.RegistryError):
            self.check('native host', ['aarch64-linux'])

    def test_selected_target_snapshot_must_report_its_complete_build_contract(self):
        mode = 'selected target; native libraries require the native host'
        self.assertEqual(self.check(mode, ['x86_64-linux', 'aarch64-linux', 'riscv64-linux'])['status'], 'pass')
        with self.assertRaises(registry.RegistryError):
            self.check(mode, ['x86_64-linux'])
