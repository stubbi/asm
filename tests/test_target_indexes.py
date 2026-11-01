"""New host rows must not strand the released Linux updater."""
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import registry

class TargetIndexTests(unittest.TestCase):
    def test_linux_03_reader_can_parse_every_row_of_compatibility_feed(self):
        linux = 'owner/pkg\t0.4.0\taarch64-linux\texecutable\t' + 'a' * 64 + '\thttps://github.com/stubbi/asm/releases/download/v0.4.0/linux\t64\tLinux\n'
        mac = linux.replace('aarch64-linux', 'aarch64-macos').replace('\tLinux\n', '\tMac\n')
        full = registry.HEADER + linux + mac
        compatible = registry.legacy_tsv(full)
        self.assertEqual(compatible, registry.HEADER + linux)
        self.assertIn('aarch64-macos', full)
        for row in compatible.splitlines()[1:]:
            self.assertIn(row.split('\t')[2], {'x86_64-linux', 'aarch64-linux', 'riscv64-linux'})
