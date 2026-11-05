# Native library builds

Status: implementation contract for source builds.
Published Asm 0.5.0 binaries do not support this extension.

## Purpose

An assembly package can call established native libraries without a generated application backend.
The first consumer is the experimental Linux x86-64 server.
Dependable reuse requires explicit inputs, retained ABI checks, and understandable failures.

## Manifest

The existing four required manifest fields remain unchanged.
These optional quoted strings belong to `[build]`:

```toml
link = "c"
libraries = "microhttpd pq pthread"
check = "abi-check.c"
```

`link = "c"` selects the system C ABI and startup objects.
Without `link`, Asm retains its existing standalone build.
Other link values are errors.
`libraries` and `check` require `link = "c"`.
Duplicate fields and explicitly empty strings are errors.

`libraries` contains at most eight names separated by one ASCII space.
Each name matches `[a-z][a-z0-9_-]{0,30}`.
Leading, repeated, and trailing spaces are errors.
Each name becomes one `-lNAME` argument.
The field cannot contain linker flags or paths.

`check` names a relative `.c` file using the existing source-path rules.
Source archives must include that file.
Archive paths retain the registry's stricter portable-path rules and 240-byte limit.
Asm compiles it with `-fsyntax-only`, C11, and warnings as errors.
Asm does not execute the checker or add it to the application.
The server retains its header assertions and checks library versions in assembly before opening a listener.

## Local library installations

`build`, `run`, and `test` accept repeated `--include-dir PATH` and `--library-dir PATH` options.
Each option accepts at most eight absolute paths, each containing at most 255 printable ASCII characters.
Paths cannot contain a colon or comma.
These options require `link = "c"`.
They are errors on other commands.

Include directories apply to the compile-only check.
Library directories supply explicit search paths and runtime search paths.
Machine-local paths do not become package metadata.
Asm does not download or install native libraries.

## Tool execution and failure behavior

The CLI implements parsing, validation, arguments, and process control in assembly.
It invokes fixed assembler and `/usr/bin/cc` paths with direct arguments.
It constructs no shell command and invokes no Makefile or package hook.
Compiler children receive only fixed `PATH=/usr/bin:/bin` and `LC_ALL=C` environment entries.
Ambient compiler, loader, and include-path settings cannot override these inputs.

Linux linking uses PIE, RELRO, immediate binding, and a non-executable stack.
macOS linking uses the Apple ABI, PIE, and the existing macOS deployment minimum.
The existing private build stage and final rename remain in use.
Invalid fields, unsupported targets, failed checks, and linker failures retain the previous executable.
The ordinary standalone build remains unchanged.

## C dependency boundary

Calling a C library from assembly retains that library as a runtime dependency.
The server's HTTP and PostgreSQL libraries remain external dependencies.
Its C checker supplies build evidence and is not an application backend.
A separate assembly protocol package requires its own contract, security review, and qualification evidence.
This build extension does not qualify such a replacement or change the architecture's transport and cryptography requirements.

## Qualification limits

This extension remains unpublished.
Published Asm 0.5.0 binaries do not implement these fields.
Each native CLI host and C ABI project needs its own runtime checks.
Cross-assembly does not establish execution, library compatibility, or a minimum supported runtime.
A port must retain parser bounds, compiler environment restrictions, staging, and failure preservation.
The dependency resolution extension can appear in the same manifest.
Its lock binds the complete root manifest, including the native-link fields.
