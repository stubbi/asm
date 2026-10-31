AS ?= as
LD ?= ld
PYTHON ?= python3
PREFIX ?= /usr/local
DESTDIR ?=

.PHONY: all test clean install uninstall check
all: build/asm

build:
	mkdir -p build

build/asm.o: cli/asm.s | build
	$(AS) --64 --fatal-warnings -o $@ $<

build/asm: build/asm.o
	$(LD) -z noexecstack -z relro -z now --build-id=none -o $@ $<

test: build/asm
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

check: test

install: build/asm
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 build/asm "$(DESTDIR)$(PREFIX)/bin/asm"

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/asm"

clean:
	rm -f build/asm build/asm.o
