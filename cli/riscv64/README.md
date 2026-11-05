# RISC-V64 Linux CLI

Status: source implementation under qualification. No RISC-V CLI release is declared by this directory.

This port retains package and command logic in native assembly.
`tools/riscv64.py` prepares the assembly sources before assembly.
It creates no runtime backend and runs no package operation.
The prepared files remain available for review in this directory.

## Machine contracts

| Work | ISA | Operating system | ABI | CPU features |
| --- | --- | --- | --- | --- |
| CLI executable | Little-endian RV64IM | Linux | LP64, freestanding | Integer multiplication and division (`M`) |
| Default standalone project | Little-endian RV64I | Linux | LP64, freestanding | Base integer instructions |
| Project with `link = "c"` | Little-endian RV64GC | Linux | LP64D, system C startup | General-purpose and compressed instruction extensions |

The CLI's instruction requirements do not establish the requirements of a package.
Executable validation checks container fields and supported ABI flags.
It does not establish every instruction requirement or program behavior.
Linux kernel and libc minimums remain unqualified.

## Build

On Linux with GNU RISC-V cross tools, run:

```sh
make ARCH=riscv64 build/asm-riscv64-linux
```

On a RISC-V64 Linux host, GNU assembler and linker provide the native tools.
`make ARCH=riscv64 build/asm` selects the development executable.
The normal build does not regenerate prepared source implicitly.
To update it, run:

```sh
python3 tools/riscv64.py
python3 tools/riscv64.py --check
```

The build selects RV64IM/LP64 and disables linker relaxation.
The CLI source also declares its ISA for self-host builds.
Generated standalone projects select RV64I/LP64.
Native-library projects select RV64GC/LP64D and position-independent objects.
Their compiler arguments name that ISA and ABI explicitly.

The CLI uses fixed `/usr/bin/as`, `/usr/bin/ld`, and `/usr/bin/cc` paths.
Transport, hashes, decompression, and provenance retain the existing fixed-tool contracts.
The assembler and linker must run on the selected Linux host.
A cross-assembled executable is not a runtime qualification result.

## Internal ABI

The internal ABI differs from the C calling convention.

| Registers | Internal role |
| --- | --- |
| `a0`–`a7` | Arguments and documented caller scratch |
| `t0` | Result |
| `s0`–`s5`, `sp`, `gp`, `tp` | Preserved by returning routines |
| `s6`, `s7`, `t1`–`t6` | Caller scratch |
| `s8`, `s10`, `s11` | Reserved expansion scratch |
| `s9` | Transient arithmetic conditions: N=8, Z=4, C=2, V=1 |
| `ra` | Return address; `RV_CALL` saves it around nested calls |

Every stack reservation uses a multiple of 16 bytes.
`RV_CALL`, `RV_SAVE`, and `RV_RESTORE` use 16-byte frames.
Routine comments describe their additional local frames and buffer ownership.
A C test wrapper must preserve all C ABI callee-saved registers at this boundary.

Word operations retain their documented 32-bit behavior and clear upper result bits.
Condition macros expand into native RISC-V instructions.
File-data loads and stores use byte operations when alignment is unknown.
They do not depend on kernel emulation of misaligned memory access.

## Linux boundary

Typed syscall adapters preserve `a0`–`a7` and return a kernel result in `t0`.
Negative results retain the kernel error number.
Arguments four through six use `a6`, `a4`, and `a5` internally.
The adapter moves them into the kernel argument registers before `ecall`.

The native `stat` structure has 128 bytes.
Mode, link count, UID, and GID use offsets 16, 20, 24, and 28.
The 64-bit size uses offset 48.
`O_DIRECTORY` is 65536; `O_NOFOLLOW` is 131072.
RISC-V omits the legacy `renameat` syscall.
The adapters use `renameat2` with zero flags for ordinary rename behavior.

These interfaces were checked against Linux v6.8 UAPI sources on 5 November 2026.
The [RISC-V psABI](https://riscv-non-isa.github.io/riscv-elf-psabi-doc/) defines the separate C and ELF contracts.
The inspected document is version 2.0-rc0, dated 4 November 2026.

## Qualification

The [qualification contract](../../docs/riscv64-qualification.md) records required tests and execution modes.
Retain failed attempts beside later results.
Bind each runtime result to the tested source and executable digests.
Emulation does not qualify a native machine, release, installer, or deployment.
Shared distribution changes require the separate release workstream.
