-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Apply this whole file in one transaction as asm_migrator.
-- Operator imports are assertions of acceptance, not publisher authentication.
SET LOCAL standard_conforming_strings = on;
SET LOCAL search_path = pg_catalog,pg_temp;
DO $$
BEGIN
    IF current_user <> 'asm_migrator' THEN
        RAISE EXCEPTION 'Use the catalog migration identity' USING ERRCODE = '42501';
    END IF;
END;
$$;

CREATE SCHEMA asm_catalog AUTHORIZATION asm_migrator;
REVOKE ALL ON SCHEMA asm_catalog FROM PUBLIC,asm_reader,asm_operator;

CREATE TABLE asm_catalog.schema_version (
    version integer PRIMARY KEY CHECK(version=1),
    sha384 text NOT NULL CHECK(sha384 COLLATE "C" ~ '^[0-9a-f]{96}$')
);

CREATE TABLE asm_catalog.namespaces (
    name text COLLATE "C" PRIMARY KEY,
    github_id bigint NOT NULL CHECK (github_id > 0),
    acceptance_commit text NOT NULL CHECK (acceptance_commit COLLATE "C" ~ '^[0-9a-f]{40}$' AND acceptance_commit <> repeat('0', 40)),
    actor name NOT NULL DEFAULT session_user,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (name COLLATE "C" ~ '^[a-z][a-z0-9-]{0,38}$' AND right(name, 1) <> '-' AND strpos(name, '--') = 0)
);

CREATE TABLE asm_catalog.releases (
    name text COLLATE "C" NOT NULL,
    version text COLLATE "C" NOT NULL,
    namespace text COLLATE "C" NOT NULL REFERENCES asm_catalog.namespaces(name),
    manifest text NOT NULL CHECK (octet_length(manifest) BETWEEN 1 AND 65536),
    sha256 text NOT NULL CHECK (sha256 = encode(pg_catalog.sha256(convert_to(manifest, 'UTF8')), 'hex')),
    acceptance_commit text NOT NULL CHECK (acceptance_commit COLLATE "C" ~ '^[0-9a-f]{40}$' AND acceptance_commit <> repeat('0', 40)),
    PRIMARY KEY (name, version)
);

CREATE TABLE asm_catalog.artifact_urls (
    url text COLLATE "C" PRIMARY KEY,
    name text COLLATE "C" NOT NULL,
    version text COLLATE "C" NOT NULL,
    FOREIGN KEY (name, version) REFERENCES asm_catalog.releases(name, version)
);

CREATE TABLE asm_catalog.snapshots (
    revision bigint PRIMARY KEY CHECK (revision > 0),
    acceptance_commit text NOT NULL UNIQUE CHECK (acceptance_commit COLLATE "C" ~ '^[0-9a-f]{40}$' AND acceptance_commit <> repeat('0', 40)),
    payload_sha256 text NOT NULL CHECK (payload_sha256 COLLATE "C" ~ '^[0-9a-f]{64}$'),
    actor name NOT NULL DEFAULT session_user,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE asm_catalog.exports (
    revision bigint NOT NULL REFERENCES asm_catalog.snapshots(revision),
    route text COLLATE "C" NOT NULL CHECK (route IN (
        '/registry/v1/index.tsv', '/registry/v1/index-macos.tsv',
        '/registry/v1/index-all.tsv', '/registry/v1/index.json')),
    media_type text NOT NULL,
    body text NOT NULL,
    sha256 text NOT NULL CHECK (sha256 = encode(pg_catalog.sha256(convert_to(body, 'UTF8')), 'hex')),
    PRIMARY KEY (revision, route),
    CHECK ((route = '/registry/v1/index.json' AND media_type = 'application/json' AND octet_length(body) BETWEEN 1 AND 4194304)
        OR (route <> '/registry/v1/index.json' AND media_type = 'text/tab-separated-values; charset=utf-8' AND octet_length(body) BETWEEN 1 AND 1048576))
);

CREATE TABLE asm_catalog.head (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    revision bigint NOT NULL REFERENCES asm_catalog.snapshots(revision)
);

CREATE TABLE asm_catalog.audit (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    action text NOT NULL CHECK (action IN ('namespace_bound', 'catalog_imported')),
    acceptance_repository text NOT NULL DEFAULT 'https://github.com/stubbi/asm'
        CHECK (acceptance_repository = 'https://github.com/stubbi/asm'),
    acceptance_commit text NOT NULL CHECK (acceptance_commit COLLATE "C" ~ '^[0-9a-f]{40}$' AND acceptance_commit <> repeat('0', 40)),
    detail jsonb NOT NULL CHECK (jsonb_typeof(detail) = 'object' AND octet_length(detail::text) <= 4096),
    actor name NOT NULL DEFAULT session_user,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE FUNCTION asm_catalog.reject_change() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog,pg_temp SET standard_conforming_strings = on AS $$
BEGIN
    RAISE EXCEPTION 'Retained catalog data is immutable' USING ERRCODE = '55000';
END;
$$;

DO $$
DECLARE table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY['namespaces', 'releases', 'artifact_urls', 'snapshots', 'exports', 'audit'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_row BEFORE UPDATE OR DELETE ON asm_catalog.%I FOR EACH ROW EXECUTE FUNCTION asm_catalog.reject_change()', table_name);
        EXECUTE format('CREATE TRIGGER immutable_table BEFORE TRUNCATE ON asm_catalog.%I FOR EACH STATEMENT EXECUTE FUNCTION asm_catalog.reject_change()', table_name);
    END LOOP;
END;
$$;

-- JSON is checked before conversion to jsonb, which would discard duplicate keys.
CREATE FUNCTION asm_catalog.check_json(value json, depth integer DEFAULT 0) RETURNS void
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog,pg_temp SET standard_conforming_strings = on AS $$
DECLARE item json;
BEGIN
    IF depth > 16 OR value IS NULL THEN
        RAISE EXCEPTION 'Catalog JSON nesting or null input is invalid' USING ERRCODE = '22023';
    END IF;
    IF json_typeof(value) = 'object' THEN
        IF (SELECT count(*) <> count(DISTINCT key) FROM json_each(value)) THEN
            RAISE EXCEPTION 'Catalog JSON contains duplicate fields' USING ERRCODE = '22023';
        END IF;
        FOR item IN SELECT v.value FROM json_each(value) AS v LOOP
            PERFORM asm_catalog.check_json(item, depth + 1);
        END LOOP;
    ELSIF json_typeof(value) = 'array' THEN
        FOR item IN SELECT v.value FROM json_array_elements(value) AS v LOOP
            PERFORM asm_catalog.check_json(item, depth + 1);
        END LOOP;
    ELSIF json_typeof(value) = 'number' AND value::text COLLATE "C" !~ '^(0|-?[1-9][0-9]*)$' THEN
        RAISE EXCEPTION 'Catalog JSON numbers must have an integer encoding' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE FUNCTION asm_catalog.portable_path(value text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog,pg_temp SET standard_conforming_strings = on AS $$
DECLARE segment text;
BEGIN
    IF value = '.' THEN RETURN true; END IF;
    IF value IS NULL OR octet_length(value) NOT BETWEEN 1 AND 240 THEN RETURN false; END IF;
    FOREACH segment IN ARRAY string_to_array(value, '/') LOOP
        IF segment COLLATE "C" !~ '^[A-Za-z0-9_.-]+$' OR segment IN ('.', '..')
            OR left(segment, 1) = '-' OR right(segment, 1) = '.'
            OR lower(split_part(segment, '.', 1)) = ANY (ARRAY[
                'con','prn','aux','nul','com1','com2','com3','com4','com5','com6','com7','com8','com9',
                'lpt1','lpt2','lpt3','lpt4','lpt5','lpt6','lpt7','lpt8','lpt9']) THEN
            RETURN false;
        END IF;
    END LOOP;
    RETURN true;
END;
$$;

-- Match registry.json_bytes for the validated ASCII v1 domain.
-- This returns no final LF so nested containers retain their exact indentation.
CREATE FUNCTION asm_catalog.canonical_json(value jsonb, depth integer DEFAULT 0) RETURNS text
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog,pg_temp SET standard_conforming_strings = on AS $$
DECLARE body text;
BEGIN
    IF depth > 16 OR value IS NULL THEN
        RAISE EXCEPTION 'Canonical JSON nesting is invalid' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(value) = 'object' THEN
        IF value = '{}'::jsonb THEN RETURN '{}'; END IF;
        SELECT string_agg(repeat(' ',2*(depth+1)) || to_json(key)::text || ': ' ||
            asm_catalog.canonical_json(v.value,depth+1), ',' || chr(10) ORDER BY key COLLATE "C")
        INTO body FROM jsonb_each(value) AS v;
        RETURN '{' || chr(10) || body || chr(10) || repeat(' ',2*depth) || '}';
    ELSIF jsonb_typeof(value) = 'array' THEN
        IF value = '[]'::jsonb THEN RETURN '[]'; END IF;
        SELECT string_agg(repeat(' ',2*(depth+1)) || asm_catalog.canonical_json(v.value,depth+1),
            ',' || chr(10) ORDER BY ordinal) INTO body
        FROM jsonb_array_elements(value) WITH ORDINALITY AS v(value,ordinal);
        RETURN '[' || chr(10) || body || chr(10) || repeat(' ',2*depth) || ']';
    END IF;
    RETURN value::text;
END;
$$;

CREATE FUNCTION asm_catalog.manifest(raw text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog,pg_temp SET standard_conforming_strings = on AS $$
DECLARE d jsonb; source jsonb; artifact jsonb; parts text[];
BEGIN
    IF raw IS NULL OR octet_length(raw) NOT BETWEEN 1 AND 65536 THEN
        RAISE EXCEPTION 'Catalog manifest size is invalid' USING ERRCODE = '22023';
    END IF;
    PERFORM asm_catalog.check_json(raw::json);
    d := raw::jsonb;
    IF jsonb_typeof(d) <> 'object' OR NOT d ?& ARRAY['schema','name','version','summary','license','source','artifacts','yanked']
        OR d - ARRAY['schema','name','version','summary','license','source','artifacts','yanked','yank_reason'] <> '{}'::jsonb
        OR jsonb_typeof(d->'schema') <> 'number' OR d->>'schema' <> '1'
        OR jsonb_typeof(d->'name') <> 'string' OR d->>'name' COLLATE "C" !~ '^[a-z][a-z0-9-]{0,38}/[a-z][a-z0-9-]{0,63}$'
        OR d->>'name' LIKE '%--%' OR d->>'name' LIKE '%-/%' OR right(d->>'name',1) = '-'
        OR jsonb_typeof(d->'version') <> 'string'
        OR d->>'version' COLLATE "C" !~ '^(0|[1-9][0-9]{0,9})[.](0|[1-9][0-9]{0,9})[.](0|[1-9][0-9]{0,9})$'
        OR jsonb_typeof(d->'summary') <> 'string' OR d->>'summary' COLLATE "C" !~ '^[ -~]{1,160}$'
        OR d->>'summary' <> btrim(d->>'summary')
        OR jsonb_typeof(d->'license') <> 'string' OR NOT d->>'license' = ANY(ARRAY[
            'AGPL-3.0-only','AGPL-3.0-or-later','Apache-2.0','BSD-2-Clause','BSD-3-Clause','BSL-1.0',
            'GPL-2.0-only','GPL-2.0-or-later','GPL-3.0-only','GPL-3.0-or-later','ISC',
            'LGPL-2.1-only','LGPL-2.1-or-later','LGPL-3.0-only','LGPL-3.0-or-later','MIT','MPL-2.0','Unlicense','Zlib'])
        OR jsonb_typeof(d->'yanked') <> 'boolean' THEN
        RAISE EXCEPTION 'Catalog manifest fields are invalid' USING ERRCODE = '22023';
    END IF;
    parts := string_to_array(d->>'version', '.');
    IF parts[1]::bigint > 2147483647 OR parts[2]::bigint > 2147483647 OR parts[3]::bigint > 2147483647 THEN
        RAISE EXCEPTION 'Catalog version is outside the v1 range' USING ERRCODE = '22023';
    END IF;
    IF ((d->>'yanked')::boolean AND (jsonb_typeof(d->'yank_reason') IS DISTINCT FROM 'string'
            OR d->>'yank_reason' COLLATE "C" !~ '^[ -~]{1,160}$' OR d->>'yank_reason' <> btrim(d->>'yank_reason')))
        OR (NOT (d->>'yanked')::boolean AND d ? 'yank_reason' AND d->>'yank_reason' IS DISTINCT FROM '') THEN
        RAISE EXCEPTION 'Catalog yank state is invalid' USING ERRCODE = '22023';
    END IF;
    source := d->'source';
    IF jsonb_typeof(source) <> 'object' OR NOT source ?& ARRAY['repository','commit','path']
        OR source - ARRAY['repository','commit','path'] <> '{}'::jsonb
        OR jsonb_typeof(source->'repository') <> 'string'
        OR source->>'repository' COLLATE "C" !~ '^https://github[.]com/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'
        OR right(source->>'repository', 4) = '.git'
        OR jsonb_typeof(source->'commit') <> 'string' OR source->>'commit' COLLATE "C" !~ '^[0-9a-f]{40}$'
        OR source->>'commit' = repeat('0', 40)
        OR jsonb_typeof(source->'path') <> 'string' OR NOT asm_catalog.portable_path(source->>'path') THEN
        RAISE EXCEPTION 'Catalog source fields are invalid' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(d->'artifacts') <> 'array' OR jsonb_array_length(d->'artifacts') NOT BETWEEN 1 AND 14 THEN
        RAISE EXCEPTION 'Catalog artifact count is invalid' USING ERRCODE = '22023';
    END IF;
    FOR artifact IN SELECT value FROM jsonb_array_elements(d->'artifacts') LOOP
        IF jsonb_typeof(artifact) <> 'object' OR NOT artifact ?& ARRAY['target','kind','sha256','url','bytes']
            OR artifact - ARRAY['target','kind','sha256','url','bytes'] <> '{}'::jsonb
            OR jsonb_typeof(artifact->'target') <> 'string'
            OR NOT artifact->>'target' = ANY(ARRAY['x86_64-linux','aarch64-linux','riscv64-linux','aarch64-macos',
                'x86_64-windows','aarch64-windows'])
            OR jsonb_typeof(artifact->'kind') <> 'string' OR NOT artifact->>'kind' = ANY(ARRAY['source','executable'])
            OR jsonb_typeof(artifact->'sha256') <> 'string' OR artifact->>'sha256' COLLATE "C" !~ '^[0-9a-f]{64}$'
            OR jsonb_typeof(artifact->'bytes') <> 'number' OR artifact->>'bytes' COLLATE "C" !~ '^[1-9][0-9]*$'
            OR (artifact->>'bytes')::numeric > 67108864
            OR jsonb_typeof(artifact->'url') <> 'string' OR octet_length(artifact->>'url') > 768
            OR artifact->>'url' COLLATE "C" !~ '^https://github[.]com/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}/releases/download/[A-Za-z0-9][A-Za-z0-9._-]{0,127}/[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
            OR right(split_part(artifact->>'url', '/', 5), 4) = '.git'
            OR (artifact->>'kind' = 'source' AND right(artifact->>'url', 7) <> '.tar.gz') THEN
            RAISE EXCEPTION 'Catalog artifact fields are invalid' USING ERRCODE = '22023';
        END IF;
    END LOOP;
    IF (SELECT count(*) <> count(DISTINCT (value->>'target', value->>'kind'))
        OR count(*) <> count(DISTINCT value->>'url') FROM jsonb_array_elements(d->'artifacts')) THEN
        RAISE EXCEPTION 'Catalog artifacts are duplicated' USING ERRCODE = '22023';
    END IF;
    IF raw <> asm_catalog.canonical_json(d) || chr(10) THEN
        RAISE EXCEPTION 'Catalog manifest encoding is not canonical' USING ERRCODE = '22023';
    END IF;
    RETURN d;
END;
$$;

CREATE FUNCTION asm_catalog.expected_index(records jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog,pg_temp SET standard_conforming_strings = on AS $$
    WITH r AS (
        SELECT value AS m, value->>'name' AS name,
            split_part(value->>'version','.',1)::integer AS major,
            split_part(value->>'version','.',2)::integer AS minor,
            split_part(value->>'version','.',3)::integer AS patch
        FROM jsonb_array_elements(records)
    ), p AS (SELECT DISTINCT name FROM r), leaders AS (
        SELECT p.name,
            coalesce((SELECT m FROM r WHERE r.name = p.name AND NOT (m->>'yanked')::boolean
                ORDER BY major DESC, minor DESC, patch DESC LIMIT 1),
                (SELECT m FROM r WHERE r.name = p.name ORDER BY major,minor,patch LIMIT 1)) AS leader,
            (SELECT m->>'version' FROM r WHERE r.name = p.name AND NOT (m->>'yanked')::boolean
                ORDER BY major DESC, minor DESC, patch DESC LIMIT 1) AS latest
        FROM p
    )
    SELECT jsonb_build_object('schema', 1, 'packages', coalesce(jsonb_agg(jsonb_build_object(
        'name', l.name, 'summary', l.leader->'summary', 'license', l.leader->'license',
        'repository', l.leader->'source'->'repository', 'latest', l.latest,
        'targets', (SELECT jsonb_agg(target ORDER BY target COLLATE "C") FROM (
            SELECT DISTINCT a.value->>'target' AS target FROM r
            CROSS JOIN LATERAL jsonb_array_elements(m->'artifacts') AS a WHERE r.name = l.name) AS t),
        'versions', (SELECT jsonb_agg(jsonb_build_object(
            'version', m->'version', 'license', m->'license', 'source', m->'source', 'yanked', m->'yanked',
            'artifacts', (SELECT jsonb_agg(a.value ORDER BY a.value->>'target' COLLATE "C",a.value->>'kind' COLLATE "C")
                FROM jsonb_array_elements(m->'artifacts') AS a),
            'evidence', jsonb_build_object('metadata','validated','artifacts','not-run','provenance','not-run','formal','not-run','agent_review','not-run'))
            || CASE WHEN (m->>'yanked')::boolean THEN jsonb_build_object('yank_reason',m->'yank_reason') ELSE '{}'::jsonb END
            ORDER BY major,minor,patch) FROM r WHERE r.name = l.name)
        ) ORDER BY l.name COLLATE "C"), '[]'::jsonb)) FROM leaders AS l;
$$;

CREATE FUNCTION asm_catalog.bind_namespace(p_namespace text, p_github_id bigint, p_acceptance_commit text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,pg_temp SET standard_conforming_strings = on AS $$
DECLARE prior bigint;
BEGIN
    IF session_user <> 'asm_operator' THEN RAISE EXCEPTION 'Use the catalog operator identity' USING ERRCODE = '42501'; END IF;
    IF p_namespace IS NULL OR p_namespace COLLATE "C" !~ '^[a-z][a-z0-9-]{0,38}$'
        OR right(p_namespace,1) = '-' OR strpos(p_namespace,'--') > 0
        OR p_github_id IS NULL OR p_github_id <= 0
        OR p_acceptance_commit IS NULL OR p_acceptance_commit COLLATE "C" !~ '^[0-9a-f]{40}$' OR p_acceptance_commit = repeat('0',40) THEN
        RAISE EXCEPTION 'Namespace assertion is invalid' USING ERRCODE = '22023';
    END IF;
    PERFORM pg_advisory_xact_lock(1095978307, 1);
    SELECT github_id INTO prior FROM asm_catalog.namespaces WHERE name = p_namespace;
    IF prior IS NOT NULL THEN
        IF prior <> p_github_id THEN RAISE EXCEPTION 'Namespace ownership conflicts' USING ERRCODE = '23505'; END IF;
        RETURN false;
    END IF;
    INSERT INTO asm_catalog.namespaces(name,github_id,acceptance_commit) VALUES(p_namespace,p_github_id,p_acceptance_commit);
    INSERT INTO asm_catalog.audit(action,acceptance_commit,detail)
        VALUES('namespace_bound',p_acceptance_commit,jsonb_build_object('namespace',p_namespace,'github_id',p_github_id));
    RETURN true;
END;
$$;

CREATE FUNCTION asm_catalog.publish(p_acceptance_commit text, p_expected_revision bigint, p_records text[],
    p_linux_tsv text, p_macos_tsv text, p_full_tsv text, p_index_json text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog,pg_temp SET standard_conforming_strings = on AS $$
DECLARE records jsonb; r jsonb; raw text; full_feed text; linux_feed text; macos_feed text; payload_sha text;
    existing asm_catalog.snapshots%ROWTYPE; old_revision bigint; new_revision bigint;
BEGIN
    IF session_user <> 'asm_operator' THEN RAISE EXCEPTION 'Use the catalog operator identity' USING ERRCODE = '42501'; END IF;
    IF p_acceptance_commit IS NULL OR p_acceptance_commit COLLATE "C" !~ '^[0-9a-f]{40}$' OR p_acceptance_commit = repeat('0',40)
        OR p_expected_revision IS NULL OR p_expected_revision < 0 OR p_records IS NULL
        OR cardinality(p_records) > 4096 OR (cardinality(p_records) > 0 AND (array_ndims(p_records) <> 1 OR array_lower(p_records,1) <> 1))
        OR p_linux_tsv IS NULL OR octet_length(p_linux_tsv) NOT BETWEEN 1 AND 1048576
        OR p_macos_tsv IS NULL OR octet_length(p_macos_tsv) NOT BETWEEN 1 AND 1048576
        OR p_full_tsv IS NULL OR octet_length(p_full_tsv) NOT BETWEEN 1 AND 1048576
        OR p_index_json IS NULL OR octet_length(p_index_json) NOT BETWEEN 1 AND 4194304 OR right(p_index_json,1) <> chr(10)
        OR coalesce((SELECT sum(octet_length(v)) FROM unnest(p_records) AS v),0) > 16777216 THEN
        RAISE EXCEPTION 'Catalog import bounds are invalid' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(jsonb_agg(asm_catalog.manifest(value) ORDER BY ordinal),'[]'::jsonb)
        INTO records FROM unnest(p_records) WITH ORDINALITY AS v(value,ordinal);
    IF (SELECT count(*) <> count(DISTINCT (value->>'name',value->>'version')) FROM jsonb_array_elements(records)) THEN
        RAISE EXCEPTION 'Catalog release identities are duplicated' USING ERRCODE = '22023';
    END IF;
    IF (SELECT count(*) > 4096 FROM jsonb_array_elements(records) AS r
        CROSS JOIN LATERAL jsonb_array_elements(r.value->'artifacts') AS a WHERE NOT (r.value->>'yanked')::boolean) THEN
        RAISE EXCEPTION 'Catalog artifact row count exceeds the native feed' USING ERRCODE = '22023';
    END IF;
    WITH rows AS (
        SELECT r.value->>'name' AS name, r.value->>'version' AS version, r.value->>'summary' AS summary,
            a.value AS artifact FROM jsonb_array_elements(records) AS r
        CROSS JOIN LATERAL jsonb_array_elements(r.value->'artifacts') AS a WHERE NOT (r.value->>'yanked')::boolean
    ), lines AS (
        SELECT *, concat_ws(chr(9),name,version,artifact->>'target',artifact->>'kind',artifact->>'sha256',
            artifact->>'url',artifact->>'bytes',summary) AS line FROM rows
    )
    SELECT '# asm-registry-v1' || chr(10) || coalesce(string_agg(line || chr(10),'' ORDER BY name COLLATE "C",
            split_part(version,'.',1)::integer,split_part(version,'.',2)::integer,split_part(version,'.',3)::integer,
            artifact->>'target' COLLATE "C",artifact->>'kind' COLLATE "C"),''),
        '# asm-registry-v1' || chr(10) || coalesce(string_agg(line || chr(10),'' ORDER BY name COLLATE "C",
            split_part(version,'.',1)::integer,split_part(version,'.',2)::integer,split_part(version,'.',3)::integer,
            artifact->>'target' COLLATE "C",artifact->>'kind' COLLATE "C") FILTER (WHERE artifact->>'target' IN
                ('x86_64-linux','aarch64-linux','riscv64-linux')),''),
        '# asm-registry-v1' || chr(10) || coalesce(string_agg(line || chr(10),'' ORDER BY name COLLATE "C",
            split_part(version,'.',1)::integer,split_part(version,'.',2)::integer,split_part(version,'.',3)::integer,
            artifact->>'target' COLLATE "C",artifact->>'kind' COLLATE "C") FILTER (WHERE artifact->>'target' IN
                ('x86_64-linux','aarch64-linux','riscv64-linux','aarch64-macos')),'')
        INTO full_feed, linux_feed, macos_feed FROM lines;
    PERFORM asm_catalog.check_json(p_index_json::json);
    IF full_feed IS DISTINCT FROM p_full_tsv OR linux_feed IS DISTINCT FROM p_linux_tsv
        OR macos_feed IS DISTINCT FROM p_macos_tsv
        OR asm_catalog.expected_index(records) IS DISTINCT FROM p_index_json::jsonb
        OR asm_catalog.canonical_json(asm_catalog.expected_index(records)) || chr(10) <> p_index_json THEN
        RAISE EXCEPTION 'Catalog exports do not match the retained records' USING ERRCODE = '22023';
    END IF;
    payload_sha := encode(pg_catalog.sha256(convert_to(json_build_array(p_records,p_linux_tsv,p_macos_tsv,p_full_tsv,p_index_json)::text,'UTF8')),'hex');
    PERFORM pg_advisory_xact_lock(1095978307, 1);
    SELECT * INTO existing FROM asm_catalog.snapshots WHERE acceptance_commit = p_acceptance_commit;
    IF FOUND THEN
        IF existing.payload_sha256 <> payload_sha THEN RAISE EXCEPTION 'Accepted source commit has different catalog bytes' USING ERRCODE = '23505'; END IF;
        RETURN existing.revision;
    END IF;
    SELECT coalesce((SELECT revision FROM asm_catalog.head WHERE singleton),0) INTO old_revision;
    IF old_revision <> p_expected_revision THEN RAISE EXCEPTION 'Catalog head changed; prepare another import' USING ERRCODE = '40001'; END IF;
    IF EXISTS(SELECT 1 FROM asm_catalog.releases AS l WHERE NOT EXISTS(
        SELECT 1 FROM jsonb_array_elements(records) AS r WHERE r.value->>'name'=l.name AND r.value->>'version'=l.version)) THEN
        RAISE EXCEPTION 'A retained release is missing from this import' USING ERRCODE = '22023';
    END IF;
    FOR raw IN SELECT value FROM unnest(p_records) AS v(value) LOOP
        r := raw::jsonb;
        IF NOT EXISTS(SELECT 1 FROM asm_catalog.namespaces WHERE name=split_part(r->>'name','/',1)) THEN
            RAISE EXCEPTION 'Bind the namespace before importing its releases' USING ERRCODE = '23503';
        END IF;
        IF EXISTS(SELECT 1 FROM asm_catalog.releases AS l WHERE l.name=r->>'name' AND l.version=r->>'version') THEN
            IF EXISTS(SELECT 1 FROM asm_catalog.releases AS l WHERE l.name=r->>'name' AND l.version=r->>'version' AND l.manifest<>raw) THEN
                RAISE EXCEPTION 'Retained release bytes differ; lifecycle changes require a separate operation' USING ERRCODE = '23505';
            END IF;
        ELSE
            INSERT INTO asm_catalog.releases(name,version,namespace,manifest,sha256,acceptance_commit)
                VALUES(r->>'name',r->>'version',split_part(r->>'name','/',1),raw,
                    encode(pg_catalog.sha256(convert_to(raw,'UTF8')),'hex'),p_acceptance_commit);
            INSERT INTO asm_catalog.artifact_urls(url,name,version)
                SELECT value->>'url',r->>'name',r->>'version' FROM jsonb_array_elements(r->'artifacts');
        END IF;
    END LOOP;
    new_revision := old_revision + 1;
    INSERT INTO asm_catalog.snapshots(revision,acceptance_commit,payload_sha256) VALUES(new_revision,p_acceptance_commit,payload_sha);
    INSERT INTO asm_catalog.exports(revision,route,media_type,body,sha256) VALUES
        (new_revision,'/registry/v1/index.tsv','text/tab-separated-values; charset=utf-8',p_linux_tsv,encode(pg_catalog.sha256(convert_to(p_linux_tsv,'UTF8')),'hex')),
        (new_revision,'/registry/v1/index-macos.tsv','text/tab-separated-values; charset=utf-8',p_macos_tsv,encode(pg_catalog.sha256(convert_to(p_macos_tsv,'UTF8')),'hex')),
        (new_revision,'/registry/v1/index-all.tsv','text/tab-separated-values; charset=utf-8',p_full_tsv,encode(pg_catalog.sha256(convert_to(p_full_tsv,'UTF8')),'hex')),
        (new_revision,'/registry/v1/index.json','application/json',p_index_json,encode(pg_catalog.sha256(convert_to(p_index_json,'UTF8')),'hex'));
    INSERT INTO asm_catalog.audit(action,acceptance_commit,detail)
        VALUES('catalog_imported',p_acceptance_commit,jsonb_build_object('revision',new_revision,'releases',cardinality(p_records),'payload_sha256',payload_sha));
    INSERT INTO asm_catalog.head(singleton,revision) VALUES(true,new_revision)
        ON CONFLICT(singleton) DO UPDATE SET revision=EXCLUDED.revision;
    RETURN new_revision;
END;
$$;

CREATE VIEW asm_catalog.current_exports AS
SELECT e.route,e.body,e.sha256,e.media_type,e.revision,s.acceptance_commit
FROM asm_catalog.head AS h JOIN asm_catalog.snapshots AS s ON s.revision=h.revision
JOIN asm_catalog.exports AS e ON e.revision=h.revision WHERE h.singleton;

REVOKE ALL ON ALL TABLES IN SCHEMA asm_catalog FROM PUBLIC,asm_reader,asm_operator;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA asm_catalog FROM PUBLIC,asm_reader,asm_operator;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA asm_catalog FROM PUBLIC,asm_reader,asm_operator;
GRANT USAGE ON SCHEMA asm_catalog TO asm_reader,asm_operator;
GRANT SELECT ON asm_catalog.current_exports,asm_catalog.schema_version TO asm_reader,asm_operator;
GRANT SELECT ON asm_catalog.releases,asm_catalog.head,asm_catalog.snapshots,asm_catalog.namespaces TO asm_operator;
GRANT EXECUTE ON FUNCTION asm_catalog.bind_namespace(text,bigint,text),
    asm_catalog.publish(text,bigint,text[],text,text,text,text) TO asm_operator;
