AS ?= as
LD ?= ld
PYTHON ?= python3
PREFIX ?= /usr/local
DESTDIR ?=
REPLACE ?= 0

.PHONY: all test clean install uninstall check
all: build/asm

build:
	mkdir -p build

build/asm.o: cli/asm.s cli/registry.s cli/elf.s cli/archive.s cli/dependencies.s cli/publish.s cli/templates.s cli/self_update.s cli/self_update_verify.s cli/self_update_metadata.s | build
	$(AS) --64 --fatal-warnings -o $@ $<

build/asm: build/asm.o
	$(LD) -z noexecstack -z relro -z now --build-id=none -o $@ $^

test: build/asm
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

check: test
	$(PYTHON) -m unittest discover -s tests/registry -p 'test_*.py' -v
	$(PYTHON) -m unittest discover -s tests/release -p 'test_*.py' -v
	node --test tests/site.test.cjs

install: build/asm
	sh cli/install.sh install build/asm "$(DESTDIR)$(PREFIX)/bin/asm" "$(REPLACE)"

uninstall: build/asm
	sh cli/install.sh uninstall build/asm "$(DESTDIR)$(PREFIX)/bin/asm" 0

clean:
	rm -f build/asm build/asm.o build/registry.o
