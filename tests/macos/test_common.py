"""Run the shared observable CLI and dependency contracts on native Darwin."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from test_cli import NativeCliTests
from test_dependencies_cli import DependencyCliTests

from test_registry_cli import RegistryCliTests
from test_install import InstallTests
from test_publish_cli import NativePublishTests

from test_target_indexes import TargetIndexTests

from test_archive_cli import NativeArchiveTests
from test_programs_cli import InstalledProgramTests

from test_resolver_cli import ResolverCliTests
from test_resolution_manifest import ResolutionManifestTests
