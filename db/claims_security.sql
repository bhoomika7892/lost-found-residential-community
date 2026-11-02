-- =====================================================================
-- Claims Workflow: Private Authentication and Authorization
-- PostgreSQL 16 + pgcrypto
--
-- This script creates the private authentication objects used by the
-- claims workflow.
--
-- IMPORTANT:
-- 1. Run only after reviewing the complete claims schema.
-- 2. This script does not create signing keys or identity mappings.
-- 3. The application must obtain signed assertions from its trusted
--    authentication service.
-- 4. reserve_assertion must be called as a standalone CALL on a
--    separate connection with autocommit enabled.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Check required extension
-- ---------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_available_extensions
        WHERE name = 'pgcrypto'
    ) THEN
        RAISE EXCEPTION
            'pgcrypto is not available on this PostgreSQL server';
    END IF;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


-- ---------------------------------------------------------------------
-- 2. Create dedicated database roles
-- ---------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = 'claims_security_owner'
    ) THEN
        CREATE ROLE claims_security_owner NOLOGIN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = 'claims_workflow_owner'
    ) THEN
        CREATE ROLE claims_workflow_owner NOLOGIN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = 'claims_app'
    ) THEN
        CREATE ROLE claims_app NOLOGIN;
    END IF;
END;
$$;


-- ---------------------------------------------------------------------
-- 3. Create private schema
-- ---------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS claims_private
    AUTHORIZATION claims_security_owner;

ALTER SCHEMA claims_private
    OWNER TO claims_security_owner;

REVOKE ALL ON SCHEMA claims_private FROM PUBLIC;

GRANT USAGE ON SCHEMA claims_private
    TO claims_security_owner, claims_workflow_owner, claims_app;


-- ---------------------------------------------------------------------
-- 4. Private identity mapping
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS claims_private.account_staff_map (
    issuer       TEXT NOT NULL
        CHECK (btrim(issuer) <> ''),

    subject      TEXT NOT NULL
        CHECK (btrim(subject) <> ''),

    staff_id     INT NOT NULL
        REFERENCES public.staff(staff_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,

    created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (issuer, subject),

    UNIQUE (staff_id)
);


-- ---------------------------------------------------------------------
-- 5. Private HMAC signing keys
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS claims_private.assertion_keys (
    kid          TEXT PRIMARY KEY
        CHECK (kid ~ '^[A-Za-z0-9._-]{1,64}$'),

    hmac_key     BYTEA NOT NULL
        CHECK (octet_length(hmac_key) = 32),

    enabled      BOOLEAN NOT NULL DEFAULT TRUE,

    created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- ---------------------------------------------------------------------
-- 6. Track reserved and consumed assertions
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS claims_private.consumed_assertions (
    kid          TEXT NOT NULL
        REFERENCES claims_private.assertion_keys(kid),

    jti          TEXT NOT NULL
        CHECK (jti ~ '^[A-Za-z0-9_-]{22,128}$'),

    expires_at   TIMESTAMPTZ NOT NULL,

    reserved_backend_pid INT NOT NULL,

    reserved_txid XID8 NOT NULL,

    action_started BOOLEAN NOT NULL DEFAULT FALSE,

    consumed_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (kid, jti)
);


-- ---------------------------------------------------------------------
-- 7. Transaction-bound authorization context
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS claims_private.tx_context (
    backend_pid INT NOT NULL,

    txid        XID8 NOT NULL,

    actor_staff_id INT NOT NULL
        REFERENCES public.staff(staff_id)
        ON DELETE RESTRICT,

    action_scope TEXT NOT NULL
        CHECK (
            action_scope IN (
                'claim:approve',
                'claim:reject',
                'handover:record'
            )
        ),

    kid         TEXT NOT NULL,

    jti         TEXT NOT NULL,

    is_finished BOOLEAN NOT NULL DEFAULT FALSE,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (backend_pid, txid)
);


-- ---------------------------------------------------------------------
-- 8. Set private table ownership
-- ---------------------------------------------------------------------

ALTER TABLE claims_private.account_staff_map
    OWNER TO claims_security_owner;

ALTER TABLE claims_private.assertion_keys
    OWNER TO claims_security_owner;

ALTER TABLE claims_private.consumed_assertions
    OWNER TO claims_security_owner;

ALTER TABLE claims_private.tx_context
    OWNER TO claims_security_owner;


-- ---------------------------------------------------------------------
-- 9. Restrict direct access to private data
-- ---------------------------------------------------------------------

REVOKE ALL ON ALL TABLES IN SCHEMA claims_private
    FROM PUBLIC, claims_app, claims_workflow_owner;

GRANT USAGE ON SCHEMA public TO claims_security_owner;

GRANT SELECT ON public.staff
    TO claims_security_owner;

-- pgcrypto HMAC function access
GRANT EXECUTE ON FUNCTION public.hmac(BYTEA, BYTEA, TEXT)
    TO claims_security_owner;


-- ---------------------------------------------------------------------
-- 10. Base64 URL decoder
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claims_private.decode_base64url(
    p_value TEXT
)
RETURNS BYTEA
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = pg_catalog
AS $$
DECLARE
    v_padded TEXT;
BEGIN
    IF p_value = ''
       OR p_value !~ '^[A-Za-z0-9_-]+$' THEN
        RAISE EXCEPTION 'Invalid base64url value';
    END IF;

    IF length(p_value) % 4 = 1 THEN
        RAISE EXCEPTION 'Invalid base64url length';
    END IF;

    v_padded := translate(p_value, '-_', '+/');

    v_padded := v_padded ||
        repeat('=', (4 - length(v_padded) % 4) % 4);

    RETURN decode(v_padded, 'base64');
END;
$$;
-- ---------------------------------------------------------------------
-- 11. Verify signed authentication assertion
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claims_private.verify_assertion(
    p_assertion TEXT,
    p_expected_scope TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, claims_private, pg_temp
AS $$
DECLARE
    v_parts TEXT[];
    v_header JSONB;
    v_claims JSONB;
    v_key BYTEA;
    v_signature BYTEA;
    v_expected_signature BYTEA;
    v_iat BIGINT;
    v_exp BIGINT;
    v_now BIGINT :=
        floor(extract(epoch FROM clock_timestamp()))::BIGINT;
BEGIN
    -- Validate the expected operation scope

    IF p_expected_scope IS NULL
       OR p_expected_scope NOT IN (
           'claim:approve',
           'claim:reject',
           'handover:record'
       ) THEN
        RAISE EXCEPTION 'Unsupported assertion scope';
    END IF;

    -- Validate assertion input

    IF p_assertion IS NULL
       OR length(p_assertion) = 0
       OR length(p_assertion) > 8192 THEN
        RAISE EXCEPTION 'Invalid assertion';
    END IF;

    v_parts := string_to_array(p_assertion, '.');

    IF cardinality(v_parts) <> 3 THEN
        RAISE EXCEPTION 'Invalid assertion format';
    END IF;

    -- Decode header and payload

    v_header :=
        convert_from(
            claims_private.decode_base64url(v_parts[1]),
            'UTF8'
        )::JSONB;

    v_claims :=
        convert_from(
            claims_private.decode_base64url(v_parts[2]),
            'UTF8'
        )::JSONB;

    -- Both header and claims must be JSON objects

    IF jsonb_typeof(v_header) IS DISTINCT FROM 'object'
       OR jsonb_typeof(v_claims) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'Invalid assertion JSON structure';
    END IF;

    -- Validate JWT header fields and their types

    IF jsonb_typeof(v_header->'typ') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_header->'alg') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_header->'kid') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'Invalid assertion header fields';
    END IF;

    IF v_header->>'typ' IS DISTINCT FROM 'JWT'
       OR v_header->>'alg' IS DISTINCT FROM 'HS256'
       OR v_header->>'kid' !~ '^[A-Za-z0-9._-]{1,64}$' THEN
        RAISE EXCEPTION 'Unsupported assertion header';
    END IF;

    -- Validate required claim types.
    -- IS DISTINCT FROM also rejects missing JSON fields.

    IF jsonb_typeof(v_claims->'iss') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_claims->'aud') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_claims->'sub') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_claims->'jti') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_claims->'scope') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_claims->'iat') IS DISTINCT FROM 'number'
       OR jsonb_typeof(v_claims->'exp') IS DISTINCT FROM 'number' THEN
        RAISE EXCEPTION 'Invalid assertion claims';
    END IF;

    -- Validate identity, audience, scope and unique token ID

    IF btrim(v_claims->>'iss') = ''
       OR btrim(v_claims->>'sub') = ''
       OR v_claims->>'aud' IS DISTINCT FROM 'lost-found-claims-db'
       OR v_claims->>'scope' IS DISTINCT FROM p_expected_scope
       OR v_claims->>'jti' !~ '^[A-Za-z0-9_-]{22,128}$' THEN
        RAISE EXCEPTION
            'Invalid assertion identity, audience, scope, or JTI';
    END IF;

    -- Validate timestamp format

    IF (v_claims->>'iat') !~ '^[0-9]{1,12}$'
       OR (v_claims->>'exp') !~ '^[0-9]{1,12}$' THEN
        RAISE EXCEPTION 'Invalid assertion timestamps';
    END IF;

    v_iat := (v_claims->>'iat')::BIGINT;
    v_exp := (v_claims->>'exp')::BIGINT;

    -- Assertions are valid for at most 60 seconds

    IF v_iat > v_now + 5
       OR v_exp <= v_now
       OR v_exp <= v_iat
       OR v_exp - v_iat > 60 THEN
        RAISE EXCEPTION
            'Assertion is expired or outside its allowed lifetime';
    END IF;

    -- Retrieve enabled signing key

    SELECT hmac_key
    INTO v_key
    FROM claims_private.assertion_keys
    WHERE kid = v_header->>'kid'
      AND enabled = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown or disabled assertion key';
    END IF;

    -- Decode supplied signature

    v_signature :=
        claims_private.decode_base64url(v_parts[3]);

    IF octet_length(v_signature) <> 32 THEN
        RAISE EXCEPTION 'Invalid assertion signature length';
    END IF;

    -- Calculate expected HS256 signature using pgcrypto

    v_expected_signature :=
        public.hmac(
            convert_to(
                v_parts[1] || '.' || v_parts[2],
                'UTF8'
            ),
            v_key,
            'sha256'
        );

    IF v_expected_signature IS DISTINCT FROM v_signature THEN
        RAISE EXCEPTION 'Invalid assertion signature';
    END IF;

    RETURN v_claims;
END;
$$;


-- ---------------------------------------------------------------------
-- 12. Reserve an assertion for a specific business transaction
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claims_private.reserve_assertion_impl(
    p_assertion TEXT,
    p_backend_pid INT,
    p_txid XID8
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, claims_private, pg_temp
AS $$
DECLARE
    v_claims JSONB;
    v_header JSONB;
BEGIN
    IF p_assertion IS NULL
       OR length(p_assertion) > 8192 THEN
        RAISE EXCEPTION 'Invalid assertion';
    END IF;

    v_header :=
        convert_from(
            claims_private.decode_base64url(
                split_part(p_assertion, '.', 1)
            ),
            'UTF8'
        )::JSONB;

    v_claims := claims_private.verify_assertion(
        p_assertion,
        (
            convert_from(
                claims_private.decode_base64url(
                    split_part(p_assertion, '.', 2)
                ),
                'UTF8'
            )::JSONB
        )->>'scope'
    );

    IF p_backend_pid <= 0 OR p_txid IS NULL THEN
        RAISE EXCEPTION
            'A live business backend and transaction are required';
    END IF;

    INSERT INTO claims_private.consumed_assertions (
        kid,
        jti,
        expires_at,
        reserved_backend_pid,
        reserved_txid
    )
    VALUES (
        v_header->>'kid',
        v_claims->>'jti',
        to_timestamp((v_claims->>'exp')::BIGINT),
        p_backend_pid,
        p_txid
    );
END;
$$;


-- ---------------------------------------------------------------------
-- 13. Secure top-level reservation procedure
--
-- IMPORTANT:
-- This procedure intentionally has no COMMIT statement.
--
-- Call it as a standalone CALL on a separate connection with
-- autocommit enabled. PostgreSQL commits the CALL statement when it
-- completes successfully.
-- ---------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE claims_private.reserve_assertion(
    p_assertion TEXT,
    p_backend_pid INT,
    p_txid XID8
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, claims_private, pg_temp
AS $$
BEGIN
    PERFORM claims_private.reserve_assertion_impl(
        p_assertion,
        p_backend_pid,
        p_txid
    );
END;
$$;


-- ---------------------------------------------------------------------
-- 14. Begin an authorized workflow action
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claims_private.begin_action(
    p_assertion TEXT,
    p_expected_scope TEXT
)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, claims_private, pg_temp
AS $$
DECLARE
    v_claims JSONB;
    v_header JSONB;
    v_kid TEXT;
    v_staff_id INT;
    v_pid INT := pg_backend_pid();
    v_txid XID8 := pg_current_xact_id();
BEGIN
    v_claims := claims_private.verify_assertion(
        p_assertion,
        p_expected_scope
    );

    v_header :=
        convert_from(
            claims_private.decode_base64url(
                split_part(p_assertion, '.', 1)
            ),
            'UTF8'
        )::JSONB;

    v_kid := v_header->>'kid';

    -- The assertion must be reserved for this exact transaction

    IF NOT EXISTS (
        SELECT 1
        FROM claims_private.consumed_assertions
        WHERE kid = v_kid
          AND jti = v_claims->>'jti'
          AND expires_at > clock_timestamp()
          AND reserved_backend_pid = v_pid
          AND reserved_txid = v_txid
          AND NOT action_started
    ) THEN
        RAISE EXCEPTION
            'Assertion JTI is not reserved for this transaction';
    END IF;

    -- Prevent a second use of the same assertion

    UPDATE claims_private.consumed_assertions
    SET action_started = TRUE
    WHERE kid = v_kid
      AND jti = v_claims->>'jti'
      AND reserved_backend_pid = v_pid
      AND reserved_txid = v_txid
      AND NOT action_started;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Assertion has already been used';
    END IF;

    -- Map external authenticated identity to an active staff account

    SELECT s.staff_id
    INTO v_staff_id
    FROM claims_private.account_staff_map m
    JOIN public.staff s
      ON s.staff_id = m.staff_id
    WHERE m.issuer = v_claims->>'iss'
      AND m.subject = v_claims->>'sub'
      AND s.active = TRUE
      AND s.role IN ('staff', 'admin');

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Authenticated account is not an active staff account';
    END IF;

    -- Remove stale transaction contexts for this backend

    DELETE FROM claims_private.tx_context
    WHERE backend_pid = v_pid
      AND txid <> v_txid;

    -- Create context for the current transaction

    INSERT INTO claims_private.tx_context (
        backend_pid,
        txid,
        actor_staff_id,
        action_scope,
        kid,
        jti,
        is_finished
    )
    VALUES (
        v_pid,
        v_txid,
        v_staff_id,
        p_expected_scope,
        v_kid,
        v_claims->>'jti',
        FALSE
    );

    RETURN v_staff_id;
END;
$$;
-- ---------------------------------------------------------------------
-- 15. Verify that the current transaction has valid authorization
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claims_private.require_action(
    p_expected_scope TEXT
)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, claims_private, pg_temp
AS $$
DECLARE
    v_staff_id INT;
BEGIN
    IF p_expected_scope IS NULL
       OR p_expected_scope NOT IN (
           'claim:approve',
           'claim:reject',
           'handover:record'
       ) THEN
        RAISE EXCEPTION 'Unsupported assertion scope';
    END IF;

    SELECT c.actor_staff_id
    INTO v_staff_id
    FROM claims_private.tx_context c
    JOIN public.staff s
      ON s.staff_id = c.actor_staff_id
    WHERE c.backend_pid = pg_backend_pid()
      AND c.txid = pg_current_xact_id()
      AND c.action_scope = p_expected_scope
      AND NOT c.is_finished
      AND s.active = TRUE
      AND s.role IN ('staff', 'admin');

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Valid transaction action context required';
    END IF;

    RETURN v_staff_id;
END;
$$;


-- ---------------------------------------------------------------------
-- 16. Finish the current authorized action
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claims_private.finish_action()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, claims_private, pg_temp
AS $$
BEGIN
    UPDATE claims_private.tx_context
    SET is_finished = TRUE
    WHERE backend_pid = pg_backend_pid()
      AND txid = pg_current_xact_id()
      AND NOT is_finished;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No active transaction action context to finish';
    END IF;
END;
$$;


-- ---------------------------------------------------------------------
-- 17. Set function and procedure ownership
-- ---------------------------------------------------------------------

ALTER FUNCTION claims_private.decode_base64url(TEXT)
    OWNER TO claims_security_owner;

ALTER FUNCTION claims_private.verify_assertion(TEXT, TEXT)
    OWNER TO claims_security_owner;

ALTER FUNCTION claims_private.reserve_assertion_impl(TEXT, INT, XID8)
    OWNER TO claims_security_owner;

ALTER PROCEDURE claims_private.reserve_assertion(TEXT, INT, XID8)
    OWNER TO claims_security_owner;

ALTER FUNCTION claims_private.begin_action(TEXT, TEXT)
    OWNER TO claims_security_owner;

ALTER FUNCTION claims_private.require_action(TEXT)
    OWNER TO claims_security_owner;

ALTER FUNCTION claims_private.finish_action()
    OWNER TO claims_security_owner;


-- ---------------------------------------------------------------------
-- 18. Restrict function and procedure execution
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION claims_private.decode_base64url(TEXT)
    FROM PUBLIC, claims_app, claims_workflow_owner;

REVOKE ALL ON FUNCTION claims_private.verify_assertion(TEXT, TEXT)
    FROM PUBLIC, claims_app, claims_workflow_owner;

REVOKE ALL ON FUNCTION claims_private.reserve_assertion_impl(TEXT, INT, XID8)
    FROM PUBLIC, claims_app, claims_workflow_owner;

REVOKE ALL ON PROCEDURE claims_private.reserve_assertion(TEXT, INT, XID8)
    FROM PUBLIC;

REVOKE ALL ON FUNCTION claims_private.begin_action(TEXT, TEXT)
    FROM PUBLIC, claims_app;

REVOKE ALL ON FUNCTION claims_private.require_action(TEXT)
    FROM PUBLIC, claims_app;

REVOKE ALL ON FUNCTION claims_private.finish_action()
    FROM PUBLIC, claims_app;


-- Application can reserve assertions only through the controlled procedure

GRANT EXECUTE ON PROCEDURE claims_private.reserve_assertion(
    TEXT, INT, XID8
) TO claims_app;


-- Workflow functions are available only to the workflow owner

GRANT EXECUTE ON FUNCTION
    claims_private.begin_action(TEXT, TEXT),
    claims_private.require_action(TEXT),
    claims_private.finish_action()
TO claims_workflow_owner;


-- ---------------------------------------------------------------------
-- END OF CLAIMS SECURITY SCRIPT
-- ---------------------------------------------------------------------