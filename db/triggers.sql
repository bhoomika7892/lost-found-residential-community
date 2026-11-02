
-- =====================================================================
-- CLAIMS WORKFLOW: TRIGGER FUNCTIONS AND DECLARATIONS
-- PostgreSQL 16
--
-- Requires:
--   1. schema_reporting.sql
--   2. schema_claims.sql
--   3. claims_security.sql
--
-- Business functions and pending claims view:
--   advanced_claims.sql
--
-- IMPORTANT:
-- Run only against the disposable claims test database.
-- Do not run schema_reporting.sql against an existing database.
-- =====================================================================


-- =====================================================================
-- 1. AUDIT STATUS CHANGES
-- =====================================================================

CREATE OR REPLACE FUNCTION audit_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, claims_private, pg_temp
AS $$
DECLARE
    v_record_id INT;
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN

        CASE TG_TABLE_NAME
            WHEN 'claim' THEN
                v_record_id := NEW.claim_id;

            WHEN 'lost_report' THEN
                v_record_id := NEW.lost_report_id;

            WHEN 'found_report' THEN
                v_record_id := NEW.found_report_id;

            ELSE
                RAISE EXCEPTION
                    'Unsupported table for status audit: %',
                    TG_TABLE_NAME;
        END CASE;

        INSERT INTO public.audit_log (
            table_name,
            record_id,
            old_status,
            new_status
        )
        VALUES (
            TG_TABLE_NAME,
            v_record_id,
            OLD.status,
            NEW.status
        );

    END IF;

    RETURN NEW;
END;
$$;


-- =====================================================================
-- 2. CLAIM WRITE GUARD
-- =====================================================================

CREATE OR REPLACE FUNCTION guard_claim_write()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, claims_private, pg_temp
AS $$
DECLARE
    v_actor_id INT;
BEGIN

    -- New claims must always start as pending.
    IF TG_OP = 'INSERT' THEN

        IF NEW.status <> 'pending'
           OR NEW.verified_by IS NOT NULL THEN

            RAISE EXCEPTION
                'Claims must be created pending without a reviewer';

        END IF;

        -- Claimant must own the lost report.
        IF NOT EXISTS (
            SELECT 1
            FROM public.lost_report
            WHERE lost_report_id = NEW.lost_report_id
              AND resident_id = NEW.claimant_id
        ) THEN

            RAISE EXCEPTION
                'Claimant must own the lost report';

        END IF;

        RETURN NEW;
    END IF;


    -- Update timestamp.
    NEW.updated_at := CURRENT_TIMESTAMP;


    -- A status change must be a valid authenticated decision.
    IF OLD.status IS DISTINCT FROM NEW.status THEN

        IF OLD.status <> 'pending'
           OR NEW.status NOT IN ('approved', 'rejected') THEN

            RAISE EXCEPTION
                'Invalid claim status transition: % -> %',
                OLD.status,
                NEW.status;

        END IF;


        IF NEW.status = 'approved' THEN

            v_actor_id := claims_private.require_action(
                'claim:approve'
            );

        ELSE

            v_actor_id := claims_private.require_action(
                'claim:reject'
            );

            IF NEW.verification_notes IS NULL
               OR btrim(NEW.verification_notes) = '' THEN

                RAISE EXCEPTION
                    'Rejection notes are required';

            END IF;

        END IF;


        -- Reviewer must match the authenticated staff member.
        IF NEW.verified_by IS DISTINCT FROM v_actor_id THEN

            RAISE EXCEPTION
                'Decision reviewer does not match authenticated actor';

        END IF;


    -- Protect decision and identity fields from independent updates.
    ELSIF NEW.verified_by IS DISTINCT FROM OLD.verified_by
       OR NEW.verification_notes IS DISTINCT FROM OLD.verification_notes
       OR NEW.lost_report_id IS DISTINCT FROM OLD.lost_report_id
       OR NEW.found_report_id IS DISTINCT FROM OLD.found_report_id
       OR NEW.claimant_id IS DISTINCT FROM OLD.claimant_id
       OR NEW.claim_date IS DISTINCT FROM OLD.claim_date THEN

        RAISE EXCEPTION
            'Decision and claim identity fields can only change during a valid claim decision';

    END IF;

    RETURN NEW;
END;
$$;


-- =====================================================================
-- 3. UPDATE REPORTS AFTER CLAIM APPROVAL
-- =====================================================================

CREATE OR REPLACE FUNCTION update_reports_after_claim_approval()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, claims_private, pg_temp
AS $$
DECLARE
    v_lost_status VARCHAR(10);
    v_found_status VARCHAR(10);
BEGIN

    IF OLD.status IS DISTINCT FROM NEW.status
       AND NEW.status = 'approved' THEN

        PERFORM claims_private.require_action(
            'claim:approve'
        );


        -- Lock and check the lost report.
        SELECT status
        INTO v_lost_status
        FROM public.lost_report
        WHERE lost_report_id = NEW.lost_report_id
        FOR UPDATE;


        -- Lock and check the found report.
        SELECT status
        INTO v_found_status
        FROM public.found_report
        WHERE found_report_id = NEW.found_report_id
        FOR UPDATE;


        IF v_lost_status NOT IN ('open', 'matched') THEN

            RAISE EXCEPTION
                'Lost report % is not open or matched',
                NEW.lost_report_id;

        END IF;


        IF v_found_status NOT IN ('open', 'matched') THEN

            RAISE EXCEPTION
                'Found report % is not open or matched',
                NEW.found_report_id;

        END IF;


        -- Both reports become claimed.
        UPDATE public.lost_report
        SET status = 'claimed'
        WHERE lost_report_id = NEW.lost_report_id;


        UPDATE public.found_report
        SET status = 'claimed'
        WHERE found_report_id = NEW.found_report_id;

    END IF;

    RETURN NEW;
END;
$$;


-- =====================================================================
-- 4. REPORT STATUS GUARD
-- =====================================================================

CREATE OR REPLACE FUNCTION guard_report_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, claims_private, pg_temp
AS $$
DECLARE
    v_claim_id INT;
BEGIN

    -- No status change: allow the update.
    IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
        RETURN NEW;
    END IF;


    -- Matching may change reports only between open and matched.
    -- Matching cannot claim or close reports.
    IF OLD.status IN ('open', 'matched')
       AND NEW.status IN ('open', 'matched') THEN

        RETURN NEW;

    END IF;


    -- A report can become claimed only during claim approval.
    IF NEW.status = 'claimed'
       AND OLD.status IN ('open', 'matched') THEN

        PERFORM claims_private.require_action(
            'claim:approve'
        );


        IF TG_TABLE_NAME = 'lost_report' THEN

            SELECT claim_id
            INTO v_claim_id
            FROM public.claim
            WHERE lost_report_id = NEW.lost_report_id
              AND status = 'approved';

        ELSE

            SELECT claim_id
            INTO v_claim_id
            FROM public.claim
            WHERE found_report_id = NEW.found_report_id
              AND status = 'approved';

        END IF;


        IF v_claim_id IS NULL THEN

            RAISE EXCEPTION
                'A report can be claimed only by an approved claim';

        END IF;

        RETURN NEW;

    END IF;


    -- A report can become closed only after a recorded handover.
    IF NEW.status = 'closed'
       AND OLD.status = 'claimed' THEN

        PERFORM claims_private.require_action(
            'handover:record'
        );


        IF TG_TABLE_NAME = 'lost_report' THEN

            IF NOT EXISTS (
                SELECT 1
                FROM public.claim c
                JOIN public.handover h USING (claim_id)
                WHERE c.lost_report_id = NEW.lost_report_id
                  AND c.status = 'approved'
            ) THEN

                RAISE EXCEPTION
                    'A report can be closed only after handover';

            END IF;

        ELSE

            IF NOT EXISTS (
                SELECT 1
                FROM public.claim c
                JOIN public.handover h USING (claim_id)
                WHERE c.found_report_id = NEW.found_report_id
                  AND c.status = 'approved'
            ) THEN

                RAISE EXCEPTION
                    'A report can be closed only after handover';

            END IF;

        END IF;

        RETURN NEW;

    END IF;


    -- Reject every other status transition.
    RAISE EXCEPTION
        'Invalid report status transition: % -> %',
        OLD.status,
        NEW.status;

END;
$$;


-- =====================================================================
-- 5. HANDOVER INSERT GUARD
-- =====================================================================

CREATE OR REPLACE FUNCTION guard_handover_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, claims_private, pg_temp
AS $$
DECLARE
    v_claim public.claim%ROWTYPE;
    v_actor_id INT;
    v_lost_status VARCHAR(10);
    v_found_status VARCHAR(10);
BEGIN

    v_actor_id := claims_private.require_action(
        'handover:record'
    );


    -- Handover staff must match the authenticated actor.
    IF NEW.staff_id IS DISTINCT FROM v_actor_id THEN

        RAISE EXCEPTION
            'Handover staff does not match authenticated actor';

    END IF;


    -- Lock and retrieve the claim.
    SELECT *
    INTO v_claim
    FROM public.claim
    WHERE claim_id = NEW.claim_id
    FOR UPDATE;


    IF NOT FOUND OR v_claim.status <> 'approved' THEN

        RAISE EXCEPTION
            'Handover requires an approved claim';

    END IF;


    -- Handover date cannot precede the claim date.
    IF NEW.handover_date IS NULL
       OR NEW.handover_date < v_claim.claim_date THEN

        RAISE EXCEPTION
            'Handover date cannot be earlier than claim date';

    END IF;


    -- Lock reports in a consistent order.
    SELECT status
    INTO v_lost_status
    FROM public.lost_report
    WHERE lost_report_id = v_claim.lost_report_id
    FOR UPDATE;


    SELECT status
    INTO v_found_status
    FROM public.found_report
    WHERE found_report_id = v_claim.found_report_id
    FOR UPDATE;


    IF v_lost_status <> 'claimed'
       OR v_found_status <> 'claimed' THEN

        RAISE EXCEPTION
            'Both reports must be claimed before handover';

    END IF;

    RETURN NEW;
END;
$$;


-- =====================================================================
-- 6. PREVENT HANDOVER MODIFICATION OR DELETION
-- =====================================================================

CREATE OR REPLACE FUNCTION reject_handover_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, claims_private, pg_temp
AS $$
BEGIN

    RAISE EXCEPTION
        'Handover records are immutable';

END;
$$;


-- =====================================================================
-- 7. CLOSE REPORTS AFTER HANDOVER
-- =====================================================================

CREATE OR REPLACE FUNCTION close_reports_after_handover()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, claims_private, pg_temp
AS $$
DECLARE
    v_claim public.claim%ROWTYPE;
BEGIN

    PERFORM claims_private.require_action(
        'handover:record'
    );


    SELECT *
    INTO v_claim
    FROM public.claim
    WHERE claim_id = NEW.claim_id
    FOR UPDATE;


    IF NOT FOUND OR v_claim.status <> 'approved' THEN

        RAISE EXCEPTION
            'Handover requires an approved claim';

    END IF;


    -- Stable lock order: lost report first, then found report.
    PERFORM 1
    FROM public.lost_report
    WHERE lost_report_id = v_claim.lost_report_id
    FOR UPDATE;


    PERFORM 1
    FROM public.found_report
    WHERE found_report_id = v_claim.found_report_id
    FOR UPDATE;


    -- Close the lost report.
    UPDATE public.lost_report
    SET status = 'closed'
    WHERE lost_report_id = v_claim.lost_report_id
      AND status = 'claimed';


    IF NOT FOUND THEN

        RAISE EXCEPTION
            'Lost report is not claimed';

    END IF;


    -- Close the found report.
    UPDATE public.found_report
    SET status = 'closed'
    WHERE found_report_id = v_claim.found_report_id
      AND status = 'claimed';


    IF NOT FOUND THEN

        RAISE EXCEPTION
            'Found report is not claimed';

    END IF;

    RETURN NEW;
END;
$$;


-- =====================================================================
-- 8. REMOVE KNOWN LEGACY TRIGGERS BEFORE RECREATING THEM
-- =====================================================================

DROP TRIGGER IF EXISTS trg_claim_status_audit
ON public.claim;

DROP TRIGGER IF EXISTS trg_lost_report_status_audit
ON public.lost_report;

DROP TRIGGER IF EXISTS trg_found_report_status_audit
ON public.found_report;

DROP TRIGGER IF EXISTS trg_claim_approval_reports
ON public.claim;

DROP TRIGGER IF EXISTS trg_validate_handover_date
ON public.handover;

DROP TRIGGER IF EXISTS trg_validate_handover
ON public.handover;

DROP TRIGGER IF EXISTS trg_close_reports_after_handover
ON public.handover;

DROP TRIGGER IF EXISTS trg_claim_updated_at
ON public.claim;


-- =====================================================================
-- 9. CLAIM TRIGGERS
-- =====================================================================

DROP TRIGGER IF EXISTS trg_claim_write_guard
ON public.claim;

CREATE TRIGGER trg_claim_write_guard
BEFORE INSERT OR UPDATE ON public.claim
FOR EACH ROW
EXECUTE FUNCTION guard_claim_write();


CREATE TRIGGER trg_claim_approval_reports
AFTER UPDATE OF status ON public.claim
FOR EACH ROW
EXECUTE FUNCTION update_reports_after_claim_approval();


CREATE TRIGGER trg_claim_status_audit
AFTER UPDATE OF status ON public.claim
FOR EACH ROW
EXECUTE FUNCTION audit_status_change();


-- =====================================================================
-- 10. LOST REPORT TRIGGERS
-- =====================================================================

DROP TRIGGER IF EXISTS trg_lost_report_status_guard
ON public.lost_report;

CREATE TRIGGER trg_lost_report_status_guard
BEFORE UPDATE OF status ON public.lost_report
FOR EACH ROW
EXECUTE FUNCTION guard_report_status();


CREATE TRIGGER trg_lost_report_status_audit
AFTER UPDATE OF status ON public.lost_report
FOR EACH ROW
EXECUTE FUNCTION audit_status_change();


-- =====================================================================
-- 11. FOUND REPORT TRIGGERS
-- =====================================================================

DROP TRIGGER IF EXISTS trg_found_report_status_guard
ON public.found_report;

CREATE TRIGGER trg_found_report_status_guard
BEFORE UPDATE OF status ON public.found_report
FOR EACH ROW
EXECUTE FUNCTION guard_report_status();


CREATE TRIGGER trg_found_report_status_audit
AFTER UPDATE OF status ON public.found_report
FOR EACH ROW
EXECUTE FUNCTION audit_status_change();


-- =====================================================================
-- 12. HANDOVER TRIGGERS
-- =====================================================================

DROP TRIGGER IF EXISTS trg_handover_insert_guard
ON public.handover;

CREATE TRIGGER trg_handover_insert_guard
BEFORE INSERT ON public.handover
FOR EACH ROW
EXECUTE FUNCTION guard_handover_insert();


DROP TRIGGER IF EXISTS trg_handover_immutable
ON public.handover;

CREATE TRIGGER trg_handover_immutable
BEFORE UPDATE OR DELETE ON public.handover
FOR EACH ROW
EXECUTE FUNCTION reject_handover_mutation();


CREATE TRIGGER trg_close_reports_after_handover
AFTER INSERT ON public.handover
FOR EACH ROW
EXECUTE FUNCTION close_reports_after_handover();


-- =====================================================================
-- 13. FUNCTION OWNERSHIP
-- =====================================================================

ALTER FUNCTION audit_status_change()
OWNER TO claims_workflow_owner;

ALTER FUNCTION guard_claim_write()
OWNER TO claims_workflow_owner;

ALTER FUNCTION update_reports_after_claim_approval()
OWNER TO claims_workflow_owner;

ALTER FUNCTION guard_report_status()
OWNER TO claims_workflow_owner;

ALTER FUNCTION guard_handover_insert()
OWNER TO claims_workflow_owner;

ALTER FUNCTION reject_handover_mutation()
OWNER TO claims_workflow_owner;

ALTER FUNCTION close_reports_after_handover()
OWNER TO claims_workflow_owner;


-- =====================================================================
-- 14. FUNCTION EXECUTION PRIVILEGES
-- =====================================================================

REVOKE ALL ON FUNCTION
    audit_status_change(),
    guard_claim_write(),
    update_reports_after_claim_approval(),
    guard_report_status(),
    guard_handover_insert(),
    reject_handover_mutation(),
    close_reports_after_handover()
FROM PUBLIC, claims_app;


-- =====================================================================
-- END OF CLAIMS WORKFLOW TRIGGER SCRIPT
-- =====================================================================
