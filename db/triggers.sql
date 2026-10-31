-- =====================================================================
-- Lost & Found Residential Community
-- File: db/triggers.sql
-- Adds audit/report/handover triggers and corrected workflow functions.
-- Run AFTER schema_reporting.sql and schema_claims.sql.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. AUDIT STATUS CHANGES
-- Supports claim, lost_report, and found_report.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION audit_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_record_id INT;
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN

        IF TG_TABLE_NAME = 'claim' THEN
            v_record_id := NEW.claim_id;
        ELSIF TG_TABLE_NAME = 'lost_report' THEN
            v_record_id := NEW.lost_report_id;
        ELSIF TG_TABLE_NAME = 'found_report' THEN
            v_record_id := NEW.found_report_id;
        ELSE
            RAISE EXCEPTION 'Unsupported table for status audit: %',
                TG_TABLE_NAME;
        END IF;

        INSERT INTO audit_log (
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


-- ---------------------------------------------------------------------
-- 2. WHEN A CLAIM IS APPROVED, MARK BOTH REPORTS AS CLAIMED
-- Approval does NOT create a handover record.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION update_reports_after_claim_approval()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status
       AND NEW.status = 'approved' THEN

        UPDATE lost_report
        SET status = 'claimed'
        WHERE lost_report_id = NEW.lost_report_id
          AND status IN ('open', 'matched');

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Lost report % is not open or matched',
                NEW.lost_report_id;
        END IF;

        UPDATE found_report
        SET status = 'claimed'
        WHERE found_report_id = NEW.found_report_id
          AND status IN ('open', 'matched');

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Found report % is not open or matched',
                NEW.found_report_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


-- ---------------------------------------------------------------------
-- 3. VALIDATE HANDOVER INSERTS
-- ---------------------------------------------------------------------

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
        RAISE EXCEPTION 'Claim % does not exist', NEW.claim_id;
    END IF;

    IF v_claim_status <> 'approved' THEN
        RAISE EXCEPTION
            'Handover can only be recorded for an approved claim';
    END IF;

    IF NEW.handover_date < v_claim_date THEN
        RAISE EXCEPTION
            'Handover date cannot be earlier than claim date';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM staff
        WHERE staff_id = NEW.staff_id
          AND active = TRUE
          AND role IN ('staff', 'admin')
    ) THEN
        RAISE EXCEPTION
            'Invalid or inactive staff account: %', NEW.staff_id;
    END IF;

    RETURN NEW;
END;
$$;


-- ---------------------------------------------------------------------
-- 4. AFTER HANDOVER, CLOSE BOTH REPORTS
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION close_reports_after_handover()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_lost_report_id INT;
    v_found_report_id INT;
BEGIN
    SELECT lost_report_id, found_report_id
    INTO v_lost_report_id, v_found_report_id
    FROM claim
    WHERE claim_id = NEW.claim_id;

    UPDATE lost_report
    SET status = 'closed'
    WHERE lost_report_id = v_lost_report_id
      AND status = 'claimed';

    UPDATE found_report
    SET status = 'closed'
    WHERE found_report_id = v_found_report_id
      AND status = 'claimed';

    RETURN NEW;
END;
$$;


-- ---------------------------------------------------------------------
-- 5. CORRECTED APPROVE CLAIM FUNCTION
-- Approval and physical handover are separate operations.
-- ---------------------------------------------------------------------

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
    SELECT *
    INTO v_claim
    FROM claim
    WHERE claim_id = p_claim_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Claim % does not exist', p_claim_id;
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
            'Invalid or inactive staff account: %', p_staff_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM lost_report
        WHERE lost_report_id = v_claim.lost_report_id
          AND status IN ('open', 'matched')
    ) THEN
        RAISE EXCEPTION
            'Lost report is not open or matched';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM found_report
        WHERE found_report_id = v_claim.found_report_id
          AND status IN ('open', 'matched')
    ) THEN
        RAISE EXCEPTION
            'Found report is not open or matched';
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


-- ---------------------------------------------------------------------
-- 6. RECORD PHYSICAL HANDOVER
-- Inserts the handover and closes both reports in one transaction.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION record_handover(
    p_claim_id INT,
    p_staff_id INT,
    p_verification_method VARCHAR(30),
    p_remarks TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_claim_status VARCHAR(10);
BEGIN
    SELECT status
    INTO v_claim_status
    FROM claim
    WHERE claim_id = p_claim_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Claim % does not exist', p_claim_id;
    END IF;

    IF v_claim_status <> 'approved' THEN
        RAISE EXCEPTION
            'Only approved claims can have a handover recorded';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM staff
        WHERE staff_id = p_staff_id
          AND active = TRUE
          AND role IN ('staff', 'admin')
    ) THEN
        RAISE EXCEPTION
            'Invalid or inactive staff account: %', p_staff_id;
    END IF;

    INSERT INTO handover (
        claim_id,
        staff_id,
        verification_method,
        remarks
    )
    VALUES (
        p_claim_id,
        p_staff_id,
        p_verification_method,
        p_remarks
    );

    RETURN 'Handover recorded; both reports closed';
END;
$$;


-- ---------------------------------------------------------------------
-- 7. CREATE TRIGGERS
-- Drop only these named triggers so the script is re-runnable.
-- ---------------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_claim_status_audit ON claim;
CREATE TRIGGER trg_claim_status_audit
AFTER UPDATE OF status ON claim
FOR EACH ROW
EXECUTE FUNCTION audit_status_change();

DROP TRIGGER IF EXISTS trg_lost_report_status_audit ON lost_report;
CREATE TRIGGER trg_lost_report_status_audit
AFTER UPDATE OF status ON lost_report
FOR EACH ROW
EXECUTE FUNCTION audit_status_change();

DROP TRIGGER IF EXISTS trg_found_report_status_audit ON found_report;
CREATE TRIGGER trg_found_report_status_audit
AFTER UPDATE OF status ON found_report
FOR EACH ROW
EXECUTE FUNCTION audit_status_change();

DROP TRIGGER IF EXISTS trg_claim_approval_reports ON claim;
CREATE TRIGGER trg_claim_approval_reports
AFTER UPDATE OF status ON claim
FOR EACH ROW
EXECUTE FUNCTION update_reports_after_claim_approval();

DROP TRIGGER IF EXISTS trg_validate_handover_date ON handover;
CREATE TRIGGER trg_validate_handover_date
BEFORE INSERT ON handover
FOR EACH ROW
EXECUTE FUNCTION validate_handover_date();

DROP TRIGGER IF EXISTS trg_close_reports_after_handover ON handover;
CREATE TRIGGER trg_close_reports_after_handover
AFTER INSERT ON handover
FOR EACH ROW
EXECUTE FUNCTION close_reports_after_handover();


-- ---------------------------------------------------------------------
-- 8. UPDATED_AT TRIGGER FOR CLAIM
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION set_claim_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_claim_updated_at ON claim;
CREATE TRIGGER trg_claim_updated_at
BEFORE UPDATE ON claim
FOR EACH ROW
EXECUTE FUNCTION set_claim_updated_at();


-- ---------------------------------------------------------------------
-- END
-- ---------------------------------------------------------------------