# Isolated port entry point. Shared release integration owns the root Makefile.
PYTHON ?= python3
SOURCES := $(wildcard cli/*.s cli/macos/x86_64/*.s) tools/macos_x86_64.py
.PHONY: all test
all: build/asm-x86_64-macos
build/macos-x86_64/asm.s: $(SOURCES)
	$(PYTHON) tools/macos_x86_64.py --output $@
build/asm-x86_64-macos: build/macos-x86_64/asm.s
	/usr/bin/clang -arch x86_64 -mmacosx-version-min=15.0 -Wl,-no_uuid -Wl,-adhoc_codesign -o $@ $<
	/usr/bin/codesign --verify --strict $@
test: all
	@asm_copy=$$(mktemp build/.intel-copy.XXXXXXXX) && cp build/asm-x86_64-macos "$$asm_copy" && chmod 755 "$$asm_copy" && mv -f "$$asm_copy" build/asm
	ASM_TEST_TARGET=x86_64-macos $(PYTHON) -m unittest discover -s tests/macos_x86_64 -p 'test_*.py' -v
