"""Run reference package behavior in the native macOS qualification suite."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from packages.test_hello_macos import MacHelloTests
from packages.test_macos_reference_io import MacReferenceIoTests
from packages.test_math_aarch64 import MathAarch64Tests
from packages.test_math_x86_64_macos import MathX8664MacosTests


def load_tests(loader, tests, pattern):
    return unittest.TestSuite([
        loader.loadTestsFromTestCase(MacHelloTests),
        loader.loadTestsFromTestCase(MacReferenceIoTests),
        MathAarch64Tests("test_macos_demo_and_unsigned_abi_cases"),
        loader.loadTestsFromTestCase(MathX8664MacosTests),
    ])
