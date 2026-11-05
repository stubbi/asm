"""Keep released parser vocabularies stable when the catalog gains targets."""

import copy
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import registry


LINUX_TARGETS = {"x86_64-linux", "aarch64-linux", "riscv64-linux"}
MACOS_COMPAT_TARGETS = LINUX_TARGETS | {"aarch64-macos"}
PLANNED_TARGETS = (
    "x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos",
    "x86_64-macos", "x86_64-windows", "aarch64-windows",
)


def row(target):
    return "\t".join(("owner/pkg", "0.4.0", target, "executable", "a" * 64,
                      f"https://github.com/stubbi/asm/releases/download/v0.4.0/{target}",
                      "64", "A target fixture")) + "\n"


class TargetIndexTests(unittest.TestCase):
    def test_linux_03_reader_can_parse_every_row_of_compatibility_feed(self):
        full = registry.HEADER + "".join(row(target) for target in PLANNED_TARGETS)
        compatible = registry.legacy_tsv(full)
        expected = registry.HEADER + "".join(row(target) for target in PLANNED_TARGETS
                                              if target in LINUX_TARGETS)
        self.assertEqual(compatible, expected)
        self.assertEqual({line.split("\t")[2] for line in compatible.splitlines()[1:]}, LINUX_TARGETS)

    def test_released_macos_reader_gets_only_its_four_known_targets(self):
        full = registry.HEADER + "".join(row(target) for target in PLANNED_TARGETS)
        compatible = registry.macos_compat_tsv(full)
        expected = registry.HEADER + "".join(row(target) for target in PLANNED_TARGETS
                                              if target in MACOS_COMPAT_TARGETS)
        self.assertEqual(compatible, expected)
        self.assertEqual({line.split("\t")[2] for line in compatible.splitlines()[1:]},
                         MACOS_COMPAT_TARGETS)

    def test_compatibility_feeds_keep_the_header_when_all_rows_are_new(self):
        full = registry.HEADER + row("x86_64-windows") + row("x86_64-macos")
        self.assertEqual(registry.legacy_tsv(full), registry.HEADER)
        self.assertEqual(registry.macos_compat_tsv(full), registry.HEADER)

    def test_published_01_through_05_feed_bytes_remain_unchanged(self):
        # Baselines captured before the feed split at catalog commit 4bcb109.
        identities = {(name, f"0.{minor}.0") for name in
                      ("stubbi/asm", "stubbi/hello", "stubbi/math") for minor in range(1, 6)}
        records = [record for record in registry.read_records(ROOT / "registry")
                   if (record["name"], record["version"]) in identities]
        self.assertEqual({(record["name"], record["version"]) for record in records}, identities)
        full, _ = registry.make_indexes(records)
        self.assertEqual(hashlib.sha256(registry.legacy_tsv(full).encode("ascii")).hexdigest(),
                         "3151cdab832982dec2f6059e18f462e34d2adfb74ade38bcf61fe8856dedccba")
        self.assertEqual(hashlib.sha256(registry.macos_compat_tsv(full).encode("ascii")).hexdigest(),
                         "456e94b0eea9ff04da63d1424e3639dfaa99215543653ac14fd7f7b4c33b8982")

    def test_registry_build_writes_full_and_compatible_feeds(self):
        full, _ = registry.make_indexes(registry.read_records(ROOT / "registry"))
        with tempfile.TemporaryDirectory(prefix="asm-target-feeds-") as temporary:
            output = Path(temporary) / "feeds"
            result = subprocess.run(
                [sys.executable, str(ROOT / "tools/registry.py"), "build", "--registry",
                 str(ROOT / "registry"), "--output", str(output)],
                capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((output / "index-all.tsv").is_file(), "The full native feed is missing")
            self.assertEqual((output / "index-all.tsv").read_bytes(), full.encode("ascii"))
            self.assertEqual((output / "index.tsv").read_bytes(),
                             registry.legacy_tsv(full).encode("ascii"))
            self.assertEqual((output / "index-macos.tsv").read_bytes(),
                             registry.macos_compat_tsv(full).encode("ascii"))

    def test_full_feed_keeps_4096_row_and_one_mib_limits(self):
        template = copy.deepcopy(registry.read_records(ROOT / "registry")[0])
        template["summary"] = "x"
        template["artifacts"] = [template["artifacts"][0]]
        records = []
        for number in range(4096):
            record = copy.deepcopy(template)
            record["version"] = f"1.0.{number}"
            record["artifacts"][0]["url"] = (
                f"https://github.com/a/b/releases/download/v{number}/a.tar.gz")
            records.append(record)
        full, _ = registry.make_indexes(records)
        self.assertEqual(len(full.splitlines()) - 1, 4096)
        self.assertLessEqual(len(full.encode("ascii")), 1048576)
        extra_target = "aarch64-linux" if records[0]["artifacts"][0]["target"] != "aarch64-linux" else "x86_64-linux"
        records[0]["artifacts"].append(dict(records[0]["artifacts"][0], target=extra_target,
            url="https://github.com/a/b/releases/download/v0/b.tar.gz"))
        with self.assertRaisesRegex(registry.RegistryError, "too many artifact rows"):
            registry.make_indexes(records)
        records[0]["artifacts"].pop()
        for number, record in enumerate(records):
            record["summary"] = "x" * 160
            record["artifacts"][0]["url"] = (
                "https://github.com/a/b/releases/download/" + f"v{number}-" + "a" * 120
                + "/" + "a" * 121 + ".tar.gz")
        with self.assertRaisesRegex(registry.RegistryError, "index exceeds one MiB"):
            registry.make_indexes(records)

    def test_catalog_format_support_does_not_widen_cli_hosts(self):
        commands = registry.strict_json((ROOT / "cli/commands.json").read_bytes())
        self.assertEqual(set(commands["hosts"]), {"x86_64-linux", "aarch64-linux", "aarch64-macos"})
        original = registry.read_records(ROOT / "registry")[0]
        for target in ("x86_64-windows", "aarch64-windows"):
            candidate = copy.deepcopy(original)
            candidate["artifacts"] = [dict(candidate["artifacts"][0], target=target)]
            with self.subTest(target=target):
                full, _ = registry.make_indexes([candidate])
                self.assertIn(target, full)
                self.assertEqual(registry.legacy_tsv(full), registry.HEADER)
                self.assertEqual(registry.macos_compat_tsv(full), registry.HEADER)
                self.assertNotIn(target, commands["hosts"])
        unsupported = copy.deepcopy(original)
        unsupported["artifacts"] = [dict(unsupported["artifacts"][0], target="x86_64-macos")]
        with self.assertRaisesRegex(registry.RegistryError, "unsupported artifact target"):
            registry.make_indexes([unsupported])
