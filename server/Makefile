# SPDX-License-Identifier: AGPL-3.0-or-later
CC ?= gcc
MHD_PREFIX ?= /usr/local
PG_PREFIX ?= /usr/local/pgsql
PG_LIB_DIR ?= $(PG_PREFIX)/lib
PG_INCLUDE_DIR ?= $(PG_PREFIX)/include
PG_BINDIR ?= $(PG_PREFIX)/bin
BUILD ?= $(abspath ../build/server)
SOURCE_REVISION ?= $(shell git rev-parse HEAD)
LIBRARIES := -L"$(MHD_PREFIX)/lib" -Wl,-rpath,"$(MHD_PREFIX)/lib" \
  -L"$(PG_LIB_DIR)" -Wl,-rpath,"$(PG_LIB_DIR)" -lmicrohttpd -l:libpq.so.5 -pthread
HOST_SYSTEM := $(shell uname -s)
HOST_MACHINE := $(shell uname -m)
NATIVE_TARGET := $(if $(filter x86_64,$(HOST_MACHINE)),x86_64-linux,$(if $(filter aarch64,$(HOST_MACHINE)),aarch64-linux,$(if $(filter riscv64,$(HOST_MACHINE)),riscv64-linux)))
TARGET ?= $(NATIVE_TARGET)
SOURCES_x86_64-linux := runtime.s config.s
SOURCES_aarch64-linux := aarch64/runtime.s aarch64/config.s
SOURCES_riscv64-linux := riscv64/runtime.s riscv64/config.s
TARGET_FLAGS_riscv64-linux := -march=rv64gc -mabi=lp64d

.PHONY: all test
all:
	@case "$(HOST_SYSTEM)/$(HOST_MACHINE)" in \
	  Linux/x86_64|Linux/aarch64|Linux/riscv64) ;; \
	  *) echo "Use native Linux x86-64, AArch64, or RV64GC/LP64D to build this runtime." >&2; exit 1 ;; esac
	@test "$(TARGET)" = "$(NATIVE_TARGET)" || \
	  { echo "TARGET must match the native Linux host: $(NATIVE_TARGET)." >&2; exit 1; }
	@printf '%s\n' '$(SOURCE_REVISION)' | LC_ALL=C grep -Eq '^[0-9a-f]{40}$$' || \
	  { echo "SOURCE_REVISION must be an exact commit ID." >&2; exit 1; }
	@set -eu; umask 077; \
	  test ! -L "$(BUILD)" || { echo "BUILD must not be a symlink." >&2; exit 1; }; \
	  mkdir -p "$(BUILD)"; \
	  stage=$$(mktemp -d "$(BUILD)/.asm-server.XXXXXXXX"); \
	  trap 'rm -rf -- "$$stage"' EXIT HUP INT TERM; \
	  $(CC) $(TARGET_FLAGS_$(TARGET)) -std=c11 -Wall -Wextra -Werror \
	    -I"$(MHD_PREFIX)/include" -I"$(PG_INCLUDE_DIR)" \
	    -o "$$stage/abi-check" abi-check.c $(LIBRARIES); \
	  "$$stage/abi-check"; \
	  $(CC) $(TARGET_FLAGS_$(TARGET)) -g -fPIE -pie -Wl,-z,relro,-z,now,-z,noexecstack \
	    -x assembler-with-cpp -DASM_SOURCE_REVISION='"$(SOURCE_REVISION)"' \
	    -o "$$stage/asm-hub" $(SOURCES_$(TARGET)) $(LIBRARIES); \
	  mv -f -- "$$stage/asm-hub" "$(BUILD)/asm-hub"

test: all
	ASM_SERVER_BINARY="$(BUILD)/asm-hub" ASM_SERVER_SOURCE_REVISION="$(SOURCE_REVISION)" \
	ASM_PROTO_LIBPQ="$(PG_LIB_DIR)/libpq.so.5" ASM_PROTO_PG_BINDIR="$(PG_BINDIR)" \
	python3 test_runtime.py
