-- =====================================================================
-- File: db/queries_reporting.sql   (Phase 2 - DML + important queries)
-- Run after schema_reporting.sql and seed_reporting.sql.
-- Each query has a comment saying WHAT it answers and WHICH concept it shows
-- (useful for the report and the viva).
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. DML: INSERT / UPDATE / DELETE
-- ---------------------------------------------------------------------

-- A1. INSERT: a resident reports a lost item (item first, then the report)
INSERT INTO item (category_id, item_name, color, brand, description)
VALUES (4, 'Grey hoodie', 'Grey', 'Nike', 'Grey Nike hoodie with a zip and a small ink stain on the left sleeve');

INSERT INTO lost_report (item_id, resident_id, location_id, lost_date)
VALUES (currval('item_item_id_seq'), 3, 7, CURRENT_DATE);

-- A2. UPDATE: a resident corrects the item colour
UPDATE item
SET    color = 'Dark grey'
WHERE  item_id = currval('item_item_id_seq');

-- A3. UPDATE: close a report
UPDATE lost_report
SET    status = 'closed'
WHERE  item_id = currval('item_item_id_seq');

-- A4. DELETE: remove the test report and its item (item delete cascades to the report)
DELETE FROM item WHERE item_id = currval('item_item_id_seq');

-- A5. Integrity demo: these must FAIL (show them in the demo)
--   a) bad phone number          -> violates CHECK on resident.phone
--   b) lost date after report    -> violates chk_lost_dates
--   c) invalid status            -> violates CHECK on status
--   d) delete a block in use     -> violates FK (ON DELETE RESTRICT)
-- INSERT INTO resident (name,email,phone,apartment_id,password_hash)
--        VALUES ('Test','t@example.com','12345',1,'x');
-- INSERT INTO lost_report (item_id,resident_id,location_id,lost_date,reported_date)
--        VALUES (4,1,1,'2026-12-01','2026-10-01');
-- UPDATE lost_report SET status = 'lost' WHERE lost_report_id = 1;
-- DELETE FROM block WHERE block_id = 1;

-- ---------------------------------------------------------------------
-- B. SELECT: JOIN
-- ---------------------------------------------------------------------

-- B1. All open lost reports with item, category, resident, place and block
--     (5-table INNER JOIN + LEFT JOIN for shared areas that have no block)
SELECT lr.lost_report_id,
       i.item_name,
       c.category_name,
       r.name         AS reported_by,
       l.location_name,
       COALESCE(b.block_name, 'Common area') AS block,
       lr.lost_date
FROM   lost_report lr
JOIN   item     i ON i.item_id     = lr.item_id
JOIN   category c ON c.category_id = i.category_id
JOIN   resident r ON r.resident_id = lr.resident_id
JOIN   location l ON l.location_id = lr.location_id
LEFT JOIN block b ON b.block_id    = l.block_id
WHERE  lr.status = 'open'
ORDER  BY lr.lost_date DESC;

-- B2. Same for found reports: who found what, where
SELECT fr.found_report_id, i.item_name, c.category_name,
       r.name AS found_by, l.location_name, fr.found_date
FROM   found_report fr
JOIN   item     i ON i.item_id     = fr.item_id
JOIN   category c ON c.category_id = i.category_id
JOIN   resident r ON r.resident_id = fr.resident_id
JOIN   location l ON l.location_id = fr.location_id
ORDER  BY fr.found_date DESC;

-- B3. Category-wise candidate pairs: lost and found items of the same category
--     (self-style join across the two report tables; basis for the matching idea)
SELECT lr.lost_report_id, li.item_name AS lost_item,
       fr.found_report_id, fi.item_name AS found_item,
       c.category_name
FROM   lost_report  lr
JOIN   item li ON li.item_id = lr.item_id
JOIN   found_report fr ON TRUE
JOIN   item fi ON fi.item_id = fr.item_id AND fi.category_id = li.category_id
JOIN   category c ON c.category_id = li.category_id
WHERE  lr.status = 'open' AND fr.status = 'open'
ORDER  BY c.category_name;

-- ---------------------------------------------------------------------
-- C. GROUP BY / HAVING / aggregates
-- ---------------------------------------------------------------------

-- C1. Number of lost reports per category, most lost first
SELECT c.category_name, COUNT(*) AS lost_count
FROM   lost_report lr
JOIN   item i     ON i.item_id = lr.item_id
JOIN   category c ON c.category_id = i.category_id
GROUP  BY c.category_name
ORDER  BY lost_count DESC, c.category_name;

-- C2. Locations where more than one item was lost or found (HAVING)
SELECT l.location_name, COUNT(*) AS total_reports
FROM  (SELECT location_id FROM lost_report
       UNION ALL
       SELECT location_id FROM found_report) r
JOIN   location l ON l.location_id = r.location_id
GROUP  BY l.location_name
HAVING COUNT(*) > 1
ORDER  BY total_reports DESC;

-- C3. Average delay (days) between losing an item and reporting it, per block
SELECT COALESCE(b.block_name, 'Common area') AS block,
       ROUND(AVG(lr.reported_date - lr.lost_date), 2) AS avg_days_to_report,
       COUNT(*) AS reports
FROM   lost_report lr
JOIN   location l ON l.location_id = lr.location_id
LEFT JOIN block b ON b.block_id = l.block_id
GROUP  BY b.block_name
ORDER  BY avg_days_to_report DESC;

-- C4. Reports per block per month (lost + found), for the admin dashboard chart
SELECT COALESCE(b.block_name, 'Common area') AS block,
       TO_CHAR(r.d, 'YYYY-MM') AS month,
       COUNT(*) AS reports
FROM  (SELECT location_id, lost_date  AS d FROM lost_report
       UNION ALL
       SELECT location_id, found_date AS d FROM found_report) r
JOIN   location l ON l.location_id = r.location_id
LEFT JOIN block b ON b.block_id = l.block_id
GROUP  BY b.block_name, TO_CHAR(r.d, 'YYYY-MM')
ORDER  BY month, block;

-- ---------------------------------------------------------------------
-- D. Subqueries
-- ---------------------------------------------------------------------

-- D1. Residents who have never reported anything lost (NOT IN subquery)
SELECT name, email
FROM   resident
WHERE  resident_id NOT IN (SELECT resident_id FROM lost_report);

-- D2. Residents who have reported BOTH a lost item and a found item (IN subqueries)
SELECT r.name,
       (SELECT COUNT(*) FROM lost_report  lr WHERE lr.resident_id = r.resident_id) AS lost_reports,
       (SELECT COUNT(*) FROM found_report fr WHERE fr.resident_id = r.resident_id) AS found_reports
FROM   resident r
WHERE  r.resident_id IN (SELECT resident_id FROM lost_report)
  AND  r.resident_id IN (SELECT resident_id FROM found_report);

-- D3. Found items nobody has reported lost in the same category (NOT EXISTS, correlated)
SELECT fr.found_report_id, i.item_name
FROM   found_report fr
JOIN   item i ON i.item_id = fr.item_id
WHERE  NOT EXISTS (SELECT 1
                   FROM lost_report lr
                   JOIN item li ON li.item_id = lr.item_id
                   WHERE li.category_id = i.category_id);

-- D4. Block with the highest number of reports (subquery in FROM)
SELECT block, reports
FROM  (SELECT COALESCE(b.block_name, 'Common area') AS block, COUNT(*) AS reports
       FROM  (SELECT location_id FROM lost_report
              UNION ALL SELECT location_id FROM found_report) r
       JOIN location l ON l.location_id = r.location_id
       LEFT JOIN block b ON b.block_id = l.block_id
       GROUP BY b.block_name) t
ORDER  BY reports DESC
LIMIT  1;
