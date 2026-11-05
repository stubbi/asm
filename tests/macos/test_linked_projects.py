"""Run the shared native-library build contract on Apple Silicon macOS.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import importlib.util
import sys

SHARED_TESTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHARED_TESTS))
# A distinct file and module name preserve full-suite test discovery.
SPEC = importlib.util.spec_from_file_location("shared_native_link_tests", SHARED_TESTS / "test_native_link.py")
shared = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(shared)
NativeLinkTests = shared.NativeLinkTests
