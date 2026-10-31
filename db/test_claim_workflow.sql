BEGIN;

-- Create a test claim using existing seeded reports and resident.
INSERT INTO claim (
    lost_report_id,
    found_report_id,
    claimant_id,
    status,
    verification_notes
)
VALUES (
    1,
    1,
    1,
    'pending',
    'Temporary workflow test'
)
RETURNING claim_id
\gset

-- Confirm it appears in the pending claims view.
SELECT claim_id, status
FROM claim
WHERE claim_id = :claim_id;

SELECT claim_id, claimant_name, lost_item_name, found_item_name
FROM v_pending_claims
WHERE claim_id = :claim_id;

-- Approve using the permanent development admin.
SELECT approve_claim(:claim_id, 1);

-- Check reports transitioned to claimed.
SELECT 'lost' AS report_type, status
FROM lost_report
WHERE lost_report_id = 1
UNION ALL
SELECT 'found', status
FROM found_report
WHERE found_report_id = 1;

-- Record physical handover.
SELECT record_handover(
    :claim_id,
    1,
    'resident_id',
    'Workflow test handover'
);

-- Check reports transitioned to closed.
SELECT 'lost' AS report_type, status
FROM lost_report
WHERE lost_report_id = 1
UNION ALL
SELECT 'found', status
FROM found_report
WHERE found_report_id = 1;

-- Verify audit entries were generated.
SELECT table_name, record_id, old_status, new_status
FROM audit_log
ORDER BY changed_at;

-- Undo all test changes, including audit rows.
ROLLBACK;