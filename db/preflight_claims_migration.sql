
-- =====================================================================
-- Lost & Found System - Claims Migration Preflight
-- File: db/preflight_claims_migration.sql
-- PostgreSQL 16
--
-- PURPOSE:
-- Inspect existing records before enabling stricter claims workflow
-- constraints, triggers and permissions.
--
-- SAFETY:
-- 1. Read-only transaction.
-- 2. Does not insert, update or delete records.
-- 3. Does not repair inconsistent data.
-- 4. Does not modify audit history.
-- 5. Run only after the required project tables exist.
-- =====================================================================

BEGIN TRANSACTION READ ONLY;

-- ---------------------------------------------------------------------
-- CHECK 1: Rejected claims must have a reviewer and rejection notes.
-- ---------------------------------------------------------------------

SELECT
    'rejected_claim_missing_decision_details' AS check_name,
    c.claim_id,
    c.verified_by,
    c.verification_notes
FROM public.claim c
WHERE c.status = 'rejected'
  AND (
      c.verified_by IS NULL
      OR c.verification_notes IS NULL
      OR btrim(c.verification_notes) = ''
  );

-- ---------------------------------------------------------------------
-- CHECK 2: Approved claims must have both reports in the correct state.
--
-- Without a handover:
--     both reports must be claimed.
--
-- With a handover:
--     both reports must be closed.
-- ---------------------------------------------------------------------

SELECT
    'approved_claim_report_state_mismatch' AS check_name,
    c.claim_id,
    c.lost_report_id,
    lr.status AS lost_status,
    c.found_report_id,
    fr.status AS found_status,
    EXISTS (
        SELECT 1
        FROM public.handover h
        WHERE h.claim_id = c.claim_id
    ) AS has_handover
FROM public.claim c
JOIN public.lost_report lr
    ON lr.lost_report_id = c.lost_report_id
JOIN public.found_report fr
    ON fr.found_report_id = c.found_report_id
WHERE c.status = 'approved'
  AND (
      (
          NOT EXISTS (
              SELECT 1
              FROM public.handover h
              WHERE h.claim_id = c.claim_id
          )
          AND (
              lr.status <> 'claimed'
              OR fr.status <> 'claimed'
          )
      )
      OR
      (
          EXISTS (
              SELECT 1
              FROM public.handover h
              WHERE h.claim_id = c.claim_id
          )
          AND (
              lr.status <> 'closed'
              OR fr.status <> 'closed'
          )
      )
  );

-- ---------------------------------------------------------------------
-- CHECK 3: Handovers must belong to approved claims.
-- Their dates must not precede claim dates.
-- Both reports must be closed.
-- ---------------------------------------------------------------------

SELECT
    'handover_inconsistent' AS check_name,
    h.handover_id,
    h.claim_id,
    h.staff_id,
    h.handover_date,
    c.claim_date,
    c.status AS claim_status,
    lr.status AS lost_status,
    fr.status AS found_status
FROM public.handover h
JOIN public.claim c
    ON c.claim_id = h.claim_id
JOIN public.lost_report lr
    ON lr.lost_report_id = c.lost_report_id
JOIN public.found_report fr
    ON fr.found_report_id = c.found_report_id
WHERE c.status <> 'approved'
   OR h.handover_date < c.claim_date
   OR lr.status <> 'closed'
   OR fr.status <> 'closed';

-- ---------------------------------------------------------------------
-- CHECK 4: Review handovers recorded by staff who are currently
-- inactive or do not currently have an eligible role.
--
-- This is a review warning only. A later deactivation does not prove
-- that the historical handover was unauthorized.
-- ---------------------------------------------------------------------

SELECT
    'historical_handover_staff_currently_ineligible_review_only'
        AS check_name,
    h.handover_id,
    h.claim_id,
    s.staff_id,
    s.name,
    s.active,
    s.role
FROM public.handover h
JOIN public.staff s
    ON s.staff_id = h.staff_id
WHERE s.active IS DISTINCT FROM TRUE
   OR s.role NOT IN ('staff', 'admin');

-- ---------------------------------------------------------------------
-- CHECK 5: Review approved/rejected claims whose reviewer is missing,
-- currently inactive, or currently has an ineligible role.
--
-- Historical review only; do not automatically change old decisions.
-- ---------------------------------------------------------------------

SELECT
    'historical_reviewer_currently_ineligible_review_only' AS check_name,
    c.claim_id,
    c.status,
    c.verified_by,
    s.name AS reviewer_name,
    s.active,
    s.role
FROM public.claim c
LEFT JOIN public.staff s
    ON s.staff_id = c.verified_by
WHERE c.status IN ('approved', 'rejected')
  AND (
      s.staff_id IS NULL
      OR s.active IS DISTINCT FROM TRUE
      OR s.role NOT IN ('staff', 'admin')
  );

-- ---------------------------------------------------------------------
-- CHECK 6: Claimed reports must be associated with an approved claim.
-- ---------------------------------------------------------------------

SELECT
    'claimed_report_without_approved_claim' AS check_name,
    'lost' AS report_type,
    lr.lost_report_id AS report_id,
    lr.status
FROM public.lost_report lr
WHERE lr.status = 'claimed'
  AND NOT EXISTS (
      SELECT 1
      FROM public.claim c
      WHERE c.lost_report_id = lr.lost_report_id
        AND c.status = 'approved'
  )

UNION ALL

SELECT
    'claimed_report_without_approved_claim',
    'found',
    fr.found_report_id,
    fr.status
FROM public.found_report fr
WHERE fr.status = 'claimed'
  AND NOT EXISTS (
      SELECT 1
      FROM public.claim c
      WHERE c.found_report_id = fr.found_report_id
        AND c.status = 'approved'
  );

-- ---------------------------------------------------------------------
-- CHECK 7: Closed reports must have an approved claim and handover.
-- ---------------------------------------------------------------------

SELECT
    'closed_report_without_handover' AS check_name,
    'lost' AS report_type,
    lr.lost_report_id AS report_id,
    lr.status
FROM public.lost_report lr
WHERE lr.status = 'closed'
  AND NOT EXISTS (
      SELECT 1
      FROM public.claim c
      JOIN public.handover h
          ON h.claim_id = c.claim_id
      WHERE c.lost_report_id = lr.lost_report_id
        AND c.status = 'approved'
  )

UNION ALL

SELECT
    'closed_report_without_handover',
    'found',
    fr.found_report_id,
    fr.status
FROM public.found_report fr
WHERE fr.status = 'closed'
  AND NOT EXISTS (
      SELECT 1
      FROM public.claim c
      JOIN public.handover h
          ON h.claim_id = c.claim_id
      WHERE c.found_report_id = fr.found_report_id
        AND c.status = 'approved'
  );

-- ---------------------------------------------------------------------
-- CHECK 8: Duplicate claim/report pairs.
-- The unique constraint should prevent these.
-- ---------------------------------------------------------------------

SELECT
    'duplicate_claim_report_pair' AS check_name,
    lost_report_id,
    found_report_id,
    COUNT(*) AS row_count
FROM public.claim
GROUP BY lost_report_id, found_report_id
HAVING COUNT(*) > 1;

-- ---------------------------------------------------------------------
-- CHECK 9: Duplicate handovers for one claim.
-- The unique constraint on handover.claim_id should prevent these.
-- ---------------------------------------------------------------------

SELECT
    'duplicate_handover_per_claim' AS check_name,
    claim_id,
    COUNT(*) AS row_count
FROM public.handover
GROUP BY claim_id
HAVING COUNT(*) > 1;

-- ---------------------------------------------------------------------
-- CHECK 10: Multiple approved claims referring to the same lost report.
-- ---------------------------------------------------------------------

SELECT
    'multiple_approved_claims_for_lost_report' AS check_name,
    lost_report_id,
    COUNT(*) AS approved_claim_count,
    ARRAY_AGG(claim_id ORDER BY claim_id) AS claim_ids
FROM public.claim
WHERE status = 'approved'
GROUP BY lost_report_id
HAVING COUNT(*) > 1;

-- ---------------------------------------------------------------------
-- CHECK 11: Multiple approved claims referring to the same found report.
-- ---------------------------------------------------------------------

SELECT
    'multiple_approved_claims_for_found_report' AS check_name,
    found_report_id,
    COUNT(*) AS approved_claim_count,
    ARRAY_AGG(claim_id ORDER BY claim_id) AS claim_ids
FROM public.claim
WHERE status = 'approved'
GROUP BY found_report_id
HAVING COUNT(*) > 1;

-- ---------------------------------------------------------------------
-- CHECK 12: Pending claims must reference reports that are still
-- open or matched. These reports are eligible for later approval.
-- ---------------------------------------------------------------------

SELECT
    'pending_claim_report_state_mismatch' AS check_name,
    c.claim_id,
    c.lost_report_id,
    lr.status AS lost_status,
    c.found_report_id,
    fr.status AS found_status
FROM public.claim c
JOIN public.lost_report lr
    ON lr.lost_report_id = c.lost_report_id
JOIN public.found_report fr
    ON fr.found_report_id = c.found_report_id
WHERE c.status = 'pending'
  AND (
      lr.status NOT IN ('open', 'matched')
      OR fr.status NOT IN ('open', 'matched')
  );

-- ---------------------------------------------------------------------
-- CHECK 13: Existing audit history summary.
-- Preserve existing history. Do not infer or manufacture missing rows.
-- ---------------------------------------------------------------------

SELECT
    'existing_audit_history_summary' AS check_name,
    table_name,
    COUNT(*) AS existing_rows,
    MIN(changed_at) AS first_recorded_at,
    MAX(changed_at) AS last_recorded_at
FROM public.audit_log
GROUP BY table_name
ORDER BY table_name;

-- ---------------------------------------------------------------------
-- CHECK 14: Audit log summary for claims and report status changes.
-- ---------------------------------------------------------------------

SELECT
    'audit_status_transition_summary' AS check_name,
    table_name,
    old_status,
    new_status,
    COUNT(*) AS transition_count
FROM public.audit_log
WHERE table_name IN (
    'claim',
    'lost_report',
    'found_report'
)
GROUP BY table_name, old_status, new_status
ORDER BY table_name, old_status, new_status;

-- ---------------------------------------------------------------------
-- CHECK 15: Every claim must belong to the resident who submitted
-- the associated lost report.
-- ---------------------------------------------------------------------

SELECT
    'claimant_does_not_own_lost_report' AS check_name,
    c.claim_id,
    c.claimant_id,
    lr.resident_id AS lost_report_resident_id,
    c.status
FROM public.claim c
JOIN public.lost_report lr
    ON lr.lost_report_id = c.lost_report_id
WHERE c.claimant_id IS DISTINCT FROM lr.resident_id;
-- ---------------------------------------------------------------------
-- END
-- No database changes are committed.
-- ---------------------------------------------------------------------

ROLLBACK;
