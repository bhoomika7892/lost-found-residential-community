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