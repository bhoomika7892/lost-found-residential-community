-- =====================================================================
-- Lost & Found System - Advanced Reporting and Vector Features
-- File: db/advanced_reporting.sql
-- PostgreSQL 16 + pgvector (>= 0.5 for HNSW)
--
-- PURPOSE:
--   1. Vector (HNSW) and full-text (GIN) indexes.
--   2. Vector READ    : similarity search for a lost report.
--   3. Vector UPDATE  : trigger that invalidates a stale embedding and
--                       its derived matches when item text changes.
--   4. Vector DELETE  : withdraw a report (removes its embedding and
--                       matches) and a purge procedure for closed items.
--   5. Advanced queries: recursive CTE, window functions, LATERAL.
--
-- RUN ORDER: after schema_reporting.sql, schema_claims.sql, triggers.sql.
-- This file is safe to run more than once.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. INDEXES
-- ---------------------------------------------------------------------

-- Approximate nearest-neighbour index for cosine distance (<=>).
-- At very small data sizes PostgreSQL may still choose a sequential
-- scan; the index matters as the number of items grows.
CREATE INDEX IF NOT EXISTS idx_item_embedding_hnsw
    ON public.item
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- Text used for full-text search. IMMUTABLE so it can back an index.
CREATE OR REPLACE FUNCTION public.item_search_text(
    p_name  TEXT,
    p_color TEXT,
    p_brand TEXT,
    p_desc  TEXT
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT coalesce(p_name, '')  || ' ' ||
           coalesce(p_color, '') || ' ' ||
           coalesce(p_brand, '') || ' ' ||
           coalesce(p_desc, '');
$$;

CREATE INDEX IF NOT EXISTS idx_item_fulltext
    ON public.item
    USING gin (
        to_tsvector(
            'english',
            public.item_search_text(item_name, color, brand, description)
        )
    );


-- ---------------------------------------------------------------------
-- 2. READ: similarity and keyword search
-- ---------------------------------------------------------------------

-- Open/matched found items ranked by semantic similarity to one lost
-- report (cosine similarity, 0..1, higher = more similar).
CREATE OR REPLACE FUNCTION public.find_similar_found_items(
    p_lost_report_id INT,
    p_limit          INT DEFAULT 5
)
RETURNS TABLE (
    found_report_id INT,
    item_name       VARCHAR,
    category_name   VARCHAR,
    similarity      NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        fr.found_report_id,
        fi.item_name,
        c.category_name,
        ROUND(
            GREATEST(0, LEAST(1, 1 - (fi.embedding <=> li.embedding)))::numeric,
            4
        ) AS similarity
    FROM public.lost_report lr
    JOIN public.item li          ON li.item_id = lr.item_id
    JOIN public.found_report fr  ON fr.status IN ('open', 'matched')
    JOIN public.item fi          ON fi.item_id = fr.item_id
    JOIN public.category c       ON c.category_id = fi.category_id
    WHERE lr.lost_report_id = p_lost_report_id
      AND li.embedding IS NOT NULL
      AND fi.embedding IS NOT NULL
    ORDER BY fi.embedding <=> li.embedding
    LIMIT GREATEST(p_limit, 1);
$$;

-- Keyword search over item name, colour, brand and description.
CREATE OR REPLACE FUNCTION public.search_items_fulltext(
    p_query TEXT,
    p_limit INT DEFAULT 10
)
RETURNS TABLE (
    item_id   INT,
    item_name VARCHAR,
    rank      REAL
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        i.item_id,
        i.item_name,
        ts_rank(
            to_tsvector('english',
                public.item_search_text(i.item_name, i.color, i.brand, i.description)),
            plainto_tsquery('english', p_query)
        ) AS rank
    FROM public.item i
    WHERE to_tsvector('english',
              public.item_search_text(i.item_name, i.color, i.brand, i.description))
          @@ plainto_tsquery('english', p_query)
    ORDER BY rank DESC, i.item_id
    LIMIT GREATEST(p_limit, 1);
$$;


-- ---------------------------------------------------------------------
-- 3. UPDATE: keep vectors honest
-- When the text that was embedded changes, the stored vector no longer
-- describes the item. Clear it and delete the matches derived from it.
-- The embedding script (--missing-only) then regenerates it.
-- Fires only when a text column appears in the UPDATE, so writing the
-- embedding column itself does not trigger it.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.clear_stale_embedding()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.item_name   IS DISTINCT FROM OLD.item_name
       OR NEW.color       IS DISTINCT FROM OLD.color
       OR NEW.brand       IS DISTINCT FROM OLD.brand
       OR NEW.description IS DISTINCT FROM OLD.description THEN

        NEW.embedding := NULL;

        DELETE FROM public.match
        WHERE lost_report_id IN (
                SELECT lr.lost_report_id
                FROM public.lost_report lr
                WHERE lr.item_id = NEW.item_id
              )
           OR found_report_id IN (
                SELECT fr.found_report_id
                FROM public.found_report fr
                WHERE fr.item_id = NEW.item_id
              );
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_item_text_changed ON public.item;

CREATE TRIGGER trg_item_text_changed
    BEFORE UPDATE OF item_name, color, brand, description ON public.item
    FOR EACH ROW
    EXECUTE FUNCTION public.clear_stale_embedding();

-- Items that still need an embedding (new rows or cleared by the trigger).
CREATE OR REPLACE VIEW public.v_items_missing_embedding AS
SELECT i.item_id, i.item_name, i.color, i.brand, i.description
FROM public.item i
WHERE i.embedding IS NULL;


-- ---------------------------------------------------------------------
-- 4. DELETE: withdraw a report / purge closed vectors
-- ---------------------------------------------------------------------

-- A resident withdraws their own lost report. Deleting the item row
-- removes the report (ON DELETE CASCADE), its matches (cascade) and
-- the embedding stored in the item row.
CREATE OR REPLACE FUNCTION public.withdraw_lost_report(
    p_lost_report_id INT,
    p_resident_id    INT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_item_id INT;
    v_owner   INT;
    v_status  VARCHAR(10);
    v_matches INT;
BEGIN
    SELECT item_id, resident_id, status
    INTO v_item_id, v_owner, v_status
    FROM public.lost_report
    WHERE lost_report_id = p_lost_report_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Lost report % does not exist', p_lost_report_id;
    END IF;

    IF v_owner <> p_resident_id THEN
        RAISE EXCEPTION 'Only the resident who filed a report can withdraw it';
    END IF;

    IF v_status NOT IN ('open', 'matched') THEN
        RAISE EXCEPTION
            'Only open or matched reports can be withdrawn (current status: %)',
            v_status;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.claim WHERE lost_report_id = p_lost_report_id
    ) THEN
        RAISE EXCEPTION 'This report has claims and cannot be withdrawn';
    END IF;

    SELECT COUNT(*) INTO v_matches
    FROM public.match
    WHERE lost_report_id = p_lost_report_id;

    DELETE FROM public.item WHERE item_id = v_item_id;

    RETURN format(
        'Lost report withdrawn. Its embedding and %s suggested match(es) were removed.',
        v_matches
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.withdraw_found_report(
    p_found_report_id INT,
    p_resident_id     INT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_item_id INT;
    v_owner   INT;
    v_status  VARCHAR(10);
    v_matches INT;
BEGIN
    SELECT item_id, resident_id, status
    INTO v_item_id, v_owner, v_status
    FROM public.found_report
    WHERE found_report_id = p_found_report_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Found report % does not exist', p_found_report_id;
    END IF;

    IF v_owner <> p_resident_id THEN
        RAISE EXCEPTION 'Only the resident who filed a report can withdraw it';
    END IF;

    IF v_status NOT IN ('open', 'matched') THEN
        RAISE EXCEPTION
            'Only open or matched reports can be withdrawn (current status: %)',
            v_status;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.claim WHERE found_report_id = p_found_report_id
    ) THEN
        RAISE EXCEPTION 'This report has claims and cannot be withdrawn';
    END IF;

    SELECT COUNT(*) INTO v_matches
    FROM public.match
    WHERE found_report_id = p_found_report_id;

    DELETE FROM public.item WHERE item_id = v_item_id;

    RETURN format(
        'Found report withdrawn. Its embedding and %s suggested match(es) were removed.',
        v_matches
    );
END;
$$;

-- Housekeeping: once a report is claimed or closed its suggested
-- matches and vector are no longer needed.
CREATE OR REPLACE PROCEDURE public.purge_closed_report_vectors()
LANGUAGE plpgsql
AS $$
DECLARE
    v_matches INT;
    v_vectors INT;
BEGIN
    DELETE FROM public.match m
    USING public.lost_report lr, public.found_report fr
    WHERE m.lost_report_id  = lr.lost_report_id
      AND m.found_report_id = fr.found_report_id
      AND (lr.status IN ('claimed', 'closed')
           OR fr.status IN ('claimed', 'closed'));

    GET DIAGNOSTICS v_matches = ROW_COUNT;

    UPDATE public.item i
    SET embedding = NULL
    WHERE i.embedding IS NOT NULL
      AND (
            EXISTS (SELECT 1 FROM public.lost_report lr
                    WHERE lr.item_id = i.item_id
                      AND lr.status IN ('claimed', 'closed'))
         OR EXISTS (SELECT 1 FROM public.found_report fr
                    WHERE fr.item_id = i.item_id
                      AND fr.status IN ('claimed', 'closed'))
      );

    GET DIAGNOSTICS v_vectors = ROW_COUNT;

    RAISE NOTICE 'Purged % match(es) and % embedding(s)', v_matches, v_vectors;
END;
$$;

COMMIT;


-- =====================================================================
-- 5. ADVANCED QUERIES (read-only)
-- =====================================================================

-- Q1. Reports per day for the last 14 days, including days with none.
-- Concepts: RECURSIVE CTE, second CTE, LEFT JOIN, running total (window).
WITH RECURSIVE days(day) AS (
    SELECT CURRENT_DATE - 13
    UNION ALL
    SELECT day + 1 FROM days WHERE day < CURRENT_DATE
),
daily AS (
    SELECT reported_date AS day, COUNT(*) AS n
    FROM (
        SELECT reported_date FROM public.lost_report
        UNION ALL
        SELECT reported_date FROM public.found_report
    ) r
    GROUP BY reported_date
)
SELECT
    d.day,
    COALESCE(x.n, 0) AS reports,
    SUM(COALESCE(x.n, 0)) OVER (ORDER BY d.day) AS running_total
FROM days d
LEFT JOIN daily x ON x.day = d.day
ORDER BY d.day;


-- Q2. Category popularity with rank and share of all reports.
-- Concepts: RANK() window, SUM() OVER () for percentage.
SELECT
    c.category_name,
    COUNT(*) AS reports,
    RANK() OVER (ORDER BY COUNT(*) DESC) AS popularity_rank,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS percent_of_reports
FROM (
    SELECT item_id FROM public.lost_report
    UNION ALL
    SELECT item_id FROM public.found_report
) r
JOIN public.item i     ON i.item_id = r.item_id
JOIN public.category c ON c.category_id = i.category_id
GROUP BY c.category_name
ORDER BY popularity_rank, c.category_name;


-- Q3. Best semantic found-item candidate for every open lost report.
-- Concepts: LATERAL correlated subquery, vector distance, LIMIT 1.
-- Needs embeddings (run scripts/generate_embeddings.py first).
SELECT
    lr.lost_report_id,
    li.item_name AS lost_item,
    best.item_name AS best_found_item,
    best.similarity
FROM public.lost_report lr
JOIN public.item li ON li.item_id = lr.item_id
CROSS JOIN LATERAL (
    SELECT
        fi.item_name,
        ROUND((1 - (fi.embedding <=> li.embedding))::numeric, 4) AS similarity
    FROM public.found_report fr
    JOIN public.item fi ON fi.item_id = fr.item_id
    WHERE fr.status IN ('open', 'matched')
      AND fi.embedding IS NOT NULL
    ORDER BY fi.embedding <=> li.embedding
    LIMIT 1
) best
WHERE lr.status = 'open'
  AND li.embedding IS NOT NULL
ORDER BY best.similarity DESC;
