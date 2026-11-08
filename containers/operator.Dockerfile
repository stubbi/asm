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

COPY tools /source/tools
COPY server/catalog/schema.sql server/catalog/reader-guard.sql server/catalog/read-exports.sql /source/server/catalog/
COPY server/publisher/schema.sql server/publisher/distribution.sql /source/server/publisher/
COPY verifier/go.mod verifier/go.sum /source/verifier/
COPY LICENSE README.md requirements-storage.txt /source/
# This generated context contains only a verified complete HEAD bundle and its manifest.
COPY .operator-source/source.bundle .operator-source/source.json /source/
RUN python3 /source/tools/operator_source.py restore --bundle /source/source.bundle \
      --manifest /source/source.json --revision "$ASM_SOURCE_REVISION" --destination /opt/asm/source.git \
    && python3 -c 'import hashlib,json,pathlib; root=pathlib.Path("/source"); data=json.loads((root/"source.json").read_bytes()); assert all(hashlib.sha256((root/name).read_bytes()).hexdigest()==digest for name,digest in data["files"].items())' \
    && chmod -R a=rX /opt/asm/source.git \
    && mkdir /accepted \
    && git --git-dir=/opt/asm/source.git archive --output=/build/accepted.tar \
       "$ASM_SOURCE_REVISION" verifier server tools/verifier_notices.py \
    && tar -xf /build/accepted.tar -C /accepted

FROM build AS operator-dependencies
RUN apt-get update \
    && apt-get install --no-install-recommends --yes python3-pip \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
# Upstream archive/checksum pins reviewed on 8 November 2026; qualification binds actual image bytes.
RUN curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 \
      --output go.tar.gz https://go.dev/dl/go1.27.3.linux-amd64.tar.gz \
    && printf '%s  %s\n' 65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40 go.tar.gz | sha256sum --check --strict \
    && tar -xzf go.tar.gz -C /opt/asm \
    && curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 \
      --output /build/kubectl https://dl.k8s.io/release/v1.35.10/bin/linux/amd64/kubectl \
    && printf '%s  %s\n' c49a28f1f4efc4d475ed05f47f2ce8e563bf7bef69ed77fe1b924ea6d83b6327 /build/kubectl | sha256sum --check --strict \
    && curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 \
      --output /build/kubernetes.tar.gz https://dl.k8s.io/release/v1.35.10/kubernetes.tar.gz \
    && printf '%s  %s\n' 58f6a64ca1ba07e9f73dc2d8155ede9212f12a48cfeed3a40420ccd4cd7929de127a22a6fc34ad6506ca5631fb8743c857b0c41a81dc9c4d4c079f7c797199f5 /build/kubernetes.tar.gz | sha512sum --check --strict \
    && tar -xzf /build/kubernetes.tar.gz -C /build kubernetes/LICENSES \
    && python3 -m pip install --no-compile --no-cache-dir --require-hashes \
       --target=/opt/asm/storage --requirement /source/requirements-storage.txt
WORKDIR /accepted/verifier
RUN CGO_ENABLED=0 GOTOOLCHAIN=local /opt/asm/go/bin/go build -mod=readonly -trimpath -buildvcs=false \
      -ldflags='-s -w -buildid=' -o /build/asm-trust ./cmd/asm-trust \
    && CGO_ENABLED=0 GOTOOLCHAIN=local python3 /accepted/tools/verifier_notices.py \
       --go /opt/asm/go/bin/go --output /build/asm-trust.LICENSES.txt

FROM debian:trixie-20261027-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS runtime
ARG ASM_SOURCE_REVISION
RUN apt-get update \
    && apt-get install --no-install-recommends --yes ca-certificates git python3 libssl3t64 \
    && rm -rf /var/lib/apt/lists/* \
    && printf 'asm:x:65532:65532:Asm operator:/nonexistent:/usr/sbin/nologin\n' >> /etc/passwd \
    && printf 'asm:x:65532:\n' >> /etc/group
COPY --from=build --chmod=0555 /opt/asm/postgres/bin/psql /opt/asm/postgres/bin/psql
COPY --from=build /opt/asm/postgres/lib/libpq.so* /opt/asm/postgres/lib/
COPY --from=build --chown=65532:65532 /opt/asm/source.git /opt/asm/source.git
COPY --from=build /source/tools/operator_entrypoint.py /source/tools/prepare_operator.py \
     /source/tools/registry_admin.py /source/tools/registry.py /source/tools/registry_mirror.py \
     /source/tools/registry_storage.py /source/tools/image_source.py /source/tools/prepare_signers.py \
     /source/tools/publisher_admin.py /source/tools/publication_worker.py /source/tools/kubernetes_checker.py \
     /source/tools/publication_check.py /source/tools/checker_entrypoint.py /source/tools/registry_distribution.py \
     /source/tools/verifier_notices.py /app/tools/
COPY --from=build /source/server/catalog /app/server/catalog
COPY --from=build /source/server/publisher /app/server/publisher
COPY --from=build /source/verifier /app/verifier
COPY --from=build /source/requirements-storage.txt /app/requirements-storage.txt
COPY --from=operator-dependencies --chmod=0555 /build/asm-trust /app/bin/asm-trust
COPY --from=operator-dependencies /build/asm-trust.LICENSES.txt /usr/share/licenses/asm-operator/asm-trust.LICENSES.txt
COPY --from=operator-dependencies --chmod=0555 /build/kubectl /usr/bin/kubectl
COPY --from=operator-dependencies /opt/asm/storage /opt/asm/storage
COPY --from=operator-dependencies /build/kubernetes/LICENSES /usr/share/licenses/asm-operator/kubectl
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
    && ln -s /app/tools/registry_mirror.py /qualification/tools/registry_mirror.py \
    && ln -s /app/tools/registry_storage.py /qualification/tools/registry_storage.py \
    && ln -s /app/tools/prepare_operator.py /qualification/tools/prepare_operator.py \
    && ln -s /app/tools/operator_entrypoint.py /qualification/tools/operator_entrypoint.py \
    && ln -s /app/tools/image_source.py /qualification/tools/image_source.py \
    && ln -s /app/tools/prepare_signers.py /qualification/tools/prepare_signers.py \
    && ln -s /app/tools/publisher_admin.py /qualification/tools/publisher_admin.py \
    && ln -s /app/tools/publication_worker.py /qualification/tools/publication_worker.py \
    && ln -s /app/tools/kubernetes_checker.py /qualification/tools/kubernetes_checker.py \
    && ln -s /app/tools/publication_check.py /qualification/tools/publication_check.py \
    && ln -s /app/tools/checker_entrypoint.py /qualification/tools/checker_entrypoint.py \
    && ln -s /app/tools/registry_distribution.py /qualification/tools/registry_distribution.py \
    && ln -s /app/server/catalog /qualification/server/catalog \
    && chmod 0555 /opt/asm/postgres/bin/psql \
    && python3 /qualification/tools/test_operator_image.py --make-projection-fixtures /qualification/projected
USER 65532:65532

# The assembly publisher has no operator dispatcher, signing key, or checker executor.
FROM build AS publisher-build
WORKDIR /build
RUN curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 \
      --output openssl.tar.gz https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz \
    && printf '%s  %s\n' 603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a openssl.tar.gz | sha256sum --check --strict \
    && tar -xzf openssl.tar.gz \
    && curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 \
      --output mhd.tar.gz https://ftp.gnu.org/gnu/libmicrohttpd/libmicrohttpd-1.0.3.tar.gz \
    && printf '%s  %s\n' 7816b57aae199cf5c3645e8770e1be5f0a4dfafbcb24b3772173dc4ee634126a mhd.tar.gz | sha256sum --check --strict \
    && tar -xzf mhd.tar.gz
WORKDIR /build/openssl-3.5.9
RUN ./Configure linux-x86_64 shared no-tests --prefix=/opt/asm/openssl --openssldir=/opt/asm/openssl/ssl --libdir=lib \
    && make -j2 build_libs && make install_dev
WORKDIR /build/libmicrohttpd-1.0.3
RUN ./configure --prefix=/opt/asm/mhd --disable-https --disable-examples --disable-doc --disable-tools --disable-curl --disable-static \
    && make -j2 && make install \
    && mkdir -p /build/mhd-notices \
    && for notice in COPYING COPYING.* LICENSE LICENSE.* NOTICE AUTHORS; do \
         if test -f "$notice"; then cp "$notice" /build/mhd-notices/; fi; done
RUN make -C /accepted/server publisher MHD_PREFIX=/opt/asm/mhd PG_PREFIX=/opt/asm/postgres BUILD=/build/publisher \
      'CC=cc -I/opt/asm/openssl/include -L/opt/asm/openssl/lib -Wl,--disable-new-dtags,-rpath,/opt/asm/openssl/lib' \
      PUBLISHER_OPENSSL_PROFILE=3.5.9 SOURCE_REVISION="$ASM_SOURCE_REVISION"

FROM debian:trixie-20261027-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS publisher
ARG ASM_SOURCE_REVISION
RUN printf 'asm:x:65532:65532:Asm publisher:/nonexistent:/usr/sbin/nologin\n' >> /etc/passwd \
    && printf 'asm:x:65532:\n' >> /etc/group
COPY --from=publisher-build --chmod=0555 /build/publisher/asm-publisher /usr/local/bin/asm-publisher
COPY --from=publisher-build /opt/asm/mhd/lib/*.so* /opt/asm/mhd/lib/
COPY --from=publisher-build /opt/asm/postgres/lib/libpq.so* /opt/asm/postgres/lib/
COPY --from=publisher-build /opt/asm/openssl/lib/*.so* /opt/asm/openssl/lib/
COPY --from=publisher-build /build/openssl-3.5.9/LICENSE.txt /usr/share/licenses/asm-publisher/openssl/LICENSE.txt
COPY --from=publisher-build /build/mhd-notices /usr/share/licenses/asm-publisher/libmicrohttpd
COPY --from=publisher-build /build/postgresql-16.15/COPYRIGHT /usr/share/licenses/asm-publisher/postgresql/COPYRIGHT
COPY --from=build --chmod=0444 /source/source.json /app/SOURCE.json
COPY --from=build /source/LICENSE /source/README.md /usr/share/licenses/asm-publisher/
LABEL org.opencontainers.image.source="https://github.com/stubbi/asm" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.revision=${ASM_SOURCE_REVISION}
ENV HOME=/nonexistent
USER 65532:65532
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/asm-publisher"]
CMD ["--help"]

# This target has only structural-check modules; no privileged operator tools or SDK.
FROM debian:trixie-20261027-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS checker
ARG ASM_SOURCE_REVISION
RUN apt-get update && apt-get install --no-install-recommends --yes python3 \
    && rm -rf /var/lib/apt/lists/* \
    && printf 'asm:x:65532:65532:Asm checker:/nonexistent:/usr/sbin/nologin\n' >> /etc/passwd \
    && printf 'asm:x:65532:\n' >> /etc/group
COPY --from=build /source/tools/checker_entrypoint.py /source/tools/image_source.py /source/tools/publication_check.py \
     /source/tools/registry.py /source/tools/registry_storage.py /app/tools/
COPY --from=build --chmod=0444 /source/source.json /app/SOURCE.json
COPY --from=build /source/LICENSE /source/README.md /usr/share/licenses/asm-checker/
LABEL org.opencontainers.image.source="https://github.com/stubbi/asm" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.revision=${ASM_SOURCE_REVISION}
ENV HOME=/nonexistent PYTHONDONTWRITEBYTECODE=1
USER 65532:65532
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/python3", "-B", "-I", "/app/tools/checker_entrypoint.py"]
CMD ["--help"]

FROM runtime AS final
