
-- =====================================================================
-- Lost & Found System for a Residential Community
-- File: db/schema_claims.sql
-- Owner: Claims, Verification and Handover module
-- Requires: db/schema_reporting.sql
-- PostgreSQL 16
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. STAFF
-- Staff/admin accounts responsible for reviewing claims and handovers.
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.staff (
    staff_id       SERIAL PRIMARY KEY,
    name           VARCHAR(100) NOT NULL,
    email          VARCHAR(120) NOT NULL UNIQUE
                   CHECK (
                       email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
                   ),
    phone          VARCHAR(10) NOT NULL
                   CHECK (phone ~ '^[0-9]{10}$'),
    role           VARCHAR(10) NOT NULL DEFAULT 'staff'
                   CHECK (role IN ('staff', 'admin')),
    password_hash  TEXT NOT NULL,
    created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    active         BOOLEAN NOT NULL DEFAULT TRUE
);

-- ---------------------------------------------------------------------
-- 2. CLAIM
-- A resident submits a claim for a found item.
--
-- Permitted final decisions:
-- pending -> approved
-- pending -> rejected
--
-- Every approved/rejected claim must retain its reviewer.
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.claim (
    claim_id            SERIAL PRIMARY KEY,

    lost_report_id      INT NOT NULL
                        REFERENCES public.lost_report(lost_report_id)
                        ON UPDATE CASCADE ON DELETE RESTRICT,

    found_report_id     INT NOT NULL
                        REFERENCES public.found_report(found_report_id)
                        ON UPDATE CASCADE ON DELETE RESTRICT,

    claimant_id         INT NOT NULL
                        REFERENCES public.resident(resident_id)
                        ON UPDATE CASCADE ON DELETE RESTRICT,

    verified_by         INT
                        REFERENCES public.staff(staff_id)
                        ON UPDATE CASCADE ON DELETE RESTRICT,

    claim_date          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    status              VARCHAR(10) NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'approved', 'rejected')),

    verification_notes  TEXT,

    updated_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_claim_report_pair
        UNIQUE (lost_report_id, found_report_id),

    CONSTRAINT chk_claim_decision_reviewer
        CHECK (
            status = 'pending'
            OR verified_by IS NOT NULL
        ),

    CONSTRAINT chk_claim_rejection_notes
        CHECK (
            status <> 'rejected'
            OR (
                verification_notes IS NOT NULL
                AND btrim(verification_notes) <> ''
            )
        )
);

-- ---------------------------------------------------------------------
-- 3. HANDOVER
-- Physical return of the item after claim approval.
--
-- One claim can have at most one handover.
-- Handover date cannot precede claim date.
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.handover (
    handover_id          SERIAL PRIMARY KEY,

    claim_id             INT NOT NULL UNIQUE
                         REFERENCES public.claim(claim_id)
                         ON UPDATE CASCADE ON DELETE RESTRICT,

    staff_id             INT NOT NULL
                         REFERENCES public.staff(staff_id)
                         ON UPDATE CASCADE ON DELETE RESTRICT,

    handover_date        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    verification_method  VARCHAR(30) NOT NULL
                         CHECK (
                             verification_method IN (
                                 'photo_id',
                                 'resident_id',
                                 'security_question',
                                 'other'
                             )
                         ),

    remarks              TEXT
);

-- ---------------------------------------------------------------------
-- 4. AUDIT LOG
-- Stores actual status transitions of claims and reports.
-- One row is inserted for each actual status change.
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.audit_log (
    log_id       BIGSERIAL PRIMARY KEY,
    table_name   VARCHAR(50) NOT NULL,
    record_id    INT NOT NULL,
    old_status   VARCHAR(20),
    new_status   VARCHAR(20) NOT NULL,
    changed_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------
-- 5. INDEXES
-- ---------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_claim_status
    ON public.claim(status);

CREATE INDEX IF NOT EXISTS idx_claim_claimant
    ON public.claim(claimant_id);

CREATE INDEX IF NOT EXISTS idx_claim_verified_by
    ON public.claim(verified_by);

CREATE INDEX IF NOT EXISTS idx_handover_staff
    ON public.handover(staff_id);

CREATE INDEX IF NOT EXISTS idx_audit_log_table_record
    ON public.audit_log(table_name, record_id);

CREATE INDEX IF NOT EXISTS idx_audit_log_changed_at
    ON public.audit_log(changed_at);

-- Note:
-- UNIQUE(claim_id) on handover already creates an index.
-- Do not create another index on handover(claim_id).
--
-- Existing databases:
-- CREATE TABLE IF NOT EXISTS does not modify an existing table.
-- Review and apply migrations separately before using this schema
-- against an existing database.
