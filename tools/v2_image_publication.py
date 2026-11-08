#!/usr/bin/env python3
"""Authorize exact qualified V2 image bytes before registry publication.

SPDX-License-Identifier: AGPL-3.0-or-later
Release automation only. This tool never loads, rebuilds, or executes an image.
"""
from __future__ import annotations

import argparse
import ast
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import operator_source
from operator_publication import canonical_input
from registry_admin import require

ROOT = Path(__file__).resolve().parents[1]
PUBLISHER_FILES = ('/usr/local/bin/asm-publisher', '/opt/asm/openssl/lib/libcrypto.so.3',
    '/opt/asm/openssl/lib/libssl.so.3', '/opt/asm/postgres/lib/libpq.so.5',
    '/opt/asm/mhd/lib/libmicrohttpd.so.12')
CHECKER_FILES = ('tools/checker_entrypoint.py', 'tools/image_source.py', 'tools/publication_check.py',
    'tools/registry.py', 'tools/registry_storage.py')
CHECKER_OUTCOMES = {'valid-source': 'pass', 'valid-features': 'pass', 'corrupt-object': 'error',
    'malformed-archive': 'fail', 'malformed-manifest': None, 'absent-object': 'error',
    'linked-object': 'error', 'target-mismatch': 'fail', 'feature-mismatch': 'fail'}
PUBLISHER_SUITES = (
    ('tests/publisher/test_authority.py', 'test_authority', 'PublisherAuthorityTests'),
    ('tests/publisher/test_distribution_authority.py', 'test_distribution_authority', 'DistributionAuthorityTests'),
    ('server/publisher/test_runtime.py', 'publisher_runtime_pg18', 'PublisherRuntimeTests'),
    ('tests/publisher/test_full_flow.py', 'test_full_flow', 'NativePublicationFullFlowTests'))


def required_test_ids(role):
    """Read required publisher methods from trusted source, without importing tests."""
    if role == 'checker':
        return sorted(CHECKER_OUTCOMES)
    require(role == 'publisher', 'Select an explicit V2 image role.')
    result = []
    for path, module, name in PUBLISHER_SUITES:
        tree = ast.parse((ROOT / path).read_text())
        classes = [item for item in tree.body if isinstance(item, ast.ClassDef) and item.name == name]
        require(len(classes) == 1, 'The required publisher suite is unavailable.')
        result.extend(f'{module}.{name}.{item.name}' for item in classes[0].body
            if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)) and item.name.startswith('test_'))
    require(len(result) >= 55 and len(set(result)) == len(result), 'The publisher qualification suites are incomplete.')
    return sorted(result)


def checker_policy_digest():
    # This reads the trusted checkout, never code supplied by an image artifact.
    import publication_check
    return publication_check.policy_digest()


def matches(pattern, value):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def hash_value(value):
    return matches(r'[0-9a-f]{64}', value)


def image_digest(value):
    return matches(r'sha256:[0-9a-f]{64}', value)


def integer(value, minimum=0, maximum=(1 << 53) - 1):
    return type(value) is int and minimum <= value <= maximum


def validate(revision, role, report, image):
    """Validate bounded decoded evidence against the trusted role and exact image."""
    require(matches(r'[0-9a-f]{40}', revision) and revision != '0' * 40, 'Supply the exact accepted source revision.')
    require(role in ('publisher', 'checker') and isinstance(report, dict) and isinstance(image, dict),
        'Select one V2 role, report, and inspected image.')
    require(type(report.get('schema')) is int and report['schema'] == 1 and report.get('status') == 'pass'
        and report.get('scope') == 'v2-runtime-qualification' and report.get('role') == role,
        'Only complete V2 role qualification can authorize publication.')
    require(report.get('os') == 'linux' and report.get('architecture') == 'amd64'
        and report.get('execution') == 'native' and report.get('source_revision') == revision,
        'The qualified source or native target differs.')
    required = required_test_ids(role)
    require(report.get('test_ids') == required and integer(report.get('tests_run'), len(required), len(required))
        and integer(report.get('tests_skipped'), 0, 0), 'Run every required role case without skips.')
    security = {'uid': 65532, 'gid': 65532, 'read_only_root': True, 'effective_capabilities': 0,
        'no_new_privileges': True, 'cluster_token': False}
    if role == 'checker':
        security['network'] = 'none'
    # Equality alone treats booleans as integers in Python. Enforce each type too.
    actual_security = report.get('security')
    require(isinstance(actual_security, dict) and actual_security == security
        and all(type(actual_security[name]) is type(value) for name, value in security.items()),
        'The measured runtime security contract differs.')
    require(image_digest(report.get('runtime_image_id')) and image.get('Id') == report['runtime_image_id']
        and image.get('Os') == 'linux' and image.get('Architecture') == 'amd64', 'The exact loaded runtime image differs.')
    config = image.get('Config')
    require(isinstance(config, dict), 'The loaded image configuration is unavailable.')
    entrypoint = ['/usr/local/bin/asm-publisher'] if role == 'publisher' else [
        '/usr/bin/python3', '-B', '-I', '/app/tools/checker_entrypoint.py']
    labels = config.get('Labels', {})
    require(config.get('User') == '65532:65532' and config.get('Entrypoint') == entrypoint
        and config.get('Cmd') == ['--help'] and not config.get('Volumes') and isinstance(labels, dict)
        and labels.get('org.opencontainers.image.revision') == revision
        and labels.get('org.opencontainers.image.source') == operator_source.REPOSITORY
        and labels.get('org.opencontainers.image.licenses') == 'AGPL-3.0-or-later',
        'The loaded entrypoint, identity, volumes, or source labels differ.')
    layers = image.get('RootFS', {}).get('Layers')
    require(isinstance(layers, list) and layers and all(image_digest(value) for value in layers),
        'The loaded image layers are unavailable.')
    source = report.get('source')
    require(isinstance(source, dict) and set(source) == {'schema', 'repository', 'source_revision',
        'bundle_sha256', 'bundle_bytes', 'files'} and type(source.get('schema')) is int and source['schema'] == 1
        and source.get('repository') == operator_source.REPOSITORY and source.get('source_revision') == revision
        and hash_value(source.get('bundle_sha256')) and integer(source.get('bundle_bytes'), 1, operator_source.MAX_BUNDLE)
        and isinstance(source.get('files'), dict) and set(source['files']) == set(operator_source.FILES)
        and all(hash_value(value) for value in source['files'].values()), 'The accepted source manifest differs.')
    files = report.get('runtime_files')
    require(isinstance(files, dict) and 1 <= len(files) <= 128 and all(
        matches(r'/[A-Za-z0-9_+./-]{1,255}', path) and '..' not in path.split('/') and hash_value(value)
        for path, value in files.items()) and hash_value(files.get('/app/SOURCE.json')),
        'The exact runtime digest inventory is incomplete.')
    if role == 'publisher':
        require(all(hash_value(files.get(path)) for path in PUBLISHER_FILES)
            and image_digest(report.get('qualification_image_id'))
            and report['qualification_image_id'] != report['runtime_image_id']
            and report.get('qualifier_runtime_files') == files,
            'The derived qualifier must retain the exact final executable and loaded libraries.')
        require(report.get('database_fixture_version') == '18.6'
            and report.get('loaded_libraries') == {'libpq': '16.15', 'OpenSSL': '3.5.9'}
            and report.get('final_compiler_and_postgresql_server_absent') is True,
            'The publisher dependency or final tool contract differs.')
    else:
        require(all(files.get('/app/' + path) == source['files'][path] for path in CHECKER_FILES)
            and report.get('checker_policy_sha256') == checker_policy_digest() and report.get('inputs_unchanged') is True,
            'The bundled checker source or preserved input evidence differs.')
        cases = report.get('cases')
        require(isinstance(cases, list) and len(cases) == len(required)
            and [case.get('id') for case in cases if isinstance(case, dict)] == required,
            'Every exact-image checker case is required once in canonical order.')
        for case in cases:
            invalid = case['id'] == 'malformed-manifest'
            require(set(case) == {'id', 'task_id', 'manifest_sha256', 'expected_outcome', 'exit_status', 'receipt_sha256'}
                and matches(r'[0-9a-f]{32}', case['task_id']) and hash_value(case['manifest_sha256'])
                and case['expected_outcome'] == CHECKER_OUTCOMES[case['id']]
                and integer(case['exit_status'], int(invalid), int(invalid))
                and (case['receipt_sha256'] is None if invalid else hash_value(case['receipt_sha256'])),
                'The checker receipt, outcome, or task binding differs.')


def check(revision, role, qualification, image):
    report = json.loads(canonical_input(qualification, report=True))
    inspected = json.loads(canonical_input(image))
    validate(revision, role, report, inspected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--role', required=True, choices=('publisher', 'checker'))
    parser.add_argument('--qualification', required=True, type=Path)
    parser.add_argument('--image', required=True, type=Path)
    args = parser.parse_args()
    try:
        check(args.revision, args.role, args.qualification, args.image)
    except (ValueError, OSError, RecursionError, TypeError, KeyError, AttributeError, SyntaxError):
        print('V2 image publication refused. Retain the exact report, image inspection, and complete logs.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
