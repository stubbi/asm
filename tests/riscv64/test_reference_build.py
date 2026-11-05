"""Test bounded diagnostic builds with tiny archives and a fake compiler.

SPDX-License-Identifier: AGPL-3.0-or-later
No RISC-V code, package, Docker image, or network operation is executed.
"""
from contextlib import contextmanager
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
MHD_MEMBER = "libmicrohttpd-1.0.3/src/include/microhttpd.h"
MHD_HEADER = b"/* MHD header copied verbatim */\n"
HEADERS = {"opt/asm/postgres/include/libpq-fe.h": b'#include "postgres_ext.h"\n',
    "opt/asm/postgres/include/postgres_ext.h": b'#include "pg_config_ext.h"\n',
    "opt/asm/postgres/include/pg_config_ext.h": b"/* PG header */\n"}


def elf(machine=243, flags=5, *, stack=6, load=5, kind=3):
    data = bytearray(176)
    data[:16] = b"\x7fELF\x02\x01\x01" + bytes(9)
    struct.pack_into("<HHIQQQIHHHHHH", data, 16, kind, machine, 1, 0, 64, 0, flags, 64, 56, 2, 64, 0, 0)
    struct.pack_into("<IIQQQQQQ", data, 64, 1, load, 0, 0, 0, len(data), len(data), 4096)
    struct.pack_into("<IIQQQQQQ", data, 120, 0x6474e551, stack, 0, 0, 0, 0, 0, 16)
    return bytes(data)


def layer(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as packed:
        for name, data, *kind in entries:
            entry = tarfile.TarInfo(name)
            if kind:
                entry.type, entry.linkname = kind[0], "elsewhere"
            else:
                entry.size = len(data)
            packed.addfile(entry, io.BytesIO(data) if entry.isfile() else None)
    return output.getvalue()


def mhd_archive(path, entries=None):
    data = gzip.compress(layer([(MHD_MEMBER, MHD_HEADER)] if entries is None else entries), mtime=0)
    path.write_bytes(data)
    return hashlib.sha256(data).hexdigest()


def mhd_pins(path, sha=None):
    return {"archive_bytes": path.stat().st_size,
        "archive_sha": hashlib.sha256(path.read_bytes()).hexdigest() if sha is None else sha,
        "header_bytes": len(MHD_HEADER), "header_sha": hashlib.sha256(MHD_HEADER).hexdigest()}


def image(path, layers, architecture="riscv64"):
    hashes = [hashlib.sha256(data).hexdigest() for data in layers]
    config = {"architecture": architecture, "os": "linux", "config": {"Env": []},
              "rootfs": {"type": "layers", "diff_ids": ["sha256:" + value for value in hashes]}}
    raw = json.dumps(config, separators=(",", ":")).encode()
    identity = hashlib.sha256(raw).hexdigest()
    names = ["blobs/sha256/" + value for value in hashes]
    manifest = json.dumps([{"Config": "blobs/sha256/" + identity, "Layers": names}]).encode()
    with tarfile.open(path, "w", format=tarfile.USTAR_FORMAT) as packed:
        for name, data in [("manifest.json", manifest), ("blobs/sha256/" + identity, raw), *zip(names, layers)]:
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            packed.addfile(entry, io.BytesIO(data))
    return {"archive_bytes": path.stat().st_size, "archive_sha": hashlib.sha256(path.read_bytes()).hexdigest(),
            "image_id": "sha256:" + identity}


COMPILER = r'''#!/usr/bin/python3
import json,os,struct,sys,time
from pathlib import Path
base=Path(__file__).parent
config=json.loads((base/'fixture.json').read_text())
with (base/'calls.jsonl').open('a') as log:log.write(json.dumps({'args':sys.argv[1:],'env':dict(os.environ)})+'\n')
time.sleep(config.get('delay',0))
args=sys.argv[1:]
if '--version' in args:print('fixture GCC 13.3.0');sys.exit(0)
if '-dumpfullversion' in args:print('13.3.0');sys.exit(0)
if '-dumpmachine' in args:print(config.get('target','riscv64-linux-gnu'));sys.exit(0)
if args and args[0].startswith('-print-prog-name='):print(__file__);sys.exit(0)
if args and args[0]=='-A':print('Tag_RISCV_arch: "rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_zicsr2p0_zifencei2p0"');sys.exit(0)
if '-o' not in args:sys.exit(91)
out=Path(args[args.index('-o')+1]);out.write_bytes(b'partial')
if config.get('failure'):print('fixture compile failed');sys.exit(7)
if config.get('flood'):print('x'*(1024*1024+1));sys.exit(8)
data=bytearray(176);data[:16]=b'\x7fELF\x02\x01\x01'+bytes(9)
struct.pack_into('<HHIQQQIHHHHHH',data,16,3,62 if config.get('wrong_elf') else 243,1,0,64,0,5,64,56,2,64,0,0)
struct.pack_into('<IIQQQQQQ',data,64,1,5,0,0,0,176,176,4096)
struct.pack_into('<IIQQQQQQ',data,120,0x6474e551,6,0,0,0,0,0,16)
out.write_bytes(data)
'''


class ReferenceBuildTests(unittest.TestCase):
    def setUp(self):
        path = ROOT / "tools/riscv64_reference_build.py"
        self.assertTrue(path.is_file(), "The bounded diagnostic build module is absent")
        spec = importlib.util.spec_from_file_location("reference_build", path)
        self.build = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.build)

    def test_extracts_only_selected_bytes_and_records_their_origin(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            archive = base / "image.tar"
            pins = image(archive, [layer([*HEADERS.items(), ("unneeded", b"not selected")])])
            output = base / "include"
            result = self.build.extract_headers(archive, output, **pins)
            self.assertEqual(set(result), {Path(name).name for name in HEADERS})
            self.assertEqual(set(p.name for p in output.iterdir()), set(result))
            for name, data in HEADERS.items():
                entry = result[Path(name).name]
                self.assertEqual((output / Path(name).name).read_bytes(), data)
                self.assertEqual(entry["sha256"], hashlib.sha256(data).hexdigest())
                self.assertEqual(entry["bytes"], len(data))
                self.assertEqual(entry["image_path"], name)

    def test_source_header_is_verbatim_and_separately_bound_from_image_headers(self):
        self.assertTrue(hasattr(self.build, "extract_mhd_header"), "The pinned source-header extractor is absent")
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "source.tar.gz"
            sha = mhd_archive(source, [("libmicrohttpd-1.0.3/unneeded", b"ignored"), (MHD_MEMBER, MHD_HEADER)])
            output = base / "microhttpd.h"
            result = self.build.extract_mhd_header(source, output, **mhd_pins(source, sha))
            self.assertEqual(output.read_bytes(), MHD_HEADER)
            self.assertEqual(set(base.iterdir()), {source, output})
            self.assertEqual(result, {"source_url": "https://ftp.gnu.org/gnu/libmicrohttpd/libmicrohttpd-1.0.3.tar.gz",
                "archive_sha256": sha, "archive_bytes": source.stat().st_size, "archive_member": MHD_MEMBER,
                "bytes": len(MHD_HEADER), "sha256": hashlib.sha256(MHD_HEADER).hexdigest()})

    def test_source_archive_bad_identity_missing_member_and_truncation_never_publish(self):
        self.assertTrue(hasattr(self.build, "extract_mhd_header"), "The pinned source-header extractor is absent")
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "source.tar.gz"
            sha = mhd_archive(source)
            with self.assertRaises(ValueError):
                self.build.extract_mhd_header(source, base / "microhttpd.h", **mhd_pins(source, "0" * 64))
            self.assertFalse((base / "microhttpd.h").exists())
            sha = mhd_archive(source, [("libmicrohttpd-1.0.3/other.h", b"unrelated")])
            with self.assertRaises(ValueError):
                self.build.extract_mhd_header(source, base / "microhttpd.h", **mhd_pins(source, sha))
            sha = mhd_archive(source)
            for changed in ({**mhd_pins(source), "archive_bytes": source.stat().st_size + 1},
                    {**mhd_pins(source), "header_sha": "0" * 64},
                    {**mhd_pins(source), "header_bytes": len(MHD_HEADER) + 1}):
                with self.subTest(changed=changed), self.assertRaises(ValueError):
                    self.build.extract_mhd_header(source, base / "microhttpd.h", **changed)
                self.assertFalse((base / "microhttpd.h").exists())
            # Production defaults must reject this unpinned synthetic archive.
            with self.assertRaises(ValueError):
                self.build.extract_mhd_header(source, base / "microhttpd.h")
            source.write_bytes(source.read_bytes()[:-4])
            with self.assertRaises(ValueError):
                self.build.extract_mhd_header(source, base / "microhttpd.h",
                    **mhd_pins(source))
            self.assertFalse((base / "microhttpd.h").exists())
            source.write_bytes(bytes.fromhex("1f8b0800000000000003") + b"\x07" + bytes(8))
            with self.assertRaises(ValueError):
                self.build.extract_mhd_header(source, base / "microhttpd.h", **mhd_pins(source))
            self.assertFalse((base / "microhttpd.h").exists())

    def test_source_archive_ambiguous_paths_links_and_whiteouts_never_publish(self):
        self.assertTrue(hasattr(self.build, "extract_mhd_header"), "The pinned source-header extractor is absent")
        cases = [[(MHD_MEMBER, MHD_HEADER), (MHD_MEMBER, b"duplicate")],
            [(MHD_MEMBER, b"", tarfile.SYMTYPE)], [(MHD_MEMBER, b"", tarfile.LNKTYPE)],
            [("libmicrohttpd-1.0.3/src/include", b"", tarfile.SYMTYPE), (MHD_MEMBER, MHD_HEADER)],
            [("libmicrohttpd-1.0.3/src/include/.wh.microhttpd.h", b""), (MHD_MEMBER, MHD_HEADER)],
            [("libmicrohttpd-1.0.3/.wh.src", b""), (MHD_MEMBER, MHD_HEADER)],
            [("libmicrohttpd-1.0.3/src/include/.wh..wh..opq", b""), (MHD_MEMBER, MHD_HEADER)],
            [("../outside", b"x"), (MHD_MEMBER, MHD_HEADER)],
            [("/outside", b"x"), (MHD_MEMBER, MHD_HEADER)]]
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "source.tar.gz"
            for index, entries in enumerate(cases):
                sha = mhd_archive(source, entries)
                with self.subTest(index=index), self.assertRaises(ValueError):
                    self.build.extract_mhd_header(source, base / "microhttpd.h", **mhd_pins(source, sha))
                self.assertFalse((base / "microhttpd.h").exists())
                self.assertFalse((base / "outside").exists())

    def test_source_archive_resource_bounds_and_existing_file_are_preserved(self):
        self.assertTrue(hasattr(self.build, "extract_mhd_header"), "The pinned source-header extractor is absent")
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "source.tar.gz"
            sha = mhd_archive(source, [(MHD_MEMBER, b"x" * (512 * 1024 + 1))])
            with self.assertRaises(ValueError):
                self.build.extract_mhd_header(source, base / "microhttpd.h", **mhd_pins(source, sha))
            sha = mhd_archive(source)
            for setting, value in (("MHD_EXPANDED_BYTES", 1024), ("MHD_ENTRIES", 0)):
                with self.subTest(setting=setting), mock.patch.object(self.build, setting, value), self.assertRaises(ValueError):
                    self.build.extract_mhd_header(source, base / "microhttpd.h", **mhd_pins(source, sha))
            with source.open("r+b") as stream:
                stream.truncate(8 * 1024 * 1024 + 1)
            with self.assertRaises(ValueError):
                self.build.extract_mhd_header(source, base / "microhttpd.h", **mhd_pins(source, sha))
            self.assertFalse((base / "microhttpd.h").exists())
            sha = mhd_archive(source)
            output = base / "microhttpd.h"
            output.write_bytes(b"prior header")
            with self.assertRaises(ValueError):
                self.build.extract_mhd_header(source, output, **mhd_pins(source, sha))
            self.assertEqual(output.read_bytes(), b"prior header")
            output.unlink()
            output.symlink_to(source)
            with self.assertRaises(ValueError):
                self.build.extract_mhd_header(source, output, **mhd_pins(source, sha))
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), sha)

    def test_missing_or_unpinned_mhd_input_fails_before_any_compiler_call(self):
        for kind in ("absent", "bad-hash", "missing-file"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                context, compiler, archive, pins = self.fixture(Path(temporary))
                source = None if kind == "absent" else pins["mhd_source"]
                if kind == "bad-hash":
                    source.write_bytes(b"not the pinned source")
                elif kind == "missing-file":
                    source.unlink()
                with self.pinned(pins), self.assertRaises(ValueError):
                    self.build.prepare_trace(archive, context, compiler, mhd_source=source)
                report = json.loads((context / "trace-build-failure.json").read_text())
                self.assertEqual(report["stage"], "mhd-source")
                self.assertFalse((compiler.parent / "calls.jsonl").exists())
                self.assertFalse((context / "trace").exists())

    def test_archive_identity_and_platform_fail_before_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            archive = base / "image.tar"
            pins = image(archive, [layer(HEADERS.items())])
            for changed in ({**pins, "archive_sha": "0" * 64}, {**pins, "archive_bytes": 1}):
                with self.assertRaises(ValueError):
                    self.build.extract_headers(archive, base / "include", **changed)
                self.assertFalse((base / "include").exists())
            pins = image(archive, [layer(HEADERS.items())], architecture="amd64")
            with self.assertRaises(ValueError):
                self.build.extract_headers(archive, base / "include", **pins)
            self.assertFalse((base / "include").exists())

    def test_unsafe_or_ambiguous_layers_never_publish_headers(self):
        first = next(iter(HEADERS))
        layers = [[layer([("../outside", b"x"), *HEADERS.items()])],
            [layer([("/outside", b"x"), *HEADERS.items()])],
            [layer([(first, b"", tarfile.SYMTYPE), *list(HEADERS.items())[1:]])],
            [layer([(first, b"", tarfile.LNKTYPE), *list(HEADERS.items())[1:]])],
            [layer([("opt/asm/postgres/include", b"", tarfile.SYMTYPE), *HEADERS.items()])],
            [layer([*HEADERS.items(), (first, b"duplicate")])],
            [layer(HEADERS.items()), layer([(first, HEADERS[first])])],
            [layer(HEADERS.items()), layer([("opt/asm/postgres/include/.wh.libpq-fe.h", b"")])],
            [layer(HEADERS.items()), layer([("opt/asm/postgres/.wh.include", b"")])],
            [layer(HEADERS.items()), layer([("opt/asm/postgres/include/.wh..wh..opq", b"")])]]
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            for index, values in enumerate(layers):
                archive = base / f"image-{index}.tar"
                pins = image(archive, values)
                with self.subTest(index=index), self.assertRaises(ValueError):
                    self.build.extract_headers(archive, base / f"out-{index}", **pins)
                self.assertFalse((base / f"out-{index}").exists())

    def test_missing_and_large_headers_preserve_an_existing_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            archive = base / "image.tar"
            for entries in (list(HEADERS.items())[1:], [(n, b"x" * (512 * 1024 + 1) if i == 0 else v)
                                                      for i, (n, v) in enumerate(HEADERS.items())]):
                pins = image(archive, [layer(entries)])
                with self.assertRaises(ValueError):
                    self.build.extract_headers(archive, base / "missing", **pins)
                self.assertFalse((base / "missing").exists())
            output = base / "include"
            output.mkdir()
            (output / "prior").write_text("prior")
            with self.assertRaises(ValueError):
                self.build.extract_headers(archive, output, **pins)
            self.assertEqual(list(output.iterdir()), [output / "prior"])
            self.assertEqual((output / "prior").read_text(), "prior")

    def fixture(self, base, **settings):
        context = base / "context"
        (context / "runner/tools/diagnostics").mkdir(parents=True)
        (context / "runner/tests/riscv64").mkdir(parents=True)
        (context / "runner/tools/diagnostics/reference_libpq_trace.c").write_text("/* selected source */\n")
        (context / "runner/tests/riscv64/test_reference_trace.py").write_text("PROVIDER='/* p */'\nDRIVER='/* d */'\n")
        tools = base / "toolchain"
        tools.mkdir()
        for name in ("riscv64-linux-gnu-gcc", "riscv64-linux-gnu-readelf"):
            path = tools / name
            # Apple's /usr/bin/python3 launcher adds SDK compiler variables.
            # Use this test process's interpreter to observe the passed env.
            path.write_text(COMPILER.replace("#!/usr/bin/python3", "#!" + sys.executable, 1))
            path.chmod(0o755)
        (tools / "fixture.json").write_text(json.dumps(settings))
        archive = base / "image.tar"
        pins = image(archive, [layer(HEADERS.items())])
        pins["mhd_source"] = base / "mhd.tar.gz"
        pins["mhd_sha"] = mhd_archive(pins["mhd_source"])
        return context, tools / "riscv64-linux-gnu-gcc", archive, pins

    @contextmanager
    def pinned(self, pins):
        with mock.patch.multiple(self.build.observations, IMAGE_TAR_BYTES=pins["archive_bytes"],
                IMAGE_TAR_SHA=pins["archive_sha"], IMAGE_ID=pins["image_id"]), \
                mock.patch.multiple(self.build, MHD_SOURCE_SHA=pins["mhd_sha"],
                    MHD_SOURCE_BYTES=pins["mhd_source"].stat().st_size if pins["mhd_source"].exists() else 1,
                    MHD_HEADER_BYTES=len(MHD_HEADER), MHD_HEADER_SHA=hashlib.sha256(MHD_HEADER).hexdigest()):
            yield

    def test_fake_build_records_private_environment_and_fixed_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            context, compiler, archive, pins = self.fixture(Path(temporary))
            with self.pinned(pins), mock.patch.dict(os.environ, {"GITHUB_TOKEN": "private", "CPATH": "private", "GCC_EXEC_PREFIX": "private"}):
                result = self.build.prepare_trace(archive, context, compiler, mhd_source=pins["mhd_source"])
            names = {"reference_libpq_trace.so", "libreference_provider.so", "reference_trace_check"}
            self.assertEqual(result["qualification"], "UNQUALIFIED")
            self.assertEqual(result["scope"], "asm-reference-trace-build")
            self.assertEqual(result["outcome"], "pass")
            self.assertEqual(set(result["outputs"]), names)
            self.assertEqual(result, json.loads((context / "trace/manifest.json").read_text()))
            for name, entry in result["outputs"].items():
                self.assertEqual(set(entry), {"bytes", "sha256", "elf_machine", "elf_type", "elf_flags", "nx_stack", "no_rwx"})
                path = context / "trace" / name
                self.assertEqual(entry["bytes"], path.stat().st_size)
                self.assertEqual(entry["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
                self.assertEqual(entry["elf_machine"], 243)
                self.assertTrue(entry["nx_stack"] and entry["no_rwx"])
            calls = [json.loads(line) for line in (compiler.parent / "calls.jsonl").read_text().splitlines()]
            for call in calls:
                self.assertTrue({"GITHUB_TOKEN", "CPATH", "GCC_EXEC_PREFIX"}.isdisjoint(call["env"]))
            compiled = [call["args"] for call in calls if "-o" in call["args"]]
            self.assertEqual(len(compiled), 3)
            self.assertTrue(all("-march=rv64gc" in args and "-mabi=lp64d" in args for args in compiled))
            self.assertIn("-Wl,-soname,libreference_provider.so", compiled[1])
            self.assertIn("-Wl,-rpath,/inputs/trace", compiled[2])
            self.assertEqual(result["target_execution"], "not-run")
            self.assertEqual(set(result["headers"]), {"microhttpd.h", "libpq-fe.h", "postgres_ext.h", "pg_config_ext.h"})
            self.assertEqual(result["headers"]["microhttpd.h"]["archive_sha256"], pins["mhd_sha"])
            self.assertNotIn("image_path", result["headers"]["microhttpd.h"])
            self.assertTrue(all("image_path" in result["headers"][name] for name in ("libpq-fe.h", "postgres_ext.h", "pg_config_ext.h")))
            self.assertEqual((context / "trace/include/microhttpd.h").read_bytes(), MHD_HEADER)

    def test_failure_logs_are_bounded_and_prior_failure_evidence_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            context, compiler, archive, pins = self.fixture(Path(temporary), flood=True)
            with self.pinned(pins), self.assertRaises(ValueError):
                self.build.prepare_trace(archive, context, compiler, mhd_source=pins["mhd_source"])
            log = context / "trace-build-failure.log"
            metadata = context / "trace-build-failure.json"
            self.assertLessEqual(log.stat().st_size, 1024 * 1024)
            self.assertEqual(json.loads(metadata.read_text())["last_failure"], "byte-limit")
            original = metadata.read_bytes(), log.read_bytes()
            with self.pinned(pins), self.assertRaises(ValueError):
                self.build.prepare_trace(archive, context, compiler, mhd_source=pins["mhd_source"])
            self.assertEqual((metadata.read_bytes(), log.read_bytes()), original)
            self.assertFalse((context / "trace").exists())

    def test_compile_wrong_target_and_wrong_elf_fail_without_partial_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            for index, settings in enumerate(({"failure": True}, {"wrong_elf": True}, {"target": "x86_64-linux-gnu"})):
                case = base / str(index)
                case.mkdir()
                context, compiler, archive, pins = self.fixture(case, **settings)
                with self.pinned(pins), self.assertRaises(ValueError):
                    self.build.prepare_trace(archive, context, compiler, mhd_source=pins["mhd_source"])
                self.assertFalse((context / "trace").exists())
                failure = context / "trace-build-failure.json"
                self.assertTrue(failure.is_file())
                self.assertEqual(json.loads(failure.read_text())["outcome"], "fail")
                self.assertLessEqual((context / "trace-build-failure.log").stat().st_size, 1024 * 1024)
                self.assertFalse(any(context.glob(".asm-reference-build-*")))

    def test_source_constants_are_not_executed_and_malformed_sources_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            context, compiler, archive, pins = self.fixture(base)
            marker = base / "do-not-create"
            source = context / "runner/tests/riscv64/test_reference_trace.py"
            source.write_text(f"from pathlib import Path\nPath({str(marker)!r}).touch()\nPROVIDER='p'\nDRIVER='d'\n")
            with self.pinned(pins):
                self.build.prepare_trace(archive, context, compiler, mhd_source=pins["mhd_source"])
            self.assertFalse(marker.exists())
        for content in ("PROVIDER='p'\nPROVIDER='q'\nDRIVER='d'\n", "PROVIDER=str('p')\nDRIVER='d'\n"):
            with tempfile.TemporaryDirectory() as temporary:
                context, compiler, archive, pins = self.fixture(Path(temporary))
                (context / "runner/tests/riscv64/test_reference_trace.py").write_text(content)
                with self.pinned(pins), self.assertRaises(ValueError):
                    self.build.prepare_trace(archive, context, compiler, mhd_source=pins["mhd_source"])
                self.assertFalse((context / "trace").exists())

    def test_source_symlink_and_existing_trace_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            context, compiler, archive, pins = self.fixture(base)
            output = context / "trace"
            output.mkdir()
            (output / "prior").write_text("prior")
            with self.pinned(pins), self.assertRaises(ValueError):
                self.build.prepare_trace(archive, context, compiler, mhd_source=pins["mhd_source"])
            self.assertEqual((output / "prior").read_text(), "prior")
            self.assertFalse((compiler.parent / "calls.jsonl").exists())
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            context, compiler, archive, pins = self.fixture(base)
            source = context / "runner/tools/diagnostics/reference_libpq_trace.c"
            source.unlink()
            (base / "external.c").write_text("external")
            source.symlink_to(base / "external.c")
            with self.pinned(pins), self.assertRaises(ValueError):
                self.build.prepare_trace(archive, context, compiler, mhd_source=pins["mhd_source"])
            self.assertFalse((context / "trace").exists())

    def test_source_header_inspection_uses_the_shared_build_deadline(self):
        with tempfile.TemporaryDirectory() as temporary:
            context, compiler, archive, pins = self.fixture(Path(temporary))
            original_extract = self.build.extract_mhd_header
            original_clock = time.monotonic
            offset = [0]

            def delayed_extract(*args, **kwargs):
                result = original_extract(*args, **kwargs)
                offset[0] = 121
                return result

            with self.pinned(pins), mock.patch.object(self.build, "extract_mhd_header", delayed_extract), \
                    mock.patch.object(time, "monotonic", lambda: original_clock() + offset[0]):
                with self.assertRaises(ValueError):
                    self.build.prepare_trace(archive, context, compiler, mhd_source=pins["mhd_source"])
            self.assertFalse((context / "trace").exists())
            self.assertFalse((compiler.parent / "calls.jsonl").exists())
            self.assertEqual(json.loads((context / "trace-build-failure.json").read_text())["stage"], "mhd-source")

    def test_shared_deadline_does_not_restart_for_each_tool(self):
        with tempfile.TemporaryDirectory() as temporary:
            context, compiler, archive, pins = self.fixture(Path(temporary), delay=0.04)
            started = time.monotonic()
            with self.pinned(pins), self.assertRaises(ValueError):
                self.build.prepare_trace(archive, context, compiler, mhd_source=pins["mhd_source"], timeout=0.14)
            self.assertLess(time.monotonic() - started, 1)
            self.assertFalse((context / "trace").exists())

    def test_unreaped_child_timeout_retains_generic_failure_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            context, compiler, archive, pins = self.fixture(Path(temporary))
            failure = subprocess.TimeoutExpired(["private argument"], 1)
            with self.pinned(pins), mock.patch.object(self.build, "bounded_process", side_effect=failure):
                with self.assertRaises(ValueError) as caught:
                    self.build.prepare_trace(archive, context, compiler, mhd_source=pins["mhd_source"])
            self.assertNotIn("private argument", str(caught.exception))
            report = json.loads((context / "trace-build-failure.json").read_text())
            self.assertEqual(report["outcome"], "fail")
            self.assertEqual(report["exception_type"], "TimeoutExpired")
            self.assertNotIn("private argument", json.dumps(report))
            self.assertFalse((context / "trace").exists())

    def test_late_final_io_or_publication_cannot_publish_success(self):
        for step in ("read", "receipt", "rename"):
            with self.subTest(step=step), tempfile.TemporaryDirectory() as temporary:
                context, compiler, archive, pins = self.fixture(Path(temporary))
                original_read = Path.read_bytes
                original_write = Path.write_text
                original_rename = os.rename
                original_clock = time.monotonic
                offset = [0]
                fired = [False]

                def late_read(path):
                    value = original_read(path)
                    if step == "read" and path.name == "reference_libpq_trace.c" and path.parent.name.startswith(".asm-reference-build-"):
                        offset[0] = 121
                        fired[0] = True
                    return value

                def late_write(path, *args, **kwargs):
                    value = original_write(path, *args, **kwargs)
                    if step == "receipt" and path.name == "manifest.json" and path.parent.name.startswith(".asm-reference-build-"):
                        offset[0] = 121
                        fired[0] = True
                    return value

                def late_rename(source, destination):
                    value = original_rename(source, destination)
                    if step == "rename" and Path(destination).name == "trace":
                        offset[0] = 121
                        fired[0] = True
                    return value

                with self.pinned(pins), mock.patch.object(Path, "read_bytes", late_read), \
                        mock.patch.object(Path, "write_text", late_write), \
                        mock.patch.object(os, "rename", late_rename), \
                        mock.patch.object(time, "monotonic", lambda: original_clock() + offset[0]):
                    with self.assertRaises(ValueError):
                        self.build.prepare_trace(archive, context, compiler, mhd_source=pins["mhd_source"])
                self.assertTrue(fired[0])
                self.assertFalse((context / "trace").exists())
                self.assertEqual(json.loads((context / "trace-build-failure.json").read_text())["outcome"], "fail")

    def test_invalid_or_extended_budget_cannot_start_a_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            context, compiler, archive, pins = self.fixture(Path(temporary))
            for timeout in (0, -1, True, float("nan"), float("inf"), 121):
                with self.subTest(timeout=timeout), self.pinned(pins), self.assertRaises(ValueError):
                    self.build.prepare_trace(archive, context, compiler, mhd_source=pins["mhd_source"], timeout=timeout)
                self.assertFalse((compiler.parent / "calls.jsonl").exists())
                self.assertFalse((context / "trace").exists())

    def test_elf_contract_rejects_wrong_machine_flags_stack_and_segments(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "artifact"
            path.write_bytes(elf())
            self.assertEqual(self.build.elf_contract(path, shared=True)["elf_flags"], 5)
            for data in (b"truncated", elf(machine=62), elf(flags=0), elf(stack=7), elf(load=7), elf(kind=2)):
                path.write_bytes(data)
                with self.subTest(data=data[:20]), self.assertRaises(ValueError):
                    self.build.elf_contract(path, shared=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
