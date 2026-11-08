"""Native ARM project publication, installation, and separate fixture execution.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import test_registry_v2_cli as fixtures


@unittest.skipUnless(platform.system() in ("Darwin", "Linux") and platform.machine() in ("arm64", "aarch64"),
                     "Requires native Linux ARM or macOS ARM")
class NativeArmRegistryV2Tests(unittest.TestCase):
    def test_second_mirror_install_then_explicit_native_execution(self):
        if not os.environ.get("ASM_REGISTRY_TEST_BINARY"):
            self.skipTest("Set ASM_REGISTRY_TEST_BINARY for the optional native V2 gate")
        fixtures.RegistryV2DistributionTests.setUpClass()
        case = fixtures.RegistryV2DistributionTests("test_real_tuf_source_fetch_and_ordered_mirror_failover")
        case.setUp()
        self.addCleanup(case.doCleanups)
        marker = case.work / "explicit-execution"
        source = case.work / "visible-output.s"
        target = "aarch64-macos" if platform.system() == "Darwin" else "aarch64-linux"
        assembly = '''.text
.global _main
_main:
    stp x29, x30, [sp, #-16]!
    adrp x0, marker@PAGE
    add x0, x0, marker@PAGEOFF
    mov w1, #384
    bl _creat
    cmn w0, #1
    b.eq failed
    bl _close
    mov x0, #1
    adrp x1, message@PAGE
    add x1, x1, message@PAGEOFF
    mov x2, #14
    bl _write
    mov w0, #0
    ldp x29, x30, [sp], #16
    ret
failed:
    mov w0, #5
    ldp x29, x30, [sp], #16
    ret
.data
message: .ascii "native-v2-arm\\n"
'''
        if target == "aarch64-linux":
            assembly = '''.text
.global _start
_start:
    mov x0, #-100
    adrp x1, marker
    add x1, x1, :lo12:marker
    mov x2, #193
    mov x3, #384
    mov x8, #56
    svc #0
    cmp x0, #0
    b.lt failed
    mov x8, #57
    svc #0
    mov x0, #1
    adrp x1, message
    add x1, x1, :lo12:message
    mov x2, #14
    mov x8, #64
    svc #0
    mov x0, #0
    b finish
failed:
    mov x0, #5
finish:
    mov x8, #93
    svc #0
.data
message: .ascii "native-v2-arm\\n"
'''
        source.write_text(assembly + "marker: .asciz " + json.dumps(str(marker)) + "\n")
        executable = case.work / "visible-output"
        if target == "aarch64-macos":
            case.tool("/usr/bin/clang", "-arch", "arm64", "-mmacosx-version-min=15.0",
                      "-Wl,-no_uuid", "-o", executable, source)
            case.tool("/usr/bin/codesign", "--verify", "--strict", executable)
        else:
            obj = source.with_suffix(".o")
            case.tool("/usr/bin/as", "--fatal-warnings", "-o", obj, source)
            case.tool("/usr/bin/ld", "-z", "noexecstack", "-z", "relro", "-z", "now",
                      "--build-id=none", "-o", executable, obj)
        from test_publish_cli import registry, source_files
        files = source_files(target=target)
        files["src/math.s"] = (source.read_bytes(), 0o644)
        files["LICENSE"] = ((ROOT / "LICENSE").read_bytes(), 0o644)
        candidate = executable.read_bytes()
        candidate_sha = hashlib.sha256(candidate).hexdigest()
        from test_registry_project import RegistryProjectTests
        RegistryProjectTests.setUpClass()
        publisher = RegistryProjectTests("test_executable_is_snapshotted_without_building_or_executing")
        publisher.setUp()
        self.addCleanup(publisher.doCleanups)
        publisher.expected = files
        commit = publisher.commit()
        # Compilation above is deliberate fixture preparation. Publication
        # receives committed source and an existing executable, with no hook.
        result = publisher.cli("publish", "--project", publisher.project,
            "--name", "owner/math", "--owner-id", "1" * 32,
            "--summary", "Native ARM project fixture.", "--license", "AGPL-3.0-or-later",
            "--source-target", target, "--executable", target, executable,
            "--credential-file", publisher.credential, "--api", publisher.api,
            "--idempotency-key", "d" * 32, "--ca", publisher.ca, "--json")
        self.assertEqual(json.loads(result.stdout)["state"], "checking")
        case.publication = json.loads(publisher.manifest.read_bytes())
        self.assertEqual(case.publication["source"]["commit"], {"algorithm": "git-sha1", "digest": commit})
        case.source = publisher.source
        case.digest = hashlib.sha256(case.source).hexdigest()
        self.assertEqual(registry.read_archive(case.source), {name: data for name, (data, _) in files.items()})
        self.assertIn(candidate_sha, publisher.additional_received)
        self.assertFalse((publisher.project / "build").exists())
        self.assertFalse(marker.exists(), "Publication executed the fixture program")
        case.manifest.write_bytes(publisher.manifest.read_bytes())
        case.sign(2, fresh=True)
        (case.delivery / "blobs/sha256" / candidate_sha).write_bytes(candidate)
        case.fetch(install=True, target=target, kind="executable",
                   mirrors=[case.api + "/unavailable", case.api])
        self.assertEqual(case.destination.read_bytes(), candidate)
        self.assertTrue(any(path.startswith("/unavailable/") for _, path in case.requests))
        self.assertFalse(marker.exists(), "Installation executed the fixture program")
        # Installation returns before this deliberate execution. Neither the
        # publisher nor the install command receives an execution hook.
        result = subprocess.run([str(case.destination)], capture_output=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"native-v2-arm\n", b""))
        self.assertTrue(marker.is_file())
