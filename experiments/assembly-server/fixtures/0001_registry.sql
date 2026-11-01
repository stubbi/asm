CREATE SCHEMA asm;
REVOKE ALL ON SCHEMA asm FROM PUBLIC;

CREATE TABLE asm.accounts (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    github_id bigint NOT NULL UNIQUE CHECK (github_id > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE asm.namespaces (
    name text COLLATE "C" PRIMARY KEY,
    owner_id bigint NOT NULL REFERENCES asm.accounts(id),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (name ~ '^[a-z][a-z0-9-]{0,38}$' AND right(name, 1) <> '-' AND strpos(name, '--') = 0)
);

CREATE TABLE asm.packages (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    namespace text COLLATE "C" NOT NULL REFERENCES asm.namespaces(name),
    name text COLLATE "C" NOT NULL,
    full_name text COLLATE "C" GENERATED ALWAYS AS (namespace || '/' || name) STORED UNIQUE,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (namespace, name),
    CHECK (name ~ '^[a-z][a-z0-9-]{0,63}$' AND right(name, 1) <> '-' AND strpos(name, '--') = 0)
);

CREATE TABLE asm.releases (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    package_id bigint NOT NULL REFERENCES asm.packages(id),
    major integer NOT NULL CHECK (major >= 0),
    minor integer NOT NULL CHECK (minor >= 0),
    patch integer NOT NULL CHECK (patch >= 0),
    version text GENERATED ALWAYS AS (major::text || '.' || minor::text || '.' || patch::text) STORED,
    summary text NOT NULL CHECK (summary COLLATE "C" ~ '^[ -~]{1,160}$' AND summary = btrim(summary)),
    license text NOT NULL CHECK (license IN (
        'AGPL-3.0-only', 'AGPL-3.0-or-later', 'Apache-2.0', 'BSD-2-Clause', 'BSD-3-Clause',
        'BSL-1.0', 'GPL-2.0-only', 'GPL-2.0-or-later', 'GPL-3.0-only', 'GPL-3.0-or-later',
        'ISC', 'LGPL-2.1-only', 'LGPL-2.1-or-later', 'LGPL-3.0-only', 'LGPL-3.0-or-later',
        'MIT', 'MPL-2.0', 'Unlicense', 'Zlib'
    )),
    source_repository text NOT NULL CHECK (octet_length(source_repository) <= 160),
    source_commit text NOT NULL CHECK (source_commit ~ '^[0-9a-f]{40}$' AND source_commit <> repeat('0', 40)),
    source_path text NOT NULL CHECK (octet_length(source_path) BETWEEN 1 AND 240),
    record_digest text NOT NULL CHECK (record_digest ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (package_id, major, minor, patch)
);

CREATE TABLE asm.artifacts (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    release_id bigint NOT NULL REFERENCES asm.releases(id),
    ordinal smallint NOT NULL CHECK (ordinal BETWEEN 0 AND 5),
    target text COLLATE "C" NOT NULL CHECK (target IN ('x86_64-linux', 'aarch64-linux', 'riscv64-linux')),
    kind text COLLATE "C" NOT NULL CHECK (kind IN ('source', 'executable')),
    sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    url text NOT NULL UNIQUE CHECK (octet_length(url) BETWEEN 1 AND 768 AND url LIKE 'https://github.com/%/releases/download/%'),
    bytes bigint NOT NULL CHECK (bytes BETWEEN 1 AND 67108864),
    UNIQUE (release_id, ordinal),
    UNIQUE (release_id, target, kind)
);

-- An import records an accepted registry revision. It is not an artifact check.
CREATE TABLE asm.publication_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    release_id bigint NOT NULL UNIQUE REFERENCES asm.releases(id),
    kind text NOT NULL CHECK (kind = 'operator_import'),
    acceptance_repository text NOT NULL CHECK (octet_length(acceptance_repository) <= 160),
    acceptance_commit text NOT NULL CHECK (acceptance_commit ~ '^[0-9a-f]{40}$' AND acceptance_commit <> repeat('0', 40)),
    yanked boolean NOT NULL,
    yank_reason text,
    actor text NOT NULL DEFAULT session_user,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK ((yanked AND yank_reason IS NOT NULL AND yank_reason COLLATE "C" ~ '^[ -~]{1,160}$' AND yank_reason = btrim(yank_reason))
           OR (NOT yanked AND yank_reason IS NULL))
);

CREATE TABLE asm.audit_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    action text NOT NULL CHECK (action IN ('namespace_bound', 'release_imported', 'download_observed')),
    subject text NOT NULL CHECK (octet_length(subject) BETWEEN 1 AND 256),
    detail jsonb NOT NULL CHECK (jsonb_typeof(detail) = 'object' AND octet_length(detail::text) <= 4096),
    actor text NOT NULL DEFAULT session_user,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE asm.download_observations (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    artifact_id bigint NOT NULL REFERENCES asm.artifacts(id),
    source text NOT NULL CHECK (source = 'github-release-assets'),
    observed_at timestamptz NOT NULL,
    count bigint CHECK (count BETWEEN 0 AND 9007199254740991),
    actor text NOT NULL DEFAULT session_user,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (artifact_id, source, observed_at)
);

CREATE INDEX releases_order ON asm.releases (package_id, major DESC, minor DESC, patch DESC);
CREATE INDEX artifacts_selection ON asm.artifacts (release_id, target, kind);
CREATE INDEX download_observations_latest ON asm.download_observations (artifact_id, observed_at DESC, id DESC);

CREATE FUNCTION asm.reject_change() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog AS $$
BEGIN
    RAISE EXCEPTION 'Retained registry records are append-only' USING ERRCODE = '55000';
END;
$$;

CREATE FUNCTION asm.stamp_event() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog AS $$
BEGIN
    NEW.actor := session_user;
    NEW.recorded_at := clock_timestamp();
    RETURN NEW;
END;
$$;

-- Both insert paths lock the parent before checking its publication seal.
-- READ COMMITTED gives the post-lock check a fresh view of a waiting publisher.
-- The fixed, schema-qualified functions need no input-dependent SQL.
CREATE FUNCTION asm.guard_artifact_insert() RETURNS trigger LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Registry publication requires READ COMMITTED isolation' USING ERRCODE = '55000';
    END IF;
    PERFORM id FROM asm.releases WHERE id = NEW.release_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'The parent release does not exist' USING ERRCODE = '23503';
    END IF;
    IF EXISTS (SELECT 1 FROM asm.publication_events WHERE release_id = NEW.release_id) THEN
        RAISE EXCEPTION 'Published artifact sets are sealed' USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION asm.seal_release() RETURNS trigger LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE artifact_count integer; first_ordinal integer; last_ordinal integer;
BEGIN
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Registry publication requires READ COMMITTED isolation' USING ERRCODE = '55000';
    END IF;
    PERFORM id FROM asm.releases WHERE id = NEW.release_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'The parent release does not exist' USING ERRCODE = '23503';
    END IF;
    SELECT count(*), min(ordinal), max(ordinal) INTO artifact_count, first_ordinal, last_ordinal
        FROM asm.artifacts WHERE release_id = NEW.release_id;
    IF artifact_count NOT BETWEEN 1 AND 6 OR first_ordinal <> 0 OR last_ordinal <> artifact_count - 1 THEN
        RAISE EXCEPTION 'A release needs one to six contiguous artifact entries' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER guard_artifact BEFORE INSERT ON asm.artifacts FOR EACH ROW EXECUTE FUNCTION asm.guard_artifact_insert();
CREATE TRIGGER seal_publication BEFORE INSERT ON asm.publication_events FOR EACH ROW EXECUTE FUNCTION asm.seal_release();

CREATE TRIGGER stamp_publication BEFORE INSERT ON asm.publication_events FOR EACH ROW EXECUTE FUNCTION asm.stamp_event();
CREATE TRIGGER stamp_audit BEFORE INSERT ON asm.audit_events FOR EACH ROW EXECUTE FUNCTION asm.stamp_event();
CREATE TRIGGER stamp_observation BEFORE INSERT ON asm.download_observations FOR EACH ROW EXECUTE FUNCTION asm.stamp_event();

DO $$
DECLARE table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY['accounts', 'namespaces', 'packages', 'releases', 'artifacts', 'publication_events', 'audit_events', 'download_observations']
    LOOP
        EXECUTE format('CREATE TRIGGER immutable_row BEFORE UPDATE OR DELETE ON asm.%I FOR EACH ROW EXECUTE FUNCTION asm.reject_change()', table_name);
        EXECUTE format('CREATE TRIGGER immutable_table BEFORE TRUNCATE ON asm.%I FOR EACH STATEMENT EXECUTE FUNCTION asm.reject_change()', table_name);
    END LOOP;
END;
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA asm FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA asm FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA asm FROM PUBLIC;
