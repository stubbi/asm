"""Check bundled-verifier installation with native macOS filesystem tools.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import platform
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import test_trusted_bootstrap as trusted
import test_bootstrap_macos as mac


@unittest.skipUnless(platform.system() == "Darwin", "requires native macOS filesystem tools")
class MacTrustedBootstrapTests(unittest.TestCase):
    setUp = mac.MacOSBootstrapUserFlowTests.setUp
    run_installer = mac.MacOSBootstrapUserFlowTests.run_installer
    save_config = mac.MacOSBootstrapUserFlowTests.save_config
    assert_no_install = mac.MacOSBootstrapUserFlowTests.assert_no_install
    destination = mac.MacOSBootstrapUserFlowTests.destination
    calls = mac.MacOSBootstrapUserFlowTests.calls
    tool_double = mac.MAC_TOOL_DOUBLE
    write_script = trusted.TrustedBootstrapTests.write_script

    test_installs_without_gh_and_checks_authorization_before_provenance = trusted.TrustedBootstrapTests.test_installs_without_gh_and_checks_authorization_before_provenance
    test_bad_helper_never_executes = trusted.TrustedBootstrapTests.test_bad_helper_never_executes
    test_expiry_signature_and_network_failure_preserve_destination = trusted.TrustedBootstrapTests.test_expiry_signature_and_network_failure_preserve_destination
    test_existing_unrelated_file_is_preserved_without_downloading = trusted.TrustedBootstrapTests.test_existing_unrelated_file_is_preserved_without_downloading
    test_template_has_valid_shell_and_exact_pins = trusted.TrustedBootstrapTests.test_template_has_valid_shell_and_exact_pins
