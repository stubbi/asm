"""Keep the gated bundled-verifier protocol executable on Intel Darwin.
These transport/authorization fixtures do not provision production trust.
"""
import os
from pathlib import Path
import re
import sys
import unittest
os.environ['ASM_TEST_TARGET'] = 'x86_64-macos'
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests'))
sys.path.insert(0, str(ROOT / 'tests/macos_x86_64'))
import test_trusted_self_update as trusted
import test_self_update as legacy
import test_update_intel as intel


class IntelTrustedUpdateTests(unittest.TestCase):
    compile_version = classmethod(intel.IntelSelfUpdateTests.compile_version.__func__)
    tearDownClass = classmethod(intel.IntelSelfUpdateTests.tearDownClass.__func__)
    setUp = legacy.SelfUpdateTests.setUp
    save = legacy.SelfUpdateTests.save
    row = legacy.SelfUpdateTests.row
    write_index = legacy.SelfUpdateTests.write_index
    cli = legacy.SelfUpdateTests.cli
    calls = legacy.SelfUpdateTests.calls
    unchanged = legacy.SelfUpdateTests.unchanged

    @classmethod
    def setUpClass(cls):
        intel.IntelSelfUpdateTests.setUpClass.__func__(cls)
        helper = cls.fixture / 'embedded-verifier'
        helper.write_text(trusted.embedded_source(cls.fixture, 'index-macos.tsv'))
        cls.original_source = '.set ASM_TRUSTED_DISTRIBUTION, 1\n' + re.sub(
            r'\.incbin "build/asm-verify-[^"]+"', f'.incbin "{helper}"', cls.original_source)
        cls.current_bytes = cls.compile_version(legacy.CURRENT)
        cls.next_bytes = cls.compile_version(legacy.NEXT)
        (cls.fixture / 'gh-fixture').unlink()

    test_updates_using_embedded_verifier_without_gh = trusted.TrustedSelfUpdateTests.test_updates_using_embedded_verifier_without_gh
    test_freshness_failure_checks_even_an_explicit_equal_version = trusted.TrustedSelfUpdateTests.test_freshness_failure_checks_even_an_explicit_equal_version
    test_revocation_and_signature_failure_keep_existing_bytes = trusted.TrustedSelfUpdateTests.test_revocation_and_signature_failure_keep_existing_bytes
