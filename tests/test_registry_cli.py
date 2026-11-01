"""Exercise the assembly registry client with deterministic local fixtures."""

import hashlib
import json
import os
import random
from pathlib import Path
import stat
import struct
import subprocess
import tempfile
import unittest

from host import IS_MACOS, TARGET, OTHER_TARGET, ELF_MACHINE, VERSION

ROOT = Path(__file__).resolve().parents[1]
ASM = ROOT / "build/asm"
HEADER = "# asm-registry-v1\n"


class RegistryCliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="registry-cli-", dir=ROOT / "build")
        self.work = Path(self.temp.name)
        self.artifact = self.work / "local artifact"
        self.artifact.write_bytes(b"a deterministic artifact\n")
        self.digest = hashlib.sha256(self.artifact.read_bytes()).hexdigest()
        self.index = self.work / "index.tsv"

    def tearDown(self):
        self.temp.cleanup()

    def row(self, **changes):
        values = dict(
            package="stubbi/hello", version="0.1.0", target=TARGET, kind="source",
            sha256=self.digest,
            url="https://github.com/stubbi/asm/releases/download/v0.1.0/hello.tar.gz",
            size=str(self.artifact.stat().st_size), summary="A small assembly example",
        )
        values.update(changes)
        return "\t".join(values[key] for key in (
            "package", "version", "target", "kind", "sha256", "url", "size", "summary"
        )) + "\n"

    def write_index(self, *rows):
        self.index.write_text(HEADER + "".join(rows))

    def cli(self, *args, code=0, local_index=True):
        argv = [str(ASM), *map(str, args)]
        if local_index:
            argv += ["--index", str(self.index)]
        result = subprocess.run(argv, cwd=self.work, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, code, (argv, result.stdout, result.stderr))
        self.assertEqual(list(self.work.glob(".asm-registry-*")), [], "Temporary files remain")
        return result

    def test_search_info_versions_and_json_escaping(self):
        summary = 'The "quoted" example uses a \\ character'
        self.write_index(
            self.row(summary=summary),
            self.row(version="0.2.0"),
            self.row(version="0.2.0", target=OTHER_TARGET),
        )
        result = json.loads(self.cli("search", "quoted", "--json").stdout)
        self.assertEqual(len(result["results"]), 1)
        self.assertEqual(result["results"][0]["summary"], summary)
        self.assertEqual(result["results"][0]["bytes"], self.artifact.stat().st_size)
        result = json.loads(self.cli("info", "stubbi/hello", "--json").stdout)
        self.assertEqual(len(result["results"]), 3)
        result = json.loads(self.cli("versions", "stubbi/hello", "--json").stdout)
        self.assertEqual(result["versions"], ["0.1.0", "0.2.0"])
        self.assertEqual(self.cli("versions", "stubbi/hello").stdout, "0.1.0\n0.2.0\n")

    def test_empty_index_and_absent_package(self):
        self.write_index()
        self.assertEqual(json.loads(self.cli("search", "--json").stdout), {"results": []})
        self.assertEqual(self.cli("search").stdout, "No matching packages.\n")
        self.cli("info", "stubbi/missing", code=1)
        self.cli("versions", "stubbi/missing", code=1)
        self.cli("fetch", "stubbi/missing@0.1.0", "--artifact", self.artifact, code=1)

    def test_fetch_verifies_bytes_and_does_not_execute(self):
        self.write_index(self.row(kind="executable"))
        result = json.loads(self.cli(
            "fetch", "stubbi/hello@0.1.0", "--kind", "executable",
            "--artifact", self.artifact, "--json",
        ).stdout)
        output = self.work / result["artifact"]
        self.assertEqual(output.read_bytes(), self.artifact.read_bytes())
        self.assertTrue(result["verified"])
        self.assertEqual(output.stat().st_mode & 0o111, 0)

    def test_fetch_resolves_numeric_latest_and_respects_target(self):
        self.write_index(
            self.row(version="2.10.0"), self.row(version="2.9.9"),
            self.row(version="3.0.0", target=OTHER_TARGET),
        )
        result = json.loads(self.cli("fetch", "stubbi/hello", "--artifact", self.artifact, "--json").stdout)
        self.assertEqual(result["version"], "2.10.0")
        result = json.loads(self.cli(
            "fetch", "stubbi/hello", "--target", OTHER_TARGET,
            "--artifact", self.artifact, "--json",
        ).stdout)
        self.assertEqual(result["version"], "3.0.0")
        self.cli("fetch", "stubbi/hello", "--target", "riscv64-linux", "--artifact", self.artifact, code=1)

    def test_fetch_refuses_existing_file_and_symlink(self):
        self.write_index(self.row())
        destination = self.work / "keep me"
        destination.write_bytes(b"keep")
        self.cli("fetch", "stubbi/hello", "--artifact", self.artifact, "--output", destination, code=1)
        self.assertEqual(destination.read_bytes(), b"keep")
        link = self.work / "linked-output"
        link.symlink_to(destination)
        self.cli("fetch", "stubbi/hello", "--artifact", self.artifact, "--output", link, code=1)
        self.assertTrue(link.is_symlink())
        self.assertEqual(destination.read_bytes(), b"keep")

    def test_output_names_are_literal_and_json_is_escaped(self):
        self.write_index(self.row())
        destination = 'artifact "quoted"; touch INJECTION\nnext'
        result = json.loads(self.cli(
            "fetch", "stubbi/hello", "--artifact", self.artifact, "--output", destination, "--json"
        ).stdout)
        self.assertEqual(result["artifact"], destination)
        self.assertEqual((self.work / destination).read_bytes(), self.artifact.read_bytes())
        self.assertFalse((self.work / "INJECTION").exists())

    def test_corrupt_digest_and_size_leave_no_output(self):
        for changes in ({"sha256": "0" * 64}, {"size": "1"}):
            with self.subTest(changes=changes):
                self.write_index(self.row(**changes))
                result = self.cli("fetch", "stubbi/hello", "--artifact", self.artifact, code=1)
                self.assertIn("verification failed", result.stderr)
                self.assertFalse((self.work / f"stubbi-hello-0.1.0-{TARGET}.tar.gz").exists())

    def test_local_artifact_symlink_is_rejected(self):
        self.write_index(self.row())
        link = self.work / "artifact-link"
        link.symlink_to(self.artifact)
        self.cli("fetch", "stubbi/hello", "--artifact", link, code=1)

    def test_native_install_checks_host_elf_and_does_not_run_it(self):
        self.artifact.write_bytes(ASM.read_bytes())
        self.digest = hashlib.sha256(self.artifact.read_bytes()).hexdigest()
        self.write_index(self.row(kind="executable"))
        destination = self.work / "installed asm"
        result = json.loads(self.cli(
            "install", "stubbi/hello@0.1.0", "--artifact", self.artifact,
            "--output", destination, "--json",
        ).stdout)
        self.assertTrue(result["verified"])
        self.assertEqual(destination.read_bytes(), self.artifact.read_bytes())
        self.assertEqual(destination.stat().st_mode & 0o777, 0o755)
        # This explicit test invocation, separate from installation, checks the result.
        version = subprocess.run([str(destination), "--version"], capture_output=True, text=True, check=True)
        self.assertIn(f"asm {VERSION}", version.stdout)
        self.cli("install", "stubbi/hello", "--artifact", self.artifact, "--output", destination, code=1)

    def test_install_rejects_wrong_target_and_malformed_elf(self):
        original = ASM.read_bytes()
        bad = []
        if IS_MACOS:
            mutations = [(0, "I", 0x464c457f), (4, "I", 0x1000007), (12, "I", 1),
                         (16, "I", 129), (20, "I", 0xffffffff), (28, "I", 1), (36, "I", 4)]
        else:
            program_offset = struct.unpack_from("<Q", original, 32)[0]
            mutations = [
                (4, "B", 1), (5, "B", 2), (18, "H", 62 if ELF_MACHINE == 183 else 183), (56, "H", 65535),
                (32, "Q", len(original) + 1), (54, "H", 55), (24, "Q", 1),
                (program_offset + 4, "I", 7),
                (program_offset + 32, "Q", 2**64 - 1),
            ]
        for offset, format_, value in mutations:
            data = bytearray(original)
            struct.pack_into("<" + format_, data, offset, value)
            bad.append(bytes(data))
        bad.append(b"#!/bin/sh\necho must-not-run\n")
        for data in bad:
            with self.subTest(prefix=data[:24]):
                self.artifact.write_bytes(data)
                self.digest = hashlib.sha256(data).hexdigest()
                self.write_index(self.row(kind="executable"))
                self.cli("install", "stubbi/hello", "--artifact", self.artifact, "--output", "rejected", code=1)
                self.assertFalse((self.work / "rejected").exists())
        self.write_index(self.row(kind="executable", target=OTHER_TARGET))
        self.cli("install", "stubbi/hello", "--target", OTHER_TARGET, "--output", "rejected", code=2)

    def test_fifo_inputs_fail_without_blocking(self):
        self.write_index(self.row())
        fifo = self.work / "fifo"
        os.mkfifo(fifo)
        self.cli("fetch", "stubbi/hello", "--artifact", fifo, code=1)
        self.index.unlink()
        os.mkfifo(self.index)
        self.cli("search", code=1)

    def test_index_structure_is_strict(self):
        malformed = [
            "", "# asm-registry-v2\n", HEADER.rstrip("\n"), HEADER + "\n",
            HEADER + self.row().rstrip("\n"), HEADER + self.row().replace("\n", "\r\n"),
            HEADER + self.row().replace("example", "example\x00hidden"),
            HEADER + self.row().replace("example", "example\x1b"),
            HEADER + self.row().replace("example", "example\ttail"),
            HEADER + self.row() + self.row(),
            HEADER + "x" * 1048576,
        ]
        for content in malformed:
            with self.subTest(length=len(content), prefix=content[:40]):
                self.index.write_bytes(content.encode())
                result = self.cli("search", "--json", code=1)
                self.assertEqual(result.stdout, "", "Do not print records from an invalid index")
                self.assertFalse(json.loads(result.stderr)["ok"])

    def test_index_fields_are_strict(self):
        mutations = [
            {"package": "hello"}, {"package": "Owner/hello"}, {"package": "owner/name-"},
            {"package": "owner-/name"}, {"package": "owner/a--b"},
            {"package": "owner/../../file"}, {"package": "a" * 40 + "/name"},
            {"package": "owner/" + "a" * 65}, {"version": "01.0.0"},
            {"version": "1.0"}, {"version": "1.0.0-beta"}, {"version": "2147483648.0.0"},
            {"target": "x86_64-windows"}, {"kind": "script"},
            {"sha256": "A" * 64}, {"sha256": "0" * 63}, {"sha256": "g" * 64},
            {"size": "0"}, {"size": "01"}, {"size": "67108865"}, {"size": "-1"},
            {"summary": ""}, {"summary": "a" * 161}, {"summary": "non-ASCII é"},
            {"summary": " leading"}, {"summary": "trailing "},
            {"url": "http://github.com/stubbi/asm/releases/download/v1/a"},
            {"url": "https://github.com.evil.test/stubbi/asm/releases/download/v1/a"},
            {"url": "https://evil.test/stubbi/asm/releases/download/v1/a"},
            {"url": "https://github.com/user@host/asm/releases/download/v1/a"},
            {"url": "https://github.com/stubbi/asm/archive/v1/a"},
            {"url": "https://github.com/stubbi/asm/releases/download/../a"},
            {"url": "https://github.com/stubbi/asm/releases/download/v1/a?query"},
            {"url": "https://github.com/stubbi/asm/releases/download/v1/%2e%2e"},
            {"url": "https://github.com/stubbi/asm/releases/download/v1/a#fragment"},
            {"url": "https://github.com/stubbi/asm/releases/download/v1/a/extra"},
            {"url": "https://github.com/stubbi/asm.git/releases/download/v1/a.tar.gz"},
            {"url": "https://github.com/stubbi/asm/releases/download/v1/a+b.tar.gz"},
            {"url": "https://github.com/stubbi/asm/releases/download/-v1/a.tar.gz"},
            {"url": "https://github.com/stubbi/asm/releases/download/v1/a.bin"},
        ]
        for changes in mutations:
            with self.subTest(changes=changes):
                self.write_index(self.row(**changes))
                self.cli("search", code=1)

    def test_row_limit_and_index_symlink(self):
        self.write_index(*(self.row(version=f"1.0.{number}") for number in range(4097)))
        self.cli("search", code=1)
        actual = self.work / "actual.tsv"
        self.index.rename(actual)
        self.index.symlink_to(actual)
        self.cli("search", code=1)

    def test_bad_arguments_fail_before_network_access(self):
        self.write_index(self.row())
        for args in [
            ("info",), ("fetch", "name"), ("fetch", "stubbi/hello@01.0.0"),
            ("fetch", "stubbi/hello@1.0.0@2.0.0"), ("search", "one", "two"),
            ("fetch", "stubbi/hello", "--target", "unknown"),
            ("fetch", "stubbi/hello", "--kind", "unknown"),
            ("search", "--output", "file"), ("search", "--artifact", "file"),
            ("fetch", "stubbi/hello", "--output", ""),
        ]:
            with self.subTest(args=args):
                self.cli(*args, code=2)
        self.cli("search", "--registry", "http://example.test/index", code=2, local_index=False)

    def test_https_network_failure_is_nonzero_and_cleans_workspace(self):
        # A closed local port gives a bounded transport failure without external traffic.
        self.cli("search", "--registry", "https://127.0.0.1:9/index.tsv", code=1, local_index=False)

    def test_deterministic_parser_corpus_has_bounded_failures(self):
        generator = random.Random(20261031)
        valid = (HEADER + self.row()).encode()
        corpus = [b"", valid, valid[:1], valid[:-1], b"\x00" * 2048]
        corpus += [generator.randbytes(generator.randrange(0, 3073)) for _ in range(60)]
        for _ in range(60):
            data = bytearray(valid)
            for _ in range(generator.randrange(1, 5)):
                data[generator.randrange(len(data))] = generator.randrange(256)
            corpus.append(bytes(data))
        for number, data in enumerate(corpus):
            with self.subTest(case=number, length=len(data)):
                self.index.write_bytes(data)
                result = subprocess.run(
                    [str(ASM), "search", "--index", str(self.index), "--json"],
                    cwd=self.work, capture_output=True, timeout=4,
                )
                self.assertIn(result.returncode, (0, 1), (number, result.stderr))
                if result.returncode == 0:
                    self.assertIn("results", json.loads(result.stdout))
                else:
                    self.assertEqual(result.stdout, b"")
                    self.assertFalse(json.loads(result.stderr)["ok"])


if __name__ == "__main__":
    unittest.main()
