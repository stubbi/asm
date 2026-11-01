# SPDX-License-Identifier: AGPL-3.0-or-later
CC ?= gcc
MHD_PREFIX ?= /usr/local
PG_PREFIX ?= /usr/local/pgsql
PG_LIB_DIR ?= $(PG_PREFIX)/lib
PG_INCLUDE_DIR ?= $(PG_PREFIX)/include
PG_BINDIR ?= $(PG_PREFIX)/bin
BUILD := $(abspath ../../build/assembly-server)
LIBRARIES := -L"$(MHD_PREFIX)/lib" -Wl,-rpath,"$(MHD_PREFIX)/lib" \
  -L"$(PG_LIB_DIR)" -Wl,-rpath,"$(PG_LIB_DIR)" -lmicrohttpd -l:libpq.so.5 -pthread

.PHONY: all test clean
# These small programs rebuild each time. A changed prefix must not reuse an
# ABI checker or executable linked against an earlier library installation.
all:
	mkdir -p "$(BUILD)"
	$(CC) -std=c11 -Wall -Wextra -Werror -I"$(MHD_PREFIX)/include" \
	  -I"$(PG_INCLUDE_DIR)" -o "$(BUILD)/abi-check" abi-check.c $(LIBRARIES)
	"$(BUILD)/abi-check"
	$(CC) -g -fPIE -pie -Wl,-z,relro,-z,now,-z,noexecstack \
	  -o "$(BUILD)/asm-hub-prototype" server.s $(LIBRARIES)

test: all
	ASM_PROTO_BINARY="$(BUILD)/asm-hub-prototype" \
	ASM_PROTO_PG_BINDIR="$(PG_BINDIR)" \
	ASM_PROTO_LIBPQ="$(PG_LIB_DIR)/libpq.so.5" \
	python3 -m unittest -v test_fixture.py test_server.py

clean:
	rm -f "$(BUILD)/asm-hub-prototype" "$(BUILD)/abi-check"
