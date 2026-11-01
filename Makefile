HOST_ARCH := $(shell uname -m)
ARCH ?= $(HOST_ARCH)
ifeq ($(filter $(ARCH),x86_64 aarch64),)
$(error Unsupported CLI architecture '$(ARCH)'; use x86_64 or aarch64)
endif

ifeq ($(ARCH),$(HOST_ARCH))
DEFAULT_AS := as
DEFAULT_LD := ld
else
DEFAULT_AS := $(ARCH)-linux-gnu-as
DEFAULT_LD := $(ARCH)-linux-gnu-ld
endif
ifeq ($(origin AS),default)
AS := $(DEFAULT_AS)
endif
ifeq ($(origin LD),default)
LD := $(DEFAULT_LD)
endif
AS ?= $(DEFAULT_AS)
LD ?= $(DEFAULT_LD)
PYTHON ?= python3
PREFIX ?= /usr/local
DESTDIR ?=
REPLACE ?= 0

.PHONY: all test clean install uninstall check build/asm
all: build/asm

ifeq ($(ARCH),aarch64)
CLI_SOURCE := cli/aarch64/asm.s
CLI_INPUTS := $(wildcard cli/aarch64/*.s cli/aarch64/*.inc)
CLI_AS_FLAGS := --fatal-warnings
else
CLI_SOURCE := cli/asm.s
CLI_INPUTS := $(wildcard cli/*.s)
CLI_AS_FLAGS := --64 --fatal-warnings
endif

build/$(ARCH):
	mkdir -p $@

build/$(ARCH)/asm.o: $(CLI_INPUTS) | build/$(ARCH)
	$(AS) $(CLI_AS_FLAGS) -o $@ $(CLI_SOURCE)

build/asm-$(ARCH)-linux: build/$(ARCH)/asm.o
	$(LD) -z noexecstack -z relro -z now --build-id=none -o $@ $^

# Keep target artifacts separate. Selecting another ARCH must not reuse the
# previous host's binary just because its timestamp is newer.
build/asm: build/asm-$(ARCH)-linux
	cp -- $< $@

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
	rm -f build/asm build/asm.o build/registry.o build/x86_64/asm.o build/aarch64/asm.o build/asm-x86_64-linux build/asm-aarch64-linux
