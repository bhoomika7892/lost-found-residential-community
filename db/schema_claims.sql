
-- =====================================================================
-- Lost & Found in a Residential Community
-- File: db/schema_claims.sql
-- Owner: Bhoomika - Claims, Verification and Handover
-- Requires: db/schema_reporting.sql to run first
-- Database: PostgreSQL 16
-- =====================================================================

-- STAFF: staff/admin accounts that review claims and record handovers
CREATE TABLE IF NOT EXISTS staff (
    staff_id       SERIAL PRIMARY KEY,
    name           VARCHAR(100) NOT NULL,
    email          VARCHAR(120) NOT NULL UNIQUE
                   CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    phone          VARCHAR(10) NOT NULL
                   CHECK (phone ~ '^[0-9]{10}$'),
    role           VARCHAR(10) NOT NULL DEFAULT 'staff'
                   CHECK (role IN ('staff', 'admin')),
    password_hash  TEXT NOT NULL,
    created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- CLAIM: a resident claims a found item that may match their lost report
CREATE TABLE IF NOT EXISTS claim (
    claim_id            SERIAL PRIMARY KEY,
    lost_report_id      INT NOT NULL
                        REFERENCES lost_report(lost_report_id)
                        ON UPDATE CASCADE ON DELETE RESTRICT,
    found_report_id     INT NOT NULL
                        REFERENCES found_report(found_report_id)
                        ON UPDATE CASCADE ON DELETE RESTRICT,
    claimant_id         INT NOT NULL
                        REFERENCES resident(resident_id)
                        ON UPDATE CASCADE ON DELETE RESTRICT,
    verified_by         INT
                        REFERENCES staff(staff_id)
                        ON UPDATE CASCADE ON DELETE SET NULL,
    claim_date          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status              VARCHAR(10) NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'approved', 'rejected')),
    verification_notes  TEXT,
    CONSTRAINT uq_claim_report_pair
        UNIQUE (lost_report_id, found_report_id),
    CONSTRAINT chk_claim_approval_reviewer
        CHECK (status <> 'approved' OR verified_by IS NOT NULL)
);

-- HANDOVER: records physical return of an item after approval
CREATE TABLE IF NOT EXISTS handover (
    handover_id          SERIAL PRIMARY KEY,
    claim_id             INT NOT NULL UNIQUE
                         REFERENCES claim(claim_id)
                         ON UPDATE CASCADE ON DELETE RESTRICT,
    staff_id             INT NOT NULL
                         REFERENCES staff(staff_id)
                         ON UPDATE CASCADE ON DELETE RESTRICT,
    handover_date        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    verification_method  VARCHAR(30) NOT NULL
                         CHECK (verification_method IN
                             ('photo_id', 'resident_id',
                              'security_question', 'other')),
    remarks              TEXT
);

-- AUDIT LOG: records status changes for claims and reports
CREATE TABLE IF NOT EXISTS audit_log (
    log_id       BIGSERIAL PRIMARY KEY,
    table_name   VARCHAR(50) NOT NULL,
    record_id    INT NOT NULL,
    old_status   VARCHAR(20),
    new_status   VARCHAR(20) NOT NULL,
    changed_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ALTER examples
ALTER TABLE staff
    ADD COLUMN IF NOT EXISTS active BOOLEAN NOT NULL DEFAULT TRUE;

ALTER TABLE claim
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP NOT NULL
    DEFAULT CURRENT_TIMESTAMP;

-- Required indexes
CREATE INDEX IF NOT EXISTS idx_claim_status
    ON claim(status);

CREATE INDEX IF NOT EXISTS idx_claim_claimant
    ON claim(claimant_id);

CREATE INDEX IF NOT EXISTS idx_handover_claim
    ON handover(claim_id);

-- Temporary table example to demonstrate CREATE and DROP.
-- This does not delete any real project data.
CREATE TABLE IF NOT EXISTS claims_drop_demo (
    demo_id SERIAL PRIMARY KEY
);

DROP TABLE IF EXISTS claims_drop_demo;
