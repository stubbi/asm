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

.PHONY: all test
all:
	@test "$$(uname -s)/$$(uname -m)" = Linux/x86_64 || \
	  { echo "Use Linux x86-64 to build this runtime." >&2; exit 1; }
	@printf '%s\n' '$(SOURCE_REVISION)' | LC_ALL=C grep -Eq '^[0-9a-f]{40}$$' || \
	  { echo "SOURCE_REVISION must be an exact commit ID." >&2; exit 1; }
	mkdir -p "$(BUILD)"
	$(CC) -std=c11 -Wall -Wextra -Werror -I"$(MHD_PREFIX)/include" \
	  -I"$(PG_INCLUDE_DIR)" -o "$(BUILD)/abi-check" abi-check.c $(LIBRARIES)
	"$(BUILD)/abi-check"
	$(CC) -g -fPIE -pie -Wl,-z,relro,-z,now,-z,noexecstack \
	  -x assembler-with-cpp -DASM_SOURCE_REVISION='"$(SOURCE_REVISION)"' \
	  -o "$(BUILD)/asm-hub" runtime.s config.s $(LIBRARIES)

test: all
	ASM_SERVER_BINARY="$(BUILD)/asm-hub" ASM_SERVER_SOURCE_REVISION="$(SOURCE_REVISION)" \
	ASM_PROTO_LIBPQ="$(PG_LIB_DIR)/libpq.so.5" ASM_PROTO_PG_BINDIR="$(PG_BINDIR)" \
	python3 test_runtime.py
