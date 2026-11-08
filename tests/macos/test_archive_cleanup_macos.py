"""Run the shared directory cleanup contract in both macOS CLI profiles.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from pathlib import Path
import importlib.util
import sys

SHARED_TESTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SHARED_TESTS))
SPEC = importlib.util.spec_from_file_location("shared_archive_cleanup_tests", SHARED_TESTS / "test_archive_cleanup.py")
shared = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(shared)
ArchiveCleanupTests = shared.ArchiveCleanupTests
