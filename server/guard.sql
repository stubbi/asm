-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Derived from the reviewed reference at 286a75c9d806aaed3e91bd54785db2ac60f5310a.
-- This query verifies the migration, required reads, and role constraints.
WITH role_write AS MATERIALIZED (
SELECT EXISTS (
           SELECT 1 FROM pg_catalog.pg_roles r
           WHERE (r.rolname = current_user OR pg_catalog.pg_has_role(current_user, r.oid, 'MEMBER'))
             AND (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls
               OR left(r.rolname, 3) = 'pg_'
               OR EXISTS (SELECT 1 FROM pg_catalog.pg_namespace s
                 WHERE pg_catalog.left(s.nspname, 8) <> 'pg_temp_'
                   AND pg_catalog.left(s.nspname, 14) <> 'pg_toast_temp_'
                   AND pg_catalog.has_schema_privilege(r.oid, s.oid, 'CREATE'))
               OR pg_catalog.has_database_privilege(r.oid, current_database(), 'CREATE')
               OR EXISTS (
                 SELECT 1 FROM pg_catalog.pg_class c
                 JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'asm' AND c.relkind IN ('r', 'p')
                   AND pg_catalog.has_table_privilege(r.oid, c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER')
               ))
         ) AS writable
), role_read AS MATERIALIZED (
SELECT pg_catalog.has_schema_privilege(current_user, 'asm', 'USAGE')
           AND pg_catalog.has_table_privilege(current_user, 'public._sqlx_migrations', 'SELECT')
           AND pg_catalog.has_table_privilege(current_user, 'asm.accounts', 'SELECT')
           AND pg_catalog.has_table_privilege(current_user, 'asm.namespaces', 'SELECT')
           AND pg_catalog.has_table_privilege(current_user, 'asm.packages', 'SELECT')
           AND pg_catalog.has_table_privilege(current_user, 'asm.releases', 'SELECT')
           AND pg_catalog.has_table_privilege(current_user, 'asm.artifacts', 'SELECT')
           AND pg_catalog.has_table_privilege(current_user, 'asm.publication_events', 'SELECT')
           AND pg_catalog.has_table_privilege(current_user, 'asm.download_observations', 'SELECT') AS readable
), catalog AS MATERIALIZED (
SELECT EXISTS (SELECT 1 FROM public._sqlx_migrations LIMIT 1),
                EXISTS (SELECT 1 FROM asm.accounts LIMIT 1),
                EXISTS (SELECT 1 FROM asm.namespaces LIMIT 1),
                EXISTS (SELECT 1 FROM asm.packages LIMIT 1),
                EXISTS (SELECT 1 FROM asm.releases LIMIT 1),
                EXISTS (SELECT 1 FROM asm.artifacts LIMIT 1),
                EXISTS (SELECT 1 FROM asm.publication_events LIMIT 1),
                EXISTS (SELECT 1 FROM asm.download_observations LIMIT 1)
), migration AS (
  SELECT count(*) = 1 AND bool_and(version = 1 AND success
    AND checksum = decode('e9fce69caa758cb9d15a700d92b76aba0fc3ca466a81624733124a742f2211aadae612ab877bd908a6e1d6ab5e803ef2', 'hex')) AS valid
  FROM public._sqlx_migrations
)
SELECT CASE WHEN NOT role_write.writable AND role_read.readable AND migration.valid
  AND current_setting('transaction_read_only') = 'on'
  THEN '1' ELSE '0' END
FROM role_write CROSS JOIN role_read CROSS JOIN migration CROSS JOIN catalog
