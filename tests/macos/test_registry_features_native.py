"""Run native V2 contracts and the case-insensitive credential boundary on macOS.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import os
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# The minimal V1 profile has no V2 command. Its existing suite still runs.
if os.environ.get("ASM_REGISTRY_TEST_BINARY"):
    from test_registry_solver import RegistrySolverTests
    from test_registry_v2_dependencies import RegistryV2DependencyTests
    from test_registry_v2_cli import (RegistryV2CliTests, RegistryV2PublicationTests,
                                      RegistryV2DistributionTests)
    from test_registry_project import RegistryProjectTests
    from test_registry_v2_arm import NativeArmRegistryV2Tests

    class RegistryCredentialCaseTests(unittest.TestCase):
        setUpClass = classmethod(RegistryProjectTests.setUpClass.__func__)
        setUp = RegistryProjectTests.setUp
        cli = RegistryProjectTests.cli
        git = RegistryProjectTests.git
        commit = RegistryProjectTests.commit
        publish_project = RegistryProjectTests.publish_project
        test_filesystem_case_alias_cannot_hide_a_packaged_credential = (
            RegistryProjectTests.check_filesystem_case_alias_cannot_hide_a_packaged_credential)
