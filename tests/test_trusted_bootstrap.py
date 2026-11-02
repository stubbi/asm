"""Bundled-verifier installation behavior; cryptography lives in Go tests.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import unittest

import test_bootstrap as legacy
sys.path.insert(0, str(legacy.ROOT / "tools"))
import trusted_bootstrap


class TrustedBootstrapTests(unittest.TestCase):
    tool_double = legacy.TOOL_DOUBLE
    setUp = legacy.BootstrapUserFlowTests.setUp
    run_installer = legacy.BootstrapUserFlowTests.run_installer
    save_config = legacy.BootstrapUserFlowTests.save_config
    assert_no_install = legacy.BootstrapUserFlowTests.assert_no_install
    destination = legacy.BootstrapUserFlowTests.destination
    calls = legacy.BootstrapUserFlowTests.calls

    def write_script(self):
        target = self.release["artifacts"][0]["target"]
        version = self.release["version"]
        helper = self.base / "helper"
        helper.write_text(f'''#!{sys.executable}
import json, os, pathlib, sys
base = pathlib.Path({str(self.base)!r})
cfg = json.loads((base / "tools/config.json").read_text())
args = sys.argv[1:]
assert not any(k in os.environ for k in ("GH_TOKEN", "GITHUB_TOKEN", "SSL_CERT_FILE", "TUF_ROOT"))
with (base / "helper-calls").open("a") as out: out.write(json.dumps(args)+"\\n")
if args[0] == "authorize":
    assert args[1] == {str(self.home / '.local/bin/.asm-trust')!r}
    assert args[2] == {f"asm-{version}-{target}"!r}
    sys.exit(1 if cfg.get("expired_metadata") else 0)
assert args[0] == "provenance" and args[3] == {legacy.COMMIT!r}
if cfg.get("verification_error"): sys.exit(1)
print("1441332955")
''' + '\n#' + ' fixture padding' * 600 + '\n')
        self.verifier = {"target": target, "bytes": helper.stat().st_size,
                         "sha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
                         "url": f"https://github.com/stubbi/asm/releases/download/v{version}/asm-verify-{version}-{target}"}
        transport = self.tool_double.replace('#!/usr/bin/python3', f'#!{sys.executable}')
        transport = transport.replace('assert url in (cfg["artifact_url"], cfg["bundle_url"])', '''if url == cfg["verifier_url"]:
        if cfg.get("network_error"): sys.exit(22)
        data = pathlib.Path(cfg["verifier_path"]).read_bytes()
        if cfg.get("bad_verifier"): data = b"!" + data[1:]
        output.write_bytes(data)
        sys.exit(0)
    assert url in (cfg["artifact_url"], cfg["bundle_url"])''')
        (self.tools / "curl").write_text(transport)
        self.config.update(verifier_url=self.verifier["url"], verifier_path=str(helper))
        # Deliberately remove gh. The production template must not consult it.
        (self.tools / "gh").unlink(missing_ok=True)
        script = trusted_bootstrap.render_installer(self.release, [self.verifier]).decode()
        for name in ("curl", "uname", "ln"):
            script = script.replace("/usr/bin/" + name, str(self.tools / name))
        script = script.replace('for asm_tool in curl stat id mktemp mkdir chmod ln rm sha256sum env timeout; do',
                                'for asm_tool in stat id mktemp mkdir chmod rm sha256sum env timeout; do')
        self.script.write_text(script)

    def test_installs_without_gh_and_checks_authorization_before_provenance(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.destination.read_bytes(), legacy.PAYLOAD)
        calls = [json.loads(line) for line in (self.base / "helper-calls").read_text().splitlines()]
        self.assertEqual([call[0] for call in calls], ["authorize", "provenance"])
        self.assertEqual(list(self.destination.parent.glob('.asm-bootstrap.*')), [])

    def test_bad_helper_never_executes(self):
        self.assert_no_install(self.run_installer(bad_verifier=True))
        self.assertFalse((self.base / "helper-calls").exists())

    def test_expiry_signature_and_network_failure_preserve_destination(self):
        for failure in ("expired_metadata", "verification_error", "network_error"):
            with self.subTest(failure=failure):
                self.config.update(expired_metadata=False, verification_error=False, network_error=False)
                self.assert_no_install(self.run_installer(**{failure:True}))

    def test_existing_unrelated_file_is_preserved_without_downloading(self):
        self.destination.parent.mkdir(parents=True, mode=0o700)
        self.destination.write_bytes(b"keep")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.destination.read_bytes(), b"keep")
        self.assertEqual(self.calls("curl"), [])

    def test_template_has_valid_shell_and_exact_pins(self):
        script = trusted_bootstrap.render_installer(self.release, [self.verifier])
        result = subprocess.run(["/bin/sh", "-n"], input=script, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(b"/usr/bin/gh", script)
        for change in ({"sha256":"bad"}, {"url":"https://example.com/verifier"}, {"bytes":0}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                trusted_bootstrap.render_installer(self.release, [{**self.verifier, **change}])
