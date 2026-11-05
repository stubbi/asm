"""Detect an ARM64-capable macOS host independently of Python's architecture."""
import platform
import subprocess


def is_apple_silicon():
    if platform.system() != "Darwin":
        return False
    # Force the probe's architecture: translated Python can report x86_64.
    result = subprocess.run(
        ["/usr/bin/arch", "-arm64", "/usr/sbin/sysctl", "-n", "hw.optional.arm64"],
        capture_output=True, timeout=10,
    )
    return result.returncode == 0 and result.stdout.strip() == b"1"
