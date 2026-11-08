"""V2 feature metadata and source binding; no dependency code executes.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from copy import deepcopy
import hashlib
import tomllib
import unittest

import test_checker as checker_fixture

registry = checker_fixture.registry


DEPENDENCIES = [
    {"default_features": True, "features": [], "name": "a/math", "optional": False, "requirement": "*"},
    {"default_features": False, "features": ["portable", "wide"], "name": "z/math", "optional": True,
     "requirement": "^2.0.0"},
]
FEATURES = [{"members": ["vectors"], "name": "default"},
            {"members": ["dep:z/math", "z/math/portable"], "name": "vectors"}]
SOURCE = '''\n[dependencies]
"z/math" = { features = ["wide", "portable"], version = "^2.0.0", optional = true, default-features = false }
"a/math" = "*"
[features]
vectors = ["z/math/portable", "dep:z/math"]
default = ["vectors"]
'''


class V2FeatureMetadataTests(unittest.TestCase):
    def declarations(self, value):
        helper = getattr(registry, "v2_declarations", None)
        self.assertTrue(callable(helper), "V2 needs complete normalized dependency and feature declarations")
        return helper(value)

    def source(self, text):
        helper = getattr(registry, "v2_project_declarations", None)
        self.assertTrue(callable(helper), "V2 source declarations need the same feature contract")
        data = text.encode("ascii")
        return helper(data, tomllib.loads(text))

    def test_legacy_defaults_and_expanded_metadata_compare_without_rewriting_input(self):
        legacy = {"dependencies": [{"name": "a/math", "requirement": "*"}]}
        before = registry.json_bytes(legacy)
        self.assertEqual(self.declarations(legacy), ([DEPENDENCIES[0]], []))
        self.assertEqual(registry.json_bytes(legacy), before)
        value = {"dependencies": deepcopy(DEPENDENCIES), "features": deepcopy(FEATURES)}
        self.assertEqual(self.declarations(value), (DEPENDENCIES, FEATURES))
        self.assertEqual(self.source(SOURCE), (DEPENDENCIES, FEATURES))

    def test_inactive_invalid_metadata_and_noncanonical_lists_are_rejected(self):
        valid = {"dependencies": deepcopy(DEPENDENCIES), "features": deepcopy(FEATURES)}
        cases = []
        for key, bad in (("optional", 1), ("default_features", "false"), ("features", ["wide", "portable"]),
                         ("features", ["portable", "portable"]), ("features", ["invalid/name"])):
            item = deepcopy(valid); item["dependencies"][1][key] = bad; cases.append(item)
        for definitions in ([{"name": "unused", "members": ["missing"]}],
                            [{"name": "unused", "members": ["dep:a/math"]}],
                            [{"name": "unused", "members": ["other/math/portable"]}],
                            [{"name": "a", "members": ["b"]}, {"name": "b", "members": ["a"]}],
                            FEATURES[::-1], FEATURES + [FEATURES[-1]]):
            item = deepcopy(valid); item["features"] = definitions; cases.append(item)
        for value in cases:
            with self.subTest(value=value), self.assertRaises(registry.RegistryError):
                self.declarations(value)

    def test_source_normalizes_members_but_rejects_syntax_the_native_parser_cannot_read(self):
        self.assertEqual(self.source('[features]\nempty = []\n'), ([], [{"members": [], "name": "empty"}]))
        for source in ('[resolution]\nschema = "1"\n', '[features]\na = [\n]\n',
                       '[dependencies]\n"a/math" = { version = "*", }\n',
                       '[features]\n"a\\u0062" = []\n', '[features]\na.b = []\n', '[ features ]\n'):
            with self.subTest(source=source), self.assertRaises((registry.RegistryError, tomllib.TOMLDecodeError)):
                self.source(source)

    def test_signed_feature_text_uses_the_native_profile_budget(self):
        # Four lists of 64 names use 31 characters plus a NUL byte: 8192 bytes.
        requested = ["f" + str(index).zfill(30) for index in range(64)]
        value = {"dependencies": [{"name": "other/" + name, "requirement": "*", "features": list(requested)}
                                   for name in "abcd"]}
        self.assertLess(len(registry.json_bytes(value)), 65536)
        normalized, features = self.declarations(value)
        self.assertEqual([edge["features"] for edge in normalized], [requested] * 4)
        self.assertEqual(features, [])
        # The final 32-character identifier remains valid; only the pool grows.
        value["dependencies"][-1]["features"][-1] += "a"
        with self.assertRaises(registry.RegistryError):
            self.declarations(value)


class V2FeatureCheckerTests(unittest.TestCase):
    setUp = checker_fixture.PublicationCheckerTests.setUp
    archive = checker_fixture.PublicationCheckerTests.archive
    write = checker_fixture.PublicationCheckerTests.write
    module = checker_fixture.PublicationCheckerTests.module
    check = checker_fixture.PublicationCheckerTests.check

    def feature_source(self):
        self.data = self.archive(SOURCE)
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.manifest["source"]["archive"] = {"sha256": self.digest, "bytes": len(self.data)}
        self.manifest["artifacts"][0].update(sha256=self.digest, bytes=len(self.data))
        self.manifest.update(dependencies=deepcopy(DEPENDENCIES), features=deepcopy(FEATURES))
        self.object_file = self.objects / (self.task + "-" + self.digest)
        self.write()

    def test_complete_source_features_are_checked_without_resolving_child_features(self):
        self.feature_source()
        before = self.manifest_file.read_bytes()
        try:
            self.assertEqual(self.check()["outcome"], "pass")
        except registry.RegistryError as error:
            self.fail(str(error))
        self.assertEqual(self.manifest_file.read_bytes(), before)

    def test_changed_inactive_options_requests_and_definitions_fail_source_binding(self):
        self.feature_source()
        original = deepcopy(self.manifest)
        for change in (lambda value: value["dependencies"][0].update(optional=True),
                       lambda value: value["dependencies"][1].update(default_features=True),
                       lambda value: value["dependencies"][1].update(features=["portable"]),
                       lambda value: value["features"][1].update(members=["dep:z/math"])):
            self.manifest = deepcopy(original)
            change(self.manifest)
            self.write()
            with self.subTest(manifest=self.manifest):
                try:
                    self.assertEqual(self.check()["outcome"], "fail")
                except registry.RegistryError as error:
                    self.fail(str(error))


if __name__ == "__main__":
    unittest.main()
