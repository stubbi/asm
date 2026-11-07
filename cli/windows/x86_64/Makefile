# SPDX-License-Identifier: AGPL-3.0-or-later
# Run from the repository root with a Visual Studio developer environment.
PYTHON ?= python
CLANG ?= clang
ROOT := .
OUT := build/windows/x86_64
BINARY := build/asm-x86_64-windows.exe

.PHONY: all prepare check host-check clean
all: $(BINARY)

prepare:
	$(PYTHON) tools/windows_x64.py --output $(OUT)/asm.s

$(BINARY): prepare
	$(CLANG) --no-default-config --target=x86_64-pc-windows-msvc -c $(OUT)/asm.s -o $(OUT)/asm.obj
	$(CLANG) --no-default-config --target=x86_64-pc-windows-msvc -fuse-ld=lld -nostdlib $(OUT)/asm.obj -o $(BINARY) -Wl,/entry:_start,/subsystem:console,/nxcompat,/dynamicbase,/stack:8388608 -Wl,kernel32.lib,advapi32.lib,bcrypt.lib,ntdll.lib,shell32.lib

check: $(BINARY)
	$(PYTHON) tools/windows_test.py --asm $(BINARY) --target x86_64-windows --evidence $(OUT)/native-test.json

host-check:
	$(PYTHON) cli/windows/x86_64/test_host_shims.py
	$(PYTHON) cli/windows/x86_64/test_native_regressions.py

clean:
	$(PYTHON) -c "from pathlib import Path; [p.unlink(missing_ok=True) for p in map(Path, ['$(OUT)/asm.s', '$(OUT)/asm.obj', '$(BINARY)'])]"
