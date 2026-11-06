"""Synthetic isolation checks; no Docker, network, PostgreSQL, or target code runs.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import copy
from contextlib import ExitStack
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import time
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))


def elf(machine=243, interpreter=None):
    raw = interpreter.encode() + b"\0" if interpreter is not None else b""
    data = bytearray(232 + len(raw) if raw else 176)
    data[:16] = b"\x7fELF\x02\x01\x01" + bytes(9)
    struct.pack_into("<HHIQQQIHHHHHH", data, 16, 3, machine, 1, 0, 64, 0, 5 if machine == 243 else 0, 64, 56, 3 if raw else 2, 64, 0, 0)
    struct.pack_into("<IIQQQQQQ", data, 64, 1, 5, 0, 0, 0, len(data), len(data), 4096)
    struct.pack_into("<IIQQQQQQ", data, 120, 0x6474e551, 6, 0, 0, 0, 0, 0, 16)
    if raw:
        struct.pack_into("<IIQQQQQQ", data, 176, 3, 4, 232, 0, 0, len(raw), len(raw), 1)
        data[232:] = raw
    return bytes(data)


def dynamic_elf(needed):
    strings = b"\0" + needed.encode() + b"\0"
    data = bytearray(296 + len(strings))
    data[:176] = elf(62)
    struct.pack_into("<H", data, 56, 3)
    struct.pack_into("<Q", data, 96, len(data))
    struct.pack_into("<Q", data, 104, len(data))
    struct.pack_into("<IIQQQQQQ", data, 176, 2, 4, 232, 232, 0, 64, 64, 8)
    for i, pair in enumerate(((5, 296), (10, len(strings)), (1, 1), (0, 0))):
        struct.pack_into("<qQ", data, 232 + 16 * i, *pair)
    data[296:] = strings
    return bytes(data)


class NativeTests(unittest.TestCase):
    def setUp(self):
        path = REPO / "tools/riscv64_reference_native.py"
        self.assertTrue(path.is_file(), "The isolated native backend module is absent")
        spec = importlib.util.spec_from_file_location("reference_native", path)
        self.n = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.n)

    def fixture(self, root):
        paths = {}
        for name in ("python", "server", "libpq", "libmicrohttpd", "postgres", "initdb", "psql"):
            path = root / name
            path.write_bytes(elf())
            paths[name] = path
        timezone = root / "UTC"
        timezone.write_bytes(b"TZif\0owned UTC")
        return paths, timezone

    def baseline(self):
        files = {}
        for name, path in self.n.RISC_FILES.items():
            size, sha = self.n.PINS.get(name, (176, "a" * 64))
            files[str(path)] = {"bytes": size, "sha256": sha, "elf_machine": 243, "resolved_path": str(path)}
        return {"schema": 1, "scope": "native-backend-risc-baseline", "outcome": "pass", "base_image": self.n.BASE_IMAGE,
                "overlay_paths_absent": True, "files": files, "postgres": files[str(self.n.RISC_FILES["postgres"])],
                "psql": files[str(self.n.RISC_FILES["psql"])], "timezone": {"bytes": 10, "sha256": "b" * 64, "resolved_path": str(self.n.TIMEZONE)}}

    def test_curated_asset_binds_platform_config_layers_source_and_copyright(self):
        asset = self.n.asset_manifest()
        self.assertEqual(asset["platform_manifest"], "sha256:751329300ebdcbde5461c14fac796c8840d13fc74cc49b9b94745b0285907961")
        self.assertEqual(asset["config"], "sha256:5bbe1b33f05489cf9ea1aa962ce6599cc238094344de42ce3f40e2478c9714bf")
        self.assertEqual(len(asset["rootfs_diff_ids"]), 11)
        self.assertEqual(sum(v["size"] for v in asset["layers"]), 115570150)
        self.assertEqual(asset["source_revision"], "9d15534160ade17f2b6c455a39ee967c49b1937d")
        copyright_data = (REPO / "tools/diagnostics/native_postgres.COPYRIGHT").read_bytes()
        self.assertEqual(hashlib.sha256(copyright_data).hexdigest(), asset["copyright_sha256"])

    def test_wrong_image_platform_config_or_layer_cannot_enter_overlay(self):
        asset = self.n.asset_manifest()
        good = {"Id": asset["config"], "Architecture": "amd64", "Os": "linux", "RootFS": {"Layers": asset["rootfs_diff_ids"]}}
        self.n.check_native_image(good, asset)
        for key, value in (("Id", "sha256:" + "0" * 64), ("Architecture", "riscv64"), ("Os", "other"), ("RootFS", {"Layers": []})):
            bad = copy.deepcopy(good)
            bad[key] = value
            with self.assertRaises(ValueError):
                self.n.check_native_image(bad, asset)

    def test_host_rejects_incomplete_or_wrong_pinned_baseline_evidence(self):
        baseline = self.baseline()
        self.n.check_baseline(baseline)
        for change in (lambda x: x.update(outcome="fail"), lambda x: x["files"].pop(str(self.n.RISC_FILES["psql"])),
                       lambda x: x["files"][str(self.n.RISC_FILES["libpq"])].update(sha256="0" * 64)):
            bad = copy.deepcopy(baseline)
            change(bad)
            with self.assertRaises(ValueError):
                self.n.check_baseline(bad)

    def test_recipe_adds_only_disjoint_paths_without_run_env_or_entrypoint(self):
        base_tag = "asm-native-base:" + "a" * 32
        recipe = self.n.overlay_recipe(base_tag).splitlines()
        commands = [line.split()[0] for line in recipe]
        self.assertEqual(commands.count("FROM"), 2)
        self.assertEqual(set(commands), {"FROM", "COPY"})
        self.assertIn(self.n.NATIVE_IMAGE, recipe[0])
        self.assertIn(base_tag, recipe[1])
        self.assertIn("COPY --from=native / /opt/asm/native-postgres/rootfs/", recipe)
        self.assertIn("COPY --from=native /lib/ld-musl-x86_64.so.1 /lib/ld-musl-x86_64.so.1", recipe)
        self.assertIn("COPY musl.path /etc/ld-musl-x86_64.path", recipe)
        for name in ("postgres", "initdb"):
            wrapper = self.n.wrapper(name)
            self.assertIn("unset LD_LIBRARY_PATH LD_PRELOAD", wrapper)
            self.assertIn('"$@"', wrapper)
            self.assertNotIn("eval", wrapper)
        self.assertIn("/opt/asm/postgres/bin/psql", self.n.wrapper("psql"))
        self.assertTrue(all(line.startswith(str(self.n.ROOT)) for line in self.n.musl_path().splitlines()))

    def test_overlay_preserves_entire_base_config_and_layer_prefix(self):
        base = {"Id": self.n.BASE_IMAGE, "Architecture": "riscv64", "Os": "linux", "RootFS": {"Layers": ["base"]}, "Config": {"Env": ["LD_LIBRARY_PATH=original"], "User": "65532:65532"}}
        overlay = copy.deepcopy(base)
        overlay["Id"] = "sha256:" + "1" * 64
        overlay["RootFS"]["Layers"].append("new")
        self.n.check_overlay(base, overlay)
        for mutate in (lambda x: x["Config"]["Env"].append("LD_LIBRARY_PATH=native"), lambda x: x["RootFS"]["Layers"].reverse(), lambda x: x.update(Architecture="amd64")):
            bad = copy.deepcopy(overlay)
            mutate(bad)
            with self.assertRaises(ValueError):
                self.n.check_overlay(base, bad)

    def test_baseline_rejects_collision_wrong_elf_and_client_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths, timezone = self.fixture(root)
            with mock.patch.object(self.n, "RISC_FILES", paths), mock.patch.object(self.n, "PINS", {}), mock.patch.object(self.n, "TIMEZONE", timezone), mock.patch.object(self.n, "COLLISIONS", (root / "native",)):
                baseline = self.n.capture_risc(require_absent=True)
                receipt = root / "baseline.json"
                receipt.write_text(json.dumps(baseline))
                with mock.patch.object(self.n, "BASELINE", receipt):
                    self.assertEqual(self.n.verify_risc()["postgres"]["sha256"], hashlib.sha256(elf()).hexdigest())
                    paths["libpq"].write_bytes(elf(62))
                    with self.assertRaises(ValueError):
                        self.n.verify_risc()
                paths["libpq"].write_bytes(elf())
                (root / "native").symlink_to(root / "missing")
                with self.assertRaises(ValueError):
                    self.n.capture_risc(require_absent=True)

    def test_pinned_client_hash_and_file_bounds_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths, timezone = self.fixture(root)
            with mock.patch.object(self.n, "RISC_FILES", paths), mock.patch.object(self.n, "PINS", {"server": (176, "0" * 64)}), mock.patch.object(self.n, "TIMEZONE", timezone):
                with self.assertRaises(ValueError):
                    self.n.capture_risc()
            path = paths["server"]
            with self.assertRaises(ValueError):
                self.n.file_identity(path, maximum=175)
            path.unlink()
            path.symlink_to(root / "missing")
            with self.assertRaises(ValueError):
                self.n.file_identity(path)

    def test_hash_read_accepts_access_time_change_but_rejects_changed_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "file"
            path.write_bytes(elf())
            os.utime(path, (1, 1))
            result = self.n.file_identity(path, machine=243)
            self.assertEqual(result["sha256"], hashlib.sha256(elf()).hexdigest())

    def test_native_elf_rejects_foreign_machine_truncation_and_outside_dependency(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "postgres"
            binary.write_bytes(elf(243))
            with self.assertRaises(ValueError):
                self.n.elf_metadata(binary, 62)
            binary.write_bytes(b"\x7fELF")
            with self.assertRaises(ValueError):
                self.n.elf_metadata(binary, 62)
            binary.write_bytes(elf(62))
            self.assertEqual(self.n.elf_metadata(binary, 62)["elf_machine"], 62)
            with mock.patch.object(self.n, "ROOT", root):
                with self.assertRaises(ValueError):
                    self.n.parse_loader_list("libc.so => /usr/lib/libc.so (0x123)\n")

    def test_selected_module_dependencies_stay_in_private_native_search_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            module = root / "usr/local/lib/postgresql/plpgsql.so"
            module.parent.mkdir(parents=True)
            module.write_bytes(dynamic_elf("libneeded.so"))
            library = root / "usr/lib/libneeded.so"
            library.parent.mkdir(parents=True)
            library.write_bytes(elf(62))
            self.assertEqual(self.n.needed_libraries(module), ["libneeded.so"])
            with mock.patch.object(self.n, "ROOT", root):
                result = self.n.dependency_closure([module], time.monotonic() + 2)
                self.assertEqual(result[str(module)]["needed"], ["libneeded.so"])
                self.assertIn(str(library), result)
                library.write_bytes(elf(243))
                with self.assertRaises(ValueError):
                    self.n.dependency_closure([module], time.monotonic() + 2)
                module.write_bytes(dynamic_elf("/outside.so"))
                with self.assertRaises(ValueError):
                    self.n.needed_libraries(module)
                for tag in (15, 29):
                    data = bytearray(dynamic_elf("libneeded.so"))
                    struct.pack_into("<q", data, 264, tag)
                    module.write_bytes(data)
                    with self.assertRaises(ValueError):
                        self.n.needed_libraries(module)

    def test_selected_dependency_accepts_verified_interpreter_through_usrmerge(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            root = base / "payload"
            (base / "usr/lib").mkdir(parents=True)
            (base / "lib").symlink_to(base / "usr/lib", target_is_directory=True)
            loader = base / "lib/ld-musl-x86_64.so.1"
            loader.write_bytes(elf(62))
            module = root / "usr/local/lib/postgresql/plpgsql.so"
            module.parent.mkdir(parents=True)
            module.write_bytes(dynamic_elf("libc.musl-x86_64.so.1"))
            (root / "lib").mkdir()
            (root / "lib/libc.musl-x86_64.so.1").symlink_to(loader)
            with mock.patch.object(self.n, "ROOT", root), mock.patch.object(self.n, "LOADER", loader):
                result = self.n.dependency_closure([module], time.monotonic() + 2)
            self.assertIn(str(base / "usr/lib/ld-musl-x86_64.so.1"), result)

    def test_prepare_deadline_or_existing_receipt_starts_no_container(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            context, output = root / "context", root / "output"
            context.mkdir()
            output.mkdir()
            with mock.patch.object(self.n, "_docker") as docker:
                with self.assertRaises(ValueError):
                    self.n.prepare_native(context, output, time.monotonic() - 1)
                docker.assert_not_called()
                (context / "native-baseline-risc.json").write_bytes(b"existing")
                with self.assertRaises(ValueError):
                    self.n.prepare_native(context, output, time.monotonic() + 30)
                docker.assert_not_called()
                self.assertEqual((context / "native-baseline-risc.json").read_bytes(), b"existing")

    def test_prepare_publishes_bound_receipts_only_after_checked_overlay(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            context, output = root / "context", root / "output"
            context.mkdir()
            output.mkdir()
            asset = self.n.asset_manifest()
            base = {"Id": self.n.BASE_IMAGE, "Architecture": "riscv64", "Os": "linux", "RootFS": {"Layers": ["base"]}, "Config": {"Env": ["original"]}}
            overlay = copy.deepcopy(base)
            overlay["Id"] = "sha256:" + "1" * 64
            overlay["RootFS"]["Layers"].append("native")
            baseline = self.baseline()
            calls = []
            owned_tag = None
            def fake(arguments, log, **kwargs):
                nonlocal owned_tag
                args = arguments[arguments.index("docker") + 1:]
                calls.append(args)
                data = b""
                if args[:2] == ["image", "tag"]:
                    self.assertEqual(args[2], self.n.BASE_IMAGE)
                    self.assertRegex(args[3], r"^asm-native-base:[0-9a-f]{32}$")
                    owned_tag = args[3]
                if args[:2] == ["image", "inspect"]:
                    value = ({"Id": asset["config"], "Architecture": "amd64", "Os": "linux", "RootFS": {"Layers": asset["rootfs_diff_ids"]}} if args[2] == self.n.NATIVE_IMAGE else base if args[2] in (self.n.BASE_IMAGE, owned_tag) else overlay)
                    data = json.dumps([value]).encode()
                if args[0] == "start":
                    data = json.dumps(baseline).encode()
                if args[0] == "build":
                    directory = Path(args[-1])
                    self.assertEqual(set(p.name for p in directory.iterdir()), {"Dockerfile", "musl.path", "wrappers"})
                    recipe = (directory / "Dockerfile").read_text()
                    self.assertNotIn("RUN ", recipe)
                    # The observed bare sha256 FROM was parsed as a repository.
                    # Inspect the recipe passed through the real build wrapper.
                    self.assertIsNotNone(owned_tag)
                    self.assertEqual(recipe.splitlines()[1], "FROM --platform=linux/riscv64 " + owned_tag)
                    self.assertIn("--pull=false", args)
                    self.assertIn("--network=none", args)
                log.write_bytes(data)
                return {"outcome": "pass", "exit_code": 0}
            with mock.patch.object(self.n, "bounded_process", side_effect=fake):
                result = self.n.prepare_native(context, output, time.monotonic() + 30)
            self.assertEqual(result["new_image_id"], overlay["Id"])
            self.assertEqual(json.loads((context / "native-baseline-risc.json").read_bytes()), baseline)
            self.assertEqual((context / "native-postgres-manifest.json").stat().st_mode & 0o777, 0o444)
            build_index = next(i for i, args in enumerate(calls) if args[0] == "build")
            self.assertEqual(calls[build_index - 1], ["image", "inspect", owned_tag])
            self.assertEqual(calls[build_index + 1], ["image", "inspect", owned_tag])

    def test_late_publication_failure_removes_new_receipts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            context, output = root / "context", root / "output"
            context.mkdir()
            output.mkdir()
            asset = self.n.asset_manifest()
            base = {"Id": self.n.BASE_IMAGE, "Architecture": "riscv64", "Os": "linux", "RootFS": {"Layers": ["base"]}, "Config": {}}
            overlay = copy.deepcopy(base)
            overlay["Id"] = "sha256:" + "2" * 64
            overlay["RootFS"]["Layers"].append("native")
            def fake(args, *unused, **kwargs):
                if args[:2] == ["image", "inspect"]:
                    value = ({"Id": asset["config"], "Architecture": "amd64", "Os": "linux", "RootFS": {"Layers": asset["rootfs_diff_ids"]}} if args[2] == self.n.NATIVE_IMAGE else base if args[2] == self.n.BASE_IMAGE or args[2].startswith("asm-native-base:") else overlay)
                    return json.dumps([value]).encode()
                if args[0] == "start":
                    return json.dumps(self.baseline()).encode()
                return b""
            original_link = os.link
            def fail_second(source, destination):
                if destination.name == "native-postgres-manifest.json":
                    raise OSError("simulated publication failure")
                return original_link(source, destination)
            with mock.patch.object(self.n, "_docker", side_effect=fake), mock.patch.object(self.n.os, "link", side_effect=fail_second):
                with self.assertRaises(OSError):
                    self.n.prepare_native(context, output, time.monotonic() + 30)
            self.assertEqual(list(context.iterdir()), [])

    def test_changed_local_tag_or_failed_build_never_publishes_receipts(self):
        for failure in ("before", "after", "build"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                context, output = root / "context", root / "output"
                context.mkdir()
                output.mkdir()
                asset = self.n.asset_manifest()
                base = {"Id": self.n.BASE_IMAGE, "Architecture": "riscv64", "Os": "linux",
                        "RootFS": {"Layers": ["base"]}, "Config": {}}
                checked, built = [], []
                def fake(args, *unused, **kwargs):
                    if args[:2] == ["image", "inspect"]:
                        value = base
                        if args[2] == self.n.NATIVE_IMAGE:
                            value = {"Id": asset["config"], "Architecture": "amd64", "Os": "linux",
                                     "RootFS": {"Layers": asset["rootfs_diff_ids"]}}
                        elif args[2].startswith("asm-native-base:"):
                            checked.append("before" if not checked else "after")
                            if checked[-1] == failure:
                                value = {**base, "Id": "sha256:" + "f" * 64}
                        return json.dumps([value]).encode()
                    if args[0] == "start":
                        return json.dumps(self.baseline()).encode()
                    if args[0] == "build":
                        built.append(True)
                        if failure == "build":
                            raise RuntimeError("The observed build failed.")
                    return b""
                with mock.patch.object(self.n, "_docker", side_effect=fake):
                    with self.assertRaises(RuntimeError if failure == "build" else ValueError):
                        self.n.prepare_native(context, output, time.monotonic() + 30)
                self.assertEqual(list(context.iterdir()), [])
                self.assertEqual(bool(built), failure != "before")
                self.assertEqual(checked, ["before"] if failure == "before" else ["before", "after"])

    def test_resource_snapshot_copies_only_numeric_whitelisted_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "cpu.stat").write_text("usage_usec 10\nuser_usec 5\nsystem_usec 5\nnr_periods 3\nnr_throttled 2\nthrottled_usec 9\nsecret 123\n")
            (root / "memory.current").write_text("1024\n")
            (root / "memory.peak").write_text("2048\n")
            with mock.patch.object(self.n, "CGROUP", root):
                result = self.n.resource_snapshot()
            self.assertEqual(result["cpu"], {"usage_usec": 10, "user_usec": 5, "system_usec": 5, "nr_periods": 3, "nr_throttled": 2, "throttled_usec": 9})
            self.assertEqual((result["memory_current"], result["memory_peak"], result["available"]), (1024, 2048, True))
            self.assertIsInstance(result["captured_monotonic"], float)
            self.assertEqual(result["memory_peak_scope"], "whole-cgroup-lifetime-not-reset")
            (root / "memory.current").write_text("private malformed value\n")
            with mock.patch.object(self.n, "CGROUP", root):
                partial = self.n.resource_snapshot()
            self.assertFalse(partial["available"])
            self.assertNotIn("memory_current", partial)

    def test_resource_snapshot_reads_sysfs_files_with_zero_advertised_size(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "cpu.stat").write_text("usage_usec 12\n")
            (root / "memory.current").write_text("1024\n")
            (root / "memory.peak").write_text("2048\n")
            fstat = os.fstat
            def virtual_size(fd):
                values = list(fstat(fd))
                values[6] = 0
                return os.stat_result(values)
            with mock.patch.object(self.n, "CGROUP", root), mock.patch.object(self.n.os, "fstat", side_effect=virtual_size):
                result = self.n.resource_snapshot()
            self.assertEqual(result["cpu"], {"usage_usec": 12})
            self.assertEqual(result["memory_peak"], 2048)

    def test_guest_preflight_checks_wrappers_without_running_database_work(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            base = Path(temporary).resolve()
            root, bindir, loader = base / "payload", base / "bin", base / "loader"
            musl, manifest = base / "musl.path", base / "manifest.json"
            for key, value in (("ROOT", root), ("BINDIR", bindir), ("POSTGRES", root / "usr/local/bin/postgres"), ("LOADER", loader), ("MUSL_PATH", musl), ("GUEST_MANIFEST", manifest)):
                stack.enter_context(mock.patch.object(self.n, key, value))
            stack.enter_context(mock.patch.object(self.n, "verify_risc", return_value={"timezone": {"sha256": "a" * 64, "bytes": 1}}))
            manifest.write_bytes(self.n.MANIFEST.read_bytes())
            musl.write_text(self.n.musl_path())
            loader.write_bytes(elf(62))
            for path in (root / "lib/ld-musl-x86_64.so.1", root / "usr/local/lib/postgresql/plpgsql.so", root / "usr/local/lib/postgresql/llvmjit.so", root / "usr/lib/ossl-modules/legacy.so"):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(elf(62))
            for path, data in ((root / "usr/local/share/postgresql/postgres.bki", b"owned bki"), (root / "etc/ssl/openssl.cnf", b"# owned config"), (root / "usr/share/icu/77.1/icudt77l.dat", b"owned icu data")):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            bindir.mkdir()
            for name in ("postgres", "initdb", "pg_config"):
                path = root / "usr/local/bin" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(elf(62, str(loader)))
                if name != "pg_config":
                    (bindir / name).write_text(self.n.wrapper(name))
            (bindir / "psql").write_text(self.n.wrapper("psql"))
            # These features are unused by the controlled fixture. They must
            # not prevent the required bootstrap/PLpgSQL comparison.
            (root / "usr/local/lib/postgresql/llvmjit.so").write_bytes(b"unused feature deliberately untested")
            (root / "usr/lib/ossl-modules/legacy.so").write_bytes(b"unused provider deliberately untested")
            calls = []
            def metadata_command(args, *unused, **kwargs):
                calls.append(args)
                if "--list" in args:
                    return (str(loader) + " (0x123)\n").encode()
                option = args[-1]
                name = Path(args[0]).name
                if option == "--version":
                    return (("PostgreSQL 16.15" if name == "pg_config" else name + " (PostgreSQL) 16.15") + "\n").encode()
                if option == "--configure":
                    return b"--with-llvm --with-icu --with-openssl\n"
                return (str(root / ("usr/local/share/postgresql" if option == "--sharedir" else "usr/local/lib/postgresql")) + "\n").encode()
            stack.enter_context(mock.patch.object(self.n, "_native_command", side_effect=metadata_command))
            previous = dict(os.environ)
            result = self.n.inspect_native(base, time.monotonic() + 30)
            self.assertEqual(result["postgres"]["elf_machine"], 62)
            self.assertTrue(result["configure"]["with_llvm"])
            self.assertEqual(result["unused_modules"], "not-tested")
            self.assertEqual(result["icu_data"]["bytes"], 14)
            self.assertEqual(result["copyright"]["sha256"], "3d6af92ff8a4c2cdf69afb1cf44edea727922f5cd0cf8b5f72b11cdecac8fdfd")
            self.assertEqual(dict(os.environ), previous)
            self.assertTrue(all(args[-1].startswith("--") or "--list" in args for args in calls))
            (root / "usr/local/lib/postgresql/plpgsql.so").write_bytes(elf(243))
            with self.assertRaises(ValueError):
                self.n.inspect_native(base, time.monotonic() + 30)
            (root / "usr/local/lib/postgresql/plpgsql.so").write_bytes(elf(62))
            (bindir / "postgres").write_text("#!/bin/sh\nexit 0\n")
            with self.assertRaises(ValueError):
                self.n.inspect_native(base, time.monotonic() + 30)


if __name__ == "__main__":
    unittest.main()
