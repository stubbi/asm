# SPDX-License-Identifier: AGPL-3.0-or-later
ROOT := ../../..
PYTHON ?= python
CLANG ?= C:/Program Files/LLVM/bin/clang.exe
LLD_LINK ?= C:/Program Files/LLVM/bin/lld-link.exe
SOURCE := $(ROOT)/build/windows/aarch64/asm.s
OBJECT := $(ROOT)/build/windows/aarch64/asm.obj
BINARY := $(ROOT)/build/asm-aarch64-windows.exe
INPUTS := $(wildcard $(ROOT)/cli/aarch64/*.s $(ROOT)/cli/aarch64/*.inc *.s) $(ROOT)/tools/windows_arm64.py

.PHONY: all test abi-test security-test contracts-test image-test clean
all: $(BINARY)

$(SOURCE): $(INPUTS)
	$(PYTHON) $(ROOT)/tools/windows_arm64.py --output $@

$(OBJECT): $(SOURCE)
	"$(CLANG)" --no-default-config --target=aarch64-pc-windows-msvc -c $< -o $@

$(BINARY): $(OBJECT)
	"$(LLD_LINK)" /machine:arm64 /entry:_start /subsystem:console /nodefaultlib /nxcompat /dynamicbase /Brepro /out:$@ $< kernel32.lib ntdll.lib advapi32.lib bcrypt.lib shell32.lib

test: $(BINARY)
	$(PYTHON) $(ROOT)/tools/windows_test.py --asm $(BINARY) --target aarch64-windows --evidence $(ROOT)/build/windows/aarch64/runtime-evidence.json

# Apple Silicon host shim; this does not qualify the Windows runtime.
abi-test:
	$(PYTHON) abi_test.py --output $(ROOT)/build/windows/aarch64/abi-shim-evidence.json

security-test:
	$(PYTHON) security_test.py --output $(ROOT)/build/windows/aarch64/security-evidence.json
	$(PYTHON) environment_test.py --output $(ROOT)/build/windows/aarch64/environment-evidence.json

contracts-test:
	$(PYTHON) contracts_test.py --output $(ROOT)/build/windows/aarch64/contracts-evidence.json

image-test:
	$(PYTHON) image_test.py --output $(ROOT)/build/windows/aarch64/image-evidence.json
	$(PYTHON) metadata_test.py --output $(ROOT)/build/windows/aarch64/metadata-evidence.json

clean:
	$(PYTHON) -c "from pathlib import Path; [Path(p).unlink(missing_ok=True) for p in ['$(SOURCE)', '$(OBJECT)', '$(BINARY)']]"
