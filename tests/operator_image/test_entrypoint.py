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
    def test_v2_help_and_privileged_overrides(self):
        script = str(ROOT / "tools/operator_entrypoint.py")
        for command in (["publisher-admin", "--help"], ["distribution", "publish", "--help"], ["prepare-signers", "--help"]):
            result = subprocess.run([sys.executable, script, *command], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertNotIn(b"--psql", result.stdout)
            self.assertNotIn(b"--trust-tool", result.stdout)
            self.assertNotIn(b"--checker-revision", result.stdout)
        for command in (["publisher-admin", "--connection-file", "/private/db", "check-policy",
                         "--reference", "audit", "--checker-revision", "2" * 40],
                        ["distribution", "publish", "--psql", "/untrusted"]):
            result = subprocess.run([sys.executable, script, *command], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2, result.stderr.decode())
            self.assertEqual(result.stdout, b"")

    def test_policy_registration_uses_bundled_checker_identity(self):
        import publisher_admin
        import publication_check
        with patch.object(entrypoint, "source_revision", return_value="1" * 40), \
                patch.object(publisher_admin, "main", return_value=0) as delegate:
            self.assertEqual(entrypoint.main(["publisher-admin", "--connection-file", "/private/db", "check-policy",
                                              "--reference", "audit/1"]), 0)
        self.assertEqual(delegate.call_args.args[0], ["--connection-file", "/private/db", "--psql",
            "/opt/asm/postgres/bin/psql", "check-policy", "--reference", "audit/1", "--checker-revision",
            "1" * 40, "--policy-sha256", publication_check.policy_digest()])

    def test_signed_distribution_fixes_the_trust_tool(self):
        import registry_distribution
        with patch.object(entrypoint, "source_revision", return_value="1" * 40), \
                patch.object(registry_distribution, "main", return_value=0) as delegate:
            self.assertEqual(entrypoint.main(["distribution", "publish", "--connection-file", "/private/db",
                "--worker-id", "a" * 32, "--trust-root", "/private/root.json", "--keys-dir", "/private/signers",
                "--work-root", "/private/work", "--store", "local", "--root", "/public",
                "--source-store", "local", "--source-root", "/retained"]), 0)
        args = delegate.call_args.args[0]
        self.assertEqual(args[args.index("--psql") + 1], "/opt/asm/postgres/bin/psql")
        self.assertEqual(args[args.index("--trust-tool") + 1], "/app/bin/asm-trust")

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
