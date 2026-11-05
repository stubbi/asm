# Hello for Windows x86-64

This package targets Windows x86-64 and the Microsoft x64 ABI.
An ABI defines function calls, register use, and stack layout.
This source package targets prospective version 0.6.0.
Native Windows qualification remains required.
The program requires no C runtime.
The source uses LLVM's assembler with Intel syntax.

The output contract is exactly `Hello from asm!` followed by one line-feed byte.
The program exits with status 0 after a complete write.
An invalid standard-output handle, failed write, or zero-length write produces status 1.
The program retries a successful short write with the remaining bytes.

## Use the Windows Asm build

These instructions require a Windows Asm build from the matching source revision.
Use the Windows x86-64 Asm build, LLVM `clang`, LLVM `lld-link`, and the Windows SDK import libraries.
The Windows SDK supplies declarations and libraries for Windows APIs.
This package uses `GetStdHandle`, `WriteFile`, and `ExitProcess` from `Kernel32.dll`.

From this package directory, run these commands in PowerShell:

```powershell
asm build
asm run
asm test
```

`asm run` builds `build/app.exe` before execution.
The required program output is:

```text
Hello from asm!
```

The assembly test exits with status 0 when all seven write-contract cases pass.
It checks complete writes, short writes, absent handles, invalid handles, failed writes, zero progress, and oversized write counts.
It also checks API arguments, output bytes, stack alignment, and shadow-space use.

## Build directly with LLVM

Install LLVM before these commands.
The supplied definition file lists only the three imported APIs.
`lld-link /lib` creates their import library without a Windows SDK installation.

From this package directory, run these commands:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
lld-link /lib /machine:x64 /def:kernel32.def /out:build/kernel32.lib
clang --target=x86_64-pc-windows-msvc -c src/main.s -o build/hello.obj
lld-link /machine:x64 /entry:mainCRTStartup /subsystem:console /nodefaultlib /nxcompat /dynamicbase /timestamp:0 /WX /out:build/app.exe build/hello.obj build/kernel32.lib
clang --target=x86_64-pc-windows-msvc -c tests/main.s -o build/test.obj
lld-link /machine:x64 /entry:mainCRTStartup /subsystem:console /nodefaultlib /nxcompat /dynamicbase /timestamp:0 /WX /out:build/test.exe build/test.obj build/kernel32.lib
```

On Windows x86-64, run `./build/app.exe` and `./build/test.exe` deliberately.
The test executable is quiet when it passes.

## Interface and evidence limits

The object format is little-endian x86-64 COFF.
The executable format is PE32+ with the console subsystem and entry point `mainCRTStartup`.
The source reserves Win64 shadow space and keeps call-site stack alignment at 16 bytes.
It includes Windows unwind metadata and preserves nonvolatile registers.
The linker enables address randomization and non-executable data sections.

Cross-assembly and PE inspection do not establish native Windows behavior.
Before publication, run the package tests on a matching Windows host.
From the repository root, run `python -m unittest discover -s tests/packages -p test_hello_windows.py -v`.
That check covers captured output, read-only standard output, file preservation, and the assembly contract test.
The native runtime check reports a skip on other operating systems.
Native Windows execution was not run during this package's local cross-build.

The ABI and API references below were reviewed on 2026-11-05:

- [Microsoft x64 calling convention](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170).
- [GetStdHandle](https://learn.microsoft.com/en-us/windows/console/getstdhandle).
- [WriteFile](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-writefile).
- [ExitProcess](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-exitprocess).

The license is MIT.
See [LICENSE](LICENSE).
