
-- =====================================================================
-- Lost & Found in a Residential Community
-- File: db/queries_reporting.sql
-- Phase: Reporting and Analytics
-- PostgreSQL 16
--
-- PURPOSE:
-- Reporting queries for lost items, found items, categories,
-- locations, blocks and resident activity.
--
-- SAFETY:
-- This file is intended for read-only reporting.
-- Data modifications must be performed through the appropriate
-- application workflows.
--
-- Claim approval and handover must use the protected claims functions.
-- Do not directly change report status to claimed or closed here.
-- =====================================================================


-- ---------------------------------------------------------------------
-- A. DML EXAMPLES (DOCUMENTATION ONLY)
-- ---------------------------------------------------------------------

-- A1. INSERT example: a resident reports a lost item.
-- The application should create the item and lost report together
-- using a transaction and the authenticated resident's identity.
--
-- INSERT INTO public.item
--     (category_id, item_name, color, brand, description)
-- VALUES
--     (4, 'Grey hoodie', 'Grey', 'Nike',
--      'Grey Nike hoodie with a zip and a small ink stain');


-- A2. UPDATE example: correcting an item's colour.
-- Only the appropriate item-editing workflow should perform this.
--
-- UPDATE public.item
-- SET color = 'Dark grey'
-- WHERE item_id = 1;


-- A3. REPORT STATUS:
-- Do not directly close a report using an UPDATE statement.
--
-- Agreed report lifecycle:
-- open / matched -> claimed -> closed
--
-- Approval of a claim changes both reports to claimed.
-- Recording a successful handover changes both reports to closed.


-- A4. DELETE example:
-- Do not execute this against actual project data.
-- Deleting an item may affect related reports through foreign keys.
--
-- DELETE FROM public.item
-- WHERE item_id = 1;


-- A5. Integrity constraint demonstrations (commented examples).
--
-- Invalid resident phone:
-- INSERT INTO public.resident
--     (name, email, phone, apartment_id, password_hash)
-- VALUES
--     ('Test', 'test@example.com', '12345', 1, 'x');
--
-- Invalid lost/report dates:
-- INSERT INTO public.lost_report
--     (item_id, resident_id, location_id, lost_date, reported_date)
-- VALUES
--     (4, 1, 1, '2026-12-01', '2026-10-01');
--
-- Invalid report status:
-- UPDATE public.lost_report
-- SET status = 'lost'
-- WHERE lost_report_id = 1;
--
-- Deleting a block that is referenced by other records:
-- DELETE FROM public.block
-- WHERE block_id = 1;


-- ---------------------------------------------------------------------
-- B. SELECT QUERIES: JOINS
-- ---------------------------------------------------------------------


-- B1. All open and matched lost reports with item, category,
--     resident, location and residential block.
--
-- Concepts: INNER JOIN, LEFT JOIN, COALESCE, ORDER BY.

SELECT
    lr.lost_report_id,
    i.item_name,
    c.category_name,
    r.name AS reported_by,
    l.location_name,
    COALESCE(b.block_name, 'Common area') AS block,
    lr.lost_date,
    lr.status
FROM public.lost_report lr
JOIN public.item i
    ON i.item_id = lr.item_id
JOIN public.category c
    ON c.category_id = i.category_id
JOIN public.resident r
    ON r.resident_id = lr.resident_id
JOIN public.location l
    ON l.location_id = lr.location_id
LEFT JOIN public.block b
    ON b.block_id = l.block_id
WHERE lr.status IN ('open', 'matched')
ORDER BY lr.lost_date DESC;


-- B2. All found reports with item, category, resident and location.
--
-- Concepts: Multiple INNER JOINs.

SELECT
    fr.found_report_id,
    i.item_name,
    c.category_name,
    r.name AS found_by,
    l.location_name,
    fr.found_date,
    fr.status
FROM public.found_report fr
JOIN public.item i
    ON i.item_id = fr.item_id
JOIN public.category c
    ON c.category_id = i.category_id
JOIN public.resident r
    ON r.resident_id = fr.resident_id
JOIN public.location l
    ON l.location_id = fr.location_id
ORDER BY fr.found_date DESC;


-- B3. Category-wise candidate pairs of lost and found items.
--
-- This query identifies possible matches based on category.
-- It does not create a match or change either report's status.
--
-- Both open and matched reports are considered.
--
-- Concepts: JOIN, cross join condition, filtering.

SELECT
    lr.lost_report_id,
    li.item_name AS lost_item,
    fr.found_report_id,
    fi.item_name AS found_item,
    c.category_name,
    lr.status AS lost_status,
    fr.status AS found_status
FROM public.lost_report lr
JOIN public.item li
    ON li.item_id = lr.item_id
JOIN public.found_report fr
    ON TRUE
JOIN public.item fi
    ON fi.item_id = fr.item_id
   AND fi.category_id = li.category_id
JOIN public.category c
    ON c.category_id = li.category_id
WHERE lr.status IN ('open', 'matched')
  AND fr.status IN ('open', 'matched')
ORDER BY c.category_name;


-- ---------------------------------------------------------------------
-- C. GROUP BY / HAVING / AGGREGATE QUERIES
-- ---------------------------------------------------------------------


-- C1. Number of lost reports per category.
--
-- Concepts: COUNT, GROUP BY, ORDER BY.

SELECT
    c.category_name,
    COUNT(*) AS lost_count
FROM public.lost_report lr
JOIN public.item i
    ON i.item_id = lr.item_id
JOIN public.category c
    ON c.category_id = i.category_id
GROUP BY c.category_name
ORDER BY lost_count DESC, c.category_name;


-- C2. Locations with more than one lost or found report.
--
-- Concepts: UNION ALL, JOIN, GROUP BY, HAVING.

SELECT
    l.location_name,
    COUNT(*) AS total_reports
FROM (
    SELECT location_id
    FROM public.lost_report

    UNION ALL

    SELECT location_id
    FROM public.found_report
) r
JOIN public.location l
    ON l.location_id = r.location_id
GROUP BY l.location_name
HAVING COUNT(*) > 1
ORDER BY total_reports DESC;


-- C3. Average delay in days between losing an item
--     and reporting it, grouped by residential block.
--
-- Concepts: AVG, ROUND, LEFT JOIN, GROUP BY.

SELECT
    COALESCE(b.block_name, 'Common area') AS block,
    ROUND(AVG(lr.reported_date - lr.lost_date), 2)
        AS avg_days_to_report,
    COUNT(*) AS reports
FROM public.lost_report lr
JOIN public.location l
    ON l.location_id = lr.location_id
LEFT JOIN public.block b
    ON b.block_id = l.block_id
GROUP BY b.block_name
ORDER BY avg_days_to_report DESC;


-- C4. Number of lost and found reports per block per month.
--
-- Concepts: UNION ALL, TO_CHAR, GROUP BY.
-- Useful for the admin dashboard.

SELECT
    COALESCE(b.block_name, 'Common area') AS block,
    TO_CHAR(r.report_date, 'YYYY-MM') AS month,
    COUNT(*) AS reports
FROM (
    SELECT
        location_id,
        lost_date AS report_date
    FROM public.lost_report

    UNION ALL

    SELECT
        location_id,
        found_date AS report_date
    FROM public.found_report
) r
JOIN public.location l
    ON l.location_id = r.location_id
LEFT JOIN public.block b
    ON b.block_id = l.block_id
GROUP BY
    b.block_name,
    TO_CHAR(r.report_date, 'YYYY-MM')
ORDER BY month, block;


-- ---------------------------------------------------------------------
-- D. SUBQUERIES
-- ---------------------------------------------------------------------


-- D1. Residents who have never reported a lost item.
--
-- Concept: NOT EXISTS correlated subquery.

SELECT
    r.name,
    r.email
FROM public.resident r
WHERE NOT EXISTS (
    SELECT 1
    FROM public.lost_report lr
    WHERE lr.resident_id = r.resident_id
);


-- D2. Residents who have reported both lost and found items.
--
-- Concepts: IN subqueries, scalar subqueries, COUNT.

SELECT
    r.name,

    (
        SELECT COUNT(*)
        FROM public.lost_report lr
        WHERE lr.resident_id = r.resident_id
    ) AS lost_reports,

    (
        SELECT COUNT(*)
        FROM public.found_report fr
        WHERE fr.resident_id = r.resident_id
    ) AS found_reports

FROM public.resident r
WHERE r.resident_id IN (
    SELECT resident_id
    FROM public.lost_report
)
AND r.resident_id IN (
    SELECT resident_id
    FROM public.found_report
);


-- D3. Found items for which nobody has reported a lost item
--     in the same category.
--
-- Concept: NOT EXISTS correlated subquery.

SELECT
    fr.found_report_id,
    i.item_name
FROM public.found_report fr
JOIN public.item i
    ON i.item_id = fr.item_id
WHERE NOT EXISTS (
    SELECT 1
    FROM public.lost_report lr
    JOIN public.item li
        ON li.item_id = lr.item_id
    WHERE li.category_id = i.category_id
);


-- D4. Residential block with the highest number of reports.
--
-- Concepts: Subquery in FROM, UNION ALL, GROUP BY, LIMIT.

SELECT
    block,
    reports
FROM (
    SELECT
        COALESCE(b.block_name, 'Common area') AS block,
        COUNT(*) AS reports
    FROM (
        SELECT location_id
        FROM public.lost_report

        UNION ALL

        SELECT location_id
        FROM public.found_report
    ) r
    JOIN public.location l
        ON l.location_id = r.location_id
    LEFT JOIN public.block b
        ON b.block_id = l.block_id
    GROUP BY b.block_name
) t
ORDER BY reports DESC
LIMIT 1;


-- =====================================================================
-- END OF REPORTING QUERIES
--
-- All executable statements in this file are SELECT statements.
-- DML examples are intentionally commented out.
-- =====================================================================
