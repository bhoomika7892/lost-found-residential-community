
-- =====================================================================
-- Lost & Found System for a Residential Community
-- File: db/advanced_claims.sql
-- Owner: Bhoomika - Claims, Verification and Handover
-- Database: PostgreSQL 16
--
-- Requires:
--   1. db/schema_reporting.sql
--   2. db/schema_claims.sql
--   3. db/claims_security.sql
--   4. db/triggers.sql
--
-- IMPORTANT:
--   Workflow functions use signed authentication assertions.
--   Staff identity is obtained from claims_private.begin_action().
--   Report status changes and audit entries are handled by triggers.
--   Physical handover is separate from claim approval.
-- =====================================================================


-- =====================================================================
-- 1. APPROVE CLAIM
-- =====================================================================

CREATE OR REPLACE FUNCTION public.approve_claim(
    p_claim_id INT,
    p_assertion TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, claims_private, pg_temp
AS $$
DECLARE
    v_claim public.claim%ROWTYPE;
    v_actor_id INT;
    v_lost_status VARCHAR(10);
    v_found_status VARCHAR(10);
BEGIN
    -- Authenticate the staff member and begin the authorized action.
    v_actor_id := claims_private.begin_action(
        p_assertion,
        'claim:approve'
    );

    -- Lock the claim to prevent concurrent decisions.
    SELECT *
    INTO v_claim
    FROM public.claim
    WHERE claim_id = p_claim_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Claim % does not exist', p_claim_id;
    END IF;

    IF v_claim.status <> 'pending' THEN
        RAISE EXCEPTION
            'Claim % is not pending (current status: %)',
            p_claim_id,
            v_claim.status;
    END IF;

    -- Lock reports in a consistent order.
    SELECT status
    INTO v_lost_status
    FROM public.lost_report
    WHERE lost_report_id = v_claim.lost_report_id
    FOR UPDATE;

    IF NOT FOUND OR v_lost_status NOT IN ('open', 'matched') THEN
        RAISE EXCEPTION 'Lost report is not open or matched';
    END IF;

    SELECT status
    INTO v_found_status
    FROM public.found_report
    WHERE found_report_id = v_claim.found_report_id
    FOR UPDATE;

    IF NOT FOUND OR v_found_status NOT IN ('open', 'matched') THEN
        RAISE EXCEPTION 'Found report is not open or matched';
    END IF;

    -- Approve the claim.
    -- The AFTER trigger moves both reports to claimed.
    -- The audit trigger records the actual status transition.
    UPDATE public.claim
    SET status = 'approved',
        verified_by = v_actor_id
    WHERE claim_id = p_claim_id;

    -- Finish the authorized transaction action.
    PERFORM claims_private.finish_action();

    RETURN 'Claim approved successfully. Physical handover must be recorded separately.';
END;
$$;


-- =====================================================================
-- 2. REJECT CLAIM
-- =====================================================================

CREATE OR REPLACE FUNCTION public.reject_claim(
    p_claim_id INT,
    p_notes TEXT,
    p_assertion TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, claims_private, pg_temp
AS $$
DECLARE
    v_claim public.claim%ROWTYPE;
    v_actor_id INT;
BEGIN
    -- Authenticate the staff member.
    v_actor_id := claims_private.begin_action(
        p_assertion,
        'claim:reject'
    );

    -- Rejection notes are mandatory.
    IF p_notes IS NULL OR btrim(p_notes) = '' THEN
        RAISE EXCEPTION 'Rejection notes are required';
    END IF;

    -- Lock the claim.
    SELECT *
    INTO v_claim
    FROM public.claim
    WHERE claim_id = p_claim_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Claim % does not exist', p_claim_id;
    END IF;

    IF v_claim.status <> 'pending' THEN
        RAISE EXCEPTION
            'Claim % is not pending (current status: %)',
            p_claim_id,
            v_claim.status;
    END IF;

    -- Reject the claim and store the actual staff-provided notes.
    -- Rejection does not change report statuses.
    UPDATE public.claim
    SET status = 'rejected',
        verified_by = v_actor_id,
        verification_notes = p_notes
    WHERE claim_id = p_claim_id;

    PERFORM claims_private.finish_action();

    RETURN 'Claim rejected successfully.';
END;
$$;


-- =====================================================================
-- 3. RECORD PHYSICAL HANDOVER
-- =====================================================================

CREATE OR REPLACE FUNCTION public.record_handover(
    p_claim_id INT,
    p_verification_method VARCHAR(30),
    p_remarks TEXT,
    p_handover_date TIMESTAMP,
    p_assertion TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, claims_private, pg_temp
AS $$
DECLARE
    v_claim public.claim%ROWTYPE;
    v_actor_id INT;
BEGIN
    -- Authenticate the staff member.
    v_actor_id := claims_private.begin_action(
        p_assertion,
        'handover:record'
    );

    -- Lock the claim.
    SELECT *
    INTO v_claim
    FROM public.claim
    WHERE claim_id = p_claim_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Claim % does not exist', p_claim_id;
    END IF;

    IF v_claim.status <> 'approved' THEN
        RAISE EXCEPTION
            'Handover requires an approved claim';
    END IF;

    IF p_handover_date IS NULL THEN
        RAISE EXCEPTION 'Handover date is required';
    END IF;

    IF p_handover_date < v_claim.claim_date THEN
        RAISE EXCEPTION
            'Handover date cannot be earlier than claim date';
    END IF;

    -- Insert the handover.
    -- BEFORE trigger validates the staff identity, claim and reports.
    -- AFTER trigger closes both reports.
    -- Audit triggers record both report status transitions.
    INSERT INTO public.handover (
        claim_id,
        staff_id,
        handover_date,
        verification_method,
        remarks
    )
    VALUES (
        p_claim_id,
        v_actor_id,
        p_handover_date,
        p_verification_method,
        p_remarks
    );

    PERFORM claims_private.finish_action();

    RETURN 'Handover recorded successfully. Both reports have been closed.';
END;
$$;


-- =====================================================================
-- 4. ADMIN VIEW: PENDING CLAIMS
-- =====================================================================

CREATE OR REPLACE VIEW public.v_pending_claims AS
SELECT
    c.claim_id,
    c.claim_date,
    c.status,
    r.resident_id,
    r.name AS claimant_name,
    li.item_name AS lost_item_name,
    li.description AS lost_item_description,
    fi.item_name AS found_item_name,
    fi.description AS found_item_description,
    c.verification_notes
FROM public.claim c
JOIN public.resident r
    ON r.resident_id = c.claimant_id
JOIN public.lost_report lr
    ON lr.lost_report_id = c.lost_report_id
JOIN public.item li
    ON li.item_id = lr.item_id
JOIN public.found_report fr
    ON fr.found_report_id = c.found_report_id
JOIN public.item fi
    ON fi.item_id = fr.item_id
WHERE c.status = 'pending';


-- =====================================================================
-- 5. PERFORMANCE INDEXES
-- =====================================================================

CREATE INDEX IF NOT EXISTS idx_claim_verified_by
    ON public.claim(verified_by);

CREATE INDEX IF NOT EXISTS idx_handover_staff
    ON public.handover(staff_id);


-- =====================================================================
-- 6. FUNCTION OWNERSHIP
-- =====================================================================

ALTER FUNCTION public.approve_claim(INT, TEXT)
    OWNER TO claims_workflow_owner;

ALTER FUNCTION public.reject_claim(INT, TEXT, TEXT)
    OWNER TO claims_workflow_owner;

ALTER FUNCTION public.record_handover(
    INT, VARCHAR, TEXT, TIMESTAMP, TEXT
)
    OWNER TO claims_workflow_owner;

ALTER VIEW public.v_pending_claims
    OWNER TO claims_workflow_owner;


-- =====================================================================
-- 7. WORKFLOW OWNER TABLE PRIVILEGES
-- =====================================================================

GRANT USAGE ON SCHEMA public
    TO claims_workflow_owner;

GRANT SELECT ON
    public.claim,
    public.lost_report,
    public.found_report
TO claims_workflow_owner;

GRANT UPDATE (
    status,
    verified_by,
    verification_notes,
    updated_at
)
ON public.claim
TO claims_workflow_owner;

GRANT UPDATE (status)
ON public.lost_report, public.found_report
TO claims_workflow_owner;

GRANT INSERT ON public.handover
    TO claims_workflow_owner;

GRANT USAGE, SELECT
ON SEQUENCE public.handover_handover_id_seq
TO claims_workflow_owner;

GRANT INSERT ON public.audit_log
    TO claims_workflow_owner;


-- =====================================================================
-- 8. APPLICATION EXECUTION PRIVILEGES
-- =====================================================================

REVOKE ALL ON FUNCTION public.approve_claim(INT, TEXT)
    FROM PUBLIC;

REVOKE ALL ON FUNCTION public.reject_claim(INT, TEXT, TEXT)
    FROM PUBLIC;

REVOKE ALL ON FUNCTION public.record_handover(
    INT, VARCHAR, TEXT, TIMESTAMP, TEXT
)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.approve_claim(INT, TEXT)
    TO claims_app;

GRANT EXECUTE ON FUNCTION public.reject_claim(INT, TEXT, TEXT)
    TO claims_app;

GRANT EXECUTE ON FUNCTION public.record_handover(
    INT, VARCHAR, TEXT, TIMESTAMP, TEXT
)
TO claims_app;

GRANT SELECT ON public.v_pending_claims
    TO claims_app;


-- =====================================================================
-- END OF ADVANCED CLAIMS SQL
-- =====================================================================
