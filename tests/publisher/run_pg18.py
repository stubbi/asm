"""Run explicit V2 suites with a new owned PostgreSQL 18.6 server.

SPDX-License-Identifier: AGPL-3.0-or-later
The default server fixture and all 16.15 client checks remain unchanged.
"""
import argparse
import importlib
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

from pg18_fixture import Pg18TlsPostgres, preflight, reader_fixture


ROOT = Path(__file__).resolve().parents[2]
SUITES = {"authority": ("test_authority", "PublisherAuthorityTests"),
          "distribution": ("test_distribution_authority", "DistributionAuthorityTests"),
          "runtime": ("publisher_runtime_pg18", "PublisherRuntimeTests"),
          "full-flow": ("test_full_flow", "NativePublicationFullFlowTests")}


def load_suites(names):
    """Select the server before authority modules bind their fixture class."""
    if any(name in sys.modules for name, _ in SUITES.values()):
        raise RuntimeError("Select the PostgreSQL 18 fixture before importing V2 qualification suites.")
    reader_fixture.TlsPostgres = Pg18TlsPostgres
    suite = unittest.TestSuite()
    for name in names:
        module_name, class_name = SUITES[name]
        if name == "runtime":
            spec = importlib.util.spec_from_file_location(module_name, ROOT / "server/publisher/test_runtime.py")
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        else:
            module = importlib.import_module(module_name)
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(getattr(module, class_name)))
    return suite


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-only", action="store_true", help="Validate binary profiles without starting a server.")
    parser.add_argument("suites", nargs="*", choices=tuple(SUITES))
    args = parser.parse_args(argv)
    if args.check_only == bool(args.suites):
        parser.error("Select one or more suites, or use --check-only alone.")
    try:
        preflight()
        if args.check_only:
            print("Fixture binary profiles match; no server checks ran.")
            return 0
        result = unittest.TextTestRunner(verbosity=2).run(load_suites(args.suites))
        return 0 if (result.testsRun and not result.skipped and not result.expectedFailures
                     and not result.unexpectedSuccesses and result.wasSuccessful()) else 1
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("PostgreSQL 18 qualification refused: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
