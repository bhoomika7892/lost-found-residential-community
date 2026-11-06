-- =====================================================================
-- Lost & Found System - Runnable DML and Vector RUD Demonstration
-- File: db/dml_demo.sql
-- Run with psql (uses \gset):
--     psql -U lostfound_user -d lost_found_db -f db/dml_demo.sql
--
-- Everything runs inside one transaction that ends in ROLLBACK, so
-- your real data is never changed. Remove the final ROLLBACK (and use
-- COMMIT) only if you want the demo rows to stay.
--
-- Needs: schema_reporting, seed_reporting, schema_claims, triggers,
--        advanced_reporting already loaded.
-- =====================================================================

\set ON_ERROR_STOP on
\pset null '(null)'

BEGIN;

-- ---------------------------------------------------------------------
-- A. INSERT
-- ---------------------------------------------------------------------

\echo '--- A1. INSERT a lost item and its report (data-modifying CTE)'

WITH new_item AS (
    INSERT INTO public.item (category_id, item_name, color, brand, description)
    SELECT category_id, 'Black umbrella', 'Black', 'Fabric',
           'Folding umbrella left in the lift'
    FROM public.category
    ORDER BY category_id
    LIMIT 1
    RETURNING item_id
)
INSERT INTO public.lost_report (item_id, resident_id, location_id, lost_date)
SELECT ni.item_id,
       (SELECT MIN(resident_id) FROM public.resident),
       (SELECT MIN(location_id) FROM public.location),
       CURRENT_DATE - 1
FROM new_item ni
RETURNING lost_report_id AS lost_report, item_id AS lost_item
\gset demo_

\echo '--- A2. INSERT two found items and their reports'

WITH new_item AS (
    INSERT INTO public.item (category_id, item_name, color, brand, description)
    SELECT category_id, 'Umbrella', 'Black', NULL,
           'Black folding umbrella found near the lift'
    FROM public.category
    ORDER BY category_id
    LIMIT 1
    RETURNING item_id
)
INSERT INTO public.found_report (item_id, resident_id, location_id, found_date)
SELECT ni.item_id,
       (SELECT MAX(resident_id) FROM public.resident),
       (SELECT MIN(location_id) FROM public.location),
       CURRENT_DATE
FROM new_item ni
RETURNING found_report_id AS found_report, item_id AS found_item
\gset demo_

WITH new_item AS (
    INSERT INTO public.item (category_id, item_name, color, brand, description)
    SELECT category_id, 'Silver key', 'Silver', NULL,
           'Single silver door key on a ring'
    FROM public.category
    ORDER BY category_id
    LIMIT 1
    RETURNING item_id
)
INSERT INTO public.found_report (item_id, resident_id, location_id, found_date)
SELECT ni.item_id,
       (SELECT MAX(resident_id) FROM public.resident),
       (SELECT MIN(location_id) FROM public.location),
       CURRENT_DATE
FROM new_item ni
RETURNING found_report_id AS key_report, item_id AS key_item
\gset demo_


-- ---------------------------------------------------------------------
-- B. UPDATE
-- ---------------------------------------------------------------------

\echo '--- B1. UPDATE a column and show the new row (RETURNING)'

UPDATE public.item
SET color = 'Navy'
WHERE item_id = :demo_lost_item
RETURNING item_id, item_name, color;

\echo '--- B2. UPDATE with a subquery: set the lost date a day earlier'

UPDATE public.lost_report
SET lost_date = lost_date - 1
WHERE item_id IN (
    SELECT item_id FROM public.item WHERE item_id = :demo_lost_item
)
RETURNING lost_report_id, lost_date, reported_date;


-- ---------------------------------------------------------------------
-- C. VECTOR: CREATE (stand-in embeddings), READ, UPDATE, DELETE
-- In the real app embeddings come from scripts/generate_embeddings.py.
-- Here unit vectors stand in so the demo needs no Python:
--   umbrella (lost) and umbrella (found) point the same way (similarity 1)
--   the key points a different way (similarity 0)
-- ---------------------------------------------------------------------

\echo '--- C1. CREATE: store embeddings in item.embedding'

UPDATE public.item
SET embedding = ARRAY(SELECT CASE WHEN g = 1 THEN 1 ELSE 0 END
                      FROM generate_series(1, 384) g)::int[]::vector(384)
WHERE item_id IN (:demo_lost_item, :demo_found_item);

UPDATE public.item
SET embedding = ARRAY(SELECT CASE WHEN g = 2 THEN 1 ELSE 0 END
                      FROM generate_series(1, 384) g)::int[]::vector(384)
WHERE item_id = :demo_key_item;

\echo '--- C2. READ: most similar found items for the demo lost report'

SELECT * FROM public.find_similar_found_items(:demo_lost_report, 3);

\echo '--- C2b. READ: keyword search'

SELECT * FROM public.search_items_fulltext('umbrella');

\echo '--- C3. UPDATE: a suggested match exists, then the item text changes'

INSERT INTO public.match (lost_report_id, found_report_id, similarity_score, match_score)
VALUES (:demo_lost_report, :demo_found_report, 1.0000, 95.00);

SELECT COUNT(*) AS matches_before
FROM public.match
WHERE lost_report_id = :demo_lost_report;

UPDATE public.item
SET description = 'Folding umbrella with a wooden handle'
WHERE item_id = :demo_lost_item;

SELECT
    (SELECT embedding IS NULL FROM public.item
     WHERE item_id = :demo_lost_item) AS vector_cleared,
    (SELECT COUNT(*) FROM public.match
     WHERE lost_report_id = :demo_lost_report) AS matches_after,
    EXISTS (SELECT 1 FROM public.v_items_missing_embedding
            WHERE item_id = :demo_lost_item) AS queued_for_reembedding;

\echo '--- C4. DELETE: only the owner may withdraw (wrong resident is refused)'

DO $$
BEGIN
    PERFORM public.withdraw_lost_report(
        (SELECT MAX(lost_report_id) FROM public.lost_report),
        -1
    );
EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'Refused as expected: %', SQLERRM;
END $$;

\echo '--- C5. DELETE: the owner withdraws the report (vector + matches go too)'

SELECT public.withdraw_lost_report(
    :demo_lost_report,
    (SELECT resident_id FROM public.lost_report
     WHERE lost_report_id = :demo_lost_report)
) AS result;

SELECT
    EXISTS (SELECT 1 FROM public.lost_report
            WHERE lost_report_id = :demo_lost_report) AS report_still_exists,
    EXISTS (SELECT 1 FROM public.item
            WHERE item_id = :demo_lost_item) AS item_still_exists,
    (SELECT COUNT(*) FROM public.match
     WHERE lost_report_id = :demo_lost_report) AS matches_left;

\echo '--- C6. DELETE (bulk): purge vectors and matches of closed reports'

CALL public.purge_closed_report_vectors();


-- ---------------------------------------------------------------------
-- D. DELETE (plain SQL)
-- ---------------------------------------------------------------------

\echo '--- D1. DELETE a found report by deleting its item (ON DELETE CASCADE)'

DELETE FROM public.item
WHERE item_id = :demo_key_item
RETURNING item_id, item_name;

SELECT EXISTS (SELECT 1 FROM public.found_report
               WHERE found_report_id = :demo_key_report) AS key_report_still_exists;


-- ---------------------------------------------------------------------
-- E. Integrity constraints reject bad data (each caught so the
--    transaction keeps going)
-- ---------------------------------------------------------------------

\echo '--- E1. Invalid phone number (CHECK)'

DO $$
BEGIN
    INSERT INTO public.resident (name, email, phone, apartment_id, password_hash)
    VALUES ('Test', 'test@example.com', '12345',
            (SELECT MIN(apartment_id) FROM public.apartment), 'x');
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END $$;

\echo '--- E2. lost_date after reported_date (CHECK)'

DO $$
BEGIN
    INSERT INTO public.lost_report (item_id, resident_id, location_id, lost_date, reported_date)
    SELECT MIN(item_id), (SELECT MIN(resident_id) FROM public.resident),
           (SELECT MIN(location_id) FROM public.location),
           '2099-12-01', '2026-10-01'
    FROM public.item;
EXCEPTION WHEN check_violation OR unique_violation THEN
    RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END $$;

\echo '--- E3. Deleting a block that other rows reference (FOREIGN KEY RESTRICT)'

DO $$
BEGIN
    DELETE FROM public.block
    WHERE block_id = (SELECT MIN(block_id) FROM public.block);
EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END $$;

\echo '--- E4. Direct status change is blocked by the report guard trigger'

DO $$
BEGIN
    UPDATE public.found_report
    SET status = 'closed'
    WHERE found_report_id = (SELECT MIN(found_report_id) FROM public.found_report);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END $$;

-- Nothing above is kept.
ROLLBACK;

\echo 'Demo finished. All changes were rolled back.'
