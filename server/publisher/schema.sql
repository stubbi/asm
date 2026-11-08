-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Apply in one transaction as asm_migrator, after the pinned canonical migration.
-- The caller records this file's reviewed SHA-384 in schema_version afterward.
-- Application routing, upload transport, and orchestration remain assembly.
SET LOCAL standard_conforming_strings = on;
SET LOCAL search_path = pg_catalog,pg_temp;
DO $$ BEGIN
    IF current_user <> 'asm_migrator' OR session_user <> current_user OR
        (SELECT count(*) FROM asm_catalog.schema_version) <> 1 OR NOT EXISTS (
            SELECT 1 FROM asm_catalog.schema_version WHERE version=1 AND
            sha384='7626f1fbee350bc04442bf5a53b78ae146c566da21cde76b56e88afe19d473787bd92cb324c9c4865623c80e6bf0a860') THEN
        RAISE EXCEPTION 'Use the publication migrator and pinned catalog prerequisite' USING ERRCODE='42501';
    END IF;
END $$;

CREATE SCHEMA asm_publication AUTHORIZATION asm_migrator;
REVOKE ALL ON SCHEMA asm_publication FROM PUBLIC,asm_reader,asm_operator,asm_publisher,asm_publication_worker;
CREATE TABLE asm_publication.schema_version (
    version integer PRIMARY KEY CHECK(version=1),
    sha384 text NOT NULL CHECK(sha384 COLLATE "C" ~ '^[0-9a-f]{96}$')
);
CREATE TABLE asm_publication.owners (
    id text COLLATE "C" PRIMARY KEY CHECK(id ~ '^[0-9a-f]{32}$'),
    namespace text COLLATE "C" UNIQUE NOT NULL CHECK(namespace ~ '^[a-z][a-z0-9-]{0,38}$'
        AND right(namespace,1)<>'-' AND strpos(namespace,'--')=0),
    max_tasks integer NOT NULL DEFAULT 64 CHECK(max_tasks BETWEEN 1 AND 4096),
    max_reserved_bytes bigint NOT NULL DEFAULT 1073741824 CHECK(max_reserved_bytes BETWEEN 1 AND 1099511627776)
);
CREATE TABLE asm_publication.credentials (
    id text COLLATE "C" PRIMARY KEY CHECK(id ~ '^[0-9a-f]{32}$'),
    owner_id text COLLATE "C" NOT NULL REFERENCES asm_publication.owners,
    token_sha256 text COLLATE "C" UNIQUE NOT NULL CHECK(token_sha256 ~ '^[0-9a-f]{64}$'),
    packages text[] NOT NULL CHECK(cardinality(packages) BETWEEN 1 AND 32),
    operations text[] NOT NULL CHECK(cardinality(operations) BETWEEN 1 AND 2 AND operations<@ARRAY['publish','task-read']::text[]),
    issued_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL CHECK(expires_at>issued_at AND expires_at<=issued_at+interval '24 hours'),
    revoked_at timestamptz
);
CREATE TABLE asm_publication.packages (
    id text COLLATE "C" PRIMARY KEY CHECK(id ~ '^[0-9a-f]{32}$'),
    owner_id text COLLATE "C" NOT NULL REFERENCES asm_publication.owners,
    name text COLLATE "C" UNIQUE NOT NULL
);
CREATE TABLE asm_publication.tasks (
    id text COLLATE "C" PRIMARY KEY CHECK(id ~ '^[0-9a-f]{32}$'),
    owner_id text COLLATE "C" NOT NULL REFERENCES asm_publication.owners,
    package_id text COLLATE "C" NOT NULL REFERENCES asm_publication.packages,
    credential_id text COLLATE "C" NOT NULL REFERENCES asm_publication.credentials,
    idempotency_key text COLLATE "C" NOT NULL CHECK(idempotency_key ~ '^[0-9a-f]{32}$'),
    name text COLLATE "C" NOT NULL,
    version text COLLATE "C" NOT NULL,
    manifest text NOT NULL CHECK(octet_length(manifest) BETWEEN 1 AND 65536),
    manifest_sha256 text COLLATE "C" NOT NULL CHECK(manifest_sha256=encode(sha256(convert_to(manifest,'UTF8')),'hex')),
    declared_bytes bigint NOT NULL CHECK(declared_bytes BETWEEN 1 AND 134217728),
    state text NOT NULL CHECK(state IN ('accepted','uploading','checking','committed')),
    accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    upload_expires_at timestamptz NOT NULL,
    failure jsonb,
    lease_owner text COLLATE "C",
    lease_until timestamptz,
    lease_fence bigint NOT NULL DEFAULT 0 CHECK(lease_fence>=0),
    UNIQUE(owner_id,idempotency_key),
    CHECK(failure IS NULL OR (jsonb_typeof(failure)='object' AND octet_length(failure::text)<=1024))
);
CREATE INDEX pending_checks ON asm_publication.tasks(state,accepted_at,id) WHERE state='checking' AND failure IS NULL;
CREATE TABLE asm_publication.reservations (
    name text COLLATE "C" NOT NULL,
    version text COLLATE "C" NOT NULL,
    task_id text COLLATE "C" UNIQUE NOT NULL REFERENCES asm_publication.tasks,
    PRIMARY KEY(name,version)
);
CREATE TABLE asm_publication.objects (
    task_id text COLLATE "C" NOT NULL REFERENCES asm_publication.tasks,
    sha256 text COLLATE "C" NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),
    bytes bigint NOT NULL CHECK(bytes BETWEEN 1 AND 67108864),
    received_at timestamptz,
    PRIMARY KEY(task_id,sha256)
);
CREATE TABLE asm_publication.checks (
    task_id text COLLATE "C" NOT NULL REFERENCES asm_publication.tasks,
    fence bigint NOT NULL,
    receipt text NOT NULL CHECK(octet_length(receipt) BETWEEN 1 AND 32768),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY(task_id,fence)
);
CREATE TABLE asm_publication.checker_policy (
    singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
    checker_revision text NOT NULL CHECK(checker_revision COLLATE "C" ~ '^[0-9a-f]{40}$' AND checker_revision<>repeat('0',40)),
    policy_sha256 text NOT NULL CHECK(policy_sha256 COLLATE "C" ~ '^[0-9a-f]{64}$')
);
CREATE TABLE asm_publication.intents (
    task_id text COLLATE "C" PRIMARY KEY REFERENCES asm_publication.tasks,
    package_id text COLLATE "C" NOT NULL REFERENCES asm_publication.packages,
    name text COLLATE "C" NOT NULL,
    version text COLLATE "C" NOT NULL,
    manifest text NOT NULL,
    manifest_sha256 text NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE(name,version)
);
CREATE TABLE asm_publication.outbox (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    task_id text COLLATE "C" UNIQUE NOT NULL REFERENCES asm_publication.intents,
    event text NOT NULL CHECK(event='publication_committed'),
    schema integer NOT NULL DEFAULT 1 CHECK(schema=1),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE asm_publication.pending_events (
    event_id bigint PRIMARY KEY REFERENCES asm_publication.outbox,
    lease_owner text COLLATE "C",
    lease_until timestamptz,
    fence bigint NOT NULL DEFAULT 0 CHECK(fence>=0),
    acknowledged_at timestamptz
);
CREATE INDEX pending_delivery ON asm_publication.pending_events(event_id) WHERE acknowledged_at IS NULL;
CREATE TABLE asm_publication.audit (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    action text NOT NULL CHECK(action IN ('owner_enrolled','credential_issued','credential_revoked','publication_accepted',
        'upload_received','checker_policy_selected','check_recorded','publication_committed','attempt_failed','event_acknowledged')),
    detail jsonb NOT NULL CHECK(jsonb_typeof(detail)='object' AND octet_length(detail::text)<=2048),
    actor name NOT NULL DEFAULT session_user,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
DO $$ DECLARE t text; BEGIN
    FOREACH t IN ARRAY ARRAY['owners','packages','checks','intents','outbox','audit'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_row BEFORE UPDATE OR DELETE ON asm_publication.%I FOR EACH ROW EXECUTE FUNCTION asm_catalog.reject_change()',t);
        EXECUTE format('CREATE TRIGGER immutable_table BEFORE TRUNCATE ON asm_publication.%I FOR EACH STATEMENT EXECUTE FUNCTION asm_catalog.reject_change()',t);
    END LOOP;
END $$;

CREATE FUNCTION asm_publication.caller(expected name) RETURNS boolean
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
SELECT session_user=expected AND NOT EXISTS (
    SELECT 1 FROM pg_roles r WHERE (r.rolname=session_user OR pg_has_role(session_user,r.oid,'MEMBER'))
    AND (r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolbypassrls
        OR r.rolname<>expected))
$$;

CREATE FUNCTION asm_publication.publisher_ready(expected_sha384 text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN RETURN (SELECT CASE WHEN asm_publication.caller('asm_publisher')
    AND current_setting('log_parameter_max_length')='0' AND current_setting('log_parameter_max_length_on_error')='0'
    AND current_setting('transaction_read_only')='off'
    AND current_setting('transaction_isolation')='read committed'
    AND NOT has_database_privilege(session_user,current_database(),'CREATE')
    AND NOT EXISTS(SELECT 1 FROM pg_namespace n WHERE left(n.nspname,8)<>'pg_temp_' AND left(n.nspname,14)<>'pg_toast_temp_'
        AND has_schema_privilege(session_user,n.oid,'CREATE'))
    AND (SELECT count(*)=1 AND bool_and(version=1 AND sha384=expected_sha384) FROM asm_publication.schema_version)
    AND (SELECT pg_get_userbyid(nspowner)='asm_migrator' FROM pg_namespace WHERE nspname='asm_publication')
    AND NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='asm_publication' AND (pg_get_userbyid(c.relowner)<>'asm_migrator'
            OR CASE WHEN c.relkind IN ('r','p','v','m','f') THEN has_table_privilege(session_user,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
                WHEN c.relkind='S' THEN has_sequence_privilege(session_user,c.oid,'SELECT,USAGE,UPDATE') ELSE false END))
    AND NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='asm_publication' AND pg_get_userbyid(p.proowner)<>'asm_migrator')
    AND NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema')
        AND p.prosecdef AND has_function_privilege(session_user,p.oid,'EXECUTE')
        AND p.oid NOT IN ('asm_publication.publisher_ready(text)'::regprocedure,'asm_publication.create_publication(text,text,text)'::regprocedure,
            'asm_publication.read_publication(text,text)'::regprocedure,'asm_publication.authorize_upload(text,text,text,bigint)'::regprocedure,
            'asm_publication.receipt_upload(text,text,text,bigint)'::regprocedure))
    AND NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND left(n.nspname,8)<>'pg_temp_' AND left(n.nspname,14)<>'pg_toast_temp_'
        AND CASE WHEN c.relkind IN ('r','p','v','m','f') THEN has_table_privilege(session_user,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
            OR has_any_column_privilege(session_user,c.oid,'INSERT,UPDATE,REFERENCES')
            WHEN c.relkind='S' THEN has_sequence_privilege(session_user,c.oid,'USAGE,UPDATE') ELSE false END)
    THEN '1' ELSE '0' END); END
$$;

CREATE FUNCTION asm_publication.enroll_owner(p_owner text,p_namespace text,p_reference text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF NOT asm_publication.caller('asm_operator') THEN RAISE EXCEPTION 'Operator authority refused' USING ERRCODE='42501'; END IF;
    IF p_owner IS NULL OR p_owner COLLATE "C" !~ '^[0-9a-f]{32}$' OR p_namespace IS NULL
        OR p_namespace COLLATE "C" !~ '^[a-z][a-z0-9-]{0,38}$' OR right(p_namespace,1)='-' OR strpos(p_namespace,'--')>0
        OR p_reference IS NULL OR (octet_length(p_reference) NOT BETWEEN 1 AND 256 OR p_reference COLLATE "C" !~ '^[ -~]+$') THEN
        RAISE EXCEPTION 'Owner assertion is invalid' USING ERRCODE='22023';
    END IF;
    PERFORM pg_advisory_xact_lock(1095978320,0);
    IF EXISTS(SELECT 1 FROM asm_publication.owners WHERE id=p_owner AND namespace=p_namespace) THEN RETURN p_owner; END IF;
    INSERT INTO asm_publication.owners(id,namespace) VALUES(p_owner,p_namespace);
    INSERT INTO asm_publication.audit(action,detail) VALUES('owner_enrolled',jsonb_build_object('owner_id',p_owner,'namespace',p_namespace,'reference',p_reference));
    RETURN p_owner;
END $$;

CREATE FUNCTION asm_publication.set_check_policy(p_revision text,p_policy text,p_reference text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF NOT asm_publication.caller('asm_operator') THEN RAISE EXCEPTION 'Operator authority refused' USING ERRCODE='42501'; END IF;
    IF p_revision IS NULL OR p_revision COLLATE "C" !~ '^[0-9a-f]{40}$' OR p_revision=repeat('0',40)
        OR p_policy IS NULL OR p_policy COLLATE "C" !~ '^[0-9a-f]{64}$'
        OR p_reference IS NULL OR (octet_length(p_reference) NOT BETWEEN 1 AND 256 OR p_reference COLLATE "C" !~ '^[ -~]+$') THEN RAISE EXCEPTION 'Checker policy is invalid' USING ERRCODE='22023'; END IF;
    PERFORM pg_advisory_xact_lock(1095978320,1);
    IF EXISTS(SELECT 1 FROM asm_publication.checker_policy WHERE checker_revision=p_revision AND policy_sha256=p_policy) THEN RETURN p_policy; END IF;
    INSERT INTO asm_publication.checker_policy VALUES(true,p_revision,p_policy) ON CONFLICT(singleton)
        DO UPDATE SET checker_revision=EXCLUDED.checker_revision,policy_sha256=EXCLUDED.policy_sha256;
    INSERT INTO asm_publication.audit(action,detail) VALUES('checker_policy_selected',jsonb_build_object('checker_revision',p_revision,'policy_sha256',p_policy,'reference',p_reference));
    RETURN p_policy;
END $$;

CREATE FUNCTION asm_publication.issue_credential(p_id text,p_owner text,p_hash text,p_packages text[],p_ttl interval,p_reference text,
    p_operations text[] DEFAULT ARRAY['publish','task-read']) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE ns text; stamp timestamptz;
BEGIN
    IF NOT asm_publication.caller('asm_operator') THEN RAISE EXCEPTION 'Operator authority refused' USING ERRCODE='42501'; END IF;
    IF p_id IS NULL OR p_id COLLATE "C" !~ '^[0-9a-f]{32}$' OR p_hash IS NULL OR p_hash COLLATE "C" !~ '^[0-9a-f]{64}$'
        OR p_packages IS NULL OR cardinality(p_packages) NOT BETWEEN 1 AND 32 OR array_ndims(p_packages)<>1
        OR p_operations IS NULL OR cardinality(p_operations) NOT BETWEEN 1 AND 2 OR array_ndims(p_operations)<>1
        OR NOT p_operations<@ARRAY['publish','task-read']::text[] OR array_position(p_operations,NULL) IS NOT NULL
        OR cardinality(p_operations)<>(SELECT count(DISTINCT op) FROM unnest(p_operations) op)
        OR p_ttl IS NULL OR p_ttl<=interval '0 seconds' OR p_ttl>interval '24 hours'
        OR p_reference IS NULL OR (octet_length(p_reference) NOT BETWEEN 1 AND 256 OR p_reference COLLATE "C" !~ '^[ -~]+$') THEN
        RAISE EXCEPTION 'Credential assertion is invalid' USING ERRCODE='22023';
    END IF;
    SELECT namespace INTO ns FROM asm_publication.owners WHERE id=p_owner FOR SHARE;
    IF NOT FOUND OR EXISTS(SELECT 1 FROM unnest(p_packages) p WHERE p IS NULL OR
        p COLLATE "C" !~ '^[a-z][a-z0-9-]{0,38}/[a-z][a-z0-9-]{0,63}$' OR strpos(p,'--')>0 OR p LIKE '%-/%'
        OR right(p,1)='-' OR split_part(p,'/',1)<>ns) OR cardinality(p_packages)<>(SELECT count(DISTINCT p) FROM unnest(p_packages) p) THEN
        RAISE EXCEPTION 'Credential package scope is invalid' USING ERRCODE='22023';
    END IF;
    IF EXISTS(SELECT 1 FROM asm_publication.credentials WHERE id=p_id) THEN
        IF EXISTS(SELECT 1 FROM asm_publication.credentials WHERE id=p_id AND owner_id=p_owner AND token_sha256=p_hash
            AND packages=p_packages AND operations=p_operations AND expires_at-issued_at=p_ttl
            AND revoked_at IS NULL AND expires_at>clock_timestamp()) THEN RETURN p_id; END IF;
        RAISE EXCEPTION 'Credential identity conflicts' USING ERRCODE='23505';
    END IF;
    stamp:=date_trunc('second',clock_timestamp());
    INSERT INTO asm_publication.credentials VALUES(p_id,p_owner,p_hash,p_packages,p_operations,stamp,stamp+p_ttl,NULL);
    INSERT INTO asm_publication.audit(action,detail) VALUES('credential_issued',jsonb_build_object('credential_id',p_id,'owner_id',p_owner,
        'package_count',cardinality(p_packages),'scope_sha256',encode(sha256(convert_to(p_packages::text,'UTF8')),'hex'),
        'operations',p_operations,'expires_at',stamp+p_ttl,'reference',p_reference));
    RETURN p_id;
END $$;

CREATE FUNCTION asm_publication.revoke_credential(p_id text,p_reference text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF NOT asm_publication.caller('asm_operator') THEN RAISE EXCEPTION 'Operator authority refused' USING ERRCODE='42501'; END IF;
    IF p_reference IS NULL OR (octet_length(p_reference) NOT BETWEEN 1 AND 256 OR p_reference COLLATE "C" !~ '^[ -~]+$') THEN RAISE EXCEPTION 'Revocation reference is invalid' USING ERRCODE='22023'; END IF;
    UPDATE asm_publication.credentials SET revoked_at=clock_timestamp() WHERE id=p_id AND revoked_at IS NULL;
    IF FOUND THEN INSERT INTO asm_publication.audit(action,detail) VALUES('credential_revoked',jsonb_build_object('credential_id',p_id,'reference',p_reference)); END IF;
    IF NOT EXISTS(SELECT 1 FROM asm_publication.credentials WHERE id=p_id) THEN RAISE EXCEPTION 'Credential is absent' USING ERRCODE='22023'; END IF;
    RETURN p_id;
END $$;

-- The native V2 grammar has no whitespace, partial versions, or alternatives.
-- This function validates metadata only; all graph solving remains assembly.
CREATE FUNCTION asm_publication.dependency_requirement(raw text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE terms text[]; term text; parts text[];
BEGIN
    IF raw IS NULL OR octet_length(raw) NOT BETWEEN 1 AND 128 THEN RETURN false; END IF;
    IF raw='*' THEN RETURN true; END IF;
    terms:=string_to_array(raw,',');
    IF cardinality(terms)>8 THEN RETURN false; END IF;
    FOREACH term IN ARRAY terms LOOP
        IF term COLLATE "C" !~ '^(<=|>=|<|>|=|\^|~)?(0|[1-9][0-9]{0,9})[.](0|[1-9][0-9]{0,9})[.](0|[1-9][0-9]{0,9})$' THEN RETURN false; END IF;
        parts:=string_to_array(regexp_replace(term,'^[<>=^~]+',''),'.');
        IF parts[1]::bigint>2147483647 OR parts[2]::bigint>2147483647 OR parts[3]::bigint>2147483647 THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
END $$;

CREATE FUNCTION asm_publication.manifest(raw text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE d jsonb; s jsonb; c jsonb; a jsonb; parts text[]; dep jsonb; previous_dependency text;
    requested jsonb; features jsonb; feature jsonb; entry jsonb; member text; feature_name text;
    previous_feature text; previous_member text; text_bytes integer:=0; progress boolean;
    dependency_names text[]:=ARRAY[]::text[]; optional_names text[]:=ARRAY[]::text[];
    feature_names text[]:=ARRAY[]::text[]; resolved text[]:=ARRAY[]::text[];
BEGIN
    IF raw IS NULL OR octet_length(raw) NOT BETWEEN 1 AND 65536 OR raw COLLATE "C" ~ E'[^\\n -~]' THEN
        RAISE EXCEPTION 'Manifest encoding is invalid' USING ERRCODE='22023'; END IF;
    PERFORM asm_catalog.check_json(raw::json);
    d:=raw::jsonb;
    IF jsonb_typeof(d)<>'object' OR NOT d ?& ARRAY['schema','owner_id','name','version','summary','license','source','artifacts']
        OR d-ARRAY['schema','owner_id','name','version','summary','license','source','artifacts','dependencies','features']<>'{}'::jsonb
        OR d->'schema'<>'2'::jsonb OR jsonb_typeof(d->'owner_id')<>'string' OR d->>'owner_id' COLLATE "C" !~ '^[0-9a-f]{32}$'
        OR jsonb_typeof(d->'name')<>'string' OR d->>'name' COLLATE "C" !~ '^[a-z][a-z0-9-]{0,38}/[a-z][a-z0-9-]{0,63}$'
        OR d->>'name' LIKE '%--%' OR d->>'name' LIKE '%-/%' OR right(d->>'name',1)='-'
        OR jsonb_typeof(d->'version')<>'string' OR d->>'version' COLLATE "C" !~ '^(0|[1-9][0-9]{0,9})[.](0|[1-9][0-9]{0,9})[.](0|[1-9][0-9]{0,9})$'
        OR jsonb_typeof(d->'summary')<>'string' OR d->>'summary' COLLATE "C" !~ '^[ -~]{1,160}$' OR d->>'summary'<>btrim(d->>'summary')
        OR jsonb_typeof(d->'license')<>'string' OR NOT d->>'license'=ANY(ARRAY['AGPL-3.0-only','AGPL-3.0-or-later','Apache-2.0','BSD-2-Clause','BSD-3-Clause','BSL-1.0','GPL-2.0-only','GPL-2.0-or-later','GPL-3.0-only','GPL-3.0-or-later','ISC','LGPL-2.1-only','LGPL-2.1-or-later','LGPL-3.0-only','LGPL-3.0-or-later','MIT','MPL-2.0','Unlicense','Zlib']) THEN
        RAISE EXCEPTION 'Manifest fields are invalid' USING ERRCODE='22023'; END IF;
    parts:=string_to_array(d->>'version','.');
    IF parts[1]::bigint>2147483647 OR parts[2]::bigint>2147483647 OR parts[3]::bigint>2147483647 THEN RAISE EXCEPTION 'Version is invalid' USING ERRCODE='22023'; END IF;
    -- Validate inactive graph metadata too. No child feature or version is
    -- selected here; the native resolver owns those decisions.
    IF d ? 'dependencies' THEN
        IF jsonb_typeof(d->'dependencies') IS DISTINCT FROM 'array' OR jsonb_array_length(d->'dependencies')>64 THEN
            RAISE EXCEPTION 'Dependency count is invalid' USING ERRCODE='22023'; END IF;
        FOR dep IN SELECT value FROM jsonb_array_elements(d->'dependencies') LOOP
            IF jsonb_typeof(dep) IS DISTINCT FROM 'object' OR NOT dep ?& ARRAY['name','requirement']
                OR dep-ARRAY['name','requirement','optional','default_features','features']<>'{}'::jsonb
                OR jsonb_typeof(dep->'name') IS DISTINCT FROM 'string'
                OR dep->>'name' COLLATE "C" !~ '^[a-z][a-z0-9-]{0,38}/[a-z][a-z0-9-]{0,63}$'
                OR dep->>'name' LIKE '%--%' OR dep->>'name' LIKE '%-/%' OR right(dep->>'name',1)='-'
                OR jsonb_typeof(dep->'requirement') IS DISTINCT FROM 'string'
                OR NOT asm_publication.dependency_requirement(dep->>'requirement')
                OR (dep ? 'optional' AND jsonb_typeof(dep->'optional') IS DISTINCT FROM 'boolean')
                OR (dep ? 'default_features' AND jsonb_typeof(dep->'default_features') IS DISTINCT FROM 'boolean')
                OR (previous_dependency IS NOT NULL AND previous_dependency COLLATE "C">=dep->>'name' COLLATE "C") THEN
                RAISE EXCEPTION 'Dependency fields are invalid' USING ERRCODE='22023'; END IF;
            previous_dependency:=dep->>'name';
            dependency_names:=array_append(dependency_names,previous_dependency);
            IF dep->'optional'='true'::jsonb THEN optional_names:=array_append(optional_names,previous_dependency); END IF;
            requested:=coalesce(dep->'features','[]'::jsonb);
            IF jsonb_typeof(requested) IS DISTINCT FROM 'array' OR jsonb_array_length(requested)>64 THEN
                RAISE EXCEPTION 'Requested feature count is invalid' USING ERRCODE='22023'; END IF;
            previous_member:=NULL;
            FOR entry IN SELECT value FROM jsonb_array_elements(requested) LOOP
                member:=entry#>>'{}';
                IF jsonb_typeof(entry) IS DISTINCT FROM 'string' OR member COLLATE "C" !~ '^[a-z][a-z0-9_-]{0,31}$'
                    OR (previous_member IS NOT NULL AND previous_member COLLATE "C">=member COLLATE "C") THEN
                    RAISE EXCEPTION 'Requested feature is invalid' USING ERRCODE='22023'; END IF;
                previous_member:=member; text_bytes:=text_bytes+octet_length(member)+1;
            END LOOP;
        END LOOP;
    END IF;
    features:=coalesce(d->'features','[]'::jsonb);
    IF jsonb_typeof(features) IS DISTINCT FROM 'array' OR jsonb_array_length(features)>64 THEN
        RAISE EXCEPTION 'Feature count is invalid' USING ERRCODE='22023'; END IF;
    FOR feature IN SELECT value FROM jsonb_array_elements(features) LOOP
        feature_name:=feature->>'name';
        IF jsonb_typeof(feature) IS DISTINCT FROM 'object' OR NOT feature ?& ARRAY['name','members']
            OR feature-ARRAY['name','members']<>'{}'::jsonb OR jsonb_typeof(feature->'name') IS DISTINCT FROM 'string'
            OR feature_name COLLATE "C" !~ '^[a-z][a-z0-9_-]{0,31}$'
            OR (previous_feature IS NOT NULL AND previous_feature COLLATE "C">=feature_name COLLATE "C")
            OR jsonb_typeof(feature->'members') IS DISTINCT FROM 'array' OR jsonb_array_length(feature->'members')>64 THEN
            RAISE EXCEPTION 'Feature definition is invalid' USING ERRCODE='22023'; END IF;
        previous_feature:=feature_name; feature_names:=array_append(feature_names,feature_name);
        text_bytes:=text_bytes+octet_length(feature_name)+1;
    END LOOP;
    FOR feature IN SELECT value FROM jsonb_array_elements(features) LOOP
        previous_member:=NULL;
        FOR entry IN SELECT value FROM jsonb_array_elements(feature->'members') LOOP
            member:=entry#>>'{}';
            IF jsonb_typeof(entry) IS DISTINCT FROM 'string' OR octet_length(member) NOT BETWEEN 1 AND 137
                OR (previous_member IS NOT NULL AND previous_member COLLATE "C">=member COLLATE "C") THEN
                RAISE EXCEPTION 'Feature member is invalid' USING ERRCODE='22023'; END IF;
            previous_member:=member; text_bytes:=text_bytes+octet_length(member)+1;
            IF left(member,4)='dep:' THEN
                IF NOT substring(member FROM 5)=ANY(optional_names) THEN
                    RAISE EXCEPTION 'Feature needs a declared optional dependency' USING ERRCODE='22023'; END IF;
            ELSIF strpos(member,'/')>0 THEN
                parts:=regexp_match(member,'^(.+)/([^/]+)$');
                IF parts IS NULL OR NOT parts[1]=ANY(dependency_names) OR parts[2] COLLATE "C" !~ '^[a-z][a-z0-9_-]{0,31}$' THEN
                    RAISE EXCEPTION 'Feature needs a declared dependency and child name' USING ERRCODE='22023'; END IF;
            ELSIF member COLLATE "C" !~ '^[a-z][a-z0-9_-]{0,31}$' OR NOT member=ANY(feature_names) THEN
                RAISE EXCEPTION 'Feature needs a declared local feature' USING ERRCODE='22023';
            END IF;
        END LOOP;
    END LOOP;
    IF text_bytes>8192 THEN RAISE EXCEPTION 'Feature text exceeds the native profile limit' USING ERRCODE='22023'; END IF;
    -- A bounded topological pass rejects local cycles without enumerating paths.
    -- At most64 passes inspect64 definitions and64 members each.
    WHILE cardinality(resolved)<cardinality(feature_names) LOOP
        progress:=false;
        FOR feature IN SELECT value FROM jsonb_array_elements(features) LOOP
            feature_name:=feature->>'name';
            IF feature_name=ANY(resolved) THEN CONTINUE; END IF;
            IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements_text(feature->'members') AS m(value)
                WHERE strpos(value,'/')=0 AND NOT value=ANY(resolved)) THEN
                resolved:=array_append(resolved,feature_name); progress:=true;
            END IF;
        END LOOP;
        IF NOT progress THEN RAISE EXCEPTION 'Local feature references contain a cycle' USING ERRCODE='22023'; END IF;
    END LOOP;
    s:=d->'source'; c:=s->'commit';
    IF jsonb_typeof(s) IS DISTINCT FROM 'object' OR NOT s ?& ARRAY['commit','path','archive']
        OR s-ARRAY['commit','path','archive','repository']<>'{}'::jsonb OR jsonb_typeof(s->'path') IS DISTINCT FROM 'string'
        OR NOT asm_catalog.portable_path(s->>'path') OR jsonb_typeof(c) IS DISTINCT FROM 'object'
        OR NOT c ?& ARRAY['algorithm','digest'] OR c-ARRAY['algorithm','digest']<>'{}'::jsonb
        OR jsonb_typeof(c->'algorithm') IS DISTINCT FROM 'string' OR jsonb_typeof(c->'digest') IS DISTINCT FROM 'string'
        OR NOT ((c->>'algorithm'='git-sha1' AND c->>'digest' COLLATE "C" ~ '^[0-9a-f]{40}$' AND c->>'digest'<>repeat('0',40))
            OR (c->>'algorithm'='git-sha256' AND c->>'digest' COLLATE "C" ~ '^[0-9a-f]{64}$' AND c->>'digest'<>repeat('0',64)))
        OR (s ? 'repository' AND (jsonb_typeof(s->'repository') IS DISTINCT FROM 'string' OR octet_length(s->>'repository')>1024
            OR s->>'repository' COLLATE "C" !~ '^https://[A-Za-z0-9][A-Za-z0-9.-]*/[A-Za-z0-9._~/-]+$')) THEN
        RAISE EXCEPTION 'Source fields are invalid' USING ERRCODE='22023'; END IF;
    a:=s->'archive';
    IF jsonb_typeof(a) IS DISTINCT FROM 'object' OR NOT a ?& ARRAY['sha256','bytes'] OR a-ARRAY['sha256','bytes']<>'{}'::jsonb
        OR jsonb_typeof(a->'sha256') IS DISTINCT FROM 'string' OR a->>'sha256' COLLATE "C" !~ '^[0-9a-f]{64}$'
        OR jsonb_typeof(a->'bytes') IS DISTINCT FROM 'number' OR a->>'bytes' COLLATE "C" !~ '^[1-9][0-9]*$'
        OR (a->>'bytes')::numeric>67108864 THEN RAISE EXCEPTION 'Source archive is invalid' USING ERRCODE='22023'; END IF;
    IF jsonb_typeof(d->'artifacts') IS DISTINCT FROM 'array' OR jsonb_array_length(d->'artifacts') NOT BETWEEN 1 AND 14 THEN
        RAISE EXCEPTION 'Artifact count is invalid' USING ERRCODE='22023'; END IF;
    FOR a IN SELECT value FROM jsonb_array_elements(d->'artifacts') LOOP
        IF jsonb_typeof(a) IS DISTINCT FROM 'object' OR NOT a ?& ARRAY['kind','format','isa','os','abi','cpu_features','sha256','bytes']
            OR a-ARRAY['kind','format','isa','os','abi','cpu_features','sha256','bytes']<>'{}'::jsonb
            OR jsonb_typeof(a->'kind') IS DISTINCT FROM 'string' OR a->>'kind' NOT IN ('source','executable')
            OR jsonb_typeof(a->'format') IS DISTINCT FROM 'string' OR jsonb_typeof(a->'isa') IS DISTINCT FROM 'string'
            OR jsonb_typeof(a->'os') IS DISTINCT FROM 'string' OR jsonb_typeof(a->'abi') IS DISTINCT FROM 'string'
            OR a->'cpu_features' IS DISTINCT FROM '[]'::jsonb
            OR (a->>'isa',a->>'os',a->>'abi') NOT IN (('x86_64','linux','sysv-amd64'),('aarch64','linux','aapcs64'),
                ('riscv64','linux','lp64d'),('aarch64','macos','apple-arm64'),('x86_64','windows','windows-x64'),('aarch64','windows','windows-arm64'))
            OR jsonb_typeof(a->'sha256') IS DISTINCT FROM 'string' OR a->>'sha256' COLLATE "C" !~ '^[0-9a-f]{64}$'
            OR jsonb_typeof(a->'bytes') IS DISTINCT FROM 'number' OR a->>'bytes' COLLATE "C" !~ '^[1-9][0-9]*$'
            OR (a->>'bytes')::numeric>67108864
            OR (a->>'kind'='source' AND (a->>'format'<>'tar.gz' OR a->>'sha256'<>s->'archive'->>'sha256' OR a->'bytes'<>s->'archive'->'bytes'))
            OR (a->>'kind'='executable' AND a->>'format'<>CASE a->>'os' WHEN 'linux' THEN 'elf' WHEN 'macos' THEN 'macho' ELSE 'pe' END) THEN
            RAISE EXCEPTION 'Artifact fields are invalid' USING ERRCODE='22023'; END IF;
    END LOOP;
    IF (SELECT count(*)<>count(DISTINCT (value->>'kind',value->>'isa',value->>'os',value->>'abi')) FROM jsonb_array_elements(d->'artifacts'))
        OR EXISTS(SELECT 1 FROM (SELECT value->>'sha256' digest,value->>'bytes' bytes FROM jsonb_array_elements(d->'artifacts')
            UNION ALL SELECT s->'archive'->>'sha256',s->'archive'->>'bytes') o GROUP BY digest HAVING count(DISTINCT bytes)>1)
        OR (SELECT sum(bytes::bigint)>134217728 FROM (SELECT DISTINCT value->>'sha256' digest,value->>'bytes' bytes FROM jsonb_array_elements(d->'artifacts')
            UNION SELECT s->'archive'->>'sha256',s->'archive'->>'bytes') o)
        OR asm_catalog.canonical_json(d)||chr(10)<>raw THEN RAISE EXCEPTION 'Manifest bytes are not canonical' USING ERRCODE='22023'; END IF;
    RETURN d;
END $$;

CREATE FUNCTION asm_publication.grant_for_token(token text) RETURNS asm_publication.credentials
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE c asm_publication.credentials;
BEGIN
    IF token IS NULL OR token COLLATE "C" !~ '^asm_pub_v1_[0-9a-f]{64}$' THEN RETURN NULL; END IF;
    SELECT * INTO c FROM asm_publication.credentials WHERE token_sha256=encode(sha256(convert_to(token,'UTF8')),'hex') FOR SHARE;
    IF NOT FOUND OR c.revoked_at IS NOT NULL OR c.expires_at<=clock_timestamp() THEN RETURN NULL; END IF;
    RETURN c;
END $$;

CREATE FUNCTION asm_publication.error(code text) RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
SELECT jsonb_build_object('error',jsonb_build_object('code',code))
$$;
CREATE FUNCTION asm_publication.reply(p_status integer,p_task text,p_body jsonb) RETURNS TABLE(status text,task_id text,body text)
LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
SELECT p_status::text,coalesce(p_task,''),CASE WHEN p_status=204 THEN '' ELSE asm_catalog.canonical_json(p_body)||chr(10) END
$$;
CREATE FUNCTION asm_publication.task_body(p_task text) RETURNS jsonb LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
SELECT jsonb_build_object('schema',2,'id',t.id,'package_id',t.package_id,'manifest_sha256',t.manifest_sha256,'state',t.state,
    'upload_expires_at',to_char(t.upload_expires_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'objects',(SELECT jsonb_agg(jsonb_build_object('sha256',o.sha256,'bytes',o.bytes,'received',o.received_at IS NOT NULL) ORDER BY o.sha256 COLLATE "C")
        FROM asm_publication.objects o WHERE o.task_id=t.id),'failure',t.failure,'release',NULL) FROM asm_publication.tasks t WHERE t.id=p_task
$$;

CREATE FUNCTION asm_publication.create_publication(token text,p_key text,raw text) RETURNS TABLE(status text,task_id text,body text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE c asm_publication.credentials; d jsonb; t asm_publication.tasks; owner_row asm_publication.owners; package text; tid text; total bigint;
BEGIN
    IF NOT asm_publication.caller('asm_publisher') THEN RETURN QUERY SELECT * FROM asm_publication.reply(403,'',asm_publication.error('forbidden')); RETURN; END IF;
    IF current_setting('transaction_isolation')<>'read committed' THEN RETURN QUERY SELECT * FROM asm_publication.reply(503,'',asm_publication.error('transaction_policy_refused')); RETURN; END IF;
    c:=asm_publication.grant_for_token(token);
    IF c.id IS NULL THEN RETURN QUERY SELECT * FROM asm_publication.reply(401,'',asm_publication.error('credential_refused')); RETURN; END IF;
    IF NOT 'publish'=ANY(c.operations) THEN RETURN QUERY SELECT * FROM asm_publication.reply(403,'',asm_publication.error('operation_not_authorized')); RETURN; END IF;
    IF p_key IS NULL OR p_key COLLATE "C" !~ '^[0-9a-f]{32}$' THEN RETURN QUERY SELECT * FROM asm_publication.reply(400,'',asm_publication.error('invalid_idempotency_key')); RETURN; END IF;
    BEGIN d:=asm_publication.manifest(raw);
    EXCEPTION WHEN data_exception OR program_limit_exceeded THEN
        RETURN QUERY SELECT * FROM asm_publication.reply(400,'',asm_publication.error('invalid_manifest')); RETURN;
    END;
    IF c.owner_id<>d->>'owner_id' OR NOT d->>'name'=ANY(c.packages) THEN
        RETURN QUERY SELECT * FROM asm_publication.reply(403,'',asm_publication.error('package_not_authorized')); RETURN; END IF;
    SELECT * INTO owner_row FROM asm_publication.owners WHERE id=c.owner_id AND namespace=split_part(d->>'name','/',1) FOR UPDATE;
    IF NOT FOUND THEN RETURN QUERY SELECT * FROM asm_publication.reply(403,'',asm_publication.error('package_not_authorized')); RETURN; END IF;
    SELECT * INTO t FROM asm_publication.tasks WHERE owner_id=c.owner_id AND idempotency_key=p_key;
    IF FOUND THEN
        IF t.manifest<>raw THEN RETURN QUERY SELECT * FROM asm_publication.reply(409,'',asm_publication.error('idempotency_conflict'));
        ELSE RETURN QUERY SELECT * FROM asm_publication.reply(200,t.id,asm_publication.task_body(t.id)); END IF; RETURN;
    END IF;
    IF EXISTS(SELECT 1 FROM asm_publication.reservations r WHERE r.name=d->>'name' AND r.version=d->>'version')
        OR EXISTS(SELECT 1 FROM asm_publication.intents i WHERE i.name=d->>'name' AND i.version=d->>'version') THEN
        RETURN QUERY SELECT * FROM asm_publication.reply(409,'',asm_publication.error('version_reserved')); RETURN; END IF;
    -- One bounded initial budget covers every owner. Count declared bytes even
    -- after failure: a timed-out retained write can leave an unreferenced object.
    -- This is not a measured storage bill or automatic garbage collection.
    PERFORM pg_advisory_xact_lock(1095978320,3);
    SELECT sum(bytes::bigint) INTO total FROM (SELECT DISTINCT value->>'sha256' digest,value->>'bytes' bytes FROM jsonb_array_elements(d->'artifacts')
        UNION SELECT d->'source'->'archive'->>'sha256',d->'source'->'archive'->>'bytes') o;
    IF (SELECT count(*)>=owner_row.max_tasks FROM asm_publication.tasks WHERE owner_id=c.owner_id AND accepted_at>=clock_timestamp()-interval '24 hours')
        OR (SELECT count(*)>=8 FROM asm_publication.tasks WHERE owner_id=c.owner_id AND state<>'committed' AND (failure IS NULL OR failure->>'retryable'='true'))
        OR (SELECT coalesce(sum(declared_bytes),0)+total>owner_row.max_reserved_bytes FROM asm_publication.tasks WHERE owner_id=c.owner_id) THEN
        RETURN QUERY SELECT * FROM asm_publication.reply(429,'',asm_publication.error('owner_quota_exceeded')); RETURN; END IF;
    IF (SELECT count(*)>=4096 OR coalesce(sum(declared_bytes),0)+total>34359738368 FROM asm_publication.tasks)
        OR (SELECT count(*)>=64 FROM asm_publication.tasks WHERE state<>'committed' AND (failure IS NULL OR failure->>'retryable'='true')) THEN
        RETURN QUERY SELECT * FROM asm_publication.reply(429,'',asm_publication.error('registry_quota_exceeded')); RETURN; END IF;
    SELECT id INTO package FROM asm_publication.packages WHERE name=d->>'name';
    IF package IS NULL THEN
        package:=replace(gen_random_uuid()::text,'-','');
        INSERT INTO asm_publication.packages VALUES(package,c.owner_id,d->>'name');
    END IF;
    tid:=replace(gen_random_uuid()::text,'-','');
    INSERT INTO asm_publication.tasks(id,owner_id,package_id,credential_id,idempotency_key,name,version,manifest,manifest_sha256,declared_bytes,state,upload_expires_at)
        VALUES(tid,c.owner_id,package,c.id,p_key,d->>'name',d->>'version',raw,encode(sha256(convert_to(raw,'UTF8')),'hex'),total,'accepted',c.expires_at);
    INSERT INTO asm_publication.objects(task_id,sha256,bytes) SELECT tid,digest,bytes::bigint FROM
        (SELECT DISTINCT value->>'sha256' digest,value->>'bytes' bytes FROM jsonb_array_elements(d->'artifacts')
            UNION SELECT d->'source'->'archive'->>'sha256',d->'source'->'archive'->>'bytes') o;
    INSERT INTO asm_publication.reservations VALUES(d->>'name',d->>'version',tid);
    INSERT INTO asm_publication.audit(action,detail) VALUES('publication_accepted',jsonb_build_object('task_id',tid,'manifest_sha256',encode(sha256(convert_to(raw,'UTF8')),'hex'),'credential_id',c.id));
    RETURN QUERY SELECT * FROM asm_publication.reply(202,tid,asm_publication.task_body(tid));
END $$;

CREATE FUNCTION asm_publication.read_publication(token text,p_task text) RETURNS TABLE(status text,task_id text,body text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE c asm_publication.credentials; t asm_publication.tasks;
BEGIN
    IF NOT asm_publication.caller('asm_publisher') THEN RETURN QUERY SELECT * FROM asm_publication.reply(403,'',asm_publication.error('forbidden')); RETURN; END IF;
    c:=asm_publication.grant_for_token(token);
    IF c.id IS NULL THEN RETURN QUERY SELECT * FROM asm_publication.reply(401,'',asm_publication.error('credential_refused')); RETURN; END IF;
    IF NOT 'task-read'=ANY(c.operations) THEN RETURN QUERY SELECT * FROM asm_publication.reply(403,'',asm_publication.error('operation_not_authorized')); RETURN; END IF;
    SELECT * INTO t FROM asm_publication.tasks WHERE id=p_task AND owner_id=c.owner_id AND name=ANY(c.packages);
    IF NOT FOUND THEN RETURN QUERY SELECT * FROM asm_publication.reply(404,'',asm_publication.error('task_not_found')); RETURN; END IF;
    RETURN QUERY SELECT * FROM asm_publication.reply(200,t.id,asm_publication.task_body(t.id));
END $$;

CREATE FUNCTION asm_publication.upload(token text,p_task text,p_digest text,p_bytes bigint,p_receipt boolean) RETURNS TABLE(status text,task_id text,body text)
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE c asm_publication.credentials; original asm_publication.credentials; t asm_publication.tasks; o asm_publication.objects;
BEGIN
    IF NOT asm_publication.caller('asm_publisher') THEN RETURN QUERY SELECT * FROM asm_publication.reply(403,'',asm_publication.error('forbidden')); RETURN; END IF;
    c:=asm_publication.grant_for_token(token);
    IF c.id IS NULL THEN RETURN QUERY SELECT * FROM asm_publication.reply(401,'',asm_publication.error('credential_refused')); RETURN; END IF;
    IF NOT 'publish'=ANY(c.operations) THEN RETURN QUERY SELECT * FROM asm_publication.reply(403,'',asm_publication.error('operation_not_authorized')); RETURN; END IF;
    SELECT * INTO t FROM asm_publication.tasks WHERE id=p_task AND owner_id=c.owner_id AND name=ANY(c.packages) FOR UPDATE;
    IF NOT FOUND THEN RETURN QUERY SELECT * FROM asm_publication.reply(404,'',asm_publication.error('task_not_found')); RETURN; END IF;
    IF t.upload_expires_at<=clock_timestamp() THEN
        RETURN QUERY SELECT * FROM asm_publication.reply(410,'',asm_publication.error('upload_expired')); RETURN; END IF;
    SELECT * INTO original FROM asm_publication.credentials WHERE id=t.credential_id FOR SHARE;
    IF original.revoked_at IS NOT NULL OR original.expires_at<=clock_timestamp()
        OR NOT EXISTS(SELECT 1 FROM asm_publication.owners WHERE id=t.owner_id AND namespace=split_part(t.name,'/',1)) THEN
        RETURN QUERY SELECT * FROM asm_publication.reply(401,'',asm_publication.error('credential_refused')); RETURN; END IF;
    SELECT q.* INTO o FROM asm_publication.objects q WHERE q.task_id=t.id AND q.sha256=p_digest;
    IF NOT FOUND THEN RETURN QUERY SELECT * FROM asm_publication.reply(404,'',asm_publication.error('artifact_not_declared')); RETURN; END IF;
    IF o.bytes IS DISTINCT FROM p_bytes THEN RETURN QUERY SELECT * FROM asm_publication.reply(409,'',asm_publication.error('artifact_length_conflict')); RETURN; END IF;
    IF t.failure IS NOT NULL OR t.state='committed' THEN RETURN QUERY SELECT * FROM asm_publication.reply(409,'',asm_publication.error('task_not_uploadable')); RETURN; END IF;
    IF NOT p_receipt OR o.received_at IS NOT NULL THEN RETURN QUERY SELECT * FROM asm_publication.reply(204,t.id,NULL); RETURN; END IF;
    UPDATE asm_publication.objects q SET received_at=clock_timestamp() WHERE q.task_id=t.id AND q.sha256=p_digest;
    UPDATE asm_publication.tasks SET state=CASE WHEN NOT EXISTS(SELECT 1 FROM asm_publication.objects q WHERE q.task_id=t.id AND q.received_at IS NULL)
        THEN 'checking' ELSE 'uploading' END WHERE id=t.id;
    INSERT INTO asm_publication.audit(action,detail) VALUES('upload_received',jsonb_build_object('task_id',t.id,'sha256',p_digest,'bytes',p_bytes));
    RETURN QUERY SELECT * FROM asm_publication.reply(201,t.id,asm_publication.task_body(t.id));
END $$;
CREATE FUNCTION asm_publication.authorize_upload(token text,p_task text,p_digest text,p_bytes bigint) RETURNS TABLE(status text,task_id text,body text)
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ SELECT * FROM asm_publication.upload(token,p_task,p_digest,p_bytes,false) $$;
CREATE FUNCTION asm_publication.receipt_upload(token text,p_task text,p_digest text,p_bytes bigint) RETURNS TABLE(status text,task_id text,body text)
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ SELECT * FROM asm_publication.upload(token,p_task,p_digest,p_bytes,true) $$;

CREATE FUNCTION asm_publication.claim_check(p_worker text,p_seconds integer) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE t asm_publication.tasks;
BEGIN
    IF NOT asm_publication.caller('asm_publication_worker') THEN RAISE EXCEPTION 'Worker authority refused' USING ERRCODE='42501'; END IF;
    IF p_worker IS NULL OR p_worker COLLATE "C" !~ '^[0-9a-f]{32}$' OR p_seconds IS NULL OR p_seconds NOT BETWEEN 1 AND 60 THEN
        RAISE EXCEPTION 'Worker lease is invalid' USING ERRCODE='22023'; END IF;
    SELECT * INTO t FROM asm_publication.tasks WHERE state='checking' AND (failure IS NULL OR failure->>'code'='check_unavailable')
        AND (lease_until IS NULL OR lease_until<=clock_timestamp()) ORDER BY accepted_at,id FOR UPDATE SKIP LOCKED LIMIT 1;
    IF NOT FOUND THEN RETURN 'null'; END IF;
    UPDATE asm_publication.tasks SET lease_owner=p_worker,lease_until=clock_timestamp()+make_interval(secs=>p_seconds),lease_fence=lease_fence+1,failure=NULL WHERE id=t.id RETURNING * INTO t;
    RETURN asm_catalog.canonical_json(jsonb_build_object('task_id',t.id,'fence',t.lease_fence,'manifest',t.manifest,
        'manifest_sha256',t.manifest_sha256,'objects',(SELECT jsonb_agg(jsonb_build_object('sha256',o.sha256,'bytes',o.bytes) ORDER BY o.sha256)
        FROM asm_publication.objects o WHERE o.task_id=t.id)))||chr(10);
END $$;

CREATE FUNCTION asm_publication.complete_check(p_task text,p_worker text,p_fence bigint,raw text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE t asm_publication.tasks; c asm_publication.credentials; r jsonb; item jsonb; error_code text; event_id bigint;
BEGIN
    IF NOT asm_publication.caller('asm_publication_worker') THEN RAISE EXCEPTION 'Worker authority refused' USING ERRCODE='42501'; END IF;
    SELECT * INTO t FROM asm_publication.tasks WHERE id=p_task FOR UPDATE;
    IF NOT FOUND THEN RETURN (asm_publication.error('task_not_found'))::text; END IF;
    IF t.state='committed' AND EXISTS(SELECT 1 FROM asm_publication.checks WHERE task_id=p_task AND fence=p_fence AND receipt=raw)
        THEN RETURN asm_catalog.canonical_json(asm_publication.task_body(t.id))||chr(10); END IF;
    IF t.state<>'checking' OR t.failure IS NOT NULL OR t.lease_owner IS DISTINCT FROM p_worker OR t.lease_fence IS DISTINCT FROM p_fence
        OR t.lease_until IS NULL OR t.lease_until<=clock_timestamp() THEN RETURN (asm_publication.error('lease_lost'))::text; END IF;
    BEGIN
        IF raw IS NULL OR octet_length(raw) NOT BETWEEN 1 AND 32768 THEN RAISE EXCEPTION 'Invalid receipt' USING ERRCODE='22023'; END IF;
        PERFORM asm_catalog.check_json(raw::json); r:=raw::jsonb;
        IF jsonb_typeof(r)<>'object' OR NOT r ?& ARRAY['schema','task_id','manifest_sha256','checker_revision','policy_sha256','outcome','objects']
            OR r-ARRAY['schema','task_id','manifest_sha256','checker_revision','policy_sha256','outcome','objects']<>'{}'::jsonb
            OR r->'schema'<>'1'::jsonb OR r->>'task_id' IS DISTINCT FROM t.id OR r->>'manifest_sha256' IS DISTINCT FROM t.manifest_sha256
            OR jsonb_typeof(r->'checker_revision') IS DISTINCT FROM 'string' OR r->>'checker_revision' COLLATE "C" !~ '^[0-9a-f]{40}$'
            OR jsonb_typeof(r->'policy_sha256') IS DISTINCT FROM 'string' OR r->>'policy_sha256' COLLATE "C" !~ '^[0-9a-f]{64}$'
            OR jsonb_typeof(r->'outcome') IS DISTINCT FROM 'string' OR r->>'outcome' NOT IN ('pass','fail','error') OR jsonb_typeof(r->'objects') IS DISTINCT FROM 'array'
            OR jsonb_array_length(r->'objects')<>(SELECT count(*) FROM asm_publication.objects WHERE task_id=t.id)
            OR asm_catalog.canonical_json(r)||chr(10)<>raw THEN RAISE EXCEPTION 'Invalid receipt' USING ERRCODE='22023'; END IF;
        FOR item IN SELECT value FROM jsonb_array_elements(r->'objects') LOOP
            IF jsonb_typeof(item)<>'object' OR NOT item ?& ARRAY['sha256','bytes','outcome'] OR item-ARRAY['sha256','bytes','outcome']<>'{}'::jsonb
                OR jsonb_typeof(item->'sha256') IS DISTINCT FROM 'string' OR jsonb_typeof(item->'bytes') IS DISTINCT FROM 'number'
                OR jsonb_typeof(item->'outcome') IS DISTINCT FROM 'string' OR item->>'outcome' NOT IN ('pass','fail','error') OR NOT EXISTS(SELECT 1 FROM asm_publication.objects o
                    WHERE o.task_id=t.id AND o.sha256=item->>'sha256' AND to_jsonb(o.bytes)=item->'bytes' AND o.received_at IS NOT NULL) THEN
                RAISE EXCEPTION 'Invalid receipt' USING ERRCODE='22023'; END IF;
        END LOOP;
        IF (SELECT count(*)<>count(DISTINCT value->>'sha256') FROM jsonb_array_elements(r->'objects'))
            OR r->>'outcome'<>(SELECT CASE WHEN bool_or(value->>'outcome'='fail') THEN 'fail'
                WHEN bool_or(value->>'outcome'='error') THEN 'error' ELSE 'pass' END FROM jsonb_array_elements(r->'objects'))
            OR (SELECT jsonb_agg(value ORDER BY value->>'sha256' COLLATE "C") FROM jsonb_array_elements(r->'objects')) IS DISTINCT FROM r->'objects' THEN
            RAISE EXCEPTION 'Invalid receipt' USING ERRCODE='22023'; END IF;
        PERFORM 1 FROM asm_publication.checker_policy WHERE checker_revision=r->>'checker_revision' AND policy_sha256=r->>'policy_sha256' FOR SHARE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Invalid receipt' USING ERRCODE='22023'; END IF;
    EXCEPTION WHEN data_exception OR program_limit_exceeded THEN
        RETURN (asm_publication.error('invalid_receipt'))::text;
    END;
    SELECT * INTO c FROM asm_publication.credentials WHERE id=t.credential_id FOR SHARE;
    IF c.revoked_at IS NOT NULL OR c.expires_at<=clock_timestamp() OR NOT t.name=ANY(c.packages) OR NOT 'publish'=ANY(c.operations)
        OR NOT EXISTS(SELECT 1 FROM asm_publication.owners WHERE id=t.owner_id AND namespace=split_part(t.name,'/',1)) THEN error_code:='authorization_changed';
    ELSIF r->>'outcome'='fail' THEN error_code:='artifact_invalid';
    ELSIF r->>'outcome'='error' THEN error_code:='check_unavailable'; END IF;
    INSERT INTO asm_publication.checks(task_id,fence,receipt) VALUES(t.id,p_fence,raw);
    INSERT INTO asm_publication.audit(action,detail) VALUES('check_recorded',jsonb_build_object('task_id',t.id,'fence',p_fence,'receipt_sha256',encode(sha256(convert_to(raw,'UTF8')),'hex')));
    IF error_code IS NOT NULL THEN
        UPDATE asm_publication.tasks SET failure=jsonb_build_object('code',error_code,'detail','The publication check did not complete.','retryable',error_code='check_unavailable'),
            lease_owner=NULL,lease_until=NULL,lease_fence=lease_fence+1 WHERE id=t.id;
        IF error_code<>'check_unavailable' THEN DELETE FROM asm_publication.reservations WHERE task_id=t.id; END IF;
        INSERT INTO asm_publication.audit(action,detail) VALUES('attempt_failed',jsonb_build_object('task_id',t.id,'code',error_code));
        RETURN (asm_publication.error(error_code))::text;
    END IF;
    INSERT INTO asm_publication.intents(task_id,package_id,name,version,manifest,manifest_sha256)
        VALUES(t.id,t.package_id,t.name,t.version,t.manifest,t.manifest_sha256);
    UPDATE asm_publication.tasks SET state='committed',lease_owner=NULL,lease_until=NULL WHERE id=t.id;
    INSERT INTO asm_publication.outbox(task_id,event) VALUES(t.id,'publication_committed') RETURNING id INTO event_id;
    INSERT INTO asm_publication.pending_events(event_id) VALUES(event_id);
    INSERT INTO asm_publication.audit(action,detail) VALUES('publication_committed',jsonb_build_object('task_id',t.id,'manifest_sha256',t.manifest_sha256,'event_id',event_id));
    RETURN asm_catalog.canonical_json(asm_publication.task_body(t.id))||chr(10);
END $$;

CREATE FUNCTION asm_publication.claim_event(p_worker text,p_seconds integer) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE e asm_publication.pending_events;
BEGIN
    IF NOT asm_publication.caller('asm_publication_worker') THEN RAISE EXCEPTION 'Worker authority refused' USING ERRCODE='42501'; END IF;
    IF p_worker IS NULL OR p_worker COLLATE "C" !~ '^[0-9a-f]{32}$' OR p_seconds IS NULL OR p_seconds NOT BETWEEN 1 AND 60 THEN
        RAISE EXCEPTION 'Worker lease is invalid' USING ERRCODE='22023'; END IF;
    SELECT * INTO e FROM asm_publication.pending_events WHERE acknowledged_at IS NULL AND (lease_until IS NULL OR lease_until<=clock_timestamp())
        ORDER BY event_id FOR UPDATE SKIP LOCKED LIMIT 1;
    IF NOT FOUND THEN RETURN 'null'; END IF;
    UPDATE asm_publication.pending_events SET lease_owner=p_worker,lease_until=clock_timestamp()+make_interval(secs=>p_seconds),fence=fence+1 WHERE event_id=e.event_id RETURNING * INTO e;
    RETURN (SELECT asm_catalog.canonical_json(jsonb_build_object('id',o.id,'task_id',o.task_id,'schema',o.schema,'event',o.event,'fence',e.fence,
        'manifest_sha256',i.manifest_sha256,'manifest',i.manifest))||chr(10) FROM asm_publication.outbox o JOIN asm_publication.intents i USING(task_id) WHERE o.id=e.event_id);
END $$;

CREATE FUNCTION asm_publication.expire_tasks(p_limit integer) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE t asm_publication.tasks; expired jsonb:='[]'::jsonb;
BEGIN
    IF NOT asm_publication.caller('asm_publication_worker') THEN RAISE EXCEPTION 'Worker authority refused' USING ERRCODE='42501'; END IF;
    IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 128 THEN RAISE EXCEPTION 'Expiry batch is invalid' USING ERRCODE='22023'; END IF;
    FOR t IN SELECT q.* FROM asm_publication.tasks q JOIN asm_publication.credentials c ON c.id=q.credential_id
        WHERE q.state<>'committed' AND (q.failure IS NULL OR q.failure->>'retryable'='true')
            AND (q.upload_expires_at<=clock_timestamp() OR c.revoked_at IS NOT NULL OR c.expires_at<=clock_timestamp())
        ORDER BY q.accepted_at,q.id FOR UPDATE OF q SKIP LOCKED LIMIT p_limit LOOP
        UPDATE asm_publication.tasks SET failure=jsonb_build_object('code','authorization_changed','detail','The publication grant expired or was revoked.','retryable',false),
            lease_owner=NULL,lease_until=NULL,lease_fence=lease_fence+1 WHERE id=t.id;
        DELETE FROM asm_publication.reservations WHERE task_id=t.id;
        INSERT INTO asm_publication.audit(action,detail) VALUES('attempt_failed',jsonb_build_object('task_id',t.id,'code','authorization_changed'));
        expired:=expired||jsonb_build_array(jsonb_build_object('task_id',t.id,'objects',(SELECT jsonb_agg(jsonb_build_object('sha256',o.sha256,'bytes',o.bytes) ORDER BY o.sha256)
            FROM asm_publication.objects o WHERE o.task_id=t.id)));
    END LOOP;
    RETURN asm_catalog.canonical_json(expired)||chr(10);
END $$;

CREATE FUNCTION asm_publication.acknowledge_event(p_event bigint,p_worker text,p_fence bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE e asm_publication.pending_events;
BEGIN
    IF NOT asm_publication.caller('asm_publication_worker') THEN RAISE EXCEPTION 'Worker authority refused' USING ERRCODE='42501'; END IF;
    SELECT * INTO e FROM asm_publication.pending_events WHERE event_id=p_event FOR UPDATE;
    IF NOT FOUND OR e.lease_owner IS DISTINCT FROM p_worker OR e.fence IS DISTINCT FROM p_fence THEN RETURN false; END IF;
    IF e.acknowledged_at IS NOT NULL THEN RETURN true; END IF;
    IF e.lease_until<=clock_timestamp() THEN RETURN false; END IF;
    UPDATE asm_publication.pending_events SET acknowledged_at=clock_timestamp() WHERE event_id=p_event;
    INSERT INTO asm_publication.audit(action,detail) VALUES('event_acknowledged',jsonb_build_object('event_id',p_event,'fence',p_fence));
    RETURN true;
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA asm_publication FROM PUBLIC,asm_reader,asm_operator,asm_publisher,asm_publication_worker;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA asm_publication FROM PUBLIC,asm_reader,asm_operator,asm_publisher,asm_publication_worker;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA asm_publication FROM PUBLIC,asm_reader,asm_operator,asm_publisher,asm_publication_worker;
GRANT USAGE ON SCHEMA asm_publication TO asm_operator,asm_publisher,asm_publication_worker;
GRANT EXECUTE ON FUNCTION asm_publication.enroll_owner(text,text,text),asm_publication.issue_credential(text,text,text,text[],interval,text,text[]),
    asm_publication.revoke_credential(text,text),asm_publication.set_check_policy(text,text,text) TO asm_operator;
GRANT EXECUTE ON FUNCTION asm_publication.publisher_ready(text),asm_publication.create_publication(text,text,text),asm_publication.read_publication(text,text),
    asm_publication.authorize_upload(text,text,text,bigint),asm_publication.receipt_upload(text,text,text,bigint) TO asm_publisher;
GRANT EXECUTE ON FUNCTION asm_publication.claim_check(text,integer),asm_publication.complete_check(text,text,bigint,text),
    asm_publication.claim_event(text,integer),asm_publication.acknowledge_event(bigint,text,bigint),asm_publication.expire_tasks(integer) TO asm_publication_worker;
