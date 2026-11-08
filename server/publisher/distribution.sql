-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Migration 2. Apply atomically as asm_migrator after publication migration 1.
-- The operator records this file's reviewed SHA-384 separately afterward.
-- SQL binds authority and receipts; the private operator verifies TUF and delivery.
SET LOCAL standard_conforming_strings=on;
SET LOCAL search_path=pg_catalog,pg_temp;
DO $$ BEGIN
    IF current_user<>'asm_migrator' OR session_user<>current_user OR
        (SELECT count(*) FROM asm_publication.schema_version)<>1 OR NOT EXISTS(
            SELECT 1 FROM asm_publication.schema_version WHERE version=1 AND
            sha384='e78431a236e7d51945ab767b4318d62f2f04f2cb0289988ed8df930d5fb4ba4604fd8ec0b35d5ef2ecffe7bb4b95ba44') THEN
        RAISE EXCEPTION 'Use the distribution migrator and pinned publication prerequisite' USING ERRCODE='42501';
    END IF;
END $$;

CREATE TABLE asm_publication.distribution_schema_version (
    version integer PRIMARY KEY CHECK(version=2),
    sha384 text NOT NULL CHECK(sha384 COLLATE "C" ~ '^[0-9a-f]{96}$')
);
CREATE TABLE asm_publication.distribution_control (
    singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
    registry_id text COLLATE "C" CHECK(registry_id ~ '^[0-9a-f]{32}$'),
    origin text,
    publication_revision bigint NOT NULL DEFAULT 0 CHECK(publication_revision BETWEEN 0 AND 9007199254740991),
    policy_revision bigint NOT NULL DEFAULT 0 CHECK(policy_revision BETWEEN 0 AND 9007199254740991),
    next_version bigint NOT NULL DEFAULT 0 CHECK(next_version BETWEEN 0 AND 9007199254740991),
    public_version bigint NOT NULL DEFAULT 0 CHECK(public_version BETWEEN 0 AND 9007199254740991),
    public_publication_revision bigint NOT NULL DEFAULT 0,
    public_policy_revision bigint NOT NULL DEFAULT 0,
    public_batch text COLLATE "C",
    active_batch text COLLATE "C",
    worker text COLLATE "C",
    fence bigint NOT NULL DEFAULT 0 CHECK(fence>=0),
    lease_until timestamptz,
    CHECK((registry_id IS NULL)=(origin IS NULL))
);
INSERT INTO asm_publication.distribution_control(singleton,publication_revision)
    SELECT true,count(*) FROM asm_publication.intents;
-- Refresh attempts retain only small headers. A publication/policy revision pair
-- owns one immutable release inventory, independent of metadata refresh cadence.
CREATE TABLE asm_publication.distribution_snapshots (
    id text COLLATE "C" PRIMARY KEY CHECK(id ~ '^[0-9a-f]{32}$'),
    publication_revision bigint NOT NULL,
    policy_revision bigint NOT NULL,
    releases jsonb NOT NULL CHECK(jsonb_typeof(releases)='array' AND jsonb_array_length(releases)<=4095),
    policy_tsv text NOT NULL CHECK(octet_length(policy_tsv) BETWEEN 1 AND 1048576),
    UNIQUE(publication_revision,policy_revision)
);
CREATE TABLE asm_publication.distribution_batches (
    id text COLLATE "C" PRIMARY KEY CHECK(id ~ '^[0-9a-f]{32}$'),
    version bigint UNIQUE NOT NULL CHECK(version BETWEEN 1 AND 9007199254740991),
    publication_revision bigint NOT NULL,
    policy_revision bigint NOT NULL,
    snapshot_id text COLLATE "C" NOT NULL REFERENCES asm_publication.distribution_snapshots,
    source_sha256 text NOT NULL CHECK(source_sha256 COLLATE "C" ~ '^[0-9a-f]{64}$'),
    sealed text CHECK(octet_length(sealed) BETWEEN 1 AND 32768),
    phase text NOT NULL CHECK(phase IN ('prepared','sealed','published','abandoned')),
    completion text CHECK(octet_length(completion) BETWEEN 1 AND 32768),
    finish_receipt text CHECK(octet_length(finish_receipt) BETWEEN 1 AND 32768),
    abandonment text CHECK(octet_length(abandonment) BETWEEN 1 AND 2048),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK((phase='published')=(completion IS NOT NULL AND finish_receipt IS NOT NULL)),
    CHECK(abandonment IS NULL OR phase='abandoned'),
    CHECK(phase NOT IN ('sealed','published') OR sealed IS NOT NULL)
);
CREATE TABLE asm_publication.distribution_members (
    snapshot_id text COLLATE "C" NOT NULL REFERENCES asm_publication.distribution_snapshots,
    release_id text COLLATE "C" NOT NULL REFERENCES asm_publication.intents(task_id),
    target text COLLATE "C" NOT NULL CHECK(octet_length(target) BETWEEN 1 AND 240),
    sha256 text NOT NULL CHECK(sha256 COLLATE "C" ~ '^[0-9a-f]{64}$'),
    bytes integer NOT NULL CHECK(bytes BETWEEN 1 AND 131072),
    PRIMARY KEY(snapshot_id,release_id),
    UNIQUE(snapshot_id,target)
);
CREATE INDEX distribution_member_release ON asm_publication.distribution_members(release_id,snapshot_id);
CREATE TABLE asm_publication.published_releases (
    release_id text COLLATE "C" PRIMARY KEY REFERENCES asm_publication.intents(task_id),
    batch_id text COLLATE "C" NOT NULL REFERENCES asm_publication.distribution_batches,
    target text COLLATE "C" NOT NULL,
    sha256 text NOT NULL,
    publication_revision bigint NOT NULL,
    policy_revision bigint NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE asm_publication.lifecycle_events (
    operation_id text COLLATE "C" PRIMARY KEY CHECK(operation_id ~ '^[0-9a-f]{32}$'),
    release_id text COLLATE "C" NOT NULL REFERENCES asm_publication.intents(task_id),
    action text NOT NULL CHECK(action IN ('yank','unyank','revoke')),
    expected_revision bigint NOT NULL,
    policy_revision bigint UNIQUE NOT NULL CHECK(policy_revision>0),
    yanked boolean NOT NULL,
    revoked boolean NOT NULL,
    reference text NOT NULL CHECK(octet_length(reference) BETWEEN 1 AND 256),
    payload_sha256 text NOT NULL,
    actor name NOT NULL DEFAULT session_user,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX lifecycle_current ON asm_publication.lifecycle_events(release_id,policy_revision DESC);

CREATE FUNCTION asm_publication.preserve_distribution_batch() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF (NEW.id,NEW.version,NEW.publication_revision,NEW.policy_revision,NEW.snapshot_id,NEW.source_sha256,NEW.recorded_at)
        IS DISTINCT FROM (OLD.id,OLD.version,OLD.publication_revision,OLD.policy_revision,OLD.snapshot_id,OLD.source_sha256,OLD.recorded_at)
        OR (OLD.sealed IS NOT NULL AND NEW.sealed IS DISTINCT FROM OLD.sealed)
        OR (OLD.completion IS NOT NULL AND NEW.completion IS DISTINCT FROM OLD.completion)
        OR (OLD.finish_receipt IS NOT NULL AND NEW.finish_receipt IS DISTINCT FROM OLD.finish_receipt)
        OR (OLD.abandonment IS NOT NULL AND NEW.abandonment IS DISTINCT FROM OLD.abandonment)
        OR (OLD.phase IN ('published','abandoned') AND NEW.phase<>OLD.phase) THEN
        RAISE EXCEPTION 'Retained distribution data is immutable' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER immutable_distribution_identity BEFORE UPDATE ON asm_publication.distribution_batches
    FOR EACH ROW EXECUTE FUNCTION asm_publication.preserve_distribution_batch();
CREATE TRIGGER immutable_distribution_delete BEFORE DELETE ON asm_publication.distribution_batches
    FOR EACH ROW EXECUTE FUNCTION asm_catalog.reject_change();
CREATE TRIGGER immutable_distribution_truncate BEFORE TRUNCATE ON asm_publication.distribution_batches
    FOR EACH STATEMENT EXECUTE FUNCTION asm_catalog.reject_change();
DO $$ DECLARE t text; BEGIN
    FOREACH t IN ARRAY ARRAY['distribution_snapshots','distribution_members','published_releases','lifecycle_events'] LOOP
        EXECUTE format('CREATE TRIGGER immutable_row BEFORE UPDATE OR DELETE ON asm_publication.%I FOR EACH ROW EXECUTE FUNCTION asm_catalog.reject_change()',t);
        EXECUTE format('CREATE TRIGGER immutable_table BEFORE TRUNCATE ON asm_publication.%I FOR EACH STATEMENT EXECUTE FUNCTION asm_catalog.reject_change()',t);
    END LOOP;
END $$;

ALTER TABLE asm_publication.packages ADD COLUMN revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0);
DROP TRIGGER immutable_row ON asm_publication.packages;
CREATE FUNCTION asm_publication.preserve_package_identity() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Package identity is immutable' USING ERRCODE='55000'; END IF;
    IF (NEW.id,NEW.owner_id,NEW.name) IS DISTINCT FROM (OLD.id,OLD.owner_id,OLD.name) OR NEW.revision<OLD.revision THEN
        RAISE EXCEPTION 'Package identity is immutable' USING ERRCODE='55000'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER immutable_row BEFORE UPDATE OR DELETE ON asm_publication.packages
    FOR EACH ROW EXECUTE FUNCTION asm_publication.preserve_package_identity();
UPDATE asm_publication.packages p SET revision=(SELECT count(*) FROM asm_publication.intents i WHERE i.package_id=p.id);

ALTER TABLE asm_publication.outbox DROP CONSTRAINT outbox_task_id_key;
ALTER TABLE asm_publication.outbox DROP CONSTRAINT outbox_event_check;
ALTER TABLE asm_publication.outbox ADD CONSTRAINT outbox_event_check
    CHECK(event IN ('publication_committed','publication_published','lifecycle_changed'));
ALTER TABLE asm_publication.outbox DROP CONSTRAINT outbox_schema_check;
ALTER TABLE asm_publication.outbox ADD CONSTRAINT outbox_schema_check CHECK(schema IN (1,2));
ALTER TABLE asm_publication.outbox ADD COLUMN distribution_version bigint NOT NULL DEFAULT 0;
ALTER TABLE asm_publication.outbox ADD COLUMN publication_revision bigint NOT NULL DEFAULT 0;
ALTER TABLE asm_publication.outbox ADD COLUMN policy_revision bigint NOT NULL DEFAULT 0;
ALTER TABLE asm_publication.outbox ADD COLUMN package_revision bigint NOT NULL DEFAULT 0;
CREATE UNIQUE INDEX outbox_occurrence ON asm_publication.outbox(task_id,event,distribution_version,policy_revision);
ALTER TABLE asm_publication.audit DROP CONSTRAINT audit_action_check;
ALTER TABLE asm_publication.audit ADD CONSTRAINT audit_action_check CHECK(action IN (
    'owner_enrolled','credential_issued','credential_revoked','publication_accepted','upload_received','checker_policy_selected',
    'check_recorded','publication_committed','attempt_failed','event_acknowledged','registry_configured','distribution_claimed',
    'distribution_sealed','distribution_published','distribution_abandoned','lifecycle_changed'));

CREATE FUNCTION asm_publication.intent_distribution_revision() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    UPDATE asm_publication.distribution_control SET publication_revision=publication_revision+1 WHERE singleton;
    UPDATE asm_publication.packages SET revision=revision+1 WHERE id=NEW.package_id;
    RETURN NEW;
END $$;
CREATE TRIGGER distribution_revision AFTER INSERT ON asm_publication.intents
    FOR EACH ROW EXECUTE FUNCTION asm_publication.intent_distribution_revision();
CREATE FUNCTION asm_publication.outbox_distribution_revision() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    NEW.schema:=2;
    IF NEW.event<>'publication_published' THEN
        SELECT c.publication_revision,c.policy_revision INTO NEW.publication_revision,NEW.policy_revision
            FROM asm_publication.distribution_control c WHERE singleton;
    END IF;
    SELECT p.revision INTO NEW.package_revision FROM asm_publication.intents i
        JOIN asm_publication.packages p ON p.id=i.package_id WHERE i.task_id=NEW.task_id;
    RETURN NEW;
END $$;
CREATE TRIGGER distribution_event_revision BEFORE INSERT ON asm_publication.outbox
    FOR EACH ROW EXECUTE FUNCTION asm_publication.outbox_distribution_revision();

CREATE FUNCTION asm_publication.configure_distribution(p_registry text,p_origin text,p_reference text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE c asm_publication.distribution_control; port text; path text;
BEGIN
    IF NOT asm_publication.caller('asm_operator') THEN RAISE EXCEPTION 'Operator authority refused' USING ERRCODE='42501'; END IF;
    IF p_registry IS NULL OR p_registry COLLATE "C" !~ '^[0-9a-f]{32}$' OR p_origin IS NULL
        OR octet_length(p_origin) NOT BETWEEN 9 AND 1024 OR right(p_origin,1)='/'
        OR p_origin COLLATE "C" !~ '^https://[a-z0-9][a-z0-9.-]*(:[1-9][0-9]{0,4})?(/[A-Za-z0-9._/-]+)?$'
        OR p_reference IS NULL OR octet_length(p_reference) NOT BETWEEN 1 AND 256 OR p_reference COLLATE "C" !~ '^[ -~]+$' THEN
        RAISE EXCEPTION 'Registry configuration is invalid' USING ERRCODE='22023'; END IF;
    port:=substring(p_origin FROM '^https://[^/:]+:([0-9]+)');
    path:=regexp_replace(p_origin,'^https://[^/]+/?','');
    IF (port IS NOT NULL AND port::integer>65535) OR (path<>'' AND NOT asm_catalog.portable_path(path)) THEN
        RAISE EXCEPTION 'Registry origin is invalid' USING ERRCODE='22023'; END IF;
    SELECT * INTO c FROM asm_publication.distribution_control WHERE singleton FOR UPDATE;
    IF c.registry_id IS NOT NULL AND (c.registry_id<>p_registry OR c.origin<>p_origin) THEN
        RAISE EXCEPTION 'Registry identity and origin are already bound' USING ERRCODE='23505'; END IF;
    IF c.registry_id IS NULL THEN
        UPDATE asm_publication.distribution_control SET registry_id=p_registry,origin=p_origin WHERE singleton;
        INSERT INTO asm_publication.audit(action,detail) VALUES('registry_configured',jsonb_build_object('registry_id',p_registry,'origin',p_origin,'reference',p_reference));
    END IF;
    RETURN asm_catalog.canonical_json(jsonb_build_object('schema',2,'registry_id',p_registry,'origin',p_origin))||chr(10);
END $$;

CREATE FUNCTION asm_publication.distribution_envelope(p_registry text,i asm_publication.intents) RETURNS text
LANGUAGE plpgsql STABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE d jsonb; raw text;
BEGIN
    d:=asm_publication.manifest(i.manifest);
    IF d->>'name'<>i.name OR d->>'version'<>i.version OR i.manifest_sha256<>encode(sha256(convert_to(i.manifest,'UTF8')),'hex') THEN
        RAISE EXCEPTION 'Committed publication binding differs' USING ERRCODE='22023'; END IF;
    raw:=asm_catalog.canonical_json(jsonb_build_object('schema',2,'registry_id',p_registry,'package_id',i.package_id,
        'release_id',i.task_id,'manifest_sha256',i.manifest_sha256,'publication',d))||chr(10);
    IF octet_length(raw)>131072 THEN RAISE EXCEPTION 'Release envelope exceeds its byte limit' USING ERRCODE='22023'; END IF;
    RETURN raw;
END $$;

CREATE FUNCTION asm_publication.distribution_source(p_batch text,p_version bigint,p_snapshot text) RETURNS text
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
SELECT asm_catalog.canonical_json(jsonb_build_object('schema',2,'batch_id',p_batch,'registry_id',c.registry_id,'origin',c.origin,
    'version',p_version::text,'publication_revision',s.publication_revision::text,'policy_revision',s.policy_revision::text,
    'policy_tsv',s.policy_tsv,'releases',s.releases))||chr(10)
FROM asm_publication.distribution_snapshots s CROSS JOIN asm_publication.distribution_control c WHERE s.id=p_snapshot AND c.singleton
$$;
CREATE FUNCTION asm_publication.distribution_batch_body(p_batch text) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
SELECT jsonb_build_object('schema',2,'batch_id',b.id,'fence',c.fence,'source_sha256',b.source_sha256,
    'source',asm_publication.distribution_source(b.id,b.version,b.snapshot_id)::jsonb,'sealed',b.sealed::jsonb)
FROM asm_publication.distribution_batches b CROSS JOIN asm_publication.distribution_control c WHERE b.id=p_batch AND c.singleton
$$;

CREATE FUNCTION asm_publication.claim_distribution(p_worker text,p_seconds integer,p_refresh boolean DEFAULT false) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE c asm_publication.distribution_control; b asm_publication.distribution_batches; entries jsonb; policy text;
    source text; batch text; version bigint; count bigint; snapshot text;
BEGIN
    IF NOT asm_publication.caller('asm_distributor') THEN RAISE EXCEPTION 'Distributor authority refused' USING ERRCODE='42501'; END IF;
    IF current_setting('transaction_isolation')<>'read committed' OR p_worker IS NULL OR p_worker COLLATE "C" !~ '^[0-9a-f]{32}$'
        OR p_seconds IS NULL OR p_seconds NOT BETWEEN 1 AND 300 OR p_refresh IS NULL THEN
        RAISE EXCEPTION 'Distribution claim is invalid' USING ERRCODE='22023'; END IF;
    SELECT * INTO c FROM asm_publication.distribution_control WHERE singleton FOR UPDATE;
    IF c.registry_id IS NULL THEN RAISE EXCEPTION 'Configure the registry before distribution' USING ERRCODE='55000'; END IF;
    IF c.active_batch IS NOT NULL THEN
        SELECT * INTO b FROM asm_publication.distribution_batches WHERE id=c.active_batch;
        IF b.phase IN ('prepared','sealed') AND b.policy_revision=c.policy_revision AND b.publication_revision>=c.public_publication_revision THEN
            IF c.lease_until>clock_timestamp() AND c.worker<>p_worker THEN RETURN 'null'||chr(10); END IF;
            IF c.lease_until IS NULL OR c.lease_until<=clock_timestamp() OR c.worker IS DISTINCT FROM p_worker THEN
                UPDATE asm_publication.distribution_control SET worker=p_worker,fence=fence+1,
                    lease_until=clock_timestamp()+make_interval(secs=>p_seconds) WHERE singleton;
            END IF;
            RETURN asm_catalog.canonical_json(asm_publication.distribution_batch_body(b.id))||chr(10);
        END IF;
        IF b.phase IN ('prepared','sealed') THEN UPDATE asm_publication.distribution_batches SET phase='abandoned' WHERE id=b.id; END IF;
    END IF;
    IF c.public_version>0 AND c.public_publication_revision=c.publication_revision AND c.public_policy_revision=c.policy_revision AND NOT p_refresh THEN
        RETURN 'null'||chr(10); END IF;
    batch:=replace(gen_random_uuid()::text,'-',''); version:=c.next_version+1;
    IF version>9007199254740991 THEN RAISE EXCEPTION 'Distribution version limit reached' USING ERRCODE='22023'; END IF;
    SELECT s.id INTO snapshot FROM asm_publication.distribution_snapshots s
        WHERE s.publication_revision=c.publication_revision AND s.policy_revision=c.policy_revision;
    IF snapshot IS NULL THEN
    SELECT count(*) INTO count FROM asm_publication.intents;
    IF count>4095 THEN RAISE EXCEPTION 'The flat signed profile permits at most 4095 releases' USING ERRCODE='22023'; END IF;
    WITH exported AS MATERIALIZED (
        SELECT i.*,asm_publication.distribution_envelope(c.registry_id,i) AS envelope FROM asm_publication.intents i
    ) SELECT coalesce(jsonb_agg(jsonb_build_object('name',e.name,'version',e.version,'package_id',e.package_id,'release_id',e.task_id,
        'target','registries/'||c.registry_id||'/releases/'||e.name||'/'||e.version||'.json',
        'sha256',encode(sha256(convert_to(e.envelope,'UTF8')),'hex'),'bytes',octet_length(e.envelope)) ORDER BY e.name COLLATE "C",e.version COLLATE "C"),'[]'::jsonb)
        INTO entries FROM exported e;
    SELECT '# asm-registry-policy-v2'||chr(9)||c.registry_id||chr(9)||c.publication_revision::text||chr(9)||c.policy_revision::text||chr(10)||
        coalesce(string_agg(i.name||chr(9)||i.version||chr(9)||i.package_id||chr(9)||i.task_id||chr(9)||
            CASE WHEN coalesce(l.yanked,false) THEN '1' ELSE '0' END||chr(9)||CASE WHEN coalesce(l.revoked,false) THEN '1' ELSE '0' END||chr(10),
            '' ORDER BY i.name COLLATE "C",i.version COLLATE "C"),'') INTO policy
    FROM asm_publication.intents i LEFT JOIN LATERAL (
        SELECT e.yanked,e.revoked FROM asm_publication.lifecycle_events e WHERE e.release_id=i.task_id AND e.policy_revision<=c.policy_revision
        ORDER BY e.policy_revision DESC LIMIT 1) l ON true;
    IF octet_length(policy)>1048576 THEN RAISE EXCEPTION 'Lifecycle policy exceeds one MiB' USING ERRCODE='22023'; END IF;
    snapshot:=replace(gen_random_uuid()::text,'-','');
    INSERT INTO asm_publication.distribution_snapshots(id,publication_revision,policy_revision,releases,policy_tsv)
        VALUES(snapshot,c.publication_revision,c.policy_revision,entries,policy);
    INSERT INTO asm_publication.distribution_members(snapshot_id,release_id,target,sha256,bytes)
        SELECT snapshot,e->>'release_id',e->>'target',e->>'sha256',(e->>'bytes')::integer FROM jsonb_array_elements(entries) e;
    END IF;
    source:=asm_publication.distribution_source(batch,version,snapshot);
    IF octet_length(source)>4194304 THEN RAISE EXCEPTION 'Frozen distribution source exceeds four MiB' USING ERRCODE='22023'; END IF;
    INSERT INTO asm_publication.distribution_batches(id,version,publication_revision,policy_revision,snapshot_id,source_sha256,phase)
        VALUES(batch,version,c.publication_revision,c.policy_revision,snapshot,encode(sha256(convert_to(source,'UTF8')),'hex'),'prepared');
    UPDATE asm_publication.distribution_control SET next_version=version,active_batch=batch,worker=p_worker,
        fence=fence+1,lease_until=clock_timestamp()+make_interval(secs=>p_seconds) WHERE singleton;
    INSERT INTO asm_publication.audit(action,detail) VALUES('distribution_claimed',jsonb_build_object('batch_id',batch,'version',version::text,
        'publication_revision',c.publication_revision::text,'policy_revision',c.policy_revision::text));
    RETURN asm_catalog.canonical_json(asm_publication.distribution_batch_body(batch))||chr(10);
END $$;

CREATE FUNCTION asm_publication.distribution_lease(p_batch text,p_worker text,p_fence bigint,p_source text) RETURNS asm_publication.distribution_batches
LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
DECLARE c asm_publication.distribution_control; b asm_publication.distribution_batches;
BEGIN
    SELECT * INTO c FROM asm_publication.distribution_control WHERE singleton FOR UPDATE;
    SELECT * INTO b FROM asm_publication.distribution_batches WHERE id=p_batch;
    IF b.id IS NULL OR c.active_batch IS DISTINCT FROM p_batch OR c.worker IS DISTINCT FROM p_worker OR c.fence IS DISTINCT FROM p_fence
        OR c.lease_until IS NULL OR c.lease_until<=clock_timestamp() OR b.phase NOT IN ('prepared','sealed') THEN
        RAISE EXCEPTION 'Distribution lease was lost' USING ERRCODE='40001'; END IF;
    IF b.source_sha256 IS DISTINCT FROM p_source OR b.policy_revision<>c.policy_revision OR b.publication_revision<c.public_publication_revision THEN
        RAISE EXCEPTION 'Distribution source or policy changed' USING ERRCODE='40001'; END IF;
    RETURN b;
END $$;

CREATE FUNCTION asm_publication.distribution_release(p_batch text,p_release text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE b asm_publication.distribution_batches; m asm_publication.distribution_members; i asm_publication.intents; raw text;
BEGIN
    IF NOT asm_publication.caller('asm_distributor') THEN RAISE EXCEPTION 'Distributor authority refused' USING ERRCODE='42501'; END IF;
    SELECT * INTO b FROM asm_publication.distribution_batches WHERE id=p_batch;
    SELECT * INTO m FROM asm_publication.distribution_members WHERE snapshot_id=b.snapshot_id AND release_id=p_release;
    IF b.id IS NULL OR m.release_id IS NULL THEN RAISE EXCEPTION 'Release is absent from the frozen batch' USING ERRCODE='22023'; END IF;
    SELECT * INTO i FROM asm_publication.intents WHERE task_id=p_release;
    raw:=asm_publication.distribution_envelope((SELECT registry_id FROM asm_publication.distribution_control WHERE singleton),i);
    IF octet_length(raw)<>m.bytes OR encode(sha256(convert_to(raw,'UTF8')),'hex')<>m.sha256 THEN
        RAISE EXCEPTION 'Frozen release bytes differ' USING ERRCODE='55000'; END IF;
    RETURN raw;
END $$;

CREATE FUNCTION asm_publication.distribution_descriptor(raw text,p_batch text,p_source text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$
DECLARE d jsonb; k text;
BEGIN
    IF raw IS NULL OR octet_length(raw) NOT BETWEEN 1 AND 32768 THEN RAISE EXCEPTION 'Distribution descriptor is invalid' USING ERRCODE='22023'; END IF;
    PERFORM asm_catalog.check_json(raw::json); d:=raw::jsonb;
    IF jsonb_typeof(d)<>'object' OR NOT d ?& ARRAY['schema','batch_id','source_sha256','plan_sha256','bundle_sha256','timestamp_sha256']
        OR d-ARRAY['schema','batch_id','source_sha256','plan_sha256','bundle_sha256','timestamp_sha256']<>'{}'::jsonb OR d->'schema'<>'2'::jsonb
        OR d->>'batch_id' IS DISTINCT FROM p_batch OR d->>'source_sha256' IS DISTINCT FROM p_source
        OR asm_catalog.canonical_json(d)||chr(10)<>raw THEN RAISE EXCEPTION 'Distribution descriptor binding differs' USING ERRCODE='22023'; END IF;
    FOREACH k IN ARRAY ARRAY['source_sha256','plan_sha256','bundle_sha256','timestamp_sha256'] LOOP
        IF jsonb_typeof(d->k) IS DISTINCT FROM 'string' OR d->>k COLLATE "C" !~ '^[0-9a-f]{64}$' THEN
            RAISE EXCEPTION 'Distribution descriptor digest is invalid' USING ERRCODE='22023'; END IF;
    END LOOP;
    RETURN d;
END $$;

CREATE FUNCTION asm_publication.seal_distribution(p_batch text,p_worker text,p_fence bigint,p_source text,raw text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE b asm_publication.distribution_batches; d jsonb;
BEGIN
    IF NOT asm_publication.caller('asm_distributor') THEN RAISE EXCEPTION 'Distributor authority refused' USING ERRCODE='42501'; END IF;
    b:=asm_publication.distribution_lease(p_batch,p_worker,p_fence,p_source);
    d:=asm_publication.distribution_descriptor(raw,p_batch,p_source);
    IF b.sealed IS NOT NULL AND b.sealed<>raw THEN RAISE EXCEPTION 'The reserved metadata version has different sealed bytes' USING ERRCODE='23505'; END IF;
    IF b.sealed IS NULL THEN
        UPDATE asm_publication.distribution_batches SET sealed=raw,phase='sealed' WHERE id=p_batch;
        INSERT INTO asm_publication.audit(action,detail) VALUES('distribution_sealed',jsonb_build_object('batch_id',p_batch,'plan_sha256',d->>'plan_sha256','timestamp_sha256',d->>'timestamp_sha256'));
    END IF;
    RETURN asm_catalog.canonical_json(asm_publication.distribution_batch_body(p_batch))||chr(10);
END $$;

CREATE FUNCTION asm_publication.renew_distribution(p_batch text,p_worker text,p_fence bigint,p_source text,p_seconds integer) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN
    IF NOT asm_publication.caller('asm_distributor') THEN RAISE EXCEPTION 'Distributor authority refused' USING ERRCODE='42501'; END IF;
    IF p_seconds IS NULL OR p_seconds NOT BETWEEN 1 AND 300 THEN RAISE EXCEPTION 'Distribution renewal is invalid' USING ERRCODE='22023'; END IF;
    PERFORM asm_publication.distribution_lease(p_batch,p_worker,p_fence,p_source);
    UPDATE asm_publication.distribution_control SET lease_until=clock_timestamp()+make_interval(secs=>p_seconds) WHERE singleton;
    RETURN asm_catalog.canonical_json(asm_publication.distribution_batch_body(p_batch))||chr(10);
END $$;

CREATE FUNCTION asm_publication.authorize_distribution_head(p_batch text,p_worker text,p_fence bigint,p_source text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE b asm_publication.distribution_batches;
BEGIN
    IF NOT asm_publication.caller('asm_distributor') THEN RAISE EXCEPTION 'Distributor authority refused' USING ERRCODE='42501'; END IF;
    b:=asm_publication.distribution_lease(p_batch,p_worker,p_fence,p_source);
    IF b.sealed IS NULL THEN RAISE EXCEPTION 'Seal exact signed bytes before exposing metadata' USING ERRCODE='55000'; END IF;
    RETURN asm_catalog.canonical_json(asm_publication.distribution_batch_body(p_batch))||chr(10);
END $$;

CREATE FUNCTION asm_publication.abandon_distribution(p_batch text,p_worker text,p_fence bigint,p_source text,p_reference text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE b asm_publication.distribution_batches; request text;
BEGIN
    IF NOT asm_publication.caller('asm_distributor') THEN RAISE EXCEPTION 'Distributor authority refused' USING ERRCODE='42501'; END IF;
    IF p_reference IS NULL OR octet_length(p_reference) NOT BETWEEN 1 AND 256 OR p_reference COLLATE "C" !~ '^[ -~]+$' THEN
        RAISE EXCEPTION 'Distribution reconciliation reference is invalid' USING ERRCODE='22023'; END IF;
    request:=asm_catalog.canonical_json(jsonb_build_object('batch_id',p_batch,'worker',p_worker,'fence',p_fence,
        'source_sha256',p_source,'reference',p_reference))||chr(10);
    PERFORM 1 FROM asm_publication.distribution_control WHERE singleton FOR UPDATE;
    SELECT * INTO b FROM asm_publication.distribution_batches WHERE id=p_batch;
    IF b.phase='abandoned' AND b.abandonment IS NOT NULL THEN
        IF b.abandonment<>request THEN RAISE EXCEPTION 'Distribution abandonment identity differs' USING ERRCODE='23505'; END IF;
    ELSE
        b:=asm_publication.distribution_lease(p_batch,p_worker,p_fence,p_source);
        UPDATE asm_publication.distribution_batches SET phase='abandoned',abandonment=request WHERE id=p_batch;
        UPDATE asm_publication.distribution_control SET active_batch=NULL,worker=NULL,lease_until=NULL,fence=fence+1 WHERE singleton;
        INSERT INTO asm_publication.audit(action,detail) VALUES('distribution_abandoned',request::jsonb);
    END IF;
    RETURN asm_catalog.canonical_json(jsonb_build_object('schema',2,'batch_id',b.id,'state','abandoned','version',b.version::text))||chr(10);
END $$;

CREATE FUNCTION asm_publication.finish_distribution(p_batch text,p_worker text,p_fence bigint,raw text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE b asm_publication.distribution_batches; c asm_publication.distribution_control; r jsonb; descriptor jsonb; ids text[];
    version bigint; completed text;
BEGIN
    IF NOT asm_publication.caller('asm_distributor') THEN RAISE EXCEPTION 'Distributor authority refused' USING ERRCODE='42501'; END IF;
    IF raw IS NULL OR octet_length(raw) NOT BETWEEN 1 AND 32768 THEN RAISE EXCEPTION 'Distribution receipt is invalid' USING ERRCODE='22023'; END IF;
    PERFORM asm_catalog.check_json(raw::json); r:=raw::jsonb;
    SELECT * INTO c FROM asm_publication.distribution_control WHERE singleton FOR UPDATE;
    SELECT * INTO b FROM asm_publication.distribution_batches WHERE id=p_batch;
    IF b.id IS NULL THEN RAISE EXCEPTION 'Distribution batch is absent' USING ERRCODE='22023'; END IF;
    IF b.phase='published' THEN
        IF b.finish_receipt<>raw THEN RAISE EXCEPTION 'Completed distribution receipt differs' USING ERRCODE='23505'; END IF;
        RETURN b.completion;
    END IF;
    b:=asm_publication.distribution_lease(p_batch,p_worker,p_fence,b.source_sha256);
    IF b.sealed IS NULL OR jsonb_typeof(r)<>'object' OR NOT r ?& ARRAY['schema','batch_id','source_sha256','plan_sha256','bundle_sha256','timestamp_sha256','version','publication_revision','policy_revision']
        OR r-ARRAY['schema','batch_id','source_sha256','plan_sha256','bundle_sha256','timestamp_sha256','version','publication_revision','policy_revision']<>'{}'::jsonb
        OR (r-ARRAY['version','publication_revision','policy_revision']) IS DISTINCT FROM b.sealed::jsonb
        OR r->'version' IS DISTINCT FROM to_jsonb(b.version::text)
        OR r->'publication_revision' IS DISTINCT FROM to_jsonb(b.publication_revision::text)
        OR r->'policy_revision' IS DISTINCT FROM to_jsonb(b.policy_revision::text)
        OR asm_catalog.canonical_json(r)||chr(10)<>raw OR b.version<=c.public_version
        OR b.publication_revision<c.public_publication_revision OR b.policy_revision<c.public_policy_revision THEN
        RAISE EXCEPTION 'Verified distribution receipt binding differs' USING ERRCODE='22023'; END IF;
    SELECT coalesce(array_agg(m.release_id),'{}'::text[]) INTO ids FROM asm_publication.distribution_members m
        WHERE m.snapshot_id=b.snapshot_id AND NOT EXISTS(SELECT 1 FROM asm_publication.published_releases p WHERE p.release_id=m.release_id);
    UPDATE asm_publication.packages SET revision=revision+1 WHERE id IN (SELECT i.package_id FROM asm_publication.intents i WHERE i.task_id=ANY(ids));
    INSERT INTO asm_publication.published_releases(release_id,batch_id,target,sha256,publication_revision,policy_revision)
        SELECT m.release_id,p_batch,m.target,m.sha256,b.publication_revision,b.policy_revision FROM asm_publication.distribution_members m
        WHERE m.snapshot_id=b.snapshot_id AND m.release_id=ANY(ids);
    WITH events AS (
        INSERT INTO asm_publication.outbox(task_id,event,distribution_version,publication_revision,policy_revision)
            SELECT unnest(ids),'publication_published',b.version,b.publication_revision,b.policy_revision RETURNING id
    ) INSERT INTO asm_publication.pending_events(event_id) SELECT id FROM events;
    UPDATE asm_publication.pending_events SET acknowledged_at=clock_timestamp()
        WHERE acknowledged_at IS NULL AND event_id IN (SELECT o.id FROM asm_publication.outbox o JOIN asm_publication.distribution_members m ON m.release_id=o.task_id
            WHERE m.snapshot_id=b.snapshot_id AND o.event='publication_committed');
    completed:=asm_catalog.canonical_json(jsonb_build_object('schema',2,'registry_id',c.registry_id,'version',b.version::text,
        'publication_revision',b.publication_revision::text,'policy_revision',b.policy_revision::text,
        'plan_sha256',r->>'plan_sha256','timestamp_sha256',r->>'timestamp_sha256','published_count',cardinality(ids)))||chr(10);
    UPDATE asm_publication.distribution_batches SET phase='published',completion=completed,finish_receipt=raw WHERE id=p_batch;
    UPDATE asm_publication.distribution_control SET public_version=b.version,public_batch=b.id,
        public_publication_revision=b.publication_revision,public_policy_revision=b.policy_revision,
        active_batch=NULL,worker=NULL,lease_until=NULL WHERE singleton;
    INSERT INTO asm_publication.audit(action,detail) VALUES('distribution_published',jsonb_build_object('batch_id',b.id,'version',b.version::text,
        'publication_revision',b.publication_revision::text,'policy_revision',b.policy_revision::text,'published_count',cardinality(ids)));
    RETURN completed;
END $$;

CREATE FUNCTION asm_publication.set_lifecycle(p_release text,p_action text,p_operation text,p_expected bigint,p_reference text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
DECLARE c asm_publication.distribution_control; old asm_publication.lifecycle_events; recorded asm_publication.lifecycle_events;
    yanked boolean:=false; revoked boolean:=false; digest text; event bigint;
BEGIN
    IF NOT asm_publication.caller('asm_operator') THEN RAISE EXCEPTION 'Operator authority refused' USING ERRCODE='42501'; END IF;
    IF p_release IS NULL OR p_release COLLATE "C" !~ '^[0-9a-f]{32}$' OR p_action IS NULL OR p_action NOT IN ('yank','unyank','revoke')
        OR p_operation IS NULL OR p_operation COLLATE "C" !~ '^[0-9a-f]{32}$' OR p_expected IS NULL OR p_expected<0
        OR p_reference IS NULL OR octet_length(p_reference) NOT BETWEEN 1 AND 256 OR p_reference COLLATE "C" !~ '^[ -~]+$' THEN
        RAISE EXCEPTION 'Lifecycle operation is invalid' USING ERRCODE='22023'; END IF;
    digest:=encode(sha256(convert_to(asm_catalog.canonical_json(jsonb_build_array(p_release,p_action,p_expected::text,p_reference)),'UTF8')),'hex');
    SELECT * INTO c FROM asm_publication.distribution_control WHERE singleton FOR UPDATE;
    SELECT * INTO recorded FROM asm_publication.lifecycle_events WHERE operation_id=p_operation;
    IF FOUND THEN
        IF recorded.payload_sha256<>digest THEN RAISE EXCEPTION 'Lifecycle operation identity conflicts' USING ERRCODE='23505'; END IF;
        RETURN asm_catalog.canonical_json(jsonb_build_object('schema',2,'release_id',recorded.release_id,'policy_revision',recorded.policy_revision::text,
            'yanked',recorded.yanked,'revoked',recorded.revoked))||chr(10);
    END IF;
    IF NOT EXISTS(SELECT 1 FROM asm_publication.intents WHERE task_id=p_release) THEN RAISE EXCEPTION 'Committed release is absent' USING ERRCODE='22023'; END IF;
    IF c.policy_revision<>p_expected THEN RAISE EXCEPTION 'Lifecycle policy changed; inspect it before retrying' USING ERRCODE='40001'; END IF;
    SELECT * INTO old FROM asm_publication.lifecycle_events WHERE release_id=p_release ORDER BY policy_revision DESC LIMIT 1;
    IF FOUND THEN yanked:=old.yanked; revoked:=old.revoked; END IF;
    IF p_action='yank' THEN yanked:=true; ELSIF p_action='unyank' THEN yanked:=false; ELSE revoked:=true; END IF;
    IF c.active_batch IS NOT NULL THEN
        UPDATE asm_publication.distribution_batches SET phase='abandoned' WHERE id=c.active_batch AND phase IN ('prepared','sealed');
    END IF;
    UPDATE asm_publication.distribution_control SET policy_revision=policy_revision+1,active_batch=NULL,worker=NULL,
        fence=fence+1,lease_until=NULL WHERE singleton RETURNING * INTO c;
    INSERT INTO asm_publication.lifecycle_events(operation_id,release_id,action,expected_revision,policy_revision,yanked,revoked,reference,payload_sha256)
        VALUES(p_operation,p_release,p_action,p_expected,c.policy_revision,yanked,revoked,p_reference,digest);
    UPDATE asm_publication.packages SET revision=revision+1 WHERE id=(SELECT package_id FROM asm_publication.intents WHERE task_id=p_release);
    INSERT INTO asm_publication.outbox(task_id,event,policy_revision) VALUES(p_release,'lifecycle_changed',c.policy_revision) RETURNING id INTO event;
    INSERT INTO asm_publication.pending_events(event_id) VALUES(event);
    INSERT INTO asm_publication.audit(action,detail) VALUES('lifecycle_changed',jsonb_build_object('operation_id',p_operation,'release_id',p_release,
        'action',p_action,'policy_revision',c.policy_revision::text,'reference',p_reference));
    RETURN asm_catalog.canonical_json(jsonb_build_object('schema',2,'release_id',p_release,'policy_revision',c.policy_revision::text,'yanked',yanked,'revoked',revoked))||chr(10);
END $$;

ALTER FUNCTION asm_publication.task_body(text) RENAME TO task_body_before_distribution;
CREATE FUNCTION asm_publication.task_body(p_task text) RETURNS jsonb
LANGUAGE sql STABLE SET search_path=pg_catalog,pg_temp AS $$
SELECT base.value||jsonb_build_object('state',CASE WHEN p.release_id IS NOT NULL THEN 'published'
    WHEN EXISTS(SELECT 1 FROM asm_publication.distribution_members m JOIN asm_publication.distribution_batches b ON b.snapshot_id=m.snapshot_id
        WHERE m.release_id=p_task AND b.id=c.active_batch AND b.phase IN ('prepared','sealed')) THEN 'distributing' ELSE base.value->>'state' END,
    'release',CASE WHEN p.release_id IS NULL THEN NULL ELSE jsonb_build_object('manifest_url',c.origin||'/targets/'||
        regexp_replace(p.target,'[^/]+$',p.sha256||'.'||substring(p.target FROM '[^/]+$')),
        'metadata_url',c.origin||'/metadata/timestamp.json') END)
FROM (SELECT asm_publication.task_body_before_distribution(p_task) value) base
CROSS JOIN asm_publication.distribution_control c LEFT JOIN asm_publication.published_releases p ON p.release_id=p_task
WHERE c.singleton AND base.value IS NOT NULL
$$;

CREATE OR REPLACE FUNCTION asm_publication.claim_event(p_worker text,p_seconds integer) RETURNS text
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
        'manifest_sha256',i.manifest_sha256,'manifest',i.manifest)||CASE WHEN o.schema=2 THEN jsonb_build_object('package_id',i.package_id,
            'package_revision',o.package_revision::text,'publication_revision',o.publication_revision::text,'policy_revision',o.policy_revision::text,
            'distribution_version',o.distribution_version::text) ELSE '{}'::jsonb END)||chr(10)
        FROM asm_publication.outbox o JOIN asm_publication.intents i USING(task_id) WHERE o.id=e.event_id);
END $$;

CREATE FUNCTION asm_publication.distribution_ready(p_expected text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$
BEGIN RETURN (SELECT CASE WHEN asm_publication.caller('asm_distributor')
    AND current_setting('log_parameter_max_length')='0' AND current_setting('log_parameter_max_length_on_error')='0'
    AND (SELECT count(*)=1 AND bool_and(version=2 AND sha384=p_expected) FROM asm_publication.distribution_schema_version)
    AND (SELECT pg_get_userbyid(nspowner)='asm_migrator' FROM pg_namespace WHERE nspname='asm_publication')
    AND current_setting('transaction_read_only')='off' AND current_setting('transaction_isolation')='read committed'
    AND NOT EXISTS(SELECT 1 FROM pg_class x JOIN pg_namespace n ON n.oid=x.relnamespace WHERE n.nspname='asm_publication'
        AND (pg_get_userbyid(x.relowner)<>'asm_migrator' OR CASE WHEN x.relkind IN ('r','p','v','m','f')
            THEN has_table_privilege(session_user,x.oid,'SELECT') WHEN x.relkind='S' THEN has_sequence_privilege(session_user,x.oid,'SELECT') ELSE false END))
    AND NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='asm_publication' AND pg_get_userbyid(p.proowner)<>'asm_migrator')
    AND NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND p.prosecdef AND has_function_privilege(session_user,p.oid,'EXECUTE')
        AND p.oid NOT IN ('asm_publication.distribution_ready(text)'::regprocedure,'asm_publication.claim_distribution(text,integer,boolean)'::regprocedure,
            'asm_publication.distribution_release(text,text)'::regprocedure,'asm_publication.seal_distribution(text,text,bigint,text,text)'::regprocedure,
            'asm_publication.renew_distribution(text,text,bigint,text,integer)'::regprocedure,'asm_publication.authorize_distribution_head(text,text,bigint,text)'::regprocedure,
            'asm_publication.abandon_distribution(text,text,bigint,text,text)'::regprocedure,
            'asm_publication.finish_distribution(text,text,bigint,text)'::regprocedure))
    AND NOT has_database_privilege(session_user,current_database(),'CREATE')
    AND NOT EXISTS(SELECT 1 FROM pg_namespace n WHERE left(n.nspname,8)<>'pg_temp_' AND left(n.nspname,14)<>'pg_toast_temp_'
        AND has_schema_privilege(session_user,n.oid,'CREATE'))
    AND NOT EXISTS(SELECT 1 FROM pg_class x JOIN pg_namespace n ON n.oid=x.relnamespace
        WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND left(n.nspname,8)<>'pg_temp_' AND left(n.nspname,14)<>'pg_toast_temp_'
        AND CASE WHEN x.relkind IN ('r','p','v','m','f') THEN has_table_privilege(session_user,x.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
            OR has_any_column_privilege(session_user,x.oid,'INSERT,UPDATE,REFERENCES')
            WHEN x.relkind='S' THEN has_sequence_privilege(session_user,x.oid,'USAGE,UPDATE') ELSE false END)
    THEN '1' ELSE '0' END); END
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA asm_publication FROM asm_distributor;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA asm_publication FROM asm_distributor;
REVOKE ALL ON FUNCTION asm_publication.preserve_distribution_batch(),asm_publication.preserve_package_identity(),
    asm_publication.intent_distribution_revision(),asm_publication.outbox_distribution_revision(),
    asm_publication.configure_distribution(text,text,text),asm_publication.distribution_envelope(text,asm_publication.intents),
    asm_publication.distribution_source(text,bigint,text),asm_publication.distribution_batch_body(text),asm_publication.claim_distribution(text,integer,boolean),
    asm_publication.distribution_lease(text,text,bigint,text),asm_publication.distribution_release(text,text),
    asm_publication.distribution_descriptor(text,text,text),asm_publication.seal_distribution(text,text,bigint,text,text),
    asm_publication.renew_distribution(text,text,bigint,text,integer),asm_publication.authorize_distribution_head(text,text,bigint,text),
    asm_publication.abandon_distribution(text,text,bigint,text,text),
    asm_publication.finish_distribution(text,text,bigint,text),asm_publication.set_lifecycle(text,text,text,bigint,text),
    asm_publication.task_body(text),asm_publication.distribution_ready(text) FROM PUBLIC,asm_reader,asm_operator,asm_publisher,asm_publication_worker,asm_distributor;
GRANT USAGE ON SCHEMA asm_publication TO asm_distributor;
GRANT EXECUTE ON FUNCTION asm_publication.configure_distribution(text,text,text),asm_publication.set_lifecycle(text,text,text,bigint,text) TO asm_operator;
GRANT EXECUTE ON FUNCTION asm_publication.claim_distribution(text,integer,boolean),asm_publication.distribution_release(text,text),
    asm_publication.seal_distribution(text,text,bigint,text,text),asm_publication.renew_distribution(text,text,bigint,text,integer),
    asm_publication.authorize_distribution_head(text,text,bigint,text),asm_publication.finish_distribution(text,text,bigint,text),
    asm_publication.abandon_distribution(text,text,bigint,text,text),
    asm_publication.distribution_ready(text) TO asm_distributor;
