"""Source archive checks for bounded native-library declarations.

SPDX-License-Identifier: AGPL-3.0-or-later
"""

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("native_link_registry", ROOT / "tools/registry.py")
registry = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(registry)


def source_files(fields="", *, checker=True):
    manifest = ('[package]\nname = "server"\nversion = "0.1.0"\n'
                '[build]\nsource = "server.s"\ntarget = "x86_64-linux"\n' + fields)
    files = {"asm.toml": (manifest.encode(), 0o644), "server.s": (b".text\n", 0o644),
             "README.md": (b"Experimental assembly server.\n", 0o644),
             "LICENSE": (b"AGPL-3.0-or-later test fixture.\n", 0o644)}
    if checker:
        files["abi-check.c"] = (b"_Static_assert(sizeof(void *) == 8, \"LP64\");\n", 0o644)
    return files


class NativeLinkArchiveTests(unittest.TestCase):
    def validate(self, fields="", *, checker=True):
        archive = registry.make_archive(source_files(fields, checker=checker))
        files = registry.read_archive(archive)
        registry.validate_project(files, "owner/server", "0.1.0", "x86_64-linux")
        return files

    def test_response_file_forms_are_not_build_inputs(self):
        for name in ["@input.c", "nested/@input.c"]:
            files = {key: value[0] for key, value in source_files(f'link = "c"\ncheck = "{name}"\n').items()}
            files[name] = b"-x c /dev/null\n"
            with self.subTest(name=name), self.assertRaises(registry.RegistryError):
                registry.validate_project(files, "owner/server", "0.1.0", "x86_64-linux")
        files = {key: value[0] for key, value in source_files().items()}
        files["asm.toml"] = files["asm.toml"].replace(b'source = "server.s"', b'source = "@input.s"')
        files["@input.s"] = b"server.s\n"
        with self.assertRaises(registry.RegistryError):
            registry.validate_project(files, "owner/server", "0.1.0", "x86_64-linux")


    def test_server_style_archive_and_standalone_manifest_remain_valid(self):
        fields = 'link = "c"\nlibraries = "microhttpd pq pthread"\ncheck = "abi-check.c"\n'
        self.assertIn("abi-check.c", self.validate(fields))
        self.validate(checker=False)
        self.validate('link = "c"\n', checker=False)

    def test_resolution_metadata_preserves_native_library_contract(self):
        self.validate('link = "c"\nlibraries = "pq"\ncheck = "abi-check.c"\n'
                      '[resolution]\nschema = "1"\n[features]\ndefault = []\n')

    def test_eight_maximum_length_library_names_are_valid(self):
        names = " ".join(chr(ord("a") + number) * 31 for number in range(8))
        self.assertEqual(len(names), 255)
        self.validate(f'link = "c"\nlibraries = "{names}"\n')

    def test_existing_toml_literal_strings_and_comments_remain_valid(self):
        self.validate("link = 'c' # Keep normal TOML strings.\nlibraries = 'pq pthread'\n")

    def test_optional_fields_reject_malformed_or_unbounded_values(self):
        candidates = [
            'link = ""', 'link = "standalone"', 'link = "C"', 'link = 1',
            'link = "' + "c" * 256 + '"',
            'libraries = "pq"', 'check = "abi-check.c"',
            'link = "c"\nlibraries = ""', 'link = "c"\ncheck = ""',
            'link = "c"\nlibraries = ["pq"]', 'link = "c"\ncheck = false',
            'link = "c"\nlibraries = " pq"', 'link = "c"\nlibraries = "pq "',
            'link = "c"\nlibraries = "pq  pthread"', 'link = "c"\nlibraries = "PQ"',
            'link = "c"\nlibraries = "-lpq"', 'link = "c"\nlibraries = "path/pq"',
            'link = "c"\nlibraries = "pq,pthread"', 'link = "c"\nlibraries = "pq;id"',
            'link = "c"\nlibraries = "9pq"', 'link = "c"\nlibraries = "' + "a" * 32 + '"',
            'link = "c"\nlibraries = "a b c d e f g h i"',
            'link = "c"\nlibraries = "' + "a" * 256 + '"',
            'link = "c"\ncheck = "../abi-check.c"', 'link = "c"\ncheck = "/abi-check.c"',
            'link = "c"\ncheck = "dir//abi-check.c"', 'link = "c"\ncheck = "./abi-check.c"',
            'link = "c"\ncheck = "-abi-check.c"', 'link = "c"\ncheck = "abi-check.s"',
            'link = "c"\ncheck = "' + "a" * 254 + '.c"',
            'link = "c"\nlink = "c"', 'link = "c"\nlibraries = "pq"\nlibraries = "pq"',
            'link = "c"\ncheck = "abi-check.c"\ncheck = "abi-check.c"',
            'link = "c"\nunknown = "pq"',
        ]
        for fields in candidates:
            with self.subTest(fields=fields), self.assertRaises(registry.RegistryError):
                self.validate(fields + "\n")

    def test_declared_compile_checker_must_exist_in_the_archive(self):
        with self.assertRaises(registry.RegistryError):
            self.validate('link = "c"\ncheck = "abi-check.c"\n', checker=False)


if __name__ == "__main__":
    unittest.main()
