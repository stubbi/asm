HOST_OS := $(shell uname -s)
HOST_ARCH := $(shell uname -m | sed s/arm64/aarch64/)
ARCH ?= $(HOST_ARCH)
ifeq ($(HOST_OS)/$(ARCH),Linux/x86_64)
CLI_TARGET := x86_64-linux
else ifeq ($(HOST_OS)/$(ARCH),Linux/aarch64)
CLI_TARGET := aarch64-linux
else ifeq ($(HOST_OS)/$(ARCH),Darwin/aarch64)
CLI_TARGET := aarch64-macos
else
$(error Unsupported CLI target '$(HOST_OS)/$(ARCH)'; use Linux/x86_64, Linux/aarch64 or Darwin/aarch64)
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
GO_TOOL_ENV := GOENV=off GOWORK=off GOTOOLCHAIN=local GOFLAGS= GOAMD64=v1 GOARM64=v8.0 GOEXPERIMENT= GOFIPS140=off
TRUSTED_DISTRIBUTION ?= 0
REGISTRY_V2 ?= 1

ifneq ($(REGISTRY_V2),0)
ifneq ($(REGISTRY_V2),1)
$(error REGISTRY_V2 must be 0 or 1)
endif
endif
ifneq ($(TRUSTED_DISTRIBUTION),0)
ifneq ($(TRUSTED_DISTRIBUTION),1)
$(error TRUSTED_DISTRIBUTION must be 0 or 1)
endif
endif

CLI_PROFILE := v$(if $(filter 1,$(REGISTRY_V2)),2,1)$(if $(filter 1,$(TRUSTED_DISTRIBUTION)),-trusted)
CLI_BUILD := build/$(CLI_PROFILE)
CLI_BINARY := $(CLI_BUILD)/asm-$(CLI_TARGET)
CLI_AS_DEFINES := $(if $(filter 1,$(REGISTRY_V2)),--defsym ASM_REGISTRY_V2=1) $(if $(filter 1,$(TRUSTED_DISTRIBUTION)),--defsym ASM_TRUSTED_DISTRIBUTION=1)
CLI_COMMA := ,
CLI_MAC_DEFINES := $(if $(filter 1,$(REGISTRY_V2)),'.set ASM_REGISTRY_V2$(CLI_COMMA) 1') $(if $(filter 1,$(TRUSTED_DISTRIBUTION)),'.set ASM_TRUSTED_DISTRIBUTION$(CLI_COMMA) 1')
CLI_ADAPTER := $(if $(filter 1,$(REGISTRY_V2) $(TRUSTED_DISTRIBUTION)),build/asm-verify-$(CLI_TARGET))
CLI_ROOT_CHECK := $(if $(filter 1,$(TRUSTED_DISTRIBUTION)),check-trust-root)

.PHONY: all test package-test clean install uninstall check build/asm
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

$(CLI_BUILD)/$(ARCH):
	mkdir -p $@

$(CLI_BUILD)/$(ARCH)/asm.o: $(CLI_INPUTS) Makefile $(CLI_ADAPTER) | $(CLI_BUILD)/$(ARCH)
	$(AS) $(CLI_AS_FLAGS) $(CLI_AS_DEFINES) -o $@ $(CLI_SOURCE)

ifeq ($(HOST_OS),Linux)
$(CLI_BINARY): $(CLI_BUILD)/$(ARCH)/asm.o $(CLI_ROOT_CHECK)
	$(LD) -z noexecstack -z relro -z now --build-id=none -o $@ $<
endif

# Keep target artifacts separate. Selecting another ARCH must not reuse the
# previous host's binary just because its timestamp is newer.
ifeq ($(HOST_OS),Darwin)
$(CLI_BUILD)/macos/asm.s: $(CLI_INPUTS) Makefile tools/macos.py $(wildcard cli/macos/*.s)
	$(PYTHON) tools/macos.py --output $@.body
	{ printf '%s\n' $(CLI_MAC_DEFINES); cat $@.body; } > $@

$(CLI_BINARY): $(CLI_BUILD)/macos/asm.s $(CLI_ADAPTER) $(CLI_ROOT_CHECK)
	/usr/bin/clang -arch arm64 -mmacosx-version-min=15.0 -Wl,-no_uuid -o $@ $<
	/usr/bin/codesign --verify --strict $@

endif

.PHONY: build/asm-$(CLI_TARGET)
build/asm build/asm-$(CLI_TARGET): $(CLI_BINARY)
ifeq ($(HOST_OS),Darwin)
	@asm_copy=$$(mktemp build/.asm-copy.XXXXXXXX) && \
	trap 'rm -f -- "$$asm_copy"' EXIT HUP INT TERM && \
	cp -- $< "$$asm_copy" && chmod 755 "$$asm_copy" && mv -f -- "$$asm_copy" $@
else
	cp -- $< $@
endif

# Native release qualification requires one complete unittest result without
# skipped provider gates. Provider and operator suites have explicit gates below.
NATIVE_OPERATOR_MODULES := test_registry_storage test_registry_storage_s3 test_registry_mirror test_registry_log_import test_registry_v2_stats test_registry_infrastructure_site test_registry_v2_site test_registry_v2_pages test_registry_v2_build
NATIVE_V2_MODULES := test_registry_solver test_registry_v2_dependencies test_registry_v2_cli test_registry_project test_registry_v2_arm
ifeq ($(REGISTRY_V2),1)
NATIVE_TEST_ENV := ASM_REGISTRY_TEST_BINARY="$(CURDIR)/build/asm" ASM_REGISTRY_TRUST="$(CURDIR)/build/asm-trust"
test: build/asm-trust
else
NATIVE_EXCLUDED_MODULES := $(NATIVE_V2_MODULES)
endif
ifneq ($(ARCH),aarch64)
NATIVE_EXCLUDED_MODULES += test_registry_v2_arm
endif
ifeq ($(HOST_OS),Darwin)
test: build/asm
	$(NATIVE_TEST_ENV) $(PYTHON) -m unittest discover -s tests/macos -p 'test_*.py' -v
else
CLI_TEST_MODULES := $(filter-out $(NATIVE_OPERATOR_MODULES) $(NATIVE_EXCLUDED_MODULES),$(patsubst tests/%.py,%,$(wildcard tests/test_*.py)))
test: build/asm
	$(NATIVE_TEST_ENV) PYTHONPATH="tests$${PYTHONPATH:+:$$PYTHONPATH}" $(PYTHON) -m unittest -v $(CLI_TEST_MODULES)
endif

package-test:
	$(PYTHON) -m unittest discover -s tests/packages -p 'test_*.py' -v

check: test package-test site-test
	$(PYTHON) -m unittest discover -s tests/registry -p 'test_*.py' -v
	$(PYTHON) -m unittest discover -s tests/release -p 'test_*.py' -v

.PHONY: site-test
site-test:
	node --test tests/site.test.cjs tests/package-demo.test.cjs tests/package-navigation.test.cjs tests/discovery.test.cjs tests/navigation.test.cjs tests/repository-stars.test.cjs
	PYTHONPATH=tests $(PYTHON) -m unittest test_site test_site_assets test_site_info test_site_routes test_site_dependencies test_package_pages test_package_activity test_discovery test_discovery_metadata test_download_data test_registry_explore test_registry_stats test_registry_infrastructure_site test_registry_v2_site test_registry_v2_pages test_registry_v2_build test_release_blog test_blog_posts test_site_docs test_count_format test_repository_stars test_target_metadata test_artifact_delivery test_serve_site test_bootstrap.BootstrapGenerationTests test_trusted_site.TrustedSiteTests -v

.PHONY: agent-test
agent-test:
	$(PYTHON) -m unittest discover -s tests/agents -p 'test_*.py' -v

.PHONY: hosted-registry-test
hosted-registry-test:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tests/hosted_registry -p 'test_*.py' -v

# Install requirements-storage.txt and nginx for the complete local operator gate.
NGINX ?= nginx
.PHONY: registry-infrastructure-test registry-storage-s3-test
registry-infrastructure-test:
	ASM_TEST_NGINX="$(NGINX)" $(PYTHON) -c 'import boto3, os, shutil; assert shutil.which(os.environ["ASM_TEST_NGINX"]), "Set NGINX to the nginx executable."'
	ASM_TEST_NGINX="$(NGINX)" PYTHONPATH=tests $(PYTHON) -m unittest test_registry_storage test_registry_mirror test_registry_log_import test_registry_v2_stats test_registry_infrastructure_site -v
	$(PYTHON) -m unittest discover -s tests/registry -p 'test_*.py' -v
	$(MAKE) publisher-tools-test PYTHON="$(PYTHON)"

registry-storage-s3-test:
	test -n "$(ASM_S3_TEST_CONFIG)"
	ASM_S3_TEST_CONFIG="$(ASM_S3_TEST_CONFIG)" PYTHONPATH=tests $(PYTHON) -m unittest test_registry_storage_s3 -v

.PHONY: publisher-tools-test publisher-proxy-test publisher-authority-test publisher-test
publisher-tools-test:
	PYTHONPATH=tests/publisher $(PYTHON) -m unittest test_admin test_checker test_features test_worker -v

publisher-proxy-test:
	ASM_TEST_NGINX="$(NGINX)" PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=tests/publisher $(PYTHON) -m unittest test_proxy -v

publisher-authority-test:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tests/publisher -p test_authority.py -v

# Supply reviewed Linux library/fixture paths, as described in server/publisher/README.md.
publisher-test: publisher-tools-test publisher-authority-test
	$(MAKE) -C server publisher-test
	$(MAKE) -C server test

install: build/asm
	sh tools/install.sh install build/asm "$(DESTDIR)$(PREFIX)/bin/asm" "$(REPLACE)"

uninstall: build/asm
	sh tools/install.sh uninstall build/asm "$(DESTDIR)$(PREFIX)/bin/asm" 0

clean:
	rm -f build/asm build/asm.o build/registry.o build/x86_64/asm.o build/aarch64/asm.o build/asm-x86_64-linux build/asm-aarch64-linux build/asm-aarch64-macos build/macos/asm.s
	rm -rf -- build/v1 build/v2 build/v1-trusted build/v2-trusted

# Provisioned distribution is a separate activation gate during migration.
# The current release path stays available until the offline root is reviewed.
# Go builds only the transport/cryptography adapter. Package logic stays native.
.PHONY: verifier-test trusted-cli check-trust-root
verifier-test:
	cd verifier && $(GO_TOOL_ENV) $(GO) test -race ./...

VERIFIER_TARGETS := build/asm-verify-x86_64-linux build/asm-verify-aarch64-linux build/asm-verify-aarch64-macos
build/asm-verify-x86_64-linux: VERIFIER_GOOS := linux
build/asm-verify-x86_64-linux: VERIFIER_GOARCH := amd64
build/asm-verify-aarch64-linux: VERIFIER_GOOS := linux
build/asm-verify-aarch64-linux: VERIFIER_GOARCH := arm64
build/asm-verify-aarch64-macos: VERIFIER_GOOS := darwin
build/asm-verify-aarch64-macos: VERIFIER_GOARCH := arm64

$(VERIFIER_TARGETS): Makefile $(wildcard verifier/*.go verifier/internal/securefs/*.go) verifier/go.mod verifier/go.sum verifier/trust/asm-root.json tools/verifier_notices.py
	mkdir -p build
	cd verifier && CGO_ENABLED=0 GOOS=$(VERIFIER_GOOS) GOARCH=$(VERIFIER_GOARCH) $(GO_TOOL_ENV) $(GO) build -mod=readonly -trimpath -buildvcs=false -ldflags='-s -w -buildid=' -o ../$@ .
	CGO_ENABLED=0 GOOS=$(VERIFIER_GOOS) GOARCH=$(VERIFIER_GOARCH) $(GO_TOOL_ENV) $(PYTHON) tools/verifier_notices.py --go "$(GO)" --output $@.LICENSES.txt

# Registry V2 uses the ordinary full build. Self-update trust remains separate.
.PHONY: registry-cli registry-v2-test registry-v2-tools-test registry-v2-authority-test registry-v2-full-flow-test
registry-cli:
	$(MAKE) REGISTRY_V2=1 TRUSTED_DISTRIBUTION=0 build/asm
	cp -- build/asm build/asm-registry-v2

.PHONY: build/asm-registry-v2
build/asm-registry-v2: registry-cli

build/asm-trust: $(wildcard verifier/cmd/asm-trust/*.go verifier/internal/securefs/*.go) verifier/go.mod verifier/go.sum
	mkdir -p build
	cd verifier && CGO_ENABLED=0 $(GO_TOOL_ENV) $(GO) build -mod=readonly -trimpath -buildvcs=false -ldflags='-s -w -buildid=' -o ../$@ ./cmd/asm-trust
	CGO_ENABLED=0 $(GO_TOOL_ENV) $(PYTHON) tools/verifier_notices.py --go "$(GO)" --output $@.LICENSES.txt

registry-v2-tools-test: build/asm-trust
	ASM_REGISTRY_TRUST="$(CURDIR)/build/asm-trust" PYTHONPATH=tests/publisher $(PYTHON) -m unittest test_distribution -v

registry-v2-test: registry-cli registry-v2-tools-test
	ASM_REGISTRY_TEST_BINARY="$(CURDIR)/build/asm-registry-v2" ASM_REGISTRY_TRUST="$(CURDIR)/build/asm-trust" PYTHONPATH=tests $(PYTHON) -m unittest test_registry_solver test_registry_v2_dependencies test_registry_v2_cli test_registry_project $(if $(filter aarch64,$(ARCH)),test_registry_v2_arm) -v

# These Linux gates require the owned PostgreSQL/TLS fixture and the reviewed
# publisher executable. Missing fixture paths fail instead of skipping checks.
registry-v2-authority-test: build/asm-trust
	ASM_REGISTRY_TRUST="$(CURDIR)/build/asm-trust" PYTHONPATH=tests/publisher $(PYTHON) -m unittest test_distribution_authority -v

registry-v2-full-flow-test: registry-cli build/asm-trust
	test -n "$(ASM_PUBLISHER_BINARY)"
	test -n "$(ASM_SERVER_SOURCE_REVISION)"
	ASM_REGISTRY_TEST_BINARY="$(CURDIR)/build/asm-registry-v2" ASM_REGISTRY_TRUST="$(CURDIR)/build/asm-trust" ASM_PUBLISHER_BINARY="$(ASM_PUBLISHER_BINARY)" ASM_SERVER_SOURCE_REVISION="$(ASM_SERVER_SOURCE_REVISION)" PYTHONPATH=tests/publisher $(PYTHON) -m unittest test_full_flow -v

check-trust-root:
	$(MAKE) build/asm-verify-$(HOST_ARCH)-$(if $(filter Darwin,$(HOST_OS)),macos,linux) ARCH=$(HOST_ARCH)
	build/asm-verify-$(HOST_ARCH)-$(if $(filter Darwin,$(HOST_OS)),macos,linux) check-root verifier/trust/asm-root.json

trusted-cli:
	$(MAKE) TRUSTED_DISTRIBUTION=1 build/asm
	cp -- build/asm build/asm-trusted

# The optional 18.6 server is owned by the launcher. It never selects an
# existing database. libpq and operator psql remain pinned to 16.15.
.PHONY: publisher-pg18-fixture-test publisher-pg18-test
publisher-pg18-fixture-test:
	PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=tests/publisher $(PYTHON) -m unittest test_pg18_fixture -v

publisher-pg18-test: publisher-pg18-fixture-test
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tests/publisher/run_pg18.py --check-only
	test -n "$(ASM_PUBLISHER_BINARY)"
	test -n "$(ASM_SERVER_SOURCE_REVISION)"
	$(MAKE) registry-cli build/asm-trust
	ASM_REGISTRY_TEST_BINARY="$(CURDIR)/build/asm-registry-v2" ASM_REGISTRY_TRUST="$(CURDIR)/build/asm-trust" ASM_PUBLISHER_BINARY="$(ASM_PUBLISHER_BINARY)" ASM_SERVER_SOURCE_REVISION="$(ASM_SERVER_SOURCE_REVISION)" ASM_TEST_NGINX="$(NGINX)" PYTHONDONTWRITEBYTECODE=1 $(PYTHON) tests/publisher/run_pg18.py authority distribution runtime full-flow
