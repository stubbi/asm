"""Native embedded-verifier protocol; signature/TUF checks use real Go tests.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import json
import re
import sys
import unittest

import test_self_update as legacy


class TrustedSelfUpdateTests(unittest.TestCase):
    compile_version = classmethod(legacy.SelfUpdateTests.compile_version.__func__)
    tearDownClass = classmethod(legacy.SelfUpdateTests.tearDownClass.__func__)
    setUp = legacy.SelfUpdateTests.setUp
    save = legacy.SelfUpdateTests.save
    row = legacy.SelfUpdateTests.row
    write_index = legacy.SelfUpdateTests.write_index
    cli = legacy.SelfUpdateTests.cli
    calls = legacy.SelfUpdateTests.calls
    unchanged = legacy.SelfUpdateTests.unchanged

    @classmethod
    def setUpClass(cls):
        legacy.SelfUpdateTests.setUpClass.__func__(cls)
        helper = cls.fixture / "embedded-verifier"
        helper.write_text(embedded_source(cls.fixture))
        source = cls.source / legacy.CLI_DIRECTORY.relative_to(legacy.ROOT) / "self_update_trust.s"
        text = re.sub(r'\.incbin "build/asm-verify-[^"]+"', f'.incbin "{helper}"', source.read_text())
        source.write_text(text)
        cls.original_source = '.set ASM_TRUSTED_DISTRIBUTION, 1\n' + cls.original_source
        cls.current_bytes = cls.compile_version(legacy.CURRENT)
        cls.next_bytes = cls.compile_version(legacy.NEXT)
        (cls.fixture / "gh-fixture").unlink()

    def test_updates_using_embedded_verifier_without_gh(self):
        self.cli("self", "update")
        self.assertEqual(self.installed.read_bytes(), self.next_bytes)
        calls = [c["args"] for c in self.calls() if c["tool"] == "embedded"]
        self.assertEqual([c[0] for c in calls], ["metadata", "provenance", "provenance", "provenance", "authorize"])
        self.assertEqual([c[3] for c in calls if c[0] == "provenance"], ["-", legacy.COMMIT, legacy.COMMIT])

    def test_freshness_failure_checks_even_an_explicit_equal_version(self):
        self.state["metadata_failure"] = True
        self.save()
        self.cli("self", "update", legacy.CURRENT, code=1)
        self.unchanged()
        self.assertEqual([c["tool"] for c in self.calls()], ["embedded"])

    def test_revocation_and_signature_failure_keep_existing_bytes(self):
        for failure in ("revoked", "verification_failure"):
            with self.subTest(failure=failure):
                self.state.update(revoked=False, verification_failure=False)
                self.state[failure] = True
                self.save()
                self.cli("self", "update", code=1)
                self.unchanged()


def embedded_source(directory, index="index.tsv"):
    return f'''#!{sys.executable}
import json, os, pathlib, sys
root = pathlib.Path({str(directory)!r})
state = json.loads((root / "state.json").read_text())
args = sys.argv[1:]
assert "GH_TOKEN" not in os.environ and "CURL_CA_BUNDLE" not in os.environ
with (root / "calls.jsonl").open("a") as out:
    out.write(json.dumps({{"tool":"embedded", "args":args, "env":dict(os.environ)}})+"\\n")
if args[0] == "metadata":
    assert args[1].endswith("/.local/bin/.asm-trust") and args[2] == {index!r}
    if state.get("metadata_failure"): sys.exit(1)
    pathlib.Path(args[3]).write_bytes((root / "index.tsv").read_bytes())
elif args[0] == "authorize":
    assert args[1].endswith("/.local/bin/.asm-trust")
    assert args[2].startswith("asm-")
    if state.get("revoked"): sys.exit(1)
elif args[0] == "provenance":
    assert args[3] in ("-", state["signed_commit"])
    if state.get("verification_failure"): sys.exit(1)
    print("1441332955")
else: raise AssertionError(args)
'''
