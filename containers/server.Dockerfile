# SPDX-License-Identifier: AGPL-3.0-or-later
FROM debian:trixie-20261027-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS build

ARG ASM_SOURCE_REVISION
ARG TARGETARCH
RUN printf '%s\n' "$ASM_SOURCE_REVISION" | grep -Eq '^[0-9a-f]{40}$' \
    && test "$ASM_SOURCE_REVISION" != 0000000000000000000000000000000000000000 \
    && case "$TARGETARCH" in amd64|arm64|riscv64) ;; *) exit 1 ;; esac
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       bison build-essential bzip2 ca-certificates curl flex libssl-dev perl pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 \
      --output mhd.tar.gz https://ftp.gnu.org/gnu/libmicrohttpd/libmicrohttpd-1.0.3.tar.gz \
    && printf '%s  %s\n' 7816b57aae199cf5c3645e8770e1be5f0a4dfafbcb24b3772173dc4ee634126a mhd.tar.gz | sha256sum --check --strict \
    && curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 \
      --output postgres.tar.bz2 https://ftp.postgresql.org/pub/source/v16.15/postgresql-16.15.tar.bz2 \
    && printf '%s  %s\n' c1575341fa7bd40f5274ea465b34390f4dc64cdd0770af327005caaeb9f6b7ed postgres.tar.bz2 | sha256sum --check --strict \
    && tar -xzf mhd.tar.gz \
    && tar -xjf postgres.tar.bz2

WORKDIR /build/libmicrohttpd-1.0.3
RUN ./configure --prefix=/opt/asm/mhd \
      --disable-https --disable-examples --disable-doc --disable-tools --disable-curl --disable-static \
    && make -j2 && make install \
    && mkdir -p /build/notices/libmicrohttpd \
    && test -f COPYING \
    && for notice in COPYING COPYING.* LICENSE LICENSE.* NOTICE AUTHORS; do \
         if test -f "$notice"; then cp "$notice" /build/notices/libmicrohttpd/; fi; \
       done

WORKDIR /build/postgresql-16.15
RUN ./configure --prefix=/opt/asm/postgres --with-openssl \
      --without-readline --without-zlib --without-icu --without-lz4 --without-zstd \
    && make -j2 && make install \
    && mkdir -p /build/notices/postgresql \
    && cp COPYRIGHT /build/notices/postgresql/COPYRIGHT

COPY server /source/server
WORKDIR /source/server
RUN make all MHD_PREFIX=/opt/asm/mhd PG_PREFIX=/opt/asm/postgres \
      BUILD=/build/server SOURCE_REVISION="$ASM_SOURCE_REVISION"

FROM debian:trixie-20261027-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS runtime
ARG ASM_SOURCE_REVISION
RUN apt-get update \
    && apt-get install --no-install-recommends --yes libssl3t64 \
    && rm -rf /var/lib/apt/lists/* \
    && printf 'asm:x:65532:65532:Asm runtime:/nonexistent:/usr/sbin/nologin\n' >> /etc/passwd \
    && printf 'asm:x:65532:\n' >> /etc/group
COPY --from=build /opt/asm/mhd/lib/*.so* /opt/asm/mhd/lib/
COPY --from=build /opt/asm/postgres/lib/libpq.so* /opt/asm/postgres/lib/
COPY --from=build --chmod=0555 /build/server/asm-hub /usr/local/bin/asm-hub
COPY --from=build /build/notices /usr/share/licenses/asm-hub/dependencies
COPY LICENSE /usr/share/licenses/asm-hub/LICENSE
LABEL org.opencontainers.image.source="https://github.com/stubbi/asm" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.revision=${ASM_SOURCE_REVISION}
ENV HOME=/nonexistent
USER 65532:65532
EXPOSE 8080
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/asm-hub"]
CMD ["serve"]

# Only this test target contains Python, PostgreSQL server tools, and fixtures.
FROM runtime AS qualification
USER 0:0
RUN apt-get update \
    && apt-get install --no-install-recommends --yes python3 openssl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/asm/postgres /opt/asm/postgres
COPY server/test_runtime.py /qualification/server/test_runtime.py
COPY experiments/assembly-server/local_postgres.py experiments/assembly-server/guard.sql /qualification/experiments/assembly-server/
COPY experiments/assembly-server/fixtures/0001_registry.sql /qualification/experiments/assembly-server/fixtures/0001_registry.sql
COPY tools/test_server_image.py /qualification/tools/test_server_image.py
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 65532:65532

FROM runtime AS final
