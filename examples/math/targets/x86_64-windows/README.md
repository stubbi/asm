# Unsigned integer helpers for Windows x86-64

This implementation belongs to the [math project](../../README.md).
The project root contains its manifest and MIT [license](../../LICENSE).
Start the manual build commands below in this target directory.
The assembler include path points to the project root.

This package targets Windows x86-64 and the Microsoft x64 ABI.
An ABI defines function calls, register use, and stack layout.
This implementation belongs to the 0.6.0 source project.
The `_start` entry alias is an unpublished addition.
Its publication requires a new package version.
Both `_start` and `mainCRTStartup` select the same assembly routine.
Native Windows qualification remains required.
The program requires no C runtime.
The source uses LLVM's assembler with Intel syntax.

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
Arguments use `rcx` and `rdx`.
The result uses `rax`.
The function changes `rax` and arithmetic flags only.
The ABI test checks all nonvolatile general-purpose registers and registers `xmm6` through `xmm15`.
The function does not access a data buffer or allocate stack storage.
`ret` reads the caller's return address from the stack.
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
lld-link /lib /machine:x64 /def:kernel32.def /out:build/kernel32.lib
clang --target=x86_64-pc-windows-msvc -I ../.. -c src/main.s -o build/math.obj
lld-link /machine:x64 /entry:mainCRTStartup /subsystem:console /nodefaultlib /nxcompat /dynamicbase /timestamp:0 /WX /out:build/app.exe build/math.obj build/kernel32.lib
clang --target=x86_64-pc-windows-msvc -I ../.. -c tests/main.s -o build/test.obj
lld-link /machine:x64 /entry:mainCRTStartup /subsystem:console /nodefaultlib /nxcompat /dynamicbase /timestamp:0 /WX /out:build/test.exe build/test.obj build/kernel32.lib
clang --target=x86_64-pc-windows-msvc -I ../.. -c tests/io.s -o build/writer-test.obj
lld-link /machine:x64 /entry:mainCRTStartup /subsystem:console /nodefaultlib /nxcompat /dynamicbase /timestamp:0 /WX /out:build/writer-test.exe build/writer-test.obj build/kernel32.lib
```

On Windows x86-64, run `./build/app.exe` and `./build/test.exe` deliberately.
Run `./build/writer-test.exe` to check write failures and short writes.
The test executables are quiet when they pass.

## Interface and evidence limits

The object format is little-endian x86-64 COFF.
The executable format is PE32+ with the console subsystem and entry point `mainCRTStartup`.
The source reserves Win64 shadow space and keeps call-site stack alignment at 16 bytes.
It includes Windows unwind metadata and preserves nonvolatile registers.
The linker enables address randomization and non-executable data sections.

Cross-assembly and PE inspection do not establish native Windows behavior.
Before publishing a Windows executable, run the package tests on a matching Windows host.
From the repository root, run `python -m unittest discover -s tests/packages -p test_math_windows.py -v`.
That check covers captured output, read-only standard output, file preservation, the unsigned-value and ABI assembly tests, and the seven writer scenarios.
The native runtime check reports a skip on other operating systems.
Native Windows execution was not run during this package's local cross-build.

The ABI and API references below were reviewed on 2026-11-05:

- [Microsoft x64 calling convention](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170).
- [GetStdHandle](https://learn.microsoft.com/en-us/windows/console/getstdhandle).
- [WriteFile](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-writefile).
- [ExitProcess](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-exitprocess).

The license is MIT.
See [LICENSE](../../LICENSE).
