"""Check V2 image publication authority with synthetic evidence.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import operator_source
import v2_image_publication as policy

REVISION = '1' * 40


def evidence(role):
    entry = ['/usr/local/bin/asm-publisher'] if role == 'publisher' else [
        '/usr/bin/python3', '-B', '-I', '/app/tools/checker_entrypoint.py']
    source = {'schema': 1, 'repository': operator_source.REPOSITORY, 'source_revision': REVISION,
        'bundle_sha256': 'a' * 64, 'bundle_bytes': 1000,
        'files': {name: 'b' * 64 for name in operator_source.FILES}}
    files = {'/app/SOURCE.json': 'c' * 64}
    if role == 'publisher':
        files.update({name: 'd' * 64 for name in policy.PUBLISHER_FILES})
    else:
        files.update({'/app/' + name: source['files'][name] for name in policy.CHECKER_FILES})
    ids = policy.required_test_ids(role)
    report = {'schema': 1, 'status': 'pass', 'scope': 'v2-runtime-qualification', 'role': role,
        'source_revision': REVISION, 'os': 'linux', 'architecture': 'amd64', 'execution': 'native',
        'runtime_image_id': 'sha256:' + '2' * 64, 'source': source, 'runtime_files': files,
        'tests_run': len(ids), 'tests_skipped': 0, 'test_ids': ids,
        'security': {'uid': 65532, 'gid': 65532, 'read_only_root': True,
            'effective_capabilities': 0, 'no_new_privileges': True, 'cluster_token': False}}
    if role == 'publisher':
        report.update(qualification_image_id='sha256:' + '3' * 64, qualifier_runtime_files=dict(files),
            database_fixture_version='18.6', loaded_libraries={'libpq': '16.15', 'OpenSSL': '3.5.9'},
            final_compiler_and_postgresql_server_absent=True)
    else:
        report['security']['network'] = 'none'
        report.update(checker_policy_sha256=policy.checker_policy_digest(), inputs_unchanged=True,
            cases=[{'id': name, 'task_id': '4' * 32, 'manifest_sha256': 'f' * 64,
                'expected_outcome': policy.CHECKER_OUTCOMES[name],
                'exit_status': 1 if name == 'malformed-manifest' else 0,
                'receipt_sha256': None if name == 'malformed-manifest' else '5' * 64} for name in ids])
    image = {'Id': report['runtime_image_id'], 'Os': 'linux', 'Architecture': 'amd64',
        'RootFS': {'Layers': ['sha256:' + '6' * 64]}, 'Config': {'User': '65532:65532',
            'Entrypoint': entry, 'Cmd': ['--help'], 'Labels': {'org.opencontainers.image.source': operator_source.REPOSITORY,
                'org.opencontainers.image.revision': REVISION, 'org.opencontainers.image.licenses': 'AGPL-3.0-or-later'}}}
    return report, image


class V2PublicationTests(unittest.TestCase):
    def refused(self, report, image, role):
        with self.assertRaises(ValueError):
            policy.validate(REVISION, role, report, image)

    def test_exact_qualified_roles_pass_without_changing_evidence(self):
        for role in ('publisher', 'checker'):
            report, image = evidence(role)
            before = copy.deepcopy((report, image))
            policy.validate(REVISION, role, report, image)
            self.assertEqual((report, image), before)

    def test_smoke_other_roles_skips_missing_tests_and_emulation_cannot_authorize_publication(self):
        for role in ('publisher', 'checker'):
            for key, bad in (('scope', 'v2-runtime-smoke'), ('role', 'operator'), ('execution', 'emulated'),
                    ('tests_run', True), ('tests_skipped', 1), ('tests_skipped', False),
                    ('test_ids', policy.required_test_ids(role)[:-1]), ('test_ids', policy.required_test_ids(role) * 2)):
                with self.subTest(role=role, key=key):
                    report, image = evidence(role)
                    report[key] = bad
                    self.refused(report, image, role)

    def test_loaded_image_identity_entrypoint_and_source_are_checked_again(self):
        for role in ('publisher', 'checker'):
            for mutate in (lambda i: i.update(Id='sha256:' + '7' * 64),
                    lambda i: i.update(Architecture='arm64'),
                    lambda i: i['Config'].update(User='0:0'),
                    lambda i: i['Config'].update(Entrypoint=['/bin/sh']),
                    lambda i: i['Config'].update(Volumes={'/app': {}}),
                    lambda i: i['Config']['Labels'].update({'org.opencontainers.image.revision': '8' * 40})):
                report, image = evidence(role)
                mutate(image)
                self.refused(report, image, role)
            report, image = evidence(role)
            report['source']['source_revision'] = '8' * 40
            self.refused(report, image, role)
            report, image = evidence(role)
            del report['source']['files']['tools/registry.py']
            self.refused(report, image, role)

    def test_runtime_and_qualifier_hashes_and_dependency_profiles_cannot_drift(self):
        for key, bad in (('qualifier_runtime_files', {}), ('qualification_image_id', 'sha256:' + '2' * 64),
                ('database_fixture_version', '16.15'), ('loaded_libraries', {'libpq': '18.6', 'OpenSSL': '3.5.9'}),
                ('final_compiler_and_postgresql_server_absent', False)):
            report, image = evidence('publisher')
            report[key] = bad
            self.refused(report, image, 'publisher')
        report, image = evidence('publisher')
        del report['runtime_files']['/usr/local/bin/asm-publisher']
        self.refused(report, image, 'publisher')
        report, image = evidence('checker')
        report['runtime_files']['/app/tools/publication_check.py'] = '0' * 64
        self.refused(report, image, 'checker')

    def test_checker_case_bindings_and_network_authority_are_required(self):
        for mutate in (lambda r: r.update(inputs_unchanged=False), lambda r: r.update(checker_policy_sha256='0' * 64),
                lambda r: r['security'].update(network='host'), lambda r: r['cases'].pop(),
                lambda r: r['cases'][0].update(expected_outcome='pass'),
                lambda r: r['cases'][0].update(task_id='other'),
                lambda r: r['cases'][0].update(receipt_sha256=None),
                lambda r: r['cases'][0].update(exit_status=1)):
            report, image = evidence('checker')
            mutate(report)
            self.refused(report, image, 'checker')

    def test_main_only_publication_checks_before_loading_and_never_executes_images(self):
        text = (ROOT / '.github/workflows/operator-images.yml').read_text()
        self.assertIn('  publish-v2:', text)
        publisher = text.split('  publish-v2:', 1)[1]
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/main'", publisher)
        self.assertIn('role: [publisher, checker]', publisher)
        checked = publisher.index('--image image.json')
        loaded = publisher.index('docker load --input runtime.tar')
        reinspected = publisher.index('--image loaded-image.json')
        self.assertLess(checked, loaded)
        self.assertLess(loaded, reinspected)
        self.assertLess(reinspected, publisher.index('docker login '))
        self.assertNotIn('docker run ', publisher)
        self.assertNotIn('docker build ', publisher)
        self.assertIn('subject-digest: ${{ steps.image.outputs.digest }}', publisher)

    def test_strict_json_command_preserves_duplicate_and_lossy_evidence(self):
        report, image = evidence('publisher')
        with tempfile.TemporaryDirectory(prefix='asm-v2-publication-') as name:
            directory = Path(name)
            image_file, report_file = directory / 'image.json', directory / 'report.json'
            image_file.write_text(json.dumps(image))
            bodies = [json.dumps(report).encode().replace(b'"schema": 1', b'"schema": 9,"schema": 1', 1),
                json.dumps(report).encode().replace(b'"tests_run": 55', b'"tests_run": 55.0', 1),
                json.dumps(report).encode() + b'\n{}']
            for body in bodies:
                report_file.write_bytes(body)
                result = subprocess.run([sys.executable, '-I', str(ROOT / 'tools/v2_image_publication.py'),
                    '--revision', REVISION, '--role', 'publisher', '--qualification', str(report_file),
                    '--image', str(image_file)], capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b'')
                self.assertEqual(report_file.read_bytes(), body)


if __name__ == '__main__':
    unittest.main()
