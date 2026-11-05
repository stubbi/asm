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
SOURCES_x86_64-linux := runtime.s config.s metrics.s
SOURCES_aarch64-linux := aarch64/runtime.s aarch64/config.s aarch64/metrics.s
SOURCES_riscv64-linux := riscv64/runtime.s riscv64/config.s riscv64/metrics.s
METRICS_x86_64-linux := metrics.s
METRICS_aarch64-linux := aarch64/metrics.s
METRICS_riscv64-linux := riscv64/metrics.s
TARGET_FLAGS_riscv64-linux := -march=rv64gc -mabi=lp64d

.PHONY: all test metrics-tools metrics-test qualification-tools test-admission-fixture
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
	  test ! -L "$(BUILD)/asm-hub" && test ! -d "$(BUILD)/asm-hub" || \
	    { echo "asm-hub must not be a symlink or directory." >&2; exit 1; }; \
	  stage=$$(mktemp -d "$(BUILD)/.asm-server.XXXXXXXX"); \
	  trap 'rm -rf -- "$$stage"' EXIT HUP INT TERM; \
	  $(CC) $(TARGET_FLAGS_$(TARGET)) -std=c11 -Wall -Wextra -Werror \
	    -I"$(MHD_PREFIX)/include" -I"$(PG_INCLUDE_DIR)" \
	    -o "$$stage/abi-check" abi-check.c $(LIBRARIES); \
	  "$$stage/abi-check"; \
	  $(CC) $(TARGET_FLAGS_$(TARGET)) -g -fPIE -pie -Wl,-z,relro,-z,now,-z,noexecstack \
	    -x assembler-with-cpp -DASM_SOURCE_REVISION='"$(SOURCE_REVISION)"' \
	    -o "$$stage/asm-hub" $(SOURCES_$(TARGET)) $(LIBRARIES); \
	  mv -fT -- "$$stage/asm-hub" "$(BUILD)/asm-hub"

metrics-tools: all
	@set -eu; umask 077; \
	test ! -L "$(BUILD)/test-metrics" && test ! -d "$(BUILD)/test-metrics" || \
	  { echo "test-metrics must not be a symlink or directory." >&2; exit 1; }; \
	stage=$$(mktemp -d "$(BUILD)/.metrics-tests.XXXXXXXX"); \
	trap 'rm -rf -- "$$stage"' EXIT HUP INT TERM; \
	$(CC) $(TARGET_FLAGS_$(TARGET)) -fPIE -x assembler-with-cpp -DASM_METRICS_TEST \
	  -c "$(METRICS_$(TARGET))" -o "$$stage/metrics.o"; \
	$(CC) $(TARGET_FLAGS_$(TARGET)) -std=c11 -Wall -Wextra -Werror -fPIE -pie \
	  -Wl,-z,relro,-z,now,-z,noexecstack \
	  -Wl,--wrap=clock_gettime,--wrap=pthread_mutex_init,--wrap=pthread_mutex_lock,--wrap=pthread_mutex_unlock \
	  -o "$$stage/test-metrics" test_metrics.c "$$stage/metrics.o" -pthread; \
	chmod 0555 "$$stage/test-metrics"; \
	mv -fT -- "$$stage/test-metrics" "$(BUILD)/test-metrics"

metrics-test: metrics-tools
	"$(BUILD)/test-metrics"

qualification-tools: metrics-tools
	@set -eu; umask 077; \
	test ! -L "$(BUILD)/metrics-faults.so" && test ! -d "$(BUILD)/metrics-faults.so" || \
	  { echo "metrics-faults.so must not be a symlink or directory." >&2; exit 1; }; \
	stage=$$(mktemp -d "$(BUILD)/.metrics-faults.XXXXXXXX"); \
	trap 'rm -rf -- "$$stage"' EXIT HUP INT TERM; \
	$(CC) $(TARGET_FLAGS_$(TARGET)) -std=c11 -Wall -Wextra -Werror -fPIC -shared \
	  -Wl,-z,relro,-z,now,-z,noexecstack -I"$(MHD_PREFIX)/include" -I"$(PG_INCLUDE_DIR)" \
	  -o "$$stage/metrics-faults.so" metrics_faults.c -ldl -pthread; \
	chmod 0555 "$$stage/metrics-faults.so"; \
	mv -fT -- "$$stage/metrics-faults.so" "$(BUILD)/metrics-faults.so"

test-admission-fixture: all
	@set -eu; umask 077; \
	  test ! -L "$(BUILD)/connect-null.so" && test ! -d "$(BUILD)/connect-null.so" || \
	    { echo "connect-null.so must not be a symlink or directory." >&2; exit 1; }; \
	  stage=$$(mktemp -d "$(BUILD)/.asm-admission-fixture.XXXXXXXX"); \
	  trap 'rm -rf -- "$$stage"' EXIT HUP INT TERM; \
	  $(CC) $(TARGET_FLAGS_$(TARGET)) -std=c11 -Wall -Wextra -Werror -fPIC -shared \
	    -Wl,-z,relro,-z,now,-z,noexecstack \
	    -o "$$stage/connect-null.so" test_connect_null.c -ldl; \
	  chmod 0444 "$$stage/connect-null.so"; \
	  mv -fT -- "$$stage/connect-null.so" "$(BUILD)/connect-null.so"

test: metrics-test qualification-tools test-admission-fixture
	ASM_SERVER_BINARY="$(BUILD)/asm-hub" ASM_SERVER_SOURCE_REVISION="$(SOURCE_REVISION)" \
	ASM_PROTO_LIBPQ="$(PG_LIB_DIR)/libpq.so.5" ASM_PROTO_PG_BINDIR="$(PG_BINDIR)" \
	ASM_METRICS_TEST_DIRECTORY="$(BUILD)" \
	ASM_SERVER_CONNECT_NULL_FIXTURE="$(abspath $(BUILD))/connect-null.so" \
	python3 -m unittest -v test_runtime test_capacity
