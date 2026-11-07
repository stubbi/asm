# SPDX-License-Identifier: AGPL-3.0-or-later
# Same reviewed base and PostgreSQL source mechanism as the server image.
FROM debian:trixie-20261027-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS build

ARG ASM_SOURCE_REVISION
ARG TARGETARCH
RUN test "$TARGETARCH" = amd64 \
    && printf '%s\n' "$ASM_SOURCE_REVISION" | grep -Eq '^[0-9a-f]{40}$' \
    && test "$ASM_SOURCE_REVISION" != 0000000000000000000000000000000000000000
RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       bison build-essential bzip2 ca-certificates curl flex git libssl-dev perl python3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 \
      --output postgres.tar.bz2 https://ftp.postgresql.org/pub/source/v16.15/postgresql-16.15.tar.bz2 \
    && printf '%s  %s\n' c1575341fa7bd40f5274ea465b34390f4dc64cdd0770af327005caaeb9f6b7ed postgres.tar.bz2 | sha256sum --check --strict \
    && tar -xjf postgres.tar.bz2
WORKDIR /build/postgresql-16.15
RUN ./configure --prefix=/opt/asm/postgres --with-openssl \
      --without-readline --without-zlib --without-icu --without-lz4 --without-zstd \
    && make -j2 && make install

COPY tools/operator_source.py tools/operator_entrypoint.py tools/prepare_operator.py \
     tools/registry_admin.py tools/registry.py tools/test_operator_image.py /source/tools/
COPY server/catalog/schema.sql server/catalog/reader-guard.sql server/catalog/read-exports.sql /source/server/catalog/
COPY LICENSE README.md /source/
# This generated context contains only a verified complete HEAD bundle and its manifest.
COPY .operator-source/source.bundle .operator-source/source.json /source/
RUN python3 /source/tools/operator_source.py restore --bundle /source/source.bundle \
      --manifest /source/source.json --revision "$ASM_SOURCE_REVISION" --destination /opt/asm/source.git \
    && python3 -c 'import hashlib,json,pathlib; root=pathlib.Path("/source"); data=json.loads((root/"source.json").read_bytes()); assert all(hashlib.sha256((root/name).read_bytes()).hexdigest()==digest for name,digest in data["files"].items())' \
    && chmod -R a=rX /opt/asm/source.git

FROM debian:trixie-20261027-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS runtime
ARG ASM_SOURCE_REVISION
RUN apt-get update \
    && apt-get install --no-install-recommends --yes git python3 libssl3t64 \
    && rm -rf /var/lib/apt/lists/* \
    && printf 'asm:x:65532:65532:Asm operator:/nonexistent:/usr/sbin/nologin\n' >> /etc/passwd \
    && printf 'asm:x:65532:\n' >> /etc/group
COPY --from=build --chmod=0555 /opt/asm/postgres/bin/psql /opt/asm/postgres/bin/psql
COPY --from=build /opt/asm/postgres/lib/libpq.so* /opt/asm/postgres/lib/
COPY --from=build --chown=65532:65532 /opt/asm/source.git /opt/asm/source.git
COPY --from=build /source/tools/operator_entrypoint.py /source/tools/prepare_operator.py \
     /source/tools/registry_admin.py /source/tools/registry.py /app/tools/
COPY --from=build /source/server/catalog /app/server/catalog
COPY --from=build --chmod=0444 /source/source.json /app/SOURCE.json
COPY --from=build /source/LICENSE /source/README.md /app/
COPY --from=build /build/postgresql-16.15/COPYRIGHT /usr/share/licenses/asm-operator/postgresql/COPYRIGHT
COPY LICENSE README.md /usr/share/licenses/asm-operator/
LABEL org.opencontainers.image.source="https://github.com/stubbi/asm" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.revision=${ASM_SOURCE_REVISION} \
      org.opencontainers.image.description="Explicit registry operations; complete source is available in /opt/asm/source.git"
ENV HOME=/nonexistent PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 65532:65532
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/python3", "-I", "/app/tools/operator_entrypoint.py"]
CMD ["--help"]

# Only this derived test target contains PostgreSQL server tools and synthetic keys.
FROM runtime AS qualification
USER 0:0
RUN apt-get update \
    && apt-get install --no-install-recommends --yes jq \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/asm/postgres /opt/asm/postgres
COPY --from=build /usr/bin/openssl /usr/bin/openssl
COPY --from=build /etc/ssl/openssl.cnf /usr/lib/ssl/openssl.cnf
COPY --from=build /usr/share/doc/openssl/copyright /usr/share/licenses/asm-operator/qualification-openssl/COPYRIGHT
COPY tools/test_operator_image.py tools/operator_source.py tools/operator_publication.py /qualification/tools/
COPY server/test_runtime.py /qualification/server/test_runtime.py
COPY experiments/assembly-server/local_postgres.py experiments/assembly-server/guard.sql /qualification/experiments/assembly-server/
COPY experiments/assembly-server/fixtures/0001_registry.sql /qualification/experiments/assembly-server/fixtures/0001_registry.sql
COPY tests/hosted_registry /qualification/tests/hosted_registry
COPY tests/operator_image /qualification/tests/operator_image
COPY containers/operator-publication.jq /qualification/containers/operator-publication.jq
COPY .github/workflows/operator-images.yml /qualification/.github/workflows/operator-images.yml
COPY registry/packages /qualification/registry/packages
RUN ln -s /app/tools/registry.py /qualification/tools/registry.py \
    && ln -s /app/tools/registry_admin.py /qualification/tools/registry_admin.py \
    && ln -s /app/tools/prepare_operator.py /qualification/tools/prepare_operator.py \
    && ln -s /app/tools/operator_entrypoint.py /qualification/tools/operator_entrypoint.py \
    && ln -s /app/server/catalog /qualification/server/catalog \
    && chmod 0555 /opt/asm/postgres/bin/psql \
    && python3 /qualification/tools/test_operator_image.py --make-projection-fixtures /qualification/projected
USER 65532:65532

FROM runtime AS final
