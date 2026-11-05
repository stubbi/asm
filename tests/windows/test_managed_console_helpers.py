"""Host checks for receipt parsing only; these do not qualify Windows APIs.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import json
import unittest

from managed_console import parse_receipt


class ConsoleReceiptTests(unittest.TestCase):
    def receipt(self, **changes):
        row = {'status': 'complete', 'event': 0, 'requested_exit_code': 0xc000013a,
               'exit_code': 0xc000013a, 'payload_exit_code': 0xc000013a, 'ready': True, 'event_sent': True,
               'launcher_reaped': True, 'payload_reaped': True, 'error': 0, 'elapsed_ms': 42}
        row.update(changes)
        return json.dumps(row).encode('ascii')

    def test_full_dword_and_failed_native_outcome_are_retained(self):
        self.assertEqual(parse_receipt(self.receipt())['exit_code'], 0xc000013a)
        failed = parse_receipt(self.receipt(status='launcher-timeout', exit_code=None,
                                          launcher_reaped=False))
        self.assertIsNone(failed['exit_code'])
        self.assertFalse(failed['launcher_reaped'])
        self.assertEqual(failed['status'], 'launcher-timeout')

    def test_malformed_or_ambiguous_receipts_are_rejected(self):
        cases = [b'', b'{}', b'x' * 4097, self.receipt() + b'{}',
                 self.receipt().replace(b'"event": 0', b'"event": 0, "event": 1'),
                 self.receipt(exit_code=-1), self.receipt(exit_code=0x100000000),
                 self.receipt(exit_code=True), self.receipt(event=2),
                 self.receipt(elapsed_ms=20001), self.receipt(ready=1),
                 self.receipt(status='invented-pass'), self.receipt(status=[]),
                 self.receipt(exit_code=None), self.receipt(payload_exit_code=None),
                 self.receipt(ready=False)]
        for raw in cases:
            with self.subTest(receipt=raw[:80]):
                with self.assertRaises(ValueError):
                    parse_receipt(raw)


if __name__ == '__main__':
    unittest.main()
