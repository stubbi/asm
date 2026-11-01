"""Check bounded duplicate rejection without changing catalog output order."""

import json
import os
from pathlib import Path
import random
import resource
import signal
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ASM = ROOT / "build/asm"
HEADER = "# asm-registry-v1\n"
KEYS = ("package", "version", "target", "kind", "sha256", "url", "bytes", "summary")


def row(**changes):
    value = dict(package="owner/name", version="0.1.0", target="x86_64-linux",
                 kind="source", sha256="1" * 64,
                 url="https://github.com/stubbi/asm/releases/download/v0.1.0/source.tar.gz",
                 bytes=128, summary="A bounded registry record")
    value.update(changes)
    return value


class RegistryIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="registry-identity-", dir=ROOT / "build")
        self.work = Path(self.temp.name)
        self.index = self.work / "index.tsv"

    def tearDown(self):
        self.temp.cleanup()

    def search(self, records, *, valid=True):
        self.index.write_text(HEADER + "".join(
            "\t".join(str(record[key]) for key in KEYS) + "\n" for record in records))
        self.assertLessEqual(self.index.stat().st_size, 1048576)
        result = subprocess.run([str(ASM), "search", "--json", "--index", str(self.index)],
                                cwd=self.work, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0 if valid else 1, result.stderr)
        if valid:
            self.assertEqual(result.stderr, b"")
            self.assertEqual(json.loads(result.stdout), {"results": records})
            self.assertEqual(result.stdout, json.dumps({"results": records}, separators=(",", ":")).encode() + b"\n")
        else:
            self.assertEqual(result.stdout, b"", "An invalid index must produce no partial catalog")
            self.assertEqual(json.loads(result.stderr), {
                "ok": False, "error": "invalid registry index; expected the bounded asm-registry-v1 format"})

    def test_empty_single_and_two_row_boundaries(self):
        first, second = row(), row(package="owner/name-long")
        for records in ([], [first], [first, second], [second, first]):
            with self.subTest(records=records):
                self.search(records)
        self.search([first, first], valid=False)

    def test_every_identity_field_distinguishes_an_artifact(self):
        records = [row(), row(package="owner/name-long"), row(version="0.1.1"),
                   row(target="aarch64-linux"), row(kind="executable")]
        for seed in range(8):
            shuffled = records.copy()
            random.Random(seed).shuffle(shuffled)
            with self.subTest(seed=seed):
                self.search(shuffled)

    def test_nonidentity_fields_cannot_hide_a_duplicate(self):
        for changes in ({}, {"sha256": "2" * 64}, {"bytes": 129},
                        {"summary": "Different metadata"},
                        {"url": "https://github.com/stubbi/asm/releases/download/v0.1.0/other.tar.gz"}):
            with self.subTest(changes=changes):
                self.search([row(), row(package="owner/other"), row(**changes)], valid=False)

    def test_maximum_catalog_preserves_sorted_reversed_and_shuffled_order(self):
        records = [row(package=f"owner/name-{number:04d}") for number in range(4096)]
        shuffled = records.copy()
        random.Random(20261101).shuffle(shuffled)
        for name, ordered in (("sorted", records), ("reversed", records[::-1]), ("shuffled", shuffled)):
            with self.subTest(order=name):
                self.search(ordered)
        for position in (0, 2047, 4094):
            duplicate = shuffled.copy()
            duplicate[-1] = duplicate[position]
            with self.subTest(duplicate_position=position):
                self.search(duplicate, valid=False)

    def test_mixed_identity_permutations_follow_an_independent_set_oracle(self):
        generator = random.Random(740913)
        records = [row(package=f"owner/name-{number // 12:03d}",
                       version=f"1.{number % 12 // 6}.0",
                       target=("x86_64-linux", "aarch64-linux", "riscv64-linux")[number % 6 // 2],
                       kind=("source", "executable")[number % 2]) for number in range(192)]
        for case in range(16):
            values = generator.sample(records, generator.randrange(2, len(records)))
            if case % 2:
                values.insert(generator.randrange(len(values) + 1), generator.choice(values).copy())
            generator.shuffle(values)
            identities = [tuple(value[key] for key in KEYS[:4]) for value in values]
            with self.subTest(case=case):
                self.search(values, valid=len(identities) == len(set(identities)))

    def test_output_buffer_edges_preserve_exact_json_bytes(self):
        records = [row(version=f"1.0.{number}") for number in range(200)]
        length = len(json.dumps({"results": records}, separators=(",", ":")).encode()) + 1
        padding = 65536 - length
        self.assertGreater(padding, 0)
        for record in records:
            count = min(160 - len(record["summary"]), padding)
            record["summary"] += "x" * count
            padding -= count
        self.assertEqual(padding, 0)
        self.assertEqual(len(json.dumps({"results": records}, separators=(",", ":")).encode()) + 1, 65536)
        self.search(records)
        shortened = [value.copy() for value in records]
        shortened[0]["summary"] = shortened[0]["summary"][:-1]
        self.search(shortened)
        extended = [value.copy() for value in records]
        extended[-1]["summary"] += "x"
        self.assertLessEqual(len(extended[-1]["summary"]), 160)
        self.search(extended)

    def test_closed_output_exits_nonzero_and_preserves_the_index(self):
        self.search([row()])
        previous = self.index.read_bytes()
        result = subprocess.run([str(ASM), "search", "--json", "--index", str(self.index)],
                                cwd=self.work, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                preexec_fn=lambda: os.close(1), timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(json.loads(result.stderr), {
            "ok": False, "error": "cannot write registry output; check the output destination and try again"})
        self.assertEqual(self.index.read_bytes(), previous)

    def test_partial_output_then_file_limit_failure_is_nonzero(self):
        records = [row(version=f"1.0.{number}") for number in range(300)]
        self.search(records)
        previous = self.index.read_bytes()
        expected = json.dumps({"results": records}, separators=(",", ":")).encode() + b"\n"

        def limit_output():
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
            resource.setrlimit(resource.RLIMIT_FSIZE, (4096, 4096))

        output = self.work / "limited-output.json"
        with output.open("wb") as destination:
            result = subprocess.run([str(ASM), "search", "--json", "--index", str(self.index)],
                                    cwd=self.work, stdout=destination, stderr=subprocess.PIPE,
                                    preexec_fn=limit_output, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(output.read_bytes(), expected[:4096])
        self.assertEqual(json.loads(result.stderr), {
            "ok": False, "error": "cannot write registry output; check the output destination and try again"})
        self.assertEqual(self.index.read_bytes(), previous)
