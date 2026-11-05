#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
logging=()
if test "$#" = 1 && test "$1" = --log-file; then
    logging=(-c logging_collector=on -c log_destination=stderr -c log_directory=/run/asm-postgres18
        -c log_filename=postgres.log -c log_file_mode=0600 -c log_rotation_age=0 -c log_rotation_size=0)
else
    test "$#" = 0
fi
test "$(id -u):$(id -g)" = 26:26
bindir=/usr/lib/postgresql/18/bin
for executable in postgres initdb; do
    version="$($bindir/$executable --version)"
    case "$version" in
        "$executable (PostgreSQL) 18.6"|"$executable (PostgreSQL) 18.6 "*) ;;
        *) exit 1 ;;
    esac
done
read -r nonce < /qualification/postgres18/nonce
[[ "$nonce" =~ ^[0-9a-f]{64}$ ]]
test ! -e /run/asm-postgres18/data
"$bindir/initdb" -D /run/asm-postgres18/data --username=asm_fixture_admin \
    --auth-host=reject --auth-local=reject --encoding=UTF8 --locale=C --no-instructions
cat > /run/asm-postgres18/data/pg_hba.conf <<'HBA'
hostssl all all 127.0.0.1/32 cert
hostnossl all all all reject
HBA
exec "$bindir/postgres" -D /run/asm-postgres18/data -p 5432 \
    -c listen_addresses=127.0.0.1 -c unix_socket_directories= \
    -c ssl=on -c ssl_min_protocol_version=TLSv1.2 \
    -c ssl_cert_file=/qualification/postgres18/server.crt \
    -c ssl_key_file=/qualification/postgres18/server.key \
    -c ssl_ca_file=/qualification/postgres18/ca.crt \
    -c "asm_fixture.nonce=$nonce" -c max_connections=64 -c shared_buffers=256MB \
    -c work_mem=4MB -c maintenance_work_mem=64MB -c effective_cache_size=512MB \
    -c max_worker_processes=0 -c max_parallel_workers=0 -c temp_file_limit=32768 \
    -c log_statement=none -c log_min_error_statement=panic "${logging[@]}"
