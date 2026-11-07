# Native CLI sources

Asm implements its project and package commands in assembly.
The repository root is the CLI project root.
The root [asm.toml](../asm.toml) describes the Linux x86-64 reference build.
The root [Makefile](../Makefile) selects the supported native implementation and coordinates builds, checks, and installation.

| Path | Purpose |
| --- | --- |
| `*.s` | Linux x86-64 implementation and starter text. |
| `aarch64/` | Linux AArch64 implementation and starter text. |
| `macos/` | Apple Silicon platform adapters for the shared AArch64 implementation. |
| `macos/x86_64/` | Separate Intel macOS source port with its own build entry point. |
| `commands.json` | Command contract used by checks. |

The root build supports Linux x86-64, Linux ARM64, and Apple Silicon macOS.
The [Intel port](../docs/intel-macos-port.md) has separate qualification and release limits.
RISC-V Linux and Windows sources under [examples](../examples/) implement packages; this CLI tree has no corresponding native host implementation.

## Build and check

1. Install the [source-build prerequisites](../README.md#build-from-source).
2. Run `make` from the repository root.
3. Run `make test` from the repository root.

On Linux, Make assembles the source into an object file, then links the executable.
On Apple Silicon macOS, `tools/macos.py` prepares assembly for Apple Clang, which assembles and links the executable.
The selected development executable is `build/asm`.
The [contribution guide](../CONTRIBUTING.md) lists additional checks and their prerequisites.

The CLI invokes system tools for assembly, linking, transport, and cryptographic checks.
Python build scripts and the separate MCP adapter do not implement its project or package commands.

## Local installation

`make install` and `make uninstall` call [tools/install.sh](../tools/install.sh) to manage the locally built binary.
The helper preserves existing commands unless replacement is explicit.
The website's downloaded installer is generated separately by [tools/bootstrap.py](../tools/bootstrap.py).
It installs a published release rather than the local build.
