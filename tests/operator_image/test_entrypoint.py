"""The image exposes fixed privileged paths and explicit operator commands.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import operator_entrypoint as entrypoint


class EntrypointTests(unittest.TestCase):
    def test_import_help_exposes_the_optional_local_distribution_gate(self):
        result = subprocess.run([sys.executable, str(ROOT / "tools/operator_entrypoint.py"), "import", "--help"],
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertIn(b"--distribution-root", result.stdout)

    def test_distribution_path_is_one_argument_without_source_or_client_override(self):
        commit = "1" * 40
        path = "/distribution/operator snapshot"
        with patch.object(entrypoint, "source_revision", return_value=commit), \
                patch.object(entrypoint.registry_admin, "main", return_value=0) as delegated:
            self.assertEqual(entrypoint.main(["import", "--connection-file", "/run/private/database.url",
                "--expected-revision", "3", "--plan-sha256", "a" * 64, "--distribution-root", path]), 0)
        arguments = delegated.call_args.args[0]
        self.assertEqual(arguments[arguments.index("--distribution-root") + 1], path)
        self.assertEqual(arguments[arguments.index("--repository") + 1], "/opt/asm/source.git")
        self.assertEqual(arguments[arguments.index("--commit") + 1], commit)
        self.assertEqual(arguments[arguments.index("--psql") + 1], "/opt/asm/postgres/bin/psql")

    def test_plan_and_import_use_only_the_image_source_and_fixed_client(self):
        commit = "1" * 40
        with patch.object(entrypoint, "source_revision", return_value=commit), patch.object(entrypoint.registry_admin, "main", return_value=0) as delegated:
            self.assertEqual(entrypoint.main(["plan", "--expected-revision", "3"]), 0)
            arguments = delegated.call_args.args[0]
            self.assertEqual(arguments[:3], ["--psql", "/opt/asm/postgres/bin/psql", "plan"])
            self.assertIn("/opt/asm/source.git", arguments)
            self.assertIn(commit, arguments)
            self.assertEqual(entrypoint.main(["import", "--connection-file", "/run/private/database.url",
                "--expected-revision", "3", "--plan-sha256", "a" * 64]), 0)
            self.assertIn("import", delegated.call_args.args[0])
            self.assertIn(commit, delegated.call_args.args[0])

    def test_path_overrides_and_legacy_role_flags_are_refused_before_delegation(self):
        with patch.object(entrypoint.registry_admin, "main") as delegated:
            for argv in (["plan", "--expected-revision", "0", "--repository", "/untrusted"],
                         ["plan", "--expected-revision", "0", "--commit", "2" * 40],
                         ["plan", "--expected-revision", "0", "--distribution-root", "/distribution"],
                         ["grant", "--connection-file", "/run/private/database.url", "--reader-role", "other"],
                         ["migrate", "--connection-file", "/run/private/database.url", "--psql", "/untrusted"]):
                with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as stopped:
                    entrypoint.main(argv)
                self.assertEqual(stopped.exception.code, 2)
            delegated.assert_not_called()

    def test_prepare_is_an_explicit_separate_operation_without_sql_delegation(self):
        arguments = ["--config-directory", "/projected/config", "--tls-directory", "/projected/tls",
                     "--destination-directory", "/run/private", "--role", "asm_migrator", "--resolve-dns"]
        with patch.object(entrypoint.prepare_operator, "main", return_value=0) as prepare, patch.object(entrypoint.registry_admin, "main") as sql:
            self.assertEqual(entrypoint.main(["prepare-operator", *arguments]), 0)
            prepare.assert_called_once_with(arguments)
            sql.assert_not_called()


if __name__ == "__main__":
    unittest.main()
