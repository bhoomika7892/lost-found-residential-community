
-- =====================================================================
-- Claims Workflow - Installation and Configuration Tests
-- File: db/test_claim_workflow.sql
-- PostgreSQL 16
--
-- IMPORTANT:
-- 1. Run ONLY against the disposable lostfound_claims_test database.
-- 2. This file checks installation, constraints, triggers and permissions.
-- 3. It does NOT create, approve, reject or hand over real claims.
-- 4. Full authentication/replay tests require two PostgreSQL sessions.
-- =====================================================================

\set ON_ERROR_STOP on


-- ---------------------------------------------------------------------
-- TEST 1: Required tables exist
-- ---------------------------------------------------------------------

DO $$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'staff',
        'claim',
        'handover',
        'audit_log',
        'lost_report',
        'found_report',
        'resident',
        'item'
    ]
    LOOP
        IF to_regclass('public.' || v_table) IS NULL THEN
            RAISE EXCEPTION
                'Required table public.% is missing',
                v_table;
        END IF;
    END LOOP;

    RAISE NOTICE 'PASS: Required tables exist';
END;
$$;


-- ---------------------------------------------------------------------
-- TEST 2: Required workflow functions exist
-- ---------------------------------------------------------------------

DO $$
BEGIN
    IF to_regprocedure(
        'public.approve_claim(integer,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'approve_claim(integer,text) is missing';
    END IF;

    IF to_regprocedure(
        'public.reject_claim(integer,text,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'reject_claim(integer,text,text) is missing';
    END IF;

    IF to_regprocedure(
        'public.record_handover(integer,character varying,text,text,timestamp without time zone)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'record_handover function is missing';
    END IF;

    RAISE NOTICE 'PASS: Workflow functions exist';
END;
$$;


-- ---------------------------------------------------------------------
-- TEST 3: Private authentication objects exist
-- ---------------------------------------------------------------------

DO $$
BEGIN
    IF to_regclass(
        'claims_private.account_staff_map'
    ) IS NULL
       OR to_regclass(
        'claims_private.assertion_keys'
    ) IS NULL
       OR to_regclass(
        'claims_private.consumed_assertions'
    ) IS NULL
       OR to_regclass(
        'claims_private.tx_context'
    ) IS NULL THEN

        RAISE EXCEPTION
            'One or more private authentication tables are missing';
    END IF;

    IF to_regprocedure(
        'claims_private.verify_assertion(text,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'verify_assertion(text,text) is missing';
    END IF;

    IF to_regprocedure(
        'claims_private.begin_action(text,text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'begin_action(text,text) is missing';
    END IF;

    IF to_regprocedure(
        'claims_private.require_action(text)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'require_action(text) is missing';
    END IF;

    IF to_regprocedure(
        'claims_private.finish_action()'
    ) IS NULL THEN
        RAISE EXCEPTION
            'finish_action() is missing';
    END IF;

    RAISE NOTICE
        'PASS: Private authentication objects exist';
END;
$$;


-- ---------------------------------------------------------------------
-- TEST 4: Required database roles exist
-- ---------------------------------------------------------------------

DO $$
DECLARE
    v_role TEXT;
BEGIN
    FOREACH v_role IN ARRAY ARRAY[
        'claims_security_owner',
        'claims_workflow_owner',
        'claims_app'
    ]
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_roles
            WHERE rolname = v_role
        ) THEN
            RAISE EXCEPTION
                'Required role % does not exist',
                v_role;
        END IF;
    END LOOP;

    RAISE NOTICE 'PASS: Required database roles exist';
END;
$$;


-- ---------------------------------------------------------------------
-- TEST 5: Claim constraints exist
-- ---------------------------------------------------------------------

DO $$
DECLARE
    v_claim_check TEXT;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.claim'::regclass
          AND conname = 'uq_claim_report_pair'
          AND contype = 'u'
    ) THEN
        RAISE EXCEPTION
            'Claim report-pair uniqueness constraint is missing';
    END IF;

    SELECT string_agg(
        pg_get_constraintdef(oid),
        ' '
    )
    INTO v_claim_check
    FROM pg_constraint
    WHERE conrelid = 'public.claim'::regclass
      AND contype = 'c';

    IF v_claim_check IS NULL
       OR v_claim_check NOT ILIKE '%verified_by%' THEN
        RAISE EXCEPTION
            'Claim reviewer check constraint is missing';
    END IF;

    IF v_claim_check NOT ILIKE '%verification_notes%' THEN
        RAISE EXCEPTION
            'Claim rejection-notes check constraint is missing';
    END IF;

    RAISE NOTICE 'PASS: Claim constraints exist';
END;
$$;


-- ---------------------------------------------------------------------
-- TEST 6: Handover uniqueness constraint exists
-- ---------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.handover'::regclass
          AND contype = 'u'
          AND pg_get_constraintdef(oid) ILIKE '%claim_id%'
    ) THEN
        RAISE EXCEPTION
            'One-handover-per-claim constraint is missing';
    END IF;

    RAISE NOTICE
        'PASS: Handover uniqueness constraint exists';
END;
$$;


-- ---------------------------------------------------------------------
-- TEST 7: Required triggers are attached to the correct tables
--         and are enabled
-- ---------------------------------------------------------------------

DO $$
DECLARE
    v_trigger_name TEXT;
    v_table_name TEXT;
BEGIN
    FOR v_trigger_name, v_table_name IN
        SELECT *
        FROM (VALUES
            ('trg_claim_status_audit', 'claim'),
            ('trg_lost_report_status_audit', 'lost_report'),
            ('trg_found_report_status_audit', 'found_report'),
            ('trg_claim_approval_reports', 'claim'),
            ('trg_claim_write_guard', 'claim'),
            ('trg_lost_report_status_guard', 'lost_report'),
            ('trg_found_report_status_guard', 'found_report'),
            ('trg_handover_insert_guard', 'handover'),
            ('trg_handover_immutable', 'handover'),
            ('trg_close_reports_after_handover', 'handover')
        ) AS expected(trigger_name, table_name)
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_trigger t
            WHERE t.tgname = v_trigger_name
              AND t.tgrelid = (
                  ('public.' || v_table_name)::regclass
              )
              AND NOT t.tgisinternal
              AND t.tgenabled = 'O'
        ) THEN
            RAISE EXCEPTION
                'Trigger % is missing, disabled, or attached to the wrong table',
                v_trigger_name;
        END IF;
    END LOOP;

    RAISE NOTICE
        'PASS: Required triggers are attached correctly and enabled';
END;
$$;


-- ---------------------------------------------------------------------
-- TEST 8: Application role cannot directly modify protected tables
-- Checks table-level and column-level write privileges.
-- ---------------------------------------------------------------------

DO $$
BEGIN

    -- Claim table: no direct INSERT, UPDATE or DELETE.
    IF has_table_privilege(
        'claims_app', 'public.claim', 'INSERT'
    ) OR has_table_privilege(
        'claims_app', 'public.claim', 'UPDATE'
    ) OR has_table_privilege(
        'claims_app', 'public.claim', 'DELETE'
    ) OR has_any_column_privilege(
        'claims_app', 'public.claim', 'INSERT'
    ) OR has_any_column_privilege(
        'claims_app', 'public.claim', 'UPDATE'
    ) THEN

        RAISE EXCEPTION
            'claims_app has direct claim write privileges';

    END IF;


    -- Handover table: no direct INSERT, UPDATE or DELETE.
    IF has_table_privilege(
        'claims_app', 'public.handover', 'INSERT'
    ) OR has_table_privilege(
        'claims_app', 'public.handover', 'UPDATE'
    ) OR has_table_privilege(
        'claims_app', 'public.handover', 'DELETE'
    ) OR has_any_column_privilege(
        'claims_app', 'public.handover', 'INSERT'
    ) OR has_any_column_privilege(
        'claims_app', 'public.handover', 'UPDATE'
    ) THEN

        RAISE EXCEPTION
            'claims_app has direct handover write privileges';

    END IF;


    -- Reports: no direct UPDATE privileges or status-column updates.
    IF has_table_privilege(
        'claims_app', 'public.lost_report', 'UPDATE'
    ) OR has_column_privilege(
        'claims_app', 'public.lost_report', 'status', 'UPDATE'
    ) OR has_table_privilege(
        'claims_app', 'public.found_report', 'UPDATE'
    ) OR has_column_privilege(
        'claims_app', 'public.found_report', 'status', 'UPDATE'
    ) THEN

        RAISE EXCEPTION
            'claims_app can directly modify report statuses';

    END IF;


    RAISE NOTICE
        'PASS: Application role cannot directly modify protected tables';

END;
$$;


-- ---------------------------------------------------------------------
-- TEST 9: Application role can execute workflow functions
-- ---------------------------------------------------------------------

DO $$
BEGIN
    IF NOT has_function_privilege(
        'claims_app',
        'public.approve_claim(integer,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'claims_app cannot execute approve_claim';
    END IF;

    IF NOT has_function_privilege(
        'claims_app',
        'public.reject_claim(integer,text,text)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'claims_app cannot execute reject_claim';
    END IF;

    IF NOT has_function_privilege(
        'claims_app',
        'public.record_handover(integer,character varying,text,text,timestamp without time zone)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'claims_app cannot execute record_handover';
    END IF;

    RAISE NOTICE
        'PASS: Application role can execute workflow functions';
END;
$$;


-- ---------------------------------------------------------------------
-- TEST 10: Application role can execute assertion reservation procedure
-- ---------------------------------------------------------------------

DO $$
DECLARE
    v_procedure_oid OID;
BEGIN
    SELECT p.oid
    INTO v_procedure_oid
    FROM pg_proc p
    JOIN pg_namespace n
        ON n.oid = p.pronamespace
    WHERE n.nspname = 'claims_private'
      AND p.proname = 'reserve_assertion'
      AND p.prokind = 'p'
      AND pg_get_function_identity_arguments(p.oid)
          = 'text, integer, xid8';

    IF v_procedure_oid IS NULL THEN
        RAISE EXCEPTION
            'reserve_assertion procedure is missing';
    END IF;

    IF NOT has_function_privilege(
        'claims_app',
        v_procedure_oid,
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'claims_app cannot execute reserve_assertion';
    END IF;

    RAISE NOTICE
        'PASS: Application role can reserve assertions';
END;
$$;


-- ---------------------------------------------------------------------
-- TEST 11: Report status constraints support the workflow
-- ---------------------------------------------------------------------

DO $$
DECLARE
    v_lost_check TEXT;
    v_found_check TEXT;
BEGIN
    SELECT string_agg(
        pg_get_constraintdef(oid),
        ' '
    )
    INTO v_lost_check
    FROM pg_constraint
    WHERE conrelid = 'public.lost_report'::regclass
      AND contype = 'c';

    SELECT string_agg(
        pg_get_constraintdef(oid),
        ' '
    )
    INTO v_found_check
    FROM pg_constraint
    WHERE conrelid = 'public.found_report'::regclass
      AND contype = 'c';

    IF v_lost_check IS NULL
       OR v_lost_check NOT ILIKE '%matched%'
       OR v_lost_check NOT ILIKE '%claimed%'
       OR v_lost_check NOT ILIKE '%closed%' THEN
        RAISE EXCEPTION
            'Lost report status constraint is incompatible';
    END IF;

    IF v_found_check IS NULL
       OR v_found_check NOT ILIKE '%matched%'
       OR v_found_check NOT ILIKE '%claimed%'
       OR v_found_check NOT ILIKE '%closed%' THEN
        RAISE EXCEPTION
            'Found report status constraint is incompatible';
    END IF;

    RAISE NOTICE
        'PASS: Report status constraints support the workflow';
END;
$$;


-- ---------------------------------------------------------------------
-- FINAL RESULT
-- ---------------------------------------------------------------------

SELECT
    'Claims workflow installation checks completed successfully'
    AS test_result;


-- ---------------------------------------------------------------------
-- MANUAL TESTS STILL REQUIRED
-- ---------------------------------------------------------------------
--
-- These tests require two PostgreSQL sessions.
--
-- A. Valid approval:
--    1. Open a transaction in Session A.
--    2. Obtain pg_backend_pid() and pg_current_xact_id().
--    3. Reserve a fresh assertion from Session B using CALL
--       claims_private.reserve_assertion(token, backend_pid, txid).
--    4. Call approve_claim in Session A.
--    5. Verify claim and both reports changed atomically.
--
-- B. Rejection:
--    1. Reserve a separate claim:reject assertion.
--    2. Call reject_claim with nonblank notes.
--    3. Verify both report statuses remain unchanged.
--
-- C. Handover:
--    1. Reserve a separate handover:record assertion.
--    2. Call record_handover for an approved claim.
--    3. Verify one handover exists and both reports are closed.
--
-- D. Replay protection:
--    1. Attempt to reserve the same JTI again.
--    2. Verify the second reservation fails.
--
-- E. Rollback:
--    1. Reserve an assertion and execute a valid workflow operation.
--    2. Roll back Session A.
--    3. Verify the independently committed JTI reservation remains.
--
-- These manual tests are not performed by this installation-check file.
-- =====================================================================
