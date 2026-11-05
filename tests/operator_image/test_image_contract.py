"""Qualification must bind actual image bytes, dependencies, and applicable tests.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
from pathlib import Path
import sys
import unittest
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import test_operator_image as image


class ImageContractTests(unittest.TestCase):
    def fixture(self):
        return {"Architecture": "amd64", "Os": "linux", "Id": "sha256:" + "1" * 64,
                "RootFS": {"Layers": ["sha256:" + "2" * 64]}, "Config": {"User": "65532:65532",
                "Entrypoint": ["/usr/bin/python3", "-I", "/app/tools/operator_entrypoint.py"], "Cmd": ["--help"],
                "Labels": {"org.opencontainers.image.revision": "3" * 40}}}

    def test_image_target_user_entrypoint_source_and_layers_are_mandatory(self):
        value = self.fixture()
        self.assertEqual(image.image_contract(value, "3" * 40), value["Id"])
        for key, replacement in (("Architecture", "arm64"), ("Os", "windows"), ("Id", "mutable-tag")):
            changed = copy.deepcopy(value)
            changed[key] = replacement
            with self.subTest(key=key), self.assertRaises(ValueError):
                image.image_contract(changed, "3" * 40)
        value["Config"]["User"] = "0:0"
        with self.assertRaises(ValueError):
            image.image_contract(value, "3" * 40)

    def test_derived_qualification_cannot_change_a_runtime_dependency(self):
        runtime = self.fixture()
        qualifier = copy.deepcopy(runtime)
        qualifier["RootFS"]["Layers"].append("sha256:" + "4" * 64)
        files = {"/app/tools/registry_admin.py": "a" * 64, "/lib/libssl.so.3": "b" * 64}
        image.derived_contract(runtime, qualifier, files, files)
        changed = dict(files, **{"/lib/libssl.so.3": "c" * 64})
        with self.assertRaises(ValueError):
            image.derived_contract(runtime, qualifier, files, changed)
        qualifier["RootFS"]["Layers"][0] = "different"
        with self.assertRaises(ValueError):
            image.derived_contract(runtime, qualifier, files, files)

    def test_only_the_named_macos_case_is_inapplicable_on_linux(self):
        def result(skips):
            return SimpleNamespace(testsRun=35, skipped=skips, wasSuccessful=lambda: True)
        named = SimpleNamespace(id=lambda: "test_database.CatalogDatabaseTests.test_extended_acl_on_private_key_cannot_reach_mutation")
        self.assertEqual(len(image.test_contract(result([(named, "macOS extended ACL interface")]), 35)), 1)
        applicable = SimpleNamespace(id=lambda: "test_prepare.RootProjectedImageTests.test_real_root_gid65532_projection_and_policy_failures")
        with self.assertRaises(ValueError):
            image.test_contract(result([(applicable, "fixture missing")]), 35)
        with self.assertRaises(ValueError):
            image.test_contract(result([]), 36)


if __name__ == "__main__":
    unittest.main()
