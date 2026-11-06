"""Bound the canonical diagnostic's preparation without target execution.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
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
from contextlib import ExitStack
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SDK_REVISION = "881208fcec32ec8fe4609747ca2c4d8b9065c49f"
SOURCE_REVISION = "cb0f3f7315fe2878660684a1fe6eea76ca65e5ae"


def blob(revision, path):
    return subprocess.run(["git", "--no-replace-objects", "-C", str(ROOT), "show", revision + ":" + path],
                          capture_output=True, check=True, timeout=5).stdout


def packed(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, data, kind, target in entries:
            item = tarfile.TarInfo(name)
            item.type, item.linkname = kind, target
            item.size = len(data) if kind == tarfile.REGTYPE else 0
            archive.addfile(item, io.BytesIO(data) if item.size else None)
    return output.getvalue()


def library(payload=b""):
    data = bytearray(64)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", data, 16, 3, 243, 1)
    struct.pack_into("<I", data, 48, 5)
    return bytes(data) + payload


def output_elf(shared=False):
    interpreter = b"/lib/ld-linux-riscv64-lp64d.so.1\0"
    count = 2 if shared else 3
    data = bytearray(64 + count * 56 + (0 if shared else len(interpreter)))
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHIQQQIHHH", data, 16, 3 if shared else 2, 243, 1, 0, 64, 0, 5, 64, 56, count)
    struct.pack_into("<IIQQQQQQ", data, 64, 1, 5, 0, 0, 0, len(data), len(data), 4096)
    struct.pack_into("<IIQQQQQQ", data, 120, 0x6474e551, 6, 0, 0, 0, 0, 0, 16)
    if not shared:
        offset = 64 + count * 56
        data[offset:] = interpreter
        struct.pack_into("<IIQQQQQQ", data, 176, 3, 4, offset, 0, 0, len(interpreter), len(interpreter), 1)
    return bytes(data)


class CanonicalBuildTests(unittest.TestCase):
    def setUp(self):
        path = ROOT / "tools/canonical_riscv_build.py"
        self.assertTrue(path.is_file(), "The bounded canonical builder is missing.")
        spec = importlib.util.spec_from_file_location("canonical_build", path)
        self.build = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.build)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.sdk_path = self.base / "sdk"
        self.sdk_path.mkdir()
        for name in ("riscv64_reference_build.py", "riscv64_server_observations.py", "riscv64_combined.py"):
            (self.sdk_path / name).write_bytes(blob(SDK_REVISION, "tools/" + name))
        self.sdk = self.build.load_sdk(self.sdk_path)

    def image(self, extra=(), *, replacement=None, later_entries=()):
        pq, mhd = library(b"pq"), library(b"mhd")
        paths = {"libpq": ("opt/asm/postgres/lib/libpq.so.5", pq),
                 "libmicrohttpd": ("opt/asm/mhd/lib/libmicrohttpd.so.12", mhd)}
        entries = []
        for name, (soname, data) in paths.items():
            entries.extend(((soname, b"", tarfile.SYMTYPE, Path(soname).name + ".1"),
                            (soname + ".1", data, tarfile.REGTYPE, "")))
        for label, path in self.build.EXTRA_INPUTS.items():
            if label != "pg_config.h":
                entries.append((path, library(label.encode()), tarfile.REGTYPE, ""))
        entries.append(("opt/asm/postgres/include/pg_config.h", b"#define PG_VERSION_NUM 160015\n", tarfile.REGTYPE, ""))
        if replacement:
            entries = replacement(entries)
        layers = [packed([*entries, *extra])]
        if later_entries:
            layers.append(packed(later_entries))
            for name, data, kind, _ in later_entries:
                if name == "opt/asm/postgres/lib/libpq.so.5.1" and kind == tarfile.REGTYPE:
                    paths["libpq"] = (paths["libpq"][0], data)
        layer_shas = [hashlib.sha256(layer).hexdigest() for layer in layers]
        config = json.dumps({"architecture": "riscv64", "os": "linux", "config": {"Env": []},
                             "rootfs": {"diff_ids": ["sha256:" + value for value in layer_shas]}}).encode()
        image_id = "sha256:" + hashlib.sha256(config).hexdigest()
        config_name = "blobs/sha256/" + image_id[7:]
        manifest = json.dumps([{"Config": config_name, "Layers": ["blobs/sha256/" + value for value in layer_shas]}]).encode()
        archive = self.base / "image.tar"
        archive.write_bytes(packed([(config_name, config, tarfile.REGTYPE, ""),
                                    ("manifest.json", manifest, tarfile.REGTYPE, ""),
                                    *[("blobs/sha256/" + value, layer, tarfile.REGTYPE, "")
                                      for value, layer in zip(layer_shas, layers)]]))
        patches = mock.patch.multiple(self.sdk.observations,
            IMAGE_TAR_BYTES=archive.stat().st_size, IMAGE_TAR_SHA=hashlib.sha256(archive.read_bytes()).hexdigest(),
            IMAGE_ID=image_id, LIBRARIES={name: ("/" + path, hashlib.sha256(data).hexdigest())
                                       for name, (path, data) in paths.items()})
        return archive, patches, paths

    def test_selected_sonames_publish_only_fixed_regular_hashed_payloads(self):
        archive, patches, paths = self.image()
        destination = self.base / "deps"
        with patches:
            receipt = self.build.extract_dependencies(archive, destination, self.sdk, deadline=time.monotonic() + 5)
        self.assertEqual(sorted(item.name for item in destination.iterdir()),
                         ["ld-linux-riscv64-lp64d.so.1", "libc.so.6", "libcrypto.so.3", "libmicrohttpd.so.12",
                          "libpq.so.5", "libssl.so.3", "pg_config.h"])
        for name, (_, data) in paths.items():
            output = destination / Path(paths[name][0]).name
            self.assertFalse(output.is_symlink())
            self.assertEqual(output.read_bytes(), data)
            self.assertEqual(receipt[name]["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(output.stat().st_mode & 0o777, 0o444)

    def test_link_escape_hardlink_whiteout_duplicate_and_digest_mismatch_fail_closed(self):
        mutations = (
            lambda entries: [(name, data, kind, "../../escape" if kind == tarfile.SYMTYPE else target)
                             for name, data, kind, target in entries],
            lambda entries: [(name, data, tarfile.LNKTYPE if kind == tarfile.SYMTYPE else kind, target)
                             for name, data, kind, target in entries],
            lambda entries: entries + [("opt/asm/postgres/lib/.wh.libpq.so.5", b"", tarfile.REGTYPE, "")],
            lambda entries: entries + [entries[1]],
            lambda entries: [(name, library(b"different") if name.endswith("libpq.so.5.1") else data, kind, target)
                             for name, data, kind, target in entries],
            lambda entries: entries + [("opt/asm/postgres", b"", tarfile.SYMTYPE, "elsewhere")],
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                archive, patches, _ = self.image(replacement=mutate)
                destination = self.base / ("bad-" + str(index))
                with patches, self.assertRaises(ValueError):
                    self.build.extract_dependencies(archive, destination, self.sdk, deadline=time.monotonic() + 5)
                self.assertFalse(destination.exists())

    def test_ordered_regular_replacement_uses_latest_bytes_and_retains_both_identities(self):
        newer = library(b"newer retained PQ library")
        archive, patches, _ = self.image(later_entries=[
            ("opt/asm/postgres/lib/libpq.so.5", b"", tarfile.SYMTYPE, "libpq.so.5.1"),
            ("opt/asm/postgres/lib/libpq.so.5.1", newer, tarfile.REGTYPE, "")])
        destination = self.base / "deps"
        with patches:
            receipt = self.build.extract_dependencies(archive, destination, self.sdk, deadline=time.monotonic() + 5)
        self.assertEqual((destination / "libpq.so.5").read_bytes(), newer)
        history = receipt["libpq"]["selected_history"]["opt/asm/postgres/lib/libpq.so.5.1"]
        self.assertEqual([item["sha256"] for item in history],
                         [hashlib.sha256(library(b"pq")).hexdigest(), hashlib.sha256(newer).hexdigest()])
        self.assertNotEqual(history[0]["layer"], history[1]["layer"])

    def test_later_selected_whiteout_still_refuses_after_a_regular_replacement(self):
        archive, patches, _ = self.image(later_entries=[
            ("opt/asm/postgres/lib/libpq.so.5.1", library(b"newer"), tarfile.REGTYPE, ""),
            ("opt/asm/postgres/lib/.wh.libpq.so.5.1", b"", tarfile.REGTYPE, "")])
        with patches, self.assertRaises(ValueError):
            self.build.extract_dependencies(archive, self.base / "deps", self.sdk, deadline=time.monotonic() + 5)
        self.assertFalse((self.base / "deps").exists())

    def test_later_soname_type_or_target_changes_are_rejected(self):
        for index, entry in enumerate((("opt/asm/postgres/lib/libpq.so.5", library(b"pq"), tarfile.REGTYPE, ""),
                                       ("opt/asm/postgres/lib/libpq.so.5", b"", tarfile.SYMTYPE, "libpq.so.5.2"))):
            with self.subTest(entry=entry[2:]):
                archive, patches, _ = self.image(later_entries=[entry])
                destination = self.base / ("deps-" + str(index))
                with patches, self.assertRaises(ValueError):
                    self.build.extract_dependencies(archive, destination, self.sdk, deadline=time.monotonic() + 5)
                self.assertFalse(destination.exists())

    def test_selected_inventory_has_a_separate_small_record_bound(self):
        archive, patches, _ = self.image()
        with patches, mock.patch.object(self.build, "DEPENDENCY_RECORDS", 2, create=True), self.assertRaises(ValueError):
            self.build.extract_dependencies(archive, self.base / "deps", self.sdk, deadline=time.monotonic() + 5)
        self.assertFalse((self.base / "deps").exists())

    def test_expired_shared_deadline_and_existing_destination_preserve_files(self):
        archive, patches, _ = self.image()
        destination = self.base / "deps"
        with patches, self.assertRaises(ValueError):
            self.build.extract_dependencies(archive, destination, self.sdk, deadline=time.monotonic() - 1)
        self.assertFalse(destination.exists())
        destination.mkdir()
        (destination / "keep").write_bytes(b"original")
        with patches, self.assertRaises(ValueError):
            self.build.extract_dependencies(archive, destination, self.sdk, deadline=time.monotonic() + 5)
        self.assertEqual((destination / "keep").read_bytes(), b"original")

    def context(self):
        context = self.base / "context"
        context.mkdir()
        for relative in self.build.SOURCE_IDENTITIES:
            path = context / "source" / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(blob(SOURCE_REVISION, relative))
        observer = b"int observer;\n"
        fixture = b'PROVIDER = "int provider;"\nDRIVER = "int main(void) { return 0; }"\n'
        (context / "observer.c").write_bytes(observer)
        (context / "observer-test.py").write_bytes(fixture)
        return context, {"observer_sha256": hashlib.sha256(observer).hexdigest(),
                         "observer_test_sha256": hashlib.sha256(fixture).hexdigest()}

    def test_wrong_canonical_source_is_rejected_before_any_compiler_command(self):
        context, identities = self.context()
        (context / "source/server/catalog/reader-guard.sql").write_bytes(b"SELECT 1;")
        with mock.patch.object(self.sdk.combined, "bounded_process") as command:
            with self.assertRaises(ValueError):
                self.build.prepare_build(self.base / "absent.tar", context, sdk=self.sdk_path,
                    mhd_source=self.base / "absent.gz", deadline=time.monotonic() + 5, **identities)
        command.assert_not_called()
        self.assertFalse((context / "canonical-build").exists())
        report = json.loads((context / "canonical-build-failure.json").read_text())
        self.assertEqual(report["outcome"], "fail")
        self.assertEqual(report["qualification"], "UNQUALIFIED")
        self.assertEqual(report["target_execution"], "not-run")

    def test_sdk_tampering_is_rejected(self):
        path = self.sdk_path / "riscv64_combined.py"
        path.write_bytes(path.read_bytes() + b"\n# changed\n")
        with self.assertRaises(ValueError):
            self.build.load_sdk(self.sdk_path)

    def guest(self, *, readonly=True, uid=65532, machine="riscv64"):
        stack = ExitStack()
        stack.enter_context(mock.patch("platform.system", return_value="Linux"))
        stack.enter_context(mock.patch("platform.machine", return_value=machine))
        stack.enter_context(mock.patch.object(self.build.os, "getuid", return_value=uid))
        stack.enter_context(mock.patch.object(self.build.os, "geteuid", return_value=uid))
        stack.enter_context(mock.patch.object(self.build.os, "fstatvfs",
                                            return_value=SimpleNamespace(f_flag=os.ST_RDONLY if readonly else 0)))
        return stack

    def test_readonly_guest_accepts_foreign_owned_exact_sdk_but_host_mode_refuses(self):
        for path in self.sdk_path.iterdir():
            path.chmod(0o444)
        with self.guest():
            with self.assertRaises(ValueError):
                self.build.load_sdk(self.sdk_path)
            sdk = self.build.load_sdk(self.sdk_path.resolve(), readonly_guest=True)
            self.assertEqual(sdk.observations.IMAGE_ID, "sha256:ea55425e6daa994ad57c46862258368c192c6f1f44b146c8a7bf3d1758571ae1")

    def test_guest_sdk_refuses_writable_mount_files_wrong_uid_architecture_and_hash(self):
        for path in self.sdk_path.iterdir():
            path.chmod(0o444)
        for changes in ({"readonly": False}, {"uid": 1001}, {"machine": "x86_64"}):
            with self.subTest(changes=changes), self.guest(**changes), self.assertRaises(ValueError):
                self.build.load_sdk(self.sdk_path.resolve(), readonly_guest=True)
        first = self.sdk_path / "riscv64_combined.py"
        first.chmod(0o644)
        with self.guest(), self.assertRaises(ValueError):
            self.build.load_sdk(self.sdk_path.resolve(), readonly_guest=True)
        first.write_bytes(first.read_bytes() + b"# changed\n")
        first.chmod(0o444)
        with self.guest(), self.assertRaises(ValueError):
            self.build.load_sdk(self.sdk_path.resolve(), readonly_guest=True)

    def test_guest_sdk_still_refuses_links_and_symlink_parents(self):
        for path in self.sdk_path.iterdir():
            path.chmod(0o444)
        first = self.sdk_path / "riscv64_combined.py"
        hardlink = self.base / "hardlink"
        os.link(first, hardlink)
        with self.guest(), self.assertRaises(ValueError):
            self.build.load_sdk(self.sdk_path.resolve(), readonly_guest=True)
        hardlink.unlink()
        alias = self.base / "alias"
        alias.symlink_to(self.sdk_path.resolve(), target_is_directory=True)
        with self.guest(), self.assertRaises(ValueError):
            self.build.load_sdk(alias, readonly_guest=True)
        original = first.read_bytes()
        first.unlink()
        target = self.base / "module.py"
        target.write_bytes(original)
        target.chmod(0o444)
        first.symlink_to(target)
        with self.guest(), self.assertRaises((OSError, ValueError)):
            self.build.load_sdk(self.sdk_path.resolve(), readonly_guest=True)

    def test_publication_requires_the_pinned_host_helper_bytes(self):
        stage = self.base / "stage"
        stage.mkdir()
        (stage / "keep").write_bytes(b"original")
        with mock.patch.object(self.build, "PUBLICATION_IDENTITIES", {"release.py": (1, "0" * 64)}, create=True):
            with self.assertRaises(ValueError):
                self.build._publish(stage, self.base / "published")
        self.assertEqual((stage / "keep").read_bytes(), b"original")
        self.assertFalse((self.base / "published").exists())

    def test_import_contract_retains_versions_and_refuses_newer_glibc(self):
        good = "  1: 0000 0 FUNC GLOBAL DEFAULT UND PQfinish\n  2: 0000 0 FUNC GLOBAL DEFAULT UND memcpy@GLIBC_2.14 (2)\n"
        receipt = self.build.import_contract(good, "  Name: GLIBC_2.34  Flags: none\n", " 0 (NEEDED) Shared library: [libpq.so.5]\n",
                                             provided_versions={"GLIBC_2.14", "GLIBC_2.34"})
        self.assertEqual(receipt["needed"], ["libpq.so.5"])
        self.assertIn("memcpy@GLIBC_2.14", receipt["undefined_symbols"])
        with self.assertRaises(ValueError):
            self.build.import_contract(good, "Name: GLIBC_2.38", "", provided_versions={"GLIBC_2.34"})

    def test_actual_interpreter_is_bound_and_wrong_loader_is_rejected(self):
        self.assertTrue(hasattr(self.build, "interpreter_contract"), "The build does not retain the actual ELF interpreter.")
        path = self.base / "elf"
        path.write_bytes(output_elf())
        self.assertEqual(self.build.interpreter_contract(path, shared=False), "/lib/ld-linux-riscv64-lp64d.so.1")
        path.write_bytes(output_elf().replace(b"/lib/ld-linux", b"/bad/ld-linux"))
        with self.assertRaises(ValueError):
            self.build.interpreter_contract(path, shared=False)
        path.write_bytes(output_elf(shared=True))
        self.assertIsNone(self.build.interpreter_contract(path, shared=True))

    def mock_build(self, *, fail=None, mutate=None, advance=None):
        """Replace the external compiler/headers; exercise actual orchestration.

        This produces synthetic ELF containers, never target ABI evidence.
        """
        context, identities = self.context()
        archive, image_patches, _ = self.image()
        compiler = self.base / "riscv64-linux-gnu-gcc"
        readelf = self.base / "riscv64-linux-gnu-readelf"
        for path in (compiler, readelf):
            path.write_bytes(b"controlled host tool identity\n")
            path.chmod(0o555)

        def headers(_, destination):
            destination.mkdir()
            receipt = {}
            for name in ("libpq-fe.h", "postgres_ext.h", "pg_config_ext.h"):
                data = b"/* controlled public header */\n"
                (destination / name).write_bytes(data)
                (destination / name).chmod(0o444)
                receipt[name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
            return receipt

        def mhd_header(_, destination):
            data = b"/* controlled MHD header */\n"
            destination.write_bytes(data)
            destination.chmod(0o444)
            return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}

        def run(arguments, log, *, cwd, timeout, max_bytes):
            # A policy regression must fail before synthetic outputs publish.
            self.assertLessEqual(timeout, 30)
            if advance:
                self.assertLessEqual(timeout, 0.5)
            self.assertGreater(timeout, 0)
            self.assertLessEqual(max_bytes, self.build.LOG_BYTES)
            self.assertEqual(arguments[:5], ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin", "LC_ALL=C", "LANG=C"])
            args = list(map(str, arguments[7:]))
            text = ""
            outcome, code, failure = "pass", 0, None
            if fail == "compiler" and "-dumpmachine" in args:
                text, outcome, code = "controlled compiler failure\n", "fail", 71
            elif "--version" in args:
                text = "controlled host compiler 1\n"
            elif "-dumpmachine" in args:
                text = "riscv64-linux-gnu\n"
            elif any(arg.startswith(("-print-prog-name=", "-print-file-name=")) for arg in args):
                text = str(compiler) + "\n"
            elif "--version-info" in args:
                text = "Version definition section\nName: GLIBC_2.34\nVersion needs section\n"
            elif "--dynamic" in args:
                name = Path(args[-1]).name
                text = " 0 (SONAME) Library soname: [" + name + "]\n" if "dependencies" in args[-1] else (
                    " 0 (NEEDED) Shared library: [libpq.so.5]\n 0 (NEEDED) Shared library: [libmicrohttpd.so.12]\n"
                    if name in ("asm-hub", "abi-check") else (
                        " 0 (NEEDED) Shared library: [libcanonical_provider.so]\n" if name == "canonical_trace_check" else ""))
            elif "--dyn-syms" in args:
                text = " 1: 0000 0 FUNC GLOBAL DEFAULT UND memcpy@GLIBC_2.34 (2)\n"
            elif "-A" in args:
                text = 'Tag_RISCV_arch: "rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_zicsr2p0_zifencei2p0"\n'
            elif "-o" in args:
                if "assembler-with-cpp" in args:
                    # Explicit libraries must not be parsed as assembly input.
                    library_index = next(i for i, value in enumerate(args) if value.endswith("libmicrohttpd.so.12"))
                    if args[:library_index].count("-x") != 2 or args[library_index - 1] != "none":
                        text, outcome, code = "assembly language leaked onto ELF libraries\n", "fail", 1
                if outcome == "pass":
                    path = Path(args[args.index("-o") + 1])
                    path.write_bytes(output_elf(path.suffix == ".so"))
                    if mutate:
                        mutate(context, path)
            else:
                self.fail("Unexpected external build command: " + repr(args))
            log.write_text(text)
            if advance:
                advance()
            return {"outcome": outcome, "exit_code": code, "failure": failure, "bytes": len(text), "seconds": 0.001}

        self.enterContext(image_patches)
        self.enterContext(mock.patch.object(self.build, "load_sdk", return_value=self.sdk))
        self.enterContext(mock.patch.object(self.sdk.reference, "extract_headers", side_effect=headers))
        self.enterContext(mock.patch.object(self.sdk.reference, "extract_mhd_header", side_effect=mhd_header))
        self.enterContext(mock.patch.object(self.sdk.combined, "bounded_process", side_effect=run))
        return context, dict(sdk=self.sdk_path, mhd_source=self.base / "controlled.gz", compiler=compiler,
                             deadline=time.monotonic() + 5, **identities), archive

    def test_controlled_build_publishes_all_five_unqualified_outputs_without_execution(self):
        context, arguments, archive = self.mock_build()
        report = self.build.prepare_build(archive, context, **arguments)
        self.assertEqual(report["qualification"], "UNQUALIFIED")
        self.assertEqual(report["target_execution"], "not-run")
        self.assertEqual(set(report["outputs"]), {"asm-hub", "abi-check", "canonical_libpq_trace.so",
                                                  "libcanonical_provider.so", "canonical_trace_check"})
        for name, receipt in report["outputs"].items():
            output = context / "canonical-build" / name
            self.assertEqual(output.stat().st_mode & 0o777, 0o555)
            self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(), receipt["sha256"])
        self.assertEqual(json.loads((context / "canonical-build/manifest.json").read_text()), report)
        self.assertFalse((context / "canonical-build-failure.json").exists())

    def test_failed_compiler_retains_bounded_failure_and_no_partial_outputs(self):
        context, arguments, archive = self.mock_build(fail="compiler")
        with self.assertRaises(ValueError):
            self.build.prepare_build(archive, context, **arguments)
        report = json.loads((context / "canonical-build-failure.json").read_text())
        self.assertEqual(report["commands"][-1]["exit_code"], 71)
        self.assertEqual((context / "canonical-build-failure.log").read_bytes(), b"controlled compiler failure\n")
        self.assertFalse((context / "canonical-build").exists())
        self.assertFalse(list(context.glob(".asm-canonical-build-*")))

    def test_source_mutation_during_compile_is_rejected(self):
        def mutate(context, output):
            if output.name == "asm-hub":
                (context / "source/server/catalog/reader-guard.sql").write_bytes(b"changed\n")
        context, arguments, archive = self.mock_build(mutate=mutate)
        with self.assertRaises(ValueError):
            self.build.prepare_build(archive, context, **arguments)
        self.assertFalse((context / "canonical-build").exists())
        report = json.loads((context / "canonical-build-failure.json").read_text())
        self.assertEqual(report["stage"], "final-inputs")

    def test_caller_deadline_caps_build_and_stops_before_later_commands(self):
        clock = [100.0]
        context, arguments, archive = self.mock_build(advance=lambda: clock.__setitem__(0, 100.6))
        arguments["deadline"] = 100.5
        arguments["timeout"] = 120
        with mock.patch.object(self.build.time, "monotonic", side_effect=lambda: clock[0]), self.assertRaises(ValueError):
            self.build.prepare_build(archive, context, **arguments)
        report = json.loads((context / "canonical-build-failure.json").read_text())
        self.assertEqual([item["label"] for item in report["commands"]], ["compiler-version"])
        self.assertEqual(report["outcome"], "fail")
        self.assertFalse((context / "canonical-build").exists())

    def test_subprocess_timeout_retains_failure_evidence(self):
        context, arguments, archive = self.mock_build()
        def timeout(*args, **kwargs):
            raise subprocess.TimeoutExpired("controlled host compiler", 0.1)
        with mock.patch.object(self.sdk.combined, "bounded_process", side_effect=timeout):
            with self.assertRaises(ValueError):
                self.build.prepare_build(archive, context, **arguments)
        self.assertFalse((context / "canonical-build").exists())
        report = json.loads((context / "canonical-build-failure.json").read_text())
        self.assertEqual(report["exception_type"], "TimeoutExpired")


if __name__ == "__main__":
    unittest.main()
