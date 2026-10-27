
-- =====================================================================
-- Lost & Found in a Residential Community
-- File: db/queries_claims.sql
-- Owner: Bhoomika - Claims, Verification and Handover
-- PostgreSQL 16
-- =====================================================================

-- 1. SELECT: Display all claims with their current status
SELECT
    claim_id,
    lost_report_id,
    found_report_id,
    claimant_id,
    verified_by,
    claim_date,
    status,
    verification_notes
FROM claim
ORDER BY claim_date DESC;


-- 2. JOIN: Claimant and reviewing staff details
SELECT
    c.claim_id,
    r.name AS claimant_name,
    c.lost_report_id,
    c.found_report_id,
    c.claim_date,
    c.status,
    s.name AS reviewer_name,
    c.verification_notes
FROM claim c
JOIN resident r
    ON r.resident_id = c.claimant_id
LEFT JOIN staff s
    ON s.staff_id = c.verified_by
ORDER BY c.claim_date DESC;


-- 3. JOIN: Item details for staff claim verification
SELECT
    c.claim_id,
    c.status AS claim_status,
    li.item_name AS lost_item,
    li.description AS lost_item_description,
    fi.item_name AS found_item,
    fi.description AS found_item_description,
    c.verification_notes
FROM claim c
JOIN lost_report lr
    ON lr.lost_report_id = c.lost_report_id
JOIN item li
    ON li.item_id = lr.item_id
JOIN found_report fr
    ON fr.found_report_id = c.found_report_id
JOIN item fi
    ON fi.item_id = fr.item_id
ORDER BY c.claim_id;


-- 4. GROUP BY: Count claims in each status
SELECT
    status,
    COUNT(*) AS total_claims
FROM claim
GROUP BY status
ORDER BY total_claims DESC;


-- 5. GROUP BY and HAVING: Staff who reviewed at least one claim
SELECT
    s.staff_id,
    s.name,
    COUNT(c.claim_id) AS reviewed_claims
FROM staff s
JOIN claim c
    ON c.verified_by = s.staff_id
GROUP BY s.staff_id, s.name
HAVING COUNT(c.claim_id) >= 1
ORDER BY reviewed_claims DESC, s.name;


-- 6. Subquery: Residents who currently have pending claims
SELECT
    resident_id,
    name
FROM resident
WHERE resident_id IN (
    SELECT claimant_id
    FROM claim
    WHERE status = 'pending'
)
ORDER BY name;


-- 7. Aggregate: Average days between claim submission
--    and creation of the recorded handover
SELECT
    ROUND(
        (
            AVG(
                EXTRACT(
                    EPOCH FROM (h.handover_date - c.claim_date)
                ) / 86400.0
            )
        )::NUMERIC,
        2
    ) AS avg_days_to_recorded_handover
FROM claim c
JOIN handover h
    ON h.claim_id = c.claim_id;


-- 8. GROUP BY: Claims per residential block
SELECT
    a.block_id,
    COUNT(c.claim_id) AS total_claims
FROM claim c
JOIN resident r
    ON r.resident_id = c.claimant_id
JOIN apartment a
    ON a.apartment_id = r.apartment_id
GROUP BY a.block_id
ORDER BY total_claims DESC, a.block_id;


-- 9. JOIN: Handover history with claimant and staff details
SELECT
    h.handover_id,
    c.claim_id,
    r.name AS claimant_name,
    s.name AS handover_staff,
    h.handover_date,
    h.verification_method,
    h.remarks
FROM handover h
JOIN claim c
    ON c.claim_id = h.claim_id
JOIN resident r
    ON r.resident_id = c.claimant_id
JOIN staff s
    ON s.staff_id = h.staff_id
ORDER BY h.handover_date DESC;


-- =====================================================================
-- DML EXAMPLES
-- Commented out to protect existing data.
-- Uncomment only when intentionally testing these operations.
-- =====================================================================

-- 10. INSERT: Example staff record
-- Use a real bcrypt password hash in the application.
-- INSERT INTO staff (name, email, phone, role, password_hash)
-- VALUES (
--     'Demo Staff',
--     'demo.staff@example.com',
--     '9876543210',
--     'staff',
--     '<bcrypt-hash>'
-- );


-- 11. UPDATE: Add a verification note to a pending claim
-- The existing trigger updates updated_at automatically.
-- UPDATE claim
-- SET verification_notes = 'Ownership evidence requested'
-- WHERE claim_id = 5
--   AND status = 'pending';


-- 12. DELETE: Demonstration only
-- Inspect the target before deleting any real record.
-- DELETE FROM claim
-- WHERE claim_id = -1;


-- =====================================================================
-- END OF CLAIMS QUERIES
-- =====================================================================
