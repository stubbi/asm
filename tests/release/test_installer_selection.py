"""Catalog target recognition does not authorize a POSIX installer host."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
import bootstrap
import registry


class InstallerSelectionTests(unittest.TestCase):
    def record(self, version='0.6.0', targets=('x86_64-linux', 'aarch64-linux', 'aarch64-macos')):
        return {'schema': 1, 'name': 'stubbi/asm', 'version': version,
                'summary': 'Installer selection fixture.', 'license': 'AGPL-3.0-or-later',
                'source': {'repository': bootstrap.REPOSITORY, 'commit': 'a' * 40, 'path': '.'},
                'yanked': False, 'artifacts': [
                    {'target': target, 'kind': 'executable', 'bytes': 1024, 'sha256': 'a' * 64,
                     'url': f'{bootstrap.REPOSITORY}/releases/download/v{version}/asm-{version}-{target}'
                            + ('.exe' if target.endswith('-windows') else '')}
                    for target in targets]}

    def test_mixed_catalog_preserves_exact_posix_installer_bytes(self):
        posix = self.record()
        mixed = self.record(targets=(*bootstrap.TARGETS, 'x86_64-windows', 'aarch64-windows'))
        checked = {('stubbi/asm', '0.6.0')}
        before = bootstrap.installer_release([posix], checked)
        after = bootstrap.installer_release([mixed], checked)
        self.assertEqual(after, before)
        self.assertEqual(bootstrap.render_installer(after), bootstrap.render_installer(before))
        self.assertNotIn(b'windows', bootstrap.render_installer(after).lower())
        self.assertEqual(mixed['artifacts'][-1]['target'], 'aarch64-windows')

    def test_new_windows_only_release_does_not_hide_latest_posix_release(self):
        old = self.record(version='0.5.0')
        new = self.record(targets=('x86_64-windows', 'aarch64-windows'))
        result = bootstrap.installer_release([old, new], {('stubbi/asm', '0.5.0'), ('stubbi/asm', '0.6.0')})
        self.assertEqual(result['version'], '0.5.0')
        self.assertIsNone(bootstrap.installer_release([new], {('stubbi/asm', '0.6.0')}))

    def test_unchecked_new_posix_release_does_not_fall_back(self):
        self.assertIsNone(bootstrap.installer_release([self.record(version='0.5.0'), self.record()],
                                                     {('stubbi/asm', '0.5.0')}))

    def test_invalid_excluded_artifact_still_fails_schema_validation(self):
        invalid = self.record(targets=('x86_64-linux', 'x86_64-windows'))
        invalid['artifacts'][-1]['sha256'] = 'invalid'
        with self.assertRaises(registry.RegistryError):
            bootstrap.installer_release([invalid], {('stubbi/asm', '0.6.0')})

    def test_direct_installer_validation_rejects_windows_host(self):
        release = bootstrap.installer_release([self.record()], {('stubbi/asm', '0.6.0')})
        invalid = copy.deepcopy(release)
        invalid['artifacts'] = [{'target': 'x86_64-windows', 'bytes': 1024, 'sha256': 'a' * 64,
                                'url': f'{bootstrap.REPOSITORY}/releases/download/v0.6.0/asm-0.6.0-x86_64-windows.exe'}]
        with self.assertRaises(registry.RegistryError):
            bootstrap.validate_release(invalid)


if __name__ == '__main__':
    unittest.main()
