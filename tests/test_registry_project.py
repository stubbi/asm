"""Observe committed-project publication by the native assembly executable.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import unittest

import test_registry_v2_cli as client_fixture
from test_publish_cli import registry, source_files, elf


class RegistryProjectTests(unittest.TestCase):
    setUpClass = classmethod(client_fixture.RegistryV2CliTests.setUpClass.__func__)
    cli = client_fixture.RegistryV2CliTests.cli

    def setUp(self):
        client_fixture.RegistryV2PublicationTests.setUp(self)
        self.project_mode = True
        self.project = self.work / "project"
        self.project.mkdir(mode=0o700)
        self.expected = source_files()

    def git(self, *arguments, data=None):
        environment = {"HOME": str(self.work), "PATH": "/usr/bin:/bin", "LC_ALL": "C",
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                       "GIT_CONFIG_SYSTEM": "/dev/null"}
        stream = {"stdin": subprocess.DEVNULL} if data is None else {"input": data}
        return subprocess.check_output(["/usr/bin/git", "-c", "commit.gpgsign=false", "-c",
                                        "core.hooksPath=/dev/null", "-C", str(self.project), *arguments],
                                       **stream, stderr=subprocess.DEVNULL,
                                       env=environment, timeout=15).decode().strip()

    def commit(self, *, sha256=False, subtree="."):
        self.git("init", "-q", *(["--object-format=sha256"] if sha256 else []))
        root = self.project if subtree == "." else self.project / subtree
        root.mkdir(parents=True, exist_ok=True)
        for name, (data, mode) in self.expected.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(mode)
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-qm", "source fixture")
        return self.git("rev-parse", "HEAD")

    def publish_project(self, *extra, code=0, targets=("x86_64-linux",)):
        selections = [item for target in targets for item in ("--source-target", target)]
        return self.cli("publish", "--project", self.project, "--name", "owner/math",
                        "--owner-id", "1" * 32, "--summary", "Native publication fixture.",
                        "--license", "MIT", *selections,
                        "--credential-file", self.credential, "--api", self.api,
                        "--idempotency-key", "d" * 32, "--ca", self.ca, "--json", *extra, code=code)

    def test_committed_project_generates_canonical_manifest_archive_and_replays(self):
        commit = self.commit()
        (self.project / "src/math.s").write_bytes(b"dirty source must not enter the archive")
        (self.project / "untracked.txt").write_text("untracked")
        result = json.loads(self.publish_project().stdout)
        self.assertEqual(result["state"], "checking")
        value = json.loads(self.manifest.read_bytes())
        self.assertEqual(value["source"]["commit"], {"algorithm": "git-sha1", "digest": commit})
        self.assertEqual(value["name"], "owner/math")
        self.assertEqual(value["version"], "0.1.0")
        self.assertNotIn("repository", value["source"])
        self.assertEqual(registry.read_archive(self.source), {name: data for name, (data, _) in self.expected.items()})
        first_manifest, first_source = self.manifest.read_bytes(), self.source
        self.requests.clear()
        self.publish_project()
        self.assertEqual((self.manifest.read_bytes(), self.source), (first_manifest, first_source))
        self.assertEqual([method for method, _ in self.requests], ["POST", "GET"])

    def test_committed_dependencies_enter_the_signed_request_in_name_order(self):
        data, mode = self.expected["asm.toml"]
        self.expected["asm.toml"] = (data + b'\n[dependencies]\n"z/math" = "^2.0.0"\n"a/math" = ">=1.0.0,<2.0.0"\n', mode)
        self.commit()
        self.publish_project()
        value = json.loads(self.manifest.read_bytes())
        self.assertEqual(value["dependencies"], [
            {"name": "a/math", "requirement": ">=1.0.0,<2.0.0"},
            {"name": "z/math", "requirement": "^2.0.0"},
        ])
        self.assertEqual(registry.read_archive(self.source)["asm.toml"], self.expected["asm.toml"][0])

    def test_invalid_dependency_ranges_fail_before_credentials_or_network(self):
        data, mode = self.expected["asm.toml"]
        self.expected["asm.toml"] = (data + b'\n[dependencies]\n"other/math" = ">=1.0.0,invalid"\n', mode)
        self.commit()
        self.credential.unlink()
        result = self.publish_project(code=1)
        self.assertIn(b"project", result.stderr)
        self.assertEqual(self.requests, [])

    def test_duplicate_optional_or_feature_declarations_fail_before_credentials(self):
        data, mode = self.expected["asm.toml"]
        cases = [
            b'\n[dependencies]\n"other/math" = "1.0.0"\n"other/math" = "2.0.0"\n',
            b'\n[dependencies]\n"other/math" = { version = "1.0.0", optional = true }\n',
            b'\n[features]\ndefault = []\n',
        ]
        self.credential.unlink()
        for declaration in cases:
            with self.subTest(declaration=declaration):
                self.expected["asm.toml"] = (data + declaration, mode)
                self.commit()
                self.publish_project(code=1)
                self.assertEqual(self.requests, [])

    def test_exact_sha256_commit_subtree_and_descriptive_source_host(self):
        commit = self.commit(sha256=True, subtree="packages/math")
        self.publish_project("--commit", commit, "--source-path", "packages/math",
                             "--repository", "https://entire.com/example/math")
        value = json.loads(self.manifest.read_bytes())
        self.assertEqual(value["source"]["commit"], {"algorithm": "git-sha256", "digest": commit})
        self.assertEqual(value["source"]["path"], "packages/math")
        self.assertEqual(value["source"]["repository"], "https://entire.com/example/math")
        self.assertEqual(registry.read_archive(self.source), {name: data for name, (data, _) in self.expected.items()})

    def test_executable_is_snapshotted_without_building_or_executing(self):
        self.commit()
        executable = self.work / "candidate"
        data = elf()
        executable.write_bytes(data)
        digest = hashlib.sha256(data).hexdigest()
        self.publish_project("--executable", "x86_64-linux", executable)
        value = json.loads(self.manifest.read_bytes())
        declarations = {(item["kind"], item["sha256"], item["bytes"]) for item in value["artifacts"]}
        self.assertIn(("executable", digest, len(data)), declarations)
        self.assertEqual(executable.read_bytes(), data)

    def test_executable_only_selection_still_uploads_the_committed_source_archive(self):
        self.commit()
        executable = self.work / "candidate"
        executable.write_bytes(elf())
        self.publish_project("--executable", "x86_64-linux", executable, targets=())
        value = json.loads(self.manifest.read_bytes())
        self.assertEqual([item["kind"] for item in value["artifacts"]], ["executable"])
        self.assertEqual(len(self.project_sizes), 2)
        self.assertEqual(registry.read_archive(self.source), {name: data for name, (data, _) in self.expected.items()})

    def test_invalid_duplicate_missing_and_mixed_selections_fail_before_network(self):
        self.commit()
        for extra, targets in [((), ()), (("--source-target", "x86_64-linux"), ("x86_64-linux",)),
                               ((), ("x86_64-macos",)), (("--manifest", self.manifest), ("x86_64-linux",)),
                               (("--source-path", "packages/../math"), ("x86_64-linux",))]:
            with self.subTest(extra=extra, targets=targets):
                self.publish_project(*extra, targets=targets, code=2)
                self.assertEqual(self.requests, [])

    def test_explicit_commit_remains_pinned_after_head_changes(self):
        commit = self.commit()
        (self.project / "src/math.s").write_text("changed source")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "new head")
        self.assertNotEqual(self.git("rev-parse", "HEAD"), commit)
        self.publish_project("--commit", commit)
        self.assertEqual(json.loads(self.manifest.read_bytes())["source"]["commit"]["digest"], commit)
        self.assertEqual(registry.read_archive(self.source)["src/math.s"], self.expected["src/math.s"][0])

    def test_git_filters_hooks_and_ambient_configuration_never_run(self):
        self.expected[".gitattributes"] = (b"* filter=evil diff=evil export-subst\n", 0o644)
        self.expected["literal.txt"] = (b"$Format:%H$\n", 0o644)
        self.commit()
        marker = self.work / "git-helper-ran"
        helper = self.work / "git-helper"
        helper.write_text("#!/bin/sh\nprintf invoked > '" + str(marker) + "'\nexit 1\n")
        helper.chmod(0o700)
        for key in ("filter.evil.clean", "filter.evil.smudge", "filter.evil.process", "diff.evil.textconv", "core.fsmonitor"):
            self.git("config", key, str(helper))
        hooks = self.work / "hooks"
        hooks.mkdir()
        (hooks / "post-index-change").write_bytes(helper.read_bytes())
        (hooks / "post-index-change").chmod(0o700)
        self.git("config", "core.hooksPath", str(hooks))
        poisoned = self.work / "global.gitconfig"
        poisoned.write_text("[core]\n\tfsmonitor = " + str(helper) + "\n")
        self.environment.update(GIT_CONFIG_GLOBAL=str(poisoned), GIT_CONFIG_SYSTEM=str(poisoned),
                                GIT_DIR=str(self.work / "wrong-git"), GIT_NO_LAZY_FETCH="0",
                                GIT_ALLOW_PROTOCOL="ext", GIT_OBJECT_DIRECTORY=str(self.work / "wrong-objects"))
        self.publish_project()
        self.assertFalse(marker.exists())
        self.assertEqual(registry.read_archive(self.source), {name: data for name, (data, _) in self.expected.items()})

    def test_all_six_source_tuples_share_one_checked_archive(self):
        targets = ("x86_64-linux", "aarch64-linux", "riscv64-linux", "aarch64-macos",
                   "x86_64-windows", "aarch64-windows")
        manifest = '[package]\nname = "math"\nversion = "0.1.0"\n'
        for target in (*targets, "x86_64-macos"):
            path = "targets/" + target + ".s"
            manifest += f'\n[target.{target}]\nsource = "{path}"\n'
            self.expected[path] = (b"ret\n", 0o644)
        self.expected["asm.toml"] = (manifest.encode(), 0o644)
        self.commit()
        self.publish_project(targets=targets)
        value = json.loads(self.manifest.read_bytes())
        self.assertEqual(len(value["artifacts"]), 6)
        self.assertEqual(len(self.project_sizes), 1)
        self.assertTrue(all(item["sha256"] == self.digest and item["cpu_features"] == [] for item in value["artifacts"]))
        self.assertEqual([method for method, _ in self.requests], ["POST", "PUT", "GET"])

    def test_committed_excluded_cache_paths_are_not_packaged(self):
        self.expected["build/file with spaces"] = (b"excluded build data", 0o644)
        self.expected[".asm/key.pem"] = (b"excluded cache data", 0o644)
        self.commit()
        self.publish_project()
        self.assertEqual(set(registry.read_archive(self.source)), set(source_files()))

    def test_lock_dependencies_and_sensitive_or_linked_members_fail_before_credentials(self):
        variants = ["lock", "dependencies", "secret", "symlink"]
        for variant in variants:
            with self.subTest(variant=variant):
                if (self.project / ".git").exists():
                    import shutil
                    shutil.rmtree(self.project)
                    self.project.mkdir(mode=0o700)
                self.expected = source_files()
                if variant == "lock":
                    self.expected["asm.lock"] = (b"# asm-lock-v1\n", 0o644)
                elif variant == "dependencies":
                    data, mode = self.expected["asm.toml"]
                    self.expected["asm.toml"] = (data + b'\n[dependencies]\nname = "unsupported"\n', mode)
                elif variant == "secret":
                    self.expected["key.pem"] = (b"must not upload", 0o600)
                self.commit()
                if variant == "symlink":
                    (self.project / "linked").symlink_to("src/math.s")
                    self.git("add", "linked")
                    self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "linked fixture")
                credential = self.credential.read_bytes()
                self.credential.unlink()
                self.requests.clear()
                result = self.publish_project(code=1)
                self.assertIn(b"project", result.stderr)
                self.assertEqual(self.requests, [])
                self.credential.write_bytes(credential)
                self.credential.chmod(0o600)

    def test_replacement_objects_and_hostile_promisor_never_change_or_fetch_source(self):
        commit = self.commit()
        blob = self.git("rev-parse", commit + ":src/math.s")
        replacement = self.git("hash-object", "-w", "--stdin")
        self.git("replace", blob, replacement)
        self.publish_project("--commit", commit)
        self.assertEqual(registry.read_archive(self.source)["src/math.s"], self.expected["src/math.s"][0])
        self.git("replace", "-d", blob)
        marker = self.work / "remote-ran"
        helper = self.work / "remote-helper"
        helper.write_text("#!/bin/sh\nprintf invoked > '" + str(marker) + "'\nexit 1\n")
        helper.chmod(0o700)
        self.git("config", "remote.origin.promisor", "true")
        self.git("config", "remote.origin.url", "ext::" + str(helper))
        self.git("config", "protocol.ext.allow", "always")
        self.environment.update(GIT_NO_LAZY_FETCH="0", GIT_ALLOW_PROTOCOL="ext")
        (self.project / ".git/objects" / blob[:2] / blob[2:]).unlink()
        self.requests.clear()
        self.publish_project(code=1)
        self.assertFalse(marker.exists())
        self.assertEqual(self.requests, [])

    def test_credential_file_inside_the_packaged_subtree_is_never_archived(self):
        self.expected["grant.txt"] = (self.credential.read_bytes(), 0o644)
        self.commit()
        self.credential = self.project / "grant.txt"
        self.credential.chmod(0o600)
        result = self.publish_project(code=1)
        self.assertIn(b"credential", result.stderr)
        self.assertEqual(self.requests, [])

    def test_dot_project_uses_the_actual_directory_for_credential_refusal(self):
        self.expected["grant.txt"] = (self.credential.read_bytes(), 0o644)
        self.commit()
        self.credential = self.project / "grant.txt"
        self.credential.chmod(0o600)
        self.work = self.project
        self.project = Path(".")
        result = self.publish_project(code=1)
        self.assertIn(b"credential", result.stderr)
        self.assertEqual(self.requests, [])

    def test_filesystem_case_alias_cannot_hide_a_packaged_credential(self):
        self.expected["grant.txt"] = (self.credential.read_bytes(), 0o644)
        self.commit()
        self.credential = self.project / "grant.txt"
        self.credential.chmod(0o600)
        alias = self.project.with_name("PROJECT")
        if not alias.is_dir():
            self.skipTest("requires a case-insensitive filesystem alias")
        self.project = alias
        self.publish_project(code=1)
        self.assertEqual(self.requests, [])

    def test_executable_cannot_alias_the_credential_file(self):
        self.commit()
        self.publish_project("--executable", "x86_64-linux", self.credential, code=1)
        self.assertEqual(self.requests, [])

    def test_prepared_digest_object_cannot_alias_the_credential_file(self):
        self.project_mode = False
        token = self.credential.read_bytes()
        digest = hashlib.sha256(token).hexdigest()
        destination = self.objects / digest
        self.credential.rename(destination)
        self.credential = destination
        self.additional_objects[digest] = token
        publication = json.loads(self.manifest.read_bytes())
        publication["artifacts"].append({"isa": "x86_64", "os": "linux", "abi": "sysv-amd64",
                                          "cpu_features": [], "kind": "executable", "format": "elf",
                                          "sha256": digest, "bytes": len(token)})
        self.manifest.write_text(json.dumps(publication, sort_keys=True, indent=2) + "\n")
        client_fixture.RegistryV2PublicationTests.publish(self, code=1)
        self.assertEqual(self.requests, [])

    def test_wrong_task_reply_preserves_the_request_identity_and_recovery(self):
        self.commit()
        self.response_mode = "wrong-id"
        result = self.publish_project(code=1)
        self.assertEqual([method for method, _ in self.requests], ["POST"])
        self.assertIn(b"inspect", result.stderr)
        self.assertNotIn(b"preparation failed", result.stderr)
        self.assertEqual((self.project / "src/math.s").read_bytes(), self.expected["src/math.s"][0])
        self.assertEqual(self.credential.read_text(), self.token + "\n")

    def test_v2_manifest_limit_precedes_credential_read(self):
        data, mode = self.expected["asm.toml"]
        self.expected["asm.toml"] = (data + b"#" + b"x" * (8190 - len(data)), mode)
        self.commit()
        self.credential.unlink()
        result = self.publish_project(code=1)
        self.assertIn(b"project", result.stderr)
        self.assertEqual(self.requests, [])

    def test_v2_manifest_at_8190_bytes_is_supported(self):
        data, mode = self.expected["asm.toml"]
        self.expected["asm.toml"] = (data + b"#" + b"x" * (8189 - len(data)), mode)
        self.assertEqual(len(self.expected["asm.toml"][0]), 8190)
        self.commit()
        self.publish_project()
        self.assertEqual(registry.read_archive(self.source)["asm.toml"], self.expected["asm.toml"][0])

    def test_committed_subtree_keeps_a_sibling_credential_outside_the_archive(self):
        self.commit(subtree="packages/math")
        sibling = self.project / "grant.txt"
        sibling.write_bytes(self.credential.read_bytes())
        sibling.chmod(0o600)
        self.credential = sibling
        self.publish_project("--source-path", "packages/math")
        self.assertEqual(set(registry.read_archive(self.source)), set(self.expected))

    def test_repository_subdirectory_is_refused_without_sibling_disclosure(self):
        self.commit(subtree="packages/math")
        (self.project / "sibling-secret.txt").write_text("outside requested project")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "sibling fixture")
        self.project = self.project / "packages/math"
        result = self.publish_project(code=1)
        self.assertIn(b"repository root", result.stderr)
        self.assertEqual(self.requests, [])

    def test_ustar_split_and_normalized_headers_preserve_full_portable_path(self):
        import gzip
        import io
        import tarfile
        name = "p" * 141 + "/" + "n" * 98
        self.assertEqual(len(name), 240)
        self.expected[name] = (b"long path", 0o755)
        self.commit()
        self.publish_project()
        self.assertEqual(registry.read_archive(self.source)[name], b"long path")
        raw = gzip.decompress(self.source)
        self.assertEqual(len(raw), 1024 + sum(512 + (len(data) + 511) // 512 * 512 for data, _ in self.expected.values()))
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
            members = archive.getmembers()
            self.assertEqual([item.name for item in members], sorted(self.expected))
            for item in members:
                self.assertEqual((item.uid, item.gid, item.mtime, item.uname, item.gname), (0, 0, 0, "", ""))
                self.assertEqual(item.mode, self.expected[item.name][1])

    def test_unencodable_or_oversized_paths_and_case_collisions_fail_before_credentials(self):
        for names in [("n" * 101,), ("p" * 141 + "/" + "n" * 99,), ("case.s", "CASE.s")]:
            with self.subTest(names=names):
                import shutil
                shutil.rmtree(self.project)
                self.project.mkdir(mode=0o700)
                self.expected = source_files() | {name: (b"source", 0o644) for name in names}
                if len(names) == 2:
                    self.expected = source_files()
                self.commit()
                if len(names) == 2:
                    blob = self.git("hash-object", "-w", "--stdin", data=b"source")
                    self.git("update-index", "--index-info", data="".join(
                        f"100644 {blob}\t{name}\n" for name in names).encode())
                    self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "case fixture")
                previous = self.credential
                self.credential = self.work / "missing-credential"
                result = self.publish_project(code=1)
                self.assertIn(b"project", result.stderr)
                self.assertEqual(self.requests, [])
                self.credential = previous

    def test_full_tar_budget_and_file_count_fail_before_object_reader_or_credentials(self):
        self.commit()
        base_bytes = sum(len(data) for data, _ in self.expected.values())
        full = b"z" * (16 * 1024 * 1024)
        first = self.git("hash-object", "-w", "--stdin", data=full)
        last = self.git("hash-object", "-w", "--stdin", data=full[:-base_bytes])
        entries = "".join(f"100644 {first}\tlarge-{index}\n" for index in range(3))
        entries += f"100644 {last}\tlarge-3\n"
        self.git("update-index", "--index-info", data=entries.encode())
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "byte bound fixture")
        credential = self.credential.read_bytes()
        self.credential.unlink()
        result = self.publish_project(code=1)
        self.assertIn(b"project", result.stderr)
        self.assertEqual(self.requests, [])
        for index in range(4):
            self.git("update-index", "--force-remove", f"large-{index}")
        empty = self.git("hash-object", "-w", "--stdin", data=b"")
        self.git("update-index", "--index-info", data="".join(
            f"100644 {empty}\tempty-{index:04d}\n" for index in range(4093)).encode())
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "entry bound fixture")
        result = self.publish_project(code=1)
        self.assertIn(b"project", result.stderr)
        self.assertEqual(self.requests, [])
        self.credential.write_bytes(credential)
        self.credential.chmod(0o600)
