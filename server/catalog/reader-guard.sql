-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Run in the reader's actual read-only transaction. One non-null text field.
-- This is the canonical catalog guard. The legacy asm.* guard is separate.
WITH reachable AS MATERIALIZED (
    SELECT r.* FROM pg_catalog.pg_roles AS r
    WHERE r.rolname = current_user OR pg_catalog.pg_has_role(current_user,r.oid,'MEMBER')
), authority AS MATERIALIZED (
    SELECT EXISTS (
        SELECT 1 FROM reachable AS r
        WHERE r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls
            OR left(r.rolname,3) = 'pg_' OR r.rolname IN ('asm_operator','asm_migrator')
            OR pg_catalog.has_database_privilege(r.oid,current_database(),'CREATE')
            OR EXISTS (
                SELECT 1 FROM pg_catalog.pg_namespace AS n
                WHERE left(n.nspname,8)<>'pg_temp_' AND left(n.nspname,14)<>'pg_toast_temp_'
                    AND pg_catalog.has_schema_privilege(r.oid,n.oid,'CREATE'))
            OR EXISTS (
                SELECT 1 FROM pg_catalog.pg_class AS c
                JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
                WHERE n.nspname NOT IN ('pg_catalog','information_schema')
                    AND left(n.nspname,8)<>'pg_temp_' AND left(n.nspname,14)<>'pg_toast_temp_'
                    AND CASE WHEN c.relkind IN ('r','p','v','m','f') THEN
                        pg_catalog.has_table_privilege(r.oid,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
                        OR pg_catalog.has_any_column_privilege(r.oid,c.oid,'INSERT,UPDATE,REFERENCES')
                        ELSE false END)
            OR EXISTS (
                SELECT 1 FROM pg_catalog.pg_class AS c
                JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
                WHERE n.nspname NOT IN ('pg_catalog','information_schema')
                    AND left(n.nspname,8)<>'pg_temp_' AND left(n.nspname,14)<>'pg_toast_temp_'
                    AND CASE WHEN c.relkind='S' THEN
                        pg_catalog.has_sequence_privilege(r.oid,c.oid,'USAGE,UPDATE') ELSE false END)
            OR EXISTS (
                SELECT 1 FROM pg_catalog.pg_proc AS p
                JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
                WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND p.prosecdef
                    AND left(n.nspname,8)<>'pg_temp_' AND left(n.nspname,14)<>'pg_toast_temp_'
                    AND pg_catalog.has_function_privilege(r.oid,p.oid,'EXECUTE'))
    ) AS writable
), reads AS MATERIALIZED (
    SELECT pg_catalog.has_schema_privilege(current_user,'asm_catalog','USAGE')
        AND pg_catalog.has_table_privilege(current_user,'asm_catalog.schema_version','SELECT')
        AND pg_catalog.has_table_privilege(current_user,'asm_catalog.current_exports','SELECT') AS permitted
), owners AS MATERIALIZED (
    SELECT (SELECT pg_catalog.pg_get_userbyid(nspowner) FROM pg_catalog.pg_namespace
                WHERE nspname='asm_catalog') = 'asm_migrator'
        AND NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_class AS c
            JOIN pg_catalog.pg_namespace AS n ON n.oid=c.relnamespace
            WHERE n.nspname='asm_catalog' AND pg_catalog.pg_get_userbyid(c.relowner)<>'asm_migrator')
        AND NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_proc AS p
            JOIN pg_catalog.pg_namespace AS n ON n.oid=p.pronamespace
            WHERE n.nspname='asm_catalog' AND pg_catalog.pg_get_userbyid(p.proowner)<>'asm_migrator') AS valid
), migration AS MATERIALIZED (
    SELECT count(*) = 1 AND coalesce(bool_and(version=1 AND
        sha384='259a54d22fcd1e53addf4f5f197d7ca0f7c5040e2492776fc60a30f59cd1428a6618f4ec39fa1f3df867d4b05ee2d9ae'),false) AS valid
    FROM asm_catalog.schema_version
), exports AS MATERIALIZED (
    -- These literal reads also fail closed if a view or permission is broken.
    SELECT count(*)=3 AND count(DISTINCT route)=3 AND min(revision)=max(revision)
        AND bool_and(revision>0 AND acceptance_commit COLLATE "C" ~ '^[0-9a-f]{40}$' AND acceptance_commit<>repeat('0',40)
            AND ((route='/registry/v1/index.json' AND media_type='application/json'
                    AND octet_length(body) BETWEEN 1 AND 4194304)
                OR (route IN ('/registry/v1/index.tsv','/registry/v1/index-macos.tsv')
                    AND media_type='text/tab-separated-values; charset=utf-8'
                    AND octet_length(body) BETWEEN 1 AND 1048576))) AS valid
    FROM asm_catalog.current_exports
)
SELECT CASE WHEN current_user='asm_reader' AND session_user=current_user
    AND current_setting('transaction_read_only')='on' AND NOT authority.writable
    AND reads.permitted AND owners.valid AND migration.valid AND exports.valid
    THEN '1' ELSE '0' END
FROM authority CROSS JOIN reads CROSS JOIN owners CROSS JOIN migration CROSS JOIN exports;
