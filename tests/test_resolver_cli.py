"""Resolve bounded source graphs through the native public CLI.

Archives and indexes are local fixtures. Package selection and verification stay
inside the assembly executable. No package code runs during resolution.
SPDX-License-Identifier: AGPL-3.0-or-later
"""

import gzip
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

from host import IS_ARM64, IS_RISCV64, IS_MACOS, OTHER_TARGET, TARGET, program

ROOT = Path(__file__).resolve().parents[1]
ASM = ROOT / "build/asm"


def dependency(value):
    if isinstance(value, str):
        return json.dumps(value)
    return "{ " + ", ".join(f"{key} = {json.dumps(item)}" for key, item in value.items()) + " }"


def manifest(name, version="1.0.0", *, dependencies=None, features=None, target=TARGET):
    text = (f'[package]\nname = "{name}"\nversion = "{version}"\n\n'
            f'[build]\nsource = "src/{name}.s"\ntarget = "{target}"\n\n'
            '[resolution]\nschema = "1"\n\n[dependencies]\n')
    text += "".join(f"{json.dumps(key)} = {dependency(value)}\n"
                    for key, value in (dependencies or {}).items())
    text += "\n[features]\n"
    return text + "".join(f"{key} = {json.dumps(value)}\n" for key, value in (features or {}).items())


class ResolverCliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="resolver-", dir=ROOT / "build")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.project = self.work / "project with spaces"
        self.artifacts = self.work / "artifact directory"
        self.artifacts.mkdir()
        self.index = self.work / "index.tsv"
        self.rows = []
        self.cli("new", self.project, cwd=self.work)

    def cli(self, *args, cwd=None, code=0, timeout=15):
        result = subprocess.run([str(ASM), *map(str, args)], cwd=cwd or self.project,
                                capture_output=True, text=True, timeout=timeout)
        self.assertEqual(result.returncode, code, (result.args, result.stdout, result.stderr))
        self.assertEqual(list((cwd or self.project).glob(".asm-registry-*")), [])
        return result

    def root_manifest(self, dependencies, *, features=None, project=None):
        path = (project or self.project) / "asm.toml"
        text = manifest("root", dependencies=dependencies, features=features)
        path.write_text(text.replace('source = "src/root.s"', 'source = "src/main.s"'))

    def package(self, name, version="1.0.0", *, dependencies=None, features=None,
                target=TARGET, source=None, manifest_text=None):
        symbol = "asm_value_" + name.replace("-", "_")
        if source is None and IS_RISCV64:
            source = f".text\n{symbol}:\n    li a0, 7\n    ret\n"
        source = source or (f".text\n{symbol}:\n    mov x0, #7\n    ret\n" if IS_ARM64 else
                            f".intel_syntax noprefix\n.text\n{symbol}:\n    mov eax, 7\n    ret\n")
        files = {
            "LICENSE": b"Fixture source under MIT.\n",
            "README.md": b"Native dependency resolver fixture.\n",
            "asm.toml": (manifest_text or manifest(name, version, dependencies=dependencies,
                                                   features=features, target=target)).encode(),
            f"src/{name}.s": source.encode(),
        }
        payload = io.BytesIO()
        with tarfile.open(fileobj=payload, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for path, data in files.items():
                member = tarfile.TarInfo(path)
                member.mode = 0o644
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        data = gzip.compress(payload.getvalue(), mtime=0)
        digest = hashlib.sha256(data).hexdigest()
        path = self.artifacts / f"{digest}.tar.gz"
        path.write_bytes(data)
        row = "\t".join([f"stubbi/{name}", version, target, "source", digest,
                         f"https://github.com/stubbi/asm/releases/download/fixtures/{name}-{version}.tar.gz",
                         str(len(data)), "Dependency resolver fixture"]) + "\n"
        self.rows.append(row)
        return path

    def resolve(self, *args, code=0, cwd=None, timeout=15):
        self.index.write_text("# asm-registry-v1\n" + "".join(self.rows))
        return self.cli("resolve", "--index", self.index, "--artifacts", self.artifacts,
                        *args, code=code, cwd=cwd, timeout=timeout)

    def selections(self, project=None):
        lock = ((project or self.project) / "asm.lock").read_text()
        self.assertTrue(lock.startswith("# asm-lock-v3\n"), lock)
        entries = [line.split("\t") for line in lock.splitlines() if line.startswith("stubbi/")]
        self.assertEqual(len(entries), len({fields[0] for fields in entries}), lock)
        return {fields[0]: fields[1] for fields in entries}

    def snapshot(self):
        return {path.relative_to(self.project): path.read_bytes()
                for path in self.project.rglob("*") if path.is_file()}

    def assert_preserved(self, previous):
        for relative, data in previous.items():
            with self.subTest(preserved=relative):
                self.assertEqual((self.project / relative).read_bytes(), data)

    def consumer(self, name, version="1.0.0", *, project=None):
        symbol = "asm_value_" + name.replace("-", "_")
        if IS_RISCV64:
            body = f"call {symbol}\naddi a0, a0, -7\nli a7, 93\necall"
        elif IS_ARM64:
            finish = "bl _exit" if IS_MACOS else "mov x8, #93\nsvc #0"
            body = f"bl {symbol}\nsub x0, x0, #7\n{finish}"
        else:
            body = f"call {symbol}\nmov edi, eax\nsub edi, 7\nmov eax, 60\nsyscall"
        (project or self.project).joinpath("src/main.s").write_text(
            f'.include "stubbi/{name}/{version}/{TARGET}/src/{name}.s"\n' + program(body))

    def test_transitive_graph_builds_and_runs_from_the_exact_offline_lock(self):
        self.package("beta")
        source = (f'.include "stubbi/beta/1.0.0/{TARGET}/src/beta.s"\n'
                  '.text\nasm_value_alpha:\n    ' + ("j" if IS_RISCV64 else "b" if IS_ARM64 else "jmp") + ' asm_value_beta\n')
        self.package("alpha", dependencies={"stubbi/beta": "1.0.0"}, source=source)
        self.root_manifest({"stubbi/alpha": "^1.0.0"})
        self.resolve()
        self.assertEqual(self.selections(), {"stubbi/alpha": "1.0.0", "stubbi/beta": "1.0.0"})
        self.consumer("alpha")
        lock = (self.project / "asm.lock").read_bytes()
        self.index.unlink()
        shutil.rmtree(self.artifacts)
        self.cli("lock")
        self.cli("run", "--locked")
        self.assertEqual((self.project / "asm.lock").read_bytes(), lock)

    def test_unresolved_manifest_requires_resolution_before_a_normal_build(self):
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        self.cli("build", code=1)
        self.assertFalse((self.project / "build/app").exists())

    def test_backtracking_finds_a_shared_version_instead_of_greedily_failing(self):
        self.package("common", "1.5.0")
        self.package("common", "2.0.0")
        self.package("alpha", "2.0.0", dependencies={"stubbi/common": "^2.0.0"})
        self.package("alpha", "1.0.0", dependencies={"stubbi/common": "^1.0.0"})
        self.package("beta", dependencies={"stubbi/common": "^1.0.0"})
        self.root_manifest({"stubbi/alpha": ">=1.0.0,<3.0.0", "stubbi/beta": "^1.0.0"})
        self.resolve()
        self.assertEqual(self.selections(), {"stubbi/alpha": "1.0.0", "stubbi/beta": "1.0.0",
                                            "stubbi/common": "1.5.0"})

    def test_existing_archives_without_resolution_metadata_are_valid_leaves(self):
        text = manifest("alpha").split("[resolution]", 1)[0]
        self.package("alpha", manifest_text=text)
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        self.resolve()
        self.assertEqual(self.selections(), {"stubbi/alpha": "1.0.0"})
        self.consumer("alpha")
        self.cli("run", "--locked")

    def test_numeric_ranges_choose_the_highest_matching_native_version(self):
        for version in ("0.0.2", "0.0.3", "0.2.1", "0.2.9", "0.3.0", "1.2.3", "1.2.9",
                        "1.3.0", "2.0.0", "2.9.9", "2.10.0"):
            self.package("alpha", version)
        self.package("alpha", "3.0.0", target=OTHER_TARGET)
        cases = [("1.2.3", "1.2.3"), ("*", "2.10.0"), ("^1.2.3", "1.3.0"),
                 ("~1.2.3", "1.2.9"), ("^0.2.1", "0.2.9"), ("^0.0.2", "0.0.2"),
                 (">=1.2.3,<1.3.0", "1.2.9"), (">1.2.3,<=1.2.9", "1.2.9"),
                 ("=2.9.9", "2.9.9"), (">=2.9.9", "2.10.0")]
        for number, (requirement, expected) in enumerate(cases):
            with self.subTest(requirement=requirement):
                project = self.work / f"range-{number}"
                self.cli("new", project)
                self.root_manifest({"stubbi/alpha": requirement}, project=project)
                self.resolve(cwd=project)
                self.assertEqual(self.selections(project), {"stubbi/alpha": expected})

    def test_feature_requests_union_across_a_diamond(self):
        self.package("left-extra")
        self.package("right-extra")
        self.package("common", dependencies={
            "stubbi/left-extra": {"version": "1.0.0", "optional": True},
            "stubbi/right-extra": {"version": "1.0.0", "optional": True},
            "stubbi/default-extra": {"version": "1.0.0", "optional": True},
        }, features={"left": ["dep:stubbi/left-extra"], "right": ["dep:stubbi/right-extra"],
                     "default": ["dep:stubbi/default-extra"]})
        self.package("alpha", dependencies={"stubbi/common": {
            "version": "^1.0.0", "features": ["left"], "default-features": False}})
        self.package("beta", dependencies={"stubbi/common": {
            "version": "^1.0.0", "features": ["right"], "default-features": False}})
        self.root_manifest({"stubbi/alpha": "1.0.0", "stubbi/beta": "1.0.0"})
        self.resolve()
        self.assertEqual(self.selections(), {"stubbi/alpha": "1.0.0", "stubbi/beta": "1.0.0",
                                            "stubbi/common": "1.0.0", "stubbi/left-extra": "1.0.0",
                                            "stubbi/right-extra": "1.0.0"})
        self.cli("lock")

    def test_a_late_feature_request_can_backtrack_to_a_version_that_provides_it(self):
        self.package("extra")
        self.package("alpha", "1.0.0",
                     dependencies={"stubbi/extra": {"version": "1.0.0", "optional": True}},
                     features={"enabled": ["dep:stubbi/extra"]})
        self.package("alpha", "2.0.0")
        self.package("beta", dependencies={"stubbi/alpha": {"version": "*", "features": ["enabled"]}})
        self.root_manifest({"stubbi/alpha": "*", "stubbi/beta": "1.0.0"})
        self.resolve()
        self.assertEqual(self.selections(), {"stubbi/alpha": "1.0.0", "stubbi/beta": "1.0.0",
                                            "stubbi/extra": "1.0.0"})

    def test_root_defaults_and_explicit_features_enable_only_requested_optional_edges(self):
        self.package("alpha")
        self.package("beta")
        self.root_manifest({
            "stubbi/alpha": {"version": "1.0.0", "optional": True},
            "stubbi/beta": {"version": "1.0.0", "optional": True},
            "stubbi/unavailable": {"version": "1.0.0", "optional": True},
        }, features={"default": ["use-alpha"], "use-alpha": ["dep:stubbi/alpha"],
                     "use-beta": ["dep:stubbi/beta"]})
        self.resolve()
        self.assertEqual(self.selections(), {"stubbi/alpha": "1.0.0"})
        self.resolve("--no-default-features")
        self.assertEqual(self.selections(), {})
        self.resolve("--no-default-features", "--features", "use-alpha,use-beta")
        self.assertEqual(self.selections(), {"stubbi/alpha": "1.0.0", "stubbi/beta": "1.0.0"})
        self.cli("lock")

    def test_dependency_defaults_and_forwarded_features_activate_transitive_edges(self):
        self.package("extra")
        self.package("common", dependencies={"stubbi/extra": {"version": "1.0.0", "optional": True}},
                     features={"enabled": ["dep:stubbi/extra"], "default": ["enabled"]})
        self.root_manifest({"stubbi/common": "1.0.0"})
        self.resolve()
        self.assertEqual(self.selections(), {"stubbi/common": "1.0.0", "stubbi/extra": "1.0.0"})
        self.root_manifest({"stubbi/common": {"version": "1.0.0", "default-features": False}},
                           features={"forward": ["stubbi/common/enabled"]})
        self.resolve("--features", "forward")
        self.assertEqual(self.selections(), {"stubbi/common": "1.0.0", "stubbi/extra": "1.0.0"})

    def test_conflicting_requirements_report_the_package_and_preserve_the_previous_graph(self):
        self.package("common", "1.0.0")
        self.package("common", "2.0.0")
        self.package("alpha", dependencies={"stubbi/common": "^1.0.0"})
        self.package("beta", dependencies={"stubbi/common": "^2.0.0"})
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        self.resolve()
        self.root_manifest({"stubbi/alpha": "1.0.0", "stubbi/beta": "1.0.0"})
        before = self.snapshot()
        result = self.resolve(code=1)
        self.assertIn("stubbi/common", result.stderr)
        self.assertRegex(result.stderr, r"\^[12]\.0\.0")
        self.assertIn("no version", result.stderr.lower())
        self.assert_preserved(before)

    def test_unsupported_transitive_target_does_not_write_a_lock(self):
        self.package("alpha", "2.0.0")
        self.package("beta", target=OTHER_TARGET)
        self.package("alpha", dependencies={"stubbi/beta": "1.0.0"})
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        result = self.resolve(code=1)
        self.assertIn("stubbi/beta", result.stderr)
        self.assertFalse((self.project / "asm.lock").exists())

    def test_dependency_cycle_fails_without_changing_the_manifest(self):
        self.package("alpha", dependencies={"stubbi/beta": "1.0.0"})
        self.package("beta", dependencies={"stubbi/alpha": "1.0.0"})
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        before = (self.project / "asm.toml").read_bytes()
        self.resolve(code=1)
        self.assertEqual((self.project / "asm.toml").read_bytes(), before)
        self.assertFalse((self.project / "asm.lock").exists())

    def test_unknown_feature_references_and_feature_cycles_are_rejected(self):
        self.package("alpha")
        cases = [(None, ("--features", "missing")), ({"default": ["missing"]}, ()),
                 ({"default": ["dep:stubbi/missing"]}, ()),
                 ({"default": ["stubbi/alpha/missing"]}, ()),
                 ({"default": ["loop"], "loop": ["default"]}, ())]
        for features, options in cases:
            with self.subTest(features=features, options=options):
                self.root_manifest({"stubbi/alpha": "1.0.0"}, features=features)
                before = (self.project / "asm.toml").read_bytes()
                self.resolve(*options, code=1)
                self.assertEqual((self.project / "asm.toml").read_bytes(), before)
                self.assertFalse((self.project / "asm.lock").exists())

    def test_enabled_features_can_expose_an_unsatisfied_dependency_constraint(self):
        self.package("common", "1.0.0")
        self.package("common", "2.0.0")
        self.package("alpha", dependencies={"stubbi/common": "^1.0.0"})
        self.package("beta", dependencies={"stubbi/common": "^2.0.0"})
        self.root_manifest({"stubbi/alpha": "1.0.0",
                            "stubbi/beta": {"version": "1.0.0", "optional": True}},
                           features={"extra": ["dep:stubbi/beta"]})
        self.resolve()
        before = self.snapshot()
        result = self.resolve("--features", "extra", code=1)
        self.assertIn("stubbi/common", result.stderr)
        self.assertRegex(result.stderr, r"\^[12]\.0\.0")
        self.assertIn("no version", result.stderr.lower())
        self.assert_preserved(before)

    def test_malformed_transitive_manifest_is_rejected_before_a_lock_is_written(self):
        text = manifest("beta").replace('schema = "1"', 'schema = "1"\nschema = "1"')
        self.package("beta", manifest_text=text)
        self.package("alpha", dependencies={"stubbi/beta": "1.0.0"})
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        before = (self.project / "asm.toml").read_bytes()
        self.resolve(code=1)
        self.assertEqual((self.project / "asm.toml").read_bytes(), before)
        self.assertFalse((self.project / "asm.lock").exists())

    def test_a_matching_digest_does_not_allow_a_malformed_source_archive(self):
        artifact = self.package("alpha")
        artifact.unlink()
        data = gzip.compress(b"not a tar archive", mtime=0)
        digest = hashlib.sha256(data).hexdigest()
        (self.artifacts / f"{digest}.tar.gz").write_bytes(data)
        fields = self.rows[-1].split("\t")
        fields[4], fields[6] = digest, str(len(data))
        self.rows[-1] = "\t".join(fields)
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        self.resolve(code=1)
        self.assertFalse((self.project / "asm.lock").exists())

    def test_malformed_and_excessive_ranges_are_rejected_before_fetching(self):
        invalid = ["1", "1.2", "01.2.3", "1.2.3-beta", "1.2.3+build", "1.2.x",
                   "^1", "1.0.0 || 2.0.0", ">=1.0.0,", ">=1.0.0,,<2.0.0",
                   ">=2147483648.0.0", ",".join([">=1.0.0"] * 9), " " * 129 + "*"]
        for requirement in invalid:
            with self.subTest(requirement=requirement):
                self.root_manifest({"stubbi/alpha": requirement})
                self.resolve(code=1)
                self.assertFalse((self.project / "asm.lock").exists())

    def test_duplicate_fields_and_manifest_limits_are_rejected(self):
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        normal = (self.project / "asm.toml").read_text()
        candidates = [normal.replace('schema = "1"', 'schema = "1"\nschema = "1"'),
                      normal.replace('"stubbi/alpha" = "1.0.0"',
                                     '"stubbi/alpha" = "1.0.0"\n"stubbi/alpha" = "2.0.0"'),
                      manifest("root", dependencies={f"stubbi/pkg-{n}": "1.0.0" for n in range(65)}),
                      manifest("root", features={f"feature-{n}": [] for n in range(65)}),
                      normal + "#" + "x" * 8190 + "\n"]
        for text in candidates:
            with self.subTest(length=len(text), suffix=text[-100:]):
                (self.project / "asm.toml").write_text(text)
                self.resolve(code=1)
                self.assertFalse((self.project / "asm.lock").exists())

    def test_more_than_128_selected_packages_fails_within_the_command_deadline(self):
        for number in range(129):
            dependencies = {f"stubbi/pkg-{number + 1}": "1.0.0"} if number < 128 else {}
            self.package(f"pkg-{number}", dependencies=dependencies)
        self.root_manifest({"stubbi/pkg-0": "1.0.0"})
        self.resolve(code=1, timeout=30)
        self.assertFalse((self.project / "asm.lock").exists())

    def test_candidate_inspection_limit_reports_exhaustion_instead_of_a_false_conflict(self):
        self.package("alpha", "1.0.0")
        for patch in range(1, 257):
            self.package("alpha", f"1.0.{patch}", dependencies={"stubbi/unavailable": "1.0.0"})
        self.root_manifest({"stubbi/alpha": "^1.0.0"})
        result = self.resolve(code=1, timeout=60)
        self.assertRegex(result.stderr.lower(), r"limit|budget|exhaust")
        self.assertFalse((self.project / "asm.lock").exists())

    def test_corrupt_new_artifact_preserves_the_lock_cache_and_output(self):
        self.package("alpha")
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        self.resolve()
        self.consumer("alpha")
        self.cli("build", "--locked")
        artifact = self.package("alpha", "2.0.0")
        data = bytearray(artifact.read_bytes())
        data[-1] ^= 1
        artifact.write_bytes(data)
        self.root_manifest({"stubbi/alpha": "*"})
        before = self.snapshot()
        self.resolve(code=1)
        self.assert_preserved(before)

    def test_resolution_refuses_to_overwrite_existing_source_cache_edits(self):
        self.package("alpha")
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        self.resolve()
        source = self.project / f".asm/packages/stubbi/alpha/1.0.0/{TARGET}/src/alpha.s"
        source.write_bytes(source.read_bytes() + b"\n# retained user edit\n")
        before = self.snapshot()
        self.resolve(code=1)
        self.assert_preserved(before)

    def test_missing_offline_artifact_preserves_existing_project_files(self):
        self.package("alpha")
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        self.resolve()
        artifact = self.package("alpha", "2.0.0")
        artifact.unlink()
        self.root_manifest({"stubbi/alpha": "*"})
        before = self.snapshot()
        self.resolve(code=1)
        self.assert_preserved(before)

    def test_offline_artifact_symlink_is_refused_without_changing_its_destination(self):
        artifact = self.package("alpha")
        destination = self.work / "outside artifact"
        artifact.rename(destination)
        artifact.symlink_to(destination)
        before = destination.read_bytes()
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        self.resolve(code=1)
        self.assertTrue(artifact.is_symlink())
        self.assertEqual(destination.read_bytes(), before)
        self.assertFalse((self.project / "asm.lock").exists())

    def test_network_failure_preserves_the_previous_lock_and_output(self):
        self.package("alpha")
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        self.resolve()
        origin = "https://127.0.0.1:9/index.tsv"
        lock = self.project / "asm.lock"
        previous = lock.read_bytes()
        self.assertIn(b"# registry local\n", previous)
        lock.write_bytes(previous.replace(b"# registry local\n", f"# registry {origin}\n".encode(), 1))
        self.consumer("alpha")
        self.cli("build", "--locked")
        before = self.snapshot()
        result = self.cli("resolve", "--registry", origin, code=1)
        self.assertIn("download", result.stderr.lower())
        self.assert_preserved(before)

    def test_lock_rows_are_deterministic_when_index_order_changes(self):
        self.package("beta", "1.0.0")
        self.package("alpha", "1.0.0", dependencies={"stubbi/beta": "*"})
        self.package("beta", "2.0.0")
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        self.resolve()
        before = (self.project / "asm.lock").read_bytes()
        self.rows.reverse()
        other = self.work / "independent project"
        self.cli("new", other)
        self.root_manifest({"stubbi/alpha": "1.0.0"}, project=other)
        self.resolve(cwd=other)
        self.assertEqual((other / "asm.lock").read_bytes(), before)
        self.resolve()
        self.assertEqual((self.project / "asm.lock").read_bytes(), before)

    def test_candidate_defaults_do_not_exhaust_explicit_feature_requests(self):
        names = [f"feature{number:02d}" for number in range(64)]
        self.package("alpha", "2.0.0", features={"default": [], **{name: [] for name in names[:-1]}})
        self.package("alpha", "1.0.0", features={name: [] for name in names})
        self.root_manifest({"stubbi/alpha": {"version": "*", "features": names}})
        self.resolve()
        self.assertEqual(self.selections(), {"stubbi/alpha": "1.0.0"})

    def test_changed_root_requirements_and_incomplete_lock_fail_before_build(self):
        self.package("beta")
        self.package("alpha", dependencies={"stubbi/beta": "1.0.0"})
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        self.resolve()
        self.consumer("alpha")
        self.cli("build", "--locked")
        output = (self.project / "build/app").read_bytes()
        original_manifest = (self.project / "asm.toml").read_bytes()
        original_lock = (self.project / "asm.lock").read_bytes()
        self.root_manifest({"stubbi/alpha": "2.0.0"})
        self.cli("build", "--locked", code=1)
        (self.project / "asm.toml").write_bytes(original_manifest)
        (self.project / "asm.lock").write_bytes(b"\n".join(
            line for line in original_lock.split(b"\n") if not line.startswith(b"stubbi/beta\t")))
        self.cli("build", "--locked", code=1)
        self.assertEqual((self.project / "build/app").read_bytes(), output)

    def test_sync_restores_the_exact_transitive_graph_without_an_index(self):
        self.package("beta")
        self.package("alpha", dependencies={"stubbi/beta": "1.0.0"})
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        self.resolve()
        clone = self.work / "fresh clone"
        self.cli("new", clone)
        shutil.copyfile(self.project / "asm.toml", clone / "asm.toml")
        shutil.copyfile(self.project / "asm.lock", clone / "asm.lock")
        self.consumer("alpha", project=clone)
        self.index.unlink()
        self.cli("build", "--locked", cwd=clone, code=1)
        self.cli("sync", "--artifacts", self.artifacts, cwd=clone)
        self.cli("run", "--locked", cwd=clone)
        self.assertEqual((clone / "asm.lock").read_bytes(), (self.project / "asm.lock").read_bytes())

    def test_graph_resolution_refuses_a_foreign_recipe_before_file_changes(self):
        self.root_manifest({})
        path = self.project / "asm.toml"
        text = path.read_text().replace('[build]\n', f'[target.{TARGET}]\n')
        text = text.replace(f'target = "{TARGET}"\n', '')
        text += f'\n[target.{OTHER_TARGET}]\nsource = "src/main.s"\n'
        path.write_text(text)
        before = self.snapshot()
        result = self.resolve("--target", OTHER_TARGET, code=2)
        self.assertIn("native host target", result.stderr)
        self.assert_preserved(before)
        self.assertFalse((self.project / "asm.lock").exists())

    def test_graph_commands_reject_exact_v2_locks_without_changing_files(self):
        self.package("alpha")
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        lock = self.project / "asm.lock"
        lock.write_text("# asm-lock-v2\n# registry local\n" + "".join(self.rows))
        before = self.snapshot()
        for command in ("resolve", "lock", "sync"):
            with self.subTest(command=command):
                if command == "resolve":
                    self.resolve(code=1)
                else:
                    self.cli(command, code=1)
                self.assert_preserved(before)
        self.assertFalse((self.project / ".asm/packages").exists())

    def test_legacy_commands_reject_graph_v3_locks_without_flattening_them(self):
        self.package("alpha")
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        self.resolve()
        self.assertTrue((self.project / "asm.lock").read_text().startswith("# asm-lock-v3\n"))
        path = self.project / "asm.toml"
        path.write_text(path.read_text().split("[resolution]", 1)[0])
        before = self.snapshot()
        for arguments in (("build", "--locked"), ("lock",), ("sync",), ("remove", "stubbi/alpha")):
            with self.subTest(arguments=arguments):
                self.cli(*arguments, code=1)
                self.assert_preserved(before)
        self.assertFalse((self.project / "build/app").exists())

    def test_legacy_mutators_refuse_a_resolution_manifest_and_preserve_its_lock(self):
        artifact = self.package("alpha")
        self.root_manifest({"stubbi/alpha": "1.0.0"})
        self.resolve()
        before = self.snapshot()
        for command in ("add", "update", "remove"):
            with self.subTest(command=command):
                args = (["stubbi/alpha"] if command == "remove" else
                        ["stubbi/alpha@1.0.0", "--index", self.index, "--artifact", artifact])
                self.cli(command, *args, code=1)
                self.assert_preserved(before)


if __name__ == "__main__":
    unittest.main()
