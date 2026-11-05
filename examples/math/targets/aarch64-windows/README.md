# Unsigned integer helpers for Windows ARM64

This implementation belongs to the [math project](../../README.md).
The project root contains its manifest and MIT [license](../../LICENSE).
Start the manual build commands below in this target directory.
The assembler include path points to the project root.

This package targets Windows ARM64 and the Microsoft ARM64 ABI.
An ABI defines function calls, register use, and stack layout.
This source package targets unreleased checkout version 0.5.0.
Native Windows qualification remains required.
The program requires no C runtime.
The source uses LLVM's assembler with AArch64 syntax.

The output contract is exactly `min(12, 37) = 12` followed by one line-feed byte.
The program exits with status 0 after a complete write.
An invalid standard-output handle, failed write, or zero-length write produces status 1.
The program retries a successful short write with the remaining bytes.

## Runtime qualification

The current Asm CLI does not build or run this Windows target.
Use the direct LLVM commands below.
Native Windows execution remains a separate qualification gate.

## Callable interface

`src/min.s` exports `asm_u64_min`.
It returns the smaller of two unsigned 64-bit integers.
Arguments use `x0` and `x1`.
The result uses `x0`.
The function changes `x0` and arithmetic flags only.
The ABI test checks registers `x18` through `x29` and the preserved 64-bit lanes of registers `v8` through `v15`.
The function does not access data memory or allocate stack storage.
The caller must supply a valid call frame.
Include `src/min.s` once in each linked program.

The assembly test covers zero, maximum values, equality, reversed arguments, and both sides of the signed boundary.
It checks the stack pointer after every call.
The test executable is quiet and exits with status 0 when all checks pass.
A separate writer test covers complete writes, short writes, absent handles, invalid handles, failed writes, zero progress, and oversized counts.
It checks the actual output bytes and Windows API arguments.
These tests are not a formal proof.
This package makes no performance claim.

## Build directly with LLVM

Install LLVM before these commands.
The supplied definition file lists only the three imported APIs.
`lld-link /lib` creates their import library without a Windows SDK installation.

From this target directory, run these commands:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
lld-link /lib /machine:arm64 /def:kernel32.def /out:build/kernel32.lib
clang --target=aarch64-pc-windows-msvc -I ../.. -c src/main.s -o build/math.obj
lld-link /machine:arm64 /entry:mainCRTStartup /subsystem:console /nodefaultlib /nxcompat /dynamicbase /timestamp:0 /WX /out:build/app.exe build/math.obj build/kernel32.lib
clang --target=aarch64-pc-windows-msvc -I ../.. -c tests/main.s -o build/test.obj
lld-link /machine:arm64 /entry:mainCRTStartup /subsystem:console /nodefaultlib /nxcompat /dynamicbase /timestamp:0 /WX /out:build/test.exe build/test.obj build/kernel32.lib
clang --target=aarch64-pc-windows-msvc -I ../.. -c tests/io.s -o build/writer-test.obj
lld-link /machine:arm64 /entry:mainCRTStartup /subsystem:console /nodefaultlib /nxcompat /dynamicbase /timestamp:0 /WX /out:build/writer-test.exe build/writer-test.obj build/kernel32.lib
```

On Windows ARM64, run `./build/app.exe` and `./build/test.exe` deliberately.
Run `./build/writer-test.exe` to check write failures and short writes.
The test executables are quiet when they pass.

## Interface and evidence limits

The object format is little-endian ARM64 COFF.
The executable format is PE32+ with the console subsystem and entry point `mainCRTStartup`.
The source keeps SP 16-byte aligned and includes Windows unwind metadata.
It preserves registers `x18` through `x30` and does not use optional instruction extensions.
The linker enables address randomization and non-executable data sections.

Cross-assembly and PE inspection do not establish native Windows behavior.
Before publication, run the package tests on a matching Windows host.
From the repository root, run `python -m unittest discover -s tests/packages -p test_math_windows.py -v`.
That check covers captured output, read-only standard output, file preservation, the unsigned-value and ABI assembly tests, and the seven writer scenarios.
The native runtime check reports a skip on other operating systems.
Native Windows execution was not run during this package's local cross-build.

The ABI and API references below were reviewed on 2026-11-05:

- [Microsoft ARM64 ABI conventions](https://learn.microsoft.com/en-us/cpp/build/arm64-windows-abi-conventions?view=msvc-170).
- [GetStdHandle](https://learn.microsoft.com/en-us/windows/console/getstdhandle).
- [WriteFile](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-writefile).
- [ExitProcess](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-exitprocess).

The license is MIT.
See [LICENSE](../../LICENSE).
