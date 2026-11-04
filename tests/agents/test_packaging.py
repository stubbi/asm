"""Release source collection must retain the agent runtime inputs."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import registry
import release


class PackagingTests(unittest.TestCase):
    def test_recorded_source_retains_skill_and_dependency_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            expected = {}
            for relative in ("skills/asm-build/SKILL.md", "skills/asm-build/references/targets.json",
                             "requirements-mcp.in", "requirements-mcp.txt", "tools/mcp_server.py",
                             "server/test_runtime.py", "experiments/assembly-server/local_postgres.py",
                             "experiments/assembly-server/guard.sql",
                             "experiments/assembly-server/fixtures/0001_registry.sql",
                             "experiments/assembly-server/DEPENDENCIES.md"):
                data = (ROOT / relative).read_bytes()
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                expected[relative] = data
            def git(*args):
                return subprocess.run(["git", "-C", str(repo), "-c", "core.hooksPath=/dev/null",
                    "-c", "commit.gpgSign=false", "-c", "user.name=Asm packaging fixture",
                    "-c", "user.email=fixture@example.invalid", *args], check=True, capture_output=True, timeout=10).stdout
            git("init", "-q")
            git("add", ".")
            git("commit", "-qm", "Record source fixture")
            commit = git("rev-parse", "HEAD").decode().strip()
            files = registry.git_files(repo, commit, ".", release.SOURCE_INCLUDES)
            self.assertEqual({path: value[0] for path, value in files.items()}, expected)


if __name__ == "__main__":
    unittest.main()
