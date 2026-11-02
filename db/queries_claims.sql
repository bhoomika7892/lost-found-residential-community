
-- =====================================================================
-- Lost & Found in a Residential Community
-- File: db/queries_claims.sql
-- Owner: Claims, Verification and Handover
-- PostgreSQL 16
--
-- PURPOSE:
-- Read-only queries for claim tracking, verification and handover.
--
-- IMPORTANT:
-- Approvals, rejections and handovers must use the protected workflow
-- functions. Do not directly update claim/report status in this file.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Display all claims with their current status.
-- ---------------------------------------------------------------------

SELECT
    c.claim_id,
    c.lost_report_id,
    c.found_report_id,
    c.claimant_id,
    c.verified_by,
    c.claim_date,
    c.status,
    c.verification_notes,
    c.updated_at
FROM public.claim c
ORDER BY c.claim_date DESC, c.claim_id DESC;


-- ---------------------------------------------------------------------
-- 2. Display claimant and reviewing staff details.
-- ---------------------------------------------------------------------

SELECT
    c.claim_id,
    r.name AS claimant_name,
    c.lost_report_id,
    c.found_report_id,
    c.claim_date,
    c.status,
    s.name AS reviewer_name,
    c.verification_notes
FROM public.claim c
JOIN public.resident r
    ON r.resident_id = c.claimant_id
LEFT JOIN public.staff s
    ON s.staff_id = c.verified_by
ORDER BY c.claim_date DESC, c.claim_id DESC;


-- ---------------------------------------------------------------------
-- 3. Display lost and found item details for claim verification.
-- ---------------------------------------------------------------------

SELECT
    c.claim_id,
    c.status AS claim_status,

    lr.lost_report_id,
    li.item_name AS lost_item,
    li.description AS lost_item_description,
    lr.status AS lost_report_status,

    fr.found_report_id,
    fi.item_name AS found_item,
    fi.description AS found_item_description,
    fr.status AS found_report_status,

    c.verification_notes

FROM public.claim c
JOIN public.lost_report lr
    ON lr.lost_report_id = c.lost_report_id
JOIN public.item li
    ON li.item_id = lr.item_id
JOIN public.found_report fr
    ON fr.found_report_id = c.found_report_id
JOIN public.item fi
    ON fi.item_id = fr.item_id
ORDER BY c.claim_id;


-- ---------------------------------------------------------------------
-- 4. Count claims in each status.
-- ---------------------------------------------------------------------

SELECT
    status,
    COUNT(*) AS total_claims
FROM public.claim
GROUP BY status
ORDER BY total_claims DESC, status;


-- ---------------------------------------------------------------------
-- 5. Count claims reviewed by each staff member.
-- ---------------------------------------------------------------------

SELECT
    s.staff_id,
    s.name AS staff_name,
    s.role,
    s.active,
    COUNT(c.claim_id) AS reviewed_claims
FROM public.staff s
JOIN public.claim c
    ON c.verified_by = s.staff_id
GROUP BY
    s.staff_id,
    s.name,
    s.role,
    s.active
HAVING COUNT(c.claim_id) >= 1
ORDER BY reviewed_claims DESC, s.name;


-- ---------------------------------------------------------------------
-- 6. Find residents who currently have pending claims.
-- ---------------------------------------------------------------------

SELECT
    r.resident_id,
    r.name
FROM public.resident r
WHERE EXISTS (
    SELECT 1
    FROM public.claim c
    WHERE c.claimant_id = r.resident_id
      AND c.status = 'pending'
)
ORDER BY r.name;


-- ---------------------------------------------------------------------
-- 7. Calculate average number of days between claim submission
--    and the recorded handover.
-- ---------------------------------------------------------------------

SELECT
    ROUND(
        AVG(
            EXTRACT(
                EPOCH FROM (h.handover_date - c.claim_date)
            ) / 86400.0
        )::NUMERIC,
        2
    ) AS avg_days_to_recorded_handover
FROM public.claim c
JOIN public.handover h
    ON h.claim_id = c.claim_id;


-- ---------------------------------------------------------------------
-- 8. Count claims per residential block.
-- ---------------------------------------------------------------------

SELECT
    a.block_id,
    COUNT(c.claim_id) AS total_claims
FROM public.claim c
JOIN public.resident r
    ON r.resident_id = c.claimant_id
JOIN public.apartment a
    ON a.apartment_id = r.apartment_id
GROUP BY a.block_id
ORDER BY total_claims DESC, a.block_id;


-- ---------------------------------------------------------------------
-- 9. Display handover history with claimant and staff details.
-- ---------------------------------------------------------------------

SELECT
    h.handover_id,
    c.claim_id,
    r.name AS claimant_name,
    s.name AS handover_staff,
    h.staff_id,
    h.handover_date,
    h.verification_method,
    h.remarks
FROM public.handover h
JOIN public.claim c
    ON c.claim_id = h.claim_id
JOIN public.resident r
    ON r.resident_id = c.claimant_id
JOIN public.staff s
    ON s.staff_id = h.staff_id
ORDER BY h.handover_date DESC, h.handover_id DESC;


-- ---------------------------------------------------------------------
-- 10. Display pending claims waiting for staff verification.
-- ---------------------------------------------------------------------

SELECT
    c.claim_id,
    c.claimant_id,
    r.name AS claimant_name,
    c.lost_report_id,
    c.found_report_id,
    c.claim_date,
    c.verification_notes
FROM public.claim c
JOIN public.resident r
    ON r.resident_id = c.claimant_id
WHERE c.status = 'pending'
ORDER BY c.claim_date ASC, c.claim_id ASC;


-- ---------------------------------------------------------------------
-- 11. Display approved claims that are awaiting physical handover.
-- ---------------------------------------------------------------------

SELECT
    c.claim_id,
    c.claimant_id,
    r.name AS claimant_name,
    c.verified_by,
    s.name AS approving_staff,
    c.claim_date,
    c.status
FROM public.claim c
JOIN public.resident r
    ON r.resident_id = c.claimant_id
LEFT JOIN public.staff s
    ON s.staff_id = c.verified_by
WHERE c.status = 'approved'
  AND NOT EXISTS (
      SELECT 1
      FROM public.handover h
      WHERE h.claim_id = c.claim_id
  )
ORDER BY c.claim_date ASC, c.claim_id ASC;


-- ---------------------------------------------------------------------
-- 12. Display rejected claims with their recorded reasons.
-- ---------------------------------------------------------------------

SELECT
    c.claim_id,
    c.claimant_id,
    r.name AS claimant_name,
    c.verified_by,
    s.name AS reviewing_staff,
    c.claim_date,
    c.verification_notes
FROM public.claim c
JOIN public.resident r
    ON r.resident_id = c.claimant_id
LEFT JOIN public.staff s
    ON s.staff_id = c.verified_by
WHERE c.status = 'rejected'
ORDER BY c.claim_date DESC, c.claim_id DESC;


-- ---------------------------------------------------------------------
-- 13. Display completed handovers.
-- ---------------------------------------------------------------------

SELECT
    h.handover_id,
    h.claim_id,
    h.staff_id,
    s.name AS handover_staff,
    h.handover_date,
    h.verification_method,
    h.remarks
FROM public.handover h
JOIN public.staff s
    ON s.staff_id = h.staff_id
ORDER BY h.handover_date DESC, h.handover_id DESC;


-- ---------------------------------------------------------------------
-- 14. Count handovers by verification method.
-- ---------------------------------------------------------------------

SELECT
    verification_method,
    COUNT(*) AS total_handovers
FROM public.handover
GROUP BY verification_method
ORDER BY total_handovers DESC, verification_method;


-- =====================================================================
-- END OF CLAIMS QUERIES
-- All queries above are SELECT statements.
-- No business records are modified.
-- =====================================================================
