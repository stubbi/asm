HOST_OS := $(shell uname -s)
HOST_ARCH := $(shell uname -m | sed s/arm64/aarch64/)
ARCH ?= $(HOST_ARCH)
ifeq ($(HOST_OS),Darwin)
ifneq ($(ARCH),aarch64)
$(error Native macOS qualification currently requires Apple Silicon)
endif
endif
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
GO ?= go
TRUSTED_DISTRIBUTION ?= 0

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
ifeq ($(HOST_OS),Darwin)
build/macos/asm.s: $(CLI_INPUTS) tools/macos.py $(wildcard cli/macos/*.s)
	$(PYTHON) tools/macos.py --output $@

build/asm-aarch64-macos: build/macos/asm.s
	/usr/bin/clang -arch arm64 -mmacosx-version-min=15.0 -Wl,-no_uuid -o $@ $<
	/usr/bin/codesign --verify --strict $@

endif

ifeq ($(TRUSTED_DISTRIBUTION),1)
build/asm: trusted-cli
	cp -- build/asm-trusted $@
else
ifeq ($(HOST_OS),Darwin)
build/asm: build/asm-aarch64-macos
else
build/asm: build/asm-$(ARCH)-linux
endif
ifeq ($(HOST_OS),Darwin)
	@asm_copy=$$(mktemp build/.asm-copy.XXXXXXXX) && \
	trap 'rm -f -- "$$asm_copy"' EXIT HUP INT TERM && \
	cp -- $< "$$asm_copy" && chmod 755 "$$asm_copy" && mv -f -- "$$asm_copy" $@
else
	cp -- $< $@
endif
endif

TEST_DIRECTORY := $(if $(filter Darwin,$(HOST_OS)),tests/macos,tests)
test: build/asm
	$(PYTHON) -m unittest discover -s $(TEST_DIRECTORY) -p 'test_*.py' -v

check: test
	$(PYTHON) -m unittest discover -s tests/registry -p 'test_*.py' -v
	$(PYTHON) -m unittest discover -s tests/release -p 'test_*.py' -v
	node --test tests/site.test.cjs

.PHONY: agent-test
agent-test:
	$(PYTHON) -m unittest discover -s tests/agents -p 'test_*.py' -v

.PHONY: hosted-registry-test
hosted-registry-test:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tests/hosted_registry -p 'test_*.py' -v

install: build/asm
	sh cli/install.sh install build/asm "$(DESTDIR)$(PREFIX)/bin/asm" "$(REPLACE)"

uninstall: build/asm
	sh cli/install.sh uninstall build/asm "$(DESTDIR)$(PREFIX)/bin/asm" 0

clean:
	rm -f build/asm build/asm.o build/registry.o build/x86_64/asm.o build/aarch64/asm.o build/asm-x86_64-linux build/asm-aarch64-linux build/asm-aarch64-macos build/macos/asm.s

# Provisioned distribution is a separate activation gate during migration.
# The current release path stays available until the offline root is reviewed.
# Go builds only the transport/cryptography adapter. Package logic stays native.
.PHONY: verifier-test trusted-cli check-trust-root
verifier-test:
	cd verifier && $(GO) test -race ./...

build/asm-verify-$(ARCH)-$(if $(filter Darwin,$(HOST_OS)),macos,linux): $(wildcard verifier/*.go) verifier/go.mod verifier/go.sum verifier/trust/asm-root.json tools/verifier_notices.py
	mkdir -p build
	cd verifier && CGO_ENABLED=0 GOARCH=$(if $(filter x86_64,$(ARCH)),amd64,arm64) $(GO) build -mod=readonly -trimpath -buildvcs=false -ldflags='-s -w -buildid=' -o ../$@ .
	GOARCH=$(if $(filter x86_64,$(ARCH)),amd64,arm64) $(PYTHON) tools/verifier_notices.py --go "$(GO)" --output $@.LICENSES.txt

check-trust-root:
	$(MAKE) build/asm-verify-$(HOST_ARCH)-$(if $(filter Darwin,$(HOST_OS)),macos,linux) ARCH=$(HOST_ARCH)
	build/asm-verify-$(HOST_ARCH)-$(if $(filter Darwin,$(HOST_OS)),macos,linux) check-root verifier/trust/asm-root.json

trusted-cli: check-trust-root build/asm-verify-$(ARCH)-$(if $(filter Darwin,$(HOST_OS)),macos,linux)
ifeq ($(HOST_OS),Darwin)
	$(PYTHON) tools/macos.py --output build/macos/asm-trusted.s
	{ printf '.set ASM_TRUSTED_DISTRIBUTION, 1\n'; cat build/macos/asm-trusted.s; } > build/macos/asm-trusted-complete.s
	/usr/bin/clang -arch arm64 -mmacosx-version-min=15.0 -Wl,-no_uuid -o build/asm-trusted build/macos/asm-trusted-complete.s
	/usr/bin/codesign --verify --strict build/asm-trusted
else
	$(AS) $(CLI_AS_FLAGS) --defsym ASM_TRUSTED_DISTRIBUTION=1 -o build/asm-trusted.o $(CLI_SOURCE)
	$(LD) -z noexecstack -z relro -z now --build-id=none -o build/asm-trusted build/asm-trusted.o
endif
