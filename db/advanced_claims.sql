
-- =====================================================================
-- Lost & Found in a Residential Community
-- File: db/advanced_claims.sql
-- Owner: Bhoomika - Claims, Verification and Handover
-- Requires: schema_reporting.sql and schema_claims.sql
-- Database: PostgreSQL 16
-- =====================================================================

-- Triggers and workflow functions are defined in db/triggers.sql.
-- Apply db/triggers.sql before using approve_claim().
-- Physical handover is recorded separately using record_handover().


-- =====================================================================
-- 1. HANDOVER DATE AND STATUS VALIDATION
-- =====================================================================

CREATE OR REPLACE FUNCTION validate_handover_date()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_claim_date TIMESTAMP;
    v_claim_status VARCHAR(10);
BEGIN
    SELECT claim_date, status
    INTO v_claim_date, v_claim_status
    FROM claim
    WHERE claim_id = NEW.claim_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Claim % does not exist', NEW.claim_id;
    END IF;

    IF NEW.handover_date < v_claim_date THEN
        RAISE EXCEPTION
            'Handover date cannot be earlier than claim date';
    END IF;

    IF v_claim_status <> 'approved' THEN
        RAISE EXCEPTION
            'Handover can only be recorded for an approved claim';
    END IF;

    RETURN NEW;
END;
$$;
-- =====================================================================
-- 2. APPROVE CLAIM
-- =====================================================================

-- Approval updates the claim and report statuses.
-- Physical handover is recorded separately using record_handover()
-- in db/triggers.sql.

CREATE OR REPLACE FUNCTION approve_claim(
    p_claim_id INT,
    p_staff_id INT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_claim claim%ROWTYPE;
BEGIN
    -- Lock the claim to prevent concurrent approvals.
    SELECT *
    INTO v_claim
    FROM claim
    WHERE claim_id = p_claim_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Claim % does not exist', p_claim_id;
    END IF;

    IF v_claim.status <> 'pending' THEN
        RAISE EXCEPTION
            'Claim % is not pending (current status: %)',
            p_claim_id, v_claim.status;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM staff
        WHERE staff_id = p_staff_id
          AND active = TRUE
          AND role IN ('staff', 'admin')
    ) THEN
        RAISE EXCEPTION
            'Invalid or inactive staff account: %',
            p_staff_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM lost_report
        WHERE lost_report_id = v_claim.lost_report_id
          AND status IN ('open', 'matched')
    ) THEN
        RAISE EXCEPTION 'Lost report is not open or matched';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM found_report
        WHERE found_report_id = v_claim.found_report_id
          AND status IN ('open', 'matched')
    ) THEN
        RAISE EXCEPTION 'Found report is not open or matched';
    END IF;

    UPDATE claim
    SET status = 'approved',
        verified_by = p_staff_id,
        verification_notes =
            COALESCE(verification_notes, '')
            || CASE
                 WHEN COALESCE(verification_notes, '') = ''
                 THEN ''
                 ELSE E'\n'
               END
            || 'Approved by staff ID ' || p_staff_id
    WHERE claim_id = p_claim_id;

    RETURN 'Claim approved; handover must be recorded separately';
END;
$$;

-- =====================================================================
-- 3. ADMIN VIEW: PENDING CLAIMS
-- =====================================================================

CREATE OR REPLACE VIEW v_pending_claims AS
SELECT
    c.claim_id,
    c.claim_date,
    r.resident_id,
    r.name AS claimant_name,
    li.item_name AS lost_item_name,
    li.description AS lost_item_description,
    fi.item_name AS found_item_name,
    fi.description AS found_item_description,
    c.verification_notes
FROM claim c
JOIN resident r
    ON r.resident_id = c.claimant_id
JOIN lost_report lr
    ON lr.lost_report_id = c.lost_report_id
JOIN item li
    ON li.item_id = lr.item_id
JOIN found_report fr
    ON fr.found_report_id = c.found_report_id
JOIN item fi
    ON fi.item_id = fr.item_id
WHERE c.status = 'pending';


-- =====================================================================
-- 4. PERFORMANCE INDEXES
-- =====================================================================

CREATE INDEX IF NOT EXISTS idx_claim_verified_by
    ON claim(verified_by);

CREATE INDEX IF NOT EXISTS idx_handover_staff
    ON handover(staff_id);


-- =====================================================================
-- END OF ADVANCED CLAIMS SQL
-- =====================================================================
