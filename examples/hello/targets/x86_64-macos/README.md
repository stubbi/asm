# Hello for macOS x86_64

This implementation belongs to the [hello project](../../README.md).
The project root contains its manifest and MIT [license](../../LICENSE).
Start the manual build commands below in this target directory.
The assembler include path points to the project root.

This assembly program writes `Hello from asm!` and returns zero after a complete write.
A write error or zero-length write returns one.
Short writes continue; interrupted writes retry.
The message contains one newline.

## Target and interface

- Instruction set: x86-64 baseline.
- Operating system: macOS 15 or later.
- Object format: Mach-O, little-endian.
- ABI: macOS System V AMD64 with libSystem calls.
- Assembler and linker: Apple clang from Xcode Command Line Tools.

`_main` follows the C entry-point contract and returns an exit status.
`_write` and `___error` supply output and error information.
The source documents changed registers, stack alignment, and immutable message storage.

## Build and run

From this target directory, run:

```sh
mkdir -p build
/usr/bin/clang -arch x86_64 -mmacosx-version-min=15.0 -Wl,-no_uuid -I ../.. -o build/hello src/main.s
./build/hello
```

Expected output:

```text
Hello from asm!
```

From the repository root, run the observable behavior tests:

```sh
python3 -m unittest discover -s tests/packages -p test_hello_macos.py -v
```

Local execution uses Rosetta on Apple Silicon; native Intel qualification remains separate.
The tests check exact output, exit status, and read-only or closed standard output.
Build success alone does not qualify an architecture or a CLI port.
This source relocation is unreleased; it does not change a published package version.

## Sources

Apple's [ARM64 guidance](https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms) defines its platform ABI differences.
Apple's [Intel guidance](https://developer.apple.com/documentation/xcode/writing-64-bit-intel-code-for-apple-platforms) defines the Intel platform contract.
These sources were checked on 5 November 2026.
The license is MIT. See [LICENSE](../../LICENSE).

## Write-loop qualification

From the repository root, run:

```sh
python3 -m unittest discover -s tests/packages -p test_macos_reference_io.py -v
```

Assembly fixtures inject complete, short, interrupted, zero-progress, failed, and oversized write results.
They execute the unchanged program body and check buffer progress, retry behavior, and exit status.
These fixtures check loop decisions; the ordinary process tests exercise real libSystem output.
