-- =====================================================================
-- Lost & Found System for a Residential Community
-- File    : db/schema_reporting.sql      (Phase 1 - Ashritha's half)
-- Contents: Block, Apartment, Resident, Category, Item, Location,
--           Lost_Report, Found_Report, Match
-- Run order: this file FIRST, then schema_claims.sql
-- Database : PostgreSQL 16 + pgvector
-- =====================================================================

-- ---------- Extensions ----------
CREATE EXTENSION IF NOT EXISTS vector;     -- vector similarity search (Phase 3)
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- password hashing in seed data (bcrypt)

-- ---------- DROP (makes the script re-runnable; also demonstrates DROP) ----------
DROP TABLE IF EXISTS match        CASCADE;
DROP TABLE IF EXISTS found_report CASCADE;
DROP TABLE IF EXISTS lost_report  CASCADE;
DROP TABLE IF EXISTS item         CASCADE;
DROP TABLE IF EXISTS category     CASCADE;
DROP TABLE IF EXISTS location     CASCADE;
DROP TABLE IF EXISTS resident     CASCADE;
DROP TABLE IF EXISTS apartment    CASCADE;
DROP TABLE IF EXISTS block        CASCADE;

-- =====================================================================
-- CREATE TABLES
-- =====================================================================

-- BLOCK: a residential tower/building
CREATE TABLE block (
    block_id     SERIAL       PRIMARY KEY,
    block_name   VARCHAR(50)  NOT NULL UNIQUE,
    total_floors INT          NOT NULL CHECK (total_floors > 0)
);

-- APARTMENT: belongs to exactly one block (Block 1 --- N Apartment)
CREATE TABLE apartment (
    apartment_id SERIAL      PRIMARY KEY,
    apartment_no VARCHAR(10) NOT NULL,
    floor_no     INT         NOT NULL CHECK (floor_no >= 0),
    block_id     INT         NOT NULL REFERENCES block(block_id)
                             ON UPDATE CASCADE ON DELETE RESTRICT,
    -- the same flat number cannot repeat inside one block
    CONSTRAINT uq_apartment_per_block UNIQUE (block_id, apartment_no)
);

-- RESIDENT: lives in one apartment (Apartment 1 --- N Resident)
-- password is stored only as a bcrypt hash, never as plain text
CREATE TABLE resident (
    resident_id     SERIAL       PRIMARY KEY,
    name            VARCHAR(100) NOT NULL,
    email           VARCHAR(120) NOT NULL UNIQUE
                    CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    phone           VARCHAR(10)  NOT NULL CHECK (phone ~ '^[0-9]{10}$'),
    resident_status VARCHAR(10)  NOT NULL DEFAULT 'active'
                    CHECK (resident_status IN ('active', 'inactive')),
    apartment_id    INT          NOT NULL REFERENCES apartment(apartment_id)
                                 ON UPDATE CASCADE ON DELETE RESTRICT,
    password_hash   TEXT         NOT NULL
);

-- CATEGORY: Electronics, Keys, Wallets & Bags ...
CREATE TABLE category (
    category_id   SERIAL      PRIMARY KEY,
    category_name VARCHAR(60) NOT NULL UNIQUE
);

-- ITEM: description of a physical object. Each lost/found report points to one item.
-- 'embedding' holds the semantic vector of the item text (filled in Phase 3).
-- 384 = output size of the all-MiniLM-L6-v2 sentence-embedding model.
CREATE TABLE item (
    item_id     SERIAL       PRIMARY KEY,
    category_id INT          NOT NULL REFERENCES category(category_id)
                             ON UPDATE CASCADE ON DELETE RESTRICT,
    item_name   VARCHAR(100) NOT NULL,
    color       VARCHAR(40),
    brand       VARCHAR(60),
    description TEXT,
    embedding   vector(384)
);

-- LOCATION: where something was lost/found (a place inside a block, or a common area)
CREATE TABLE location (
    location_id   SERIAL       PRIMARY KEY,
    location_name VARCHAR(80)  NOT NULL,
    location_type VARCHAR(20)  NOT NULL
                  CHECK (location_type IN ('lobby', 'lift', 'parking', 'garden',
                                           'clubhouse', 'gym', 'gate', 'other')),
    block_id      INT          REFERENCES block(block_id)
                               ON UPDATE CASCADE ON DELETE SET NULL  -- NULL = shared area
);

-- LOST_REPORT: a resident reports losing an item
-- status flow: open -> matched -> claimed -> closed
CREATE TABLE lost_report (
    lost_report_id SERIAL      PRIMARY KEY,
    item_id        INT         NOT NULL UNIQUE REFERENCES item(item_id)
                               ON DELETE CASCADE,          -- one item = one report
    resident_id    INT         NOT NULL REFERENCES resident(resident_id)
                               ON DELETE RESTRICT,
    location_id    INT         NOT NULL REFERENCES location(location_id)
                               ON DELETE RESTRICT,
    lost_date      DATE        NOT NULL,
    reported_date  DATE        NOT NULL DEFAULT CURRENT_DATE,
    status         VARCHAR(10) NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open', 'matched', 'claimed', 'closed')),
    -- cannot report an item as lost after the day you reported it, nor lose it in the future
    CONSTRAINT chk_lost_dates CHECK (lost_date <= reported_date)
);

-- FOUND_REPORT: a resident hands in / reports a found item
CREATE TABLE found_report (
    found_report_id SERIAL      PRIMARY KEY,
    item_id         INT         NOT NULL UNIQUE REFERENCES item(item_id)
                                ON DELETE CASCADE,
    resident_id     INT         NOT NULL REFERENCES resident(resident_id)
                                ON DELETE RESTRICT,      -- the finder
    location_id     INT         NOT NULL REFERENCES location(location_id)
                                ON DELETE RESTRICT,
    found_date      DATE        NOT NULL,
    reported_date   DATE        NOT NULL DEFAULT CURRENT_DATE,
    status          VARCHAR(10) NOT NULL DEFAULT 'open'
                    CHECK (status IN ('open', 'matched', 'claimed', 'closed')),
    CONSTRAINT chk_found_dates CHECK (found_date <= reported_date)
);

-- MATCH: a suggested pairing of one lost report with one found report
--   similarity_score = cosine similarity of the two item embeddings (0..1)
--   match_score      = final weighted score out of 100 (text similarity + same category
--                      + same block); calculated by the matching function in Phase 3
CREATE TABLE match (
    match_id         SERIAL       PRIMARY KEY,
    lost_report_id   INT          NOT NULL REFERENCES lost_report(lost_report_id)
                                  ON DELETE CASCADE,
    found_report_id  INT          NOT NULL REFERENCES found_report(found_report_id)
                                  ON DELETE CASCADE,
    similarity_score NUMERIC(5,4) NOT NULL CHECK (similarity_score BETWEEN 0 AND 1),
    match_score      NUMERIC(5,2) NOT NULL CHECK (match_score BETWEEN 0 AND 100),
    generated_at     TIMESTAMP    NOT NULL DEFAULT NOW(),
    -- the same pair must never be suggested twice
    CONSTRAINT uq_match_pair UNIQUE (lost_report_id, found_report_id)
);

-- =====================================================================
-- ALTER examples (change structure after creation)
-- =====================================================================

-- 1. add a new column
ALTER TABLE resident ADD COLUMN registered_on DATE NOT NULL DEFAULT CURRENT_DATE;

-- 2. add a constraint to an existing table
ALTER TABLE location
    ADD CONSTRAINT uq_location_in_block UNIQUE (location_name, block_id);

-- 3. add a temporary column and drop it again (shows ALTER ... DROP COLUMN)
ALTER TABLE item ADD COLUMN temp_note TEXT;
ALTER TABLE item DROP COLUMN temp_note;

-- =====================================================================
-- Basic indexes (speed up joins and the most common filters)
-- Full-text and vector indexes are added in Phase 3 (db/advanced_reporting.sql)
-- =====================================================================
CREATE INDEX idx_apartment_block     ON apartment(block_id);
CREATE INDEX idx_resident_apartment  ON resident(apartment_id);
CREATE INDEX idx_item_category       ON item(category_id);
CREATE INDEX idx_location_block      ON location(block_id);
CREATE INDEX idx_lost_resident       ON lost_report(resident_id);
CREATE INDEX idx_lost_location       ON lost_report(location_id);
CREATE INDEX idx_lost_status         ON lost_report(status);
CREATE INDEX idx_found_resident      ON found_report(resident_id);
CREATE INDEX idx_found_location      ON found_report(location_id);
CREATE INDEX idx_found_status        ON found_report(status);
CREATE INDEX idx_match_lost          ON match(lost_report_id);
CREATE INDEX idx_match_found         ON match(found_report_id);
