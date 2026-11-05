#!/usr/bin/env python3
"""Execute the Intel Darwin behavioral suite and retain its real result."""
import argparse
import json
import os
from pathlib import Path
import platform
import sys
import unittest
ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('Intel Darwin tests require macOS; no Linux substitution is permitted')
    os.environ['ASM_TEST_TARGET'] = 'x86_64-macos'
    sys.path.insert(0, str(ROOT / 'tests'))
    suite = unittest.defaultTestLoader.discover(str(ROOT / 'tests/macos_x86_64'), 'test_*.py')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    report = {'target': 'x86_64-macos', 'tests': result.testsRun,
              'failures': len(result.failures), 'errors': len(result.errors),
              'skipped': len(result.skipped),
              'expected_failures': len(result.expectedFailures), 'unexpected_successes': len(result.unexpectedSuccesses),
              'status': 'pass' if result.wasSuccessful() and result.testsRun >= 175 and not result.skipped and not result.expectedFailures else 'fail',
              'failed_cases': [{'test': str(case), 'detail': detail} for case, detail in result.failures + result.errors]}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report['status'] == 'pass' else 1

if __name__ == '__main__':
    raise SystemExit(main())
