"""Reject incompatible runtime libraries before configuration or listeners.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest


BINARY = Path(os.environ["ASM_PROTO_BINARY"])
BUILD = Path(os.environ.get("ASM_PROTO_BUILD_DIR", Path(__file__).resolve().parent / "build"))


def runtime_sources(machine):
    """Assembly interposers use the selected host's native C calling convention."""
    if machine == "x86_64":
        http = 'lea version(%rip), %rax\nret\n'
        database = 'mov $160014, %eax\nret\n'
    elif machine == "aarch64":
        http = 'adrp x0, version\nadd x0, x0, :lo12:version\nret\n'
        database = 'mov w0, #28942\nmovk w0, #2, lsl #16\nret\n'
    elif machine == "riscv64":
        http = 'lla a0, version\nret\n'
        database = 'li a0, 160014\nret\n'
    else:
        raise ValueError(f"Unsupported runtime version test host: {machine}.")
    candidates = {"http": '.global MHD_get_version\nMHD_get_version:\n' + http
                  + '.section .rodata\nversion: .asciz "1.0.2"\n',
                  "database": '.global PQlibVersion\nPQlibVersion:\n' + database}
    target_flags = ["-march=rv64gc", "-mabi=lp64d"] if machine == "riscv64" else []
    stack_note = '.section .note.GNU-stack,"",%progbits\n' if machine == "aarch64" else '.section .note.GNU-stack,"",@progbits\n'
    return candidates, target_flags, stack_note


class RuntimeVersionTests(unittest.TestCase):
    def test_wrong_http_or_database_runtime_fails_before_configuration(self):
        if platform.system() != "Linux":
            self.fail("Runtime version checks require a native Linux host.")
        candidates, target_flags, stack_note = runtime_sources(platform.machine())
        with tempfile.TemporaryDirectory(prefix="asm-version-test-", dir=BUILD) as temporary:
            base = Path(temporary)
            for name, source in candidates.items():
                with self.subTest(library=name):
                    assembly = base / (name + ".s")
                    library = base / (name + ".so")
                    assembly.write_text(source + stack_note)
                    subprocess.run(
                        ["/usr/bin/cc", *target_flags, "-shared", "-nostdlib", "-Wl,-z,noexecstack", "-o", str(library), str(assembly)],
                        check=True, capture_output=True, timeout=20,
                        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
                    )
                    result = subprocess.run(
                        [str(BINARY), "8081", str(base / "missing-database-url")],
                        env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LD_PRELOAD": str(library)},
                        capture_output=True, text=True, timeout=5,
                    )
                    self.assertEqual(result.returncode, 78, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(
                        result.stderr,
                        "asm-hub-prototype: use libmicrohttpd 1.0.3 and libpq 16.15. Rebuild with the pinned libraries.\n",
                    )


if __name__ == "__main__":
    unittest.main()
