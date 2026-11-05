# SPDX-License-Identifier: AGPL-3.0-or-later
# These targets add only isolated test inputs to already inspected images.
FROM asm-operator:qualification-amd64 AS operator
COPY --chown=65532:65532 --chmod=0400 .postgres18-fixture/app/* /qualification/postgres18/
COPY tools/postgres18_fixture.py tools/postgres18_docker.py tools/test_postgres18_image.py tools/test_server_image.py /qualification/tools/

FROM asm-server:qualification-amd64 AS http
COPY --chown=65532:65532 --chmod=0400 .postgres18-fixture/app/* /qualification/postgres18/
COPY tools/postgres18_fixture.py tools/postgres18_docker.py tools/test_postgres18_image.py tools/test_operator_image.py tools/operator_source.py /qualification/tools/

FROM ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie@sha256:39add80f5b1e573e2f6b641c66fd1a2f8dede67ca0330e870285bc1078551390 AS database
COPY --chown=26:26 --chmod=0400 .postgres18-fixture/server/* /qualification/postgres18/
COPY --chmod=0555 containers/postgres18-entrypoint.sh /qualification/postgres18-entrypoint.sh
USER 26:26
ENTRYPOINT ["/bin/bash", "/qualification/postgres18-entrypoint.sh"]
CMD []
