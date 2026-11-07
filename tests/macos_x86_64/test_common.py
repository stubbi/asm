"""Run the same observable command contracts with Intel Darwin fixtures."""
import os
from pathlib import Path
import sys
os.environ['ASM_TEST_TARGET'] = 'x86_64-macos'
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from test_cli import NativeCliTests
from test_dependencies_cli import DependencyCliTests
from test_registry_cli import RegistryCliTests
from test_install import InstallTests
from test_publish_cli import NativePublishTests
from test_programs_cli import InstalledProgramTests

from test_native_link import NativeLinkTests
from test_archive_cli import NativeArchiveTests
from test_cross_build_cli import CrossBuildTests
from test_resolver_cli import ResolverCliTests
from test_resolution_manifest import ResolutionManifestTests
from test_resolution_manifest_cli import ResolutionManifestCliTests
