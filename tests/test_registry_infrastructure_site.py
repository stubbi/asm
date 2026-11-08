"""Origin log measurements reach the existing static statistics interface.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import inspect
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import build_site
import registry


class OriginLogSiteTests(unittest.TestCase):
    def test_operator_can_select_log_measurements_without_public_private_state(self):
        self.assertIn('origin_log_state',inspect.signature(build_site.build_site).parameters,
                      'site builder cannot select asynchronous log observations')
        import registry_log_import
        with tempfile.TemporaryDirectory() as temporary:
            base=Path(temporary).resolve()
            records=registry.read_records(ROOT/'registry')
            state=base/'origin.sqlite3'
            store=registry_log_import.LogStore(state,records)
            # An explicitly imported empty batch establishes an observed zero,
            # not complete delivery coverage or an installation count.
            logs=base/'batch.jsonl'; logs.write_bytes(b'')
            store.import_batch('asm-origin','empty-batch','2026-11-06T00:00:00Z','2026-11-06T01:00:00Z',logs)
            output=base/'site'
            build_site.build_site(ROOT,ROOT/'registry',output,origin_log_state=state)
            stats=json.loads((output/'registry/v1/stats.json').read_text())
            self.assertEqual(stats['transfers']['total'],0)
            self.assertFalse(stats['transfers']['complete'])
            self.assertEqual(stats['measurement']['profile'],'origin-log-lower-bounds-v1')
            self.assertEqual(stats['measurement']['sources'],['asm-origin'])
            self.assertEqual(stats['measurement']['deduplication'],'source-request-id')
            self.assertEqual(stats['measurement']['reported_through'],'2026-11-06T01:00:00Z')
            self.assertNotIn('origin.sqlite3',[p.name for p in output.rglob('*')])
            self.assertIn('Reporting coverage is incomplete',(output/'stats/index.html').read_text())

    def test_log_state_inside_public_output_is_rejected_before_build(self):
        self.assertIn('origin_log_state',inspect.signature(build_site.build_site).parameters)
        with tempfile.TemporaryDirectory() as temporary:
            output=Path(temporary)/'public'
            with self.assertRaises(registry.RegistryError):
                build_site.build_site(ROOT,ROOT/'registry',output,origin_log_state=output/'private.sqlite3')
            self.assertFalse(output.exists())
