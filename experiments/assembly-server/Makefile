# SPDX-License-Identifier: AGPL-3.0-or-later
.DEFAULT_GOAL := all
ASM ?= asm
MHD_PREFIX ?= /usr/local
PG_PREFIX ?= /usr/local/pgsql
PG_LIB_DIR ?= $(PG_PREFIX)/lib
PG_INCLUDE_DIR ?= $(PG_PREFIX)/include
PG_BINDIR ?= $(PG_PREFIX)/bin
BUILD := $(CURDIR)/build
HOST_SYSTEM := $(shell uname -s)
HOST_MACHINE := $(shell uname -m)
NATIVE_TARGET := $(if $(filter x86_64,$(HOST_MACHINE)),x86_64-linux,$(if $(filter aarch64,$(HOST_MACHINE)),aarch64-linux,$(if $(filter riscv64,$(HOST_MACHINE)),riscv64-linux)))
TARGET ?= $(NATIVE_TARGET)
PACKAGE_DIR ?= $(BUILD)/package-$(TARGET)
MANIFEST_TARGET = $(shell python3 -c 'import pathlib,tomllib; print(tomllib.loads(pathlib.Path("asm.toml").read_text())["build"]["target"])')

.PHONY: all test clean package check-host
check-host:
	@case "$(HOST_SYSTEM)/$(HOST_MACHINE)" in \
	  Linux/x86_64|Linux/aarch64|Linux/riscv64) ;; \
	  *) echo "Use native Linux x86-64, AArch64, or RV64GC/LP64D to build this server." >&2; exit 1 ;; esac
	@test "$(TARGET)" = "$(NATIVE_TARGET)" || \
	  { echo "TARGET must match the native Linux host: $(NATIVE_TARGET)." >&2; exit 1; }
	@test "$(MANIFEST_TARGET)" = "$(TARGET)" || \
	  { echo 'Prepare the native package first: python3 package.py --target $(TARGET) --output NEWDIR' >&2; exit 1; }

# The CLI repeats the compile-only ABI assertions for each build.
all: check-host
	"$(ASM)" build \
	  --include-dir "$(MHD_PREFIX)/include" --include-dir "$(PG_INCLUDE_DIR)" \
	  --library-dir "$(MHD_PREFIX)/lib" --library-dir "$(PG_LIB_DIR)"

test: all
	ASM_PROTO_BINARY="$(BUILD)/app" \
	ASM_PROTO_BUILD_DIR="$(BUILD)" \
	ASM_PROTO_PG_BINDIR="$(PG_BINDIR)" \
	ASM_PROTO_LIBPQ="$(PG_LIB_DIR)/libpq.so.5" \
	python3 -m unittest -v test_fixture.py test_server.py test_runtime_versions.py test_package.py

# Preparation runs on any host. The new tree has its selected root manifest.
package:
	python3 package.py --target "$(TARGET)" --output "$(PACKAGE_DIR)"

clean:
	"$(ASM)" clean
