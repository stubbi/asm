# Hello for Linux x86-64

This implementation belongs to the [hello project](../../README.md).
The project root contains its manifest and MIT [license](../../LICENSE).

The program writes `Hello from asm!` and exits with status zero.
It uses Linux system calls and requires no C runtime.
The entry point is `_start`.

## Build and run directly

These commands require GNU Binutils on Linux x86-64.

1. Open this target directory.
2. Create the output directory.

```sh
mkdir -p build
```

3. Assemble and link the example.

```sh
as --64 --fatal-warnings -o build/hello.o src/main.s
ld -z noexecstack --build-id=none -o build/hello build/hello.o
```

Successful build commands produce no output.

4. Run the program.

```sh
./build/hello
```

Expected output:

```text
Hello from asm!
```

5. Assemble and run the startup test.

```sh
as --64 --fatal-warnings -o build/tests.o tests/main.s
ld -z noexecstack --build-id=none -o build/tests build/tests.o
./build/tests
```

The test produces no output and exits with status zero.
It checks startup and exit only.
The example performs one write and does not check its result.
These checks do not establish short-write or output-error handling.

The target uses little-endian ELF64 and the Linux x86-64 system call convention.
The project [README](../../README.md) describes commands that use the root manifest.
