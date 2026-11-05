"""Run shared selected-target contracts on native Apple Silicon macOS."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from test_cross_build_cli import CrossBuildTests
