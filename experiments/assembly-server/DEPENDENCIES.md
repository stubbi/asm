# Build the local dependencies

This recipe supplies the exact libraries, headers, and PostgreSQL tools used by the experiment.
It targets Linux x86-64 with the GNU toolchain.
It installs files below the checkout's ignored `build` directory.

Use a C compiler, GNU make, binutils, Perl, tar, bzip2, curl, and `sha256sum`.
Use Python 3.10 or later for the tests.
Run PostgreSQL tests as an ordinary user, without `sudo`.
The [PostgreSQL documentation](https://www.postgresql.org/docs/16/app-initdb.html) requires an unprivileged server owner.

The following commands download source from the official GNU and PostgreSQL hosts.
`make` and `make test` do not download dependencies or contact an external database.

## 1. Fetch the pinned sources

Run these commands from the repository root:

```sh
set -eu
ASM_DEPS="$PWD/build/assembly-server-deps"
mkdir -p "$ASM_DEPS/downloads" "$ASM_DEPS/tmp"

curl --fail --location --proto '=https' --proto-redir '=https' --max-time 120 \
  --output "$ASM_DEPS/downloads/libmicrohttpd-1.0.3.tar.gz" \
  https://ftp.gnu.org/gnu/libmicrohttpd/libmicrohttpd-1.0.3.tar.gz
printf '%s  %s\n' \
  7816b57aae199cf5c3645e8770e1be5f0a4dfafbcb24b3772173dc4ee634126a \
  "$ASM_DEPS/downloads/libmicrohttpd-1.0.3.tar.gz" | sha256sum --check --strict

curl --fail --location --proto '=https' --proto-redir '=https' --max-time 120 \
  --output "$ASM_DEPS/downloads/postgresql-16.15.tar.bz2" \
  https://ftp.postgresql.org/pub/source/v16.15/postgresql-16.15.tar.bz2
printf '%s  %s\n' \
  c1575341fa7bd40f5274ea465b34390f4dc64cdd0770af327005caaeb9f6b7ed \
  "$ASM_DEPS/downloads/postgresql-16.15.tar.bz2" | sha256sum --check --strict
```

Stop if either digest check fails.
Each successful digest check prints the archive path followed by `OK`.
These checks bind the downloaded bytes to the recorded inputs.
They are not a claim that a detached maintainer signature was verified.

## 2. Build the libraries and fixture tools

Extract the archives only after both checks pass:

```sh
tar -xzf "$ASM_DEPS/downloads/libmicrohttpd-1.0.3.tar.gz" -C "$ASM_DEPS"
tar -xjf "$ASM_DEPS/downloads/postgresql-16.15.tar.bz2" -C "$ASM_DEPS"
```

Build the HTTP library:

```sh
(
  set -eu
  cd "$ASM_DEPS/libmicrohttpd-1.0.3"
  TMPDIR="$ASM_DEPS/tmp" ./configure --prefix="$ASM_DEPS/mhd" \
    --disable-https --disable-examples --disable-doc --disable-tools \
    --disable-curl --disable-static
  make -j2
  make install
)
```

Build PostgreSQL, libpq, and their headers:

```sh
(
  set -eu
  cd "$ASM_DEPS/postgresql-16.15"
  TMPDIR="$ASM_DEPS/tmp" ./configure --prefix="$ASM_DEPS/postgres" \
    --without-readline --without-zlib --without-icu --without-lz4 --without-zstd
  make -j2
  make install
)
```

Use two build jobs to keep concurrent local work bounded.
The PostgreSQL build uses its default configuration without TLS support.
These dependencies serve a loopback experiment; this recipe does not qualify a public TLS stack.

## 3. Run the experiment checks

Run this command from the repository root:

```sh
make -C experiments/assembly-server test \
  MHD_PREFIX="$ASM_DEPS/mhd" \
  PG_PREFIX="$ASM_DEPS/postgres"
```

The build checks headers, runtime versions, and the ABI before compiling the assembly application.
The tests initialize their own PostgreSQL clusters and stop them after use.
They do not require Rust, an existing PostgreSQL service, credentials, a container engine, or a public endpoint.

The library prefixes are trusted local build inputs.
Use full paths when they are outside this recipe's directory.
`PG_INCLUDE_DIR`, `PG_LIB_DIR`, and `PG_BINDIR` can describe a split installation.
The same exact versions and ABI checks still apply.

## Sources

- [GNU libmicrohttpd 1.0.3 announcement](https://lists.gnu.org/archive/html/info-gnu/2026-04/msg00000.html)
- [PostgreSQL 16.15 source directory](https://ftp.postgresql.org/pub/source/v16.15/)
- [PostgreSQL 16.15 source digest](https://ftp.postgresql.org/pub/source/v16.15/postgresql-16.15.tar.bz2.sha256)
- [PostgreSQL build documentation](https://www.postgresql.org/docs/16/install-make.html)
