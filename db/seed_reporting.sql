-- =====================================================================
-- File: db/seed_reporting.sql   (Phase 2 - sample data)
-- Run AFTER schema_reporting.sql.
-- All demo passwords are 'Password@123', stored as bcrypt hashes (pgcrypto).
-- Item embeddings stay NULL here; Phase 3 fills them using the embedding script.
-- =====================================================================

INSERT INTO block (block_name, total_floors) VALUES
    ('Block A', 10),
    ('Block B', 8),
    ('Block C', 12);

INSERT INTO apartment (apartment_no, floor_no, block_id) VALUES
    ('A-101', 1, 1), ('A-502', 5, 1), ('A-803', 8, 1),
    ('B-204', 2, 2), ('B-607', 6, 2),
    ('C-301', 3, 3), ('C-905', 9, 3), ('C-1102', 11, 3);

INSERT INTO resident (name, email, phone, resident_status, apartment_id, password_hash) VALUES
    ('Ananya Rao',    'ananya.rao@example.com',    '9845012345', 'active',   1, crypt('Password@123', gen_salt('bf'))),
    ('Rohit Menon',   'rohit.menon@example.com',   '9901123456', 'active',   2, crypt('Password@123', gen_salt('bf'))),
    ('Sneha Kulkarni','sneha.k@example.com',       '9738234567', 'active',   3, crypt('Password@123', gen_salt('bf'))),
    ('Arjun Nair',    'arjun.nair@example.com',    '9886345678', 'active',   4, crypt('Password@123', gen_salt('bf'))),
    ('Meera Iyer',    'meera.iyer@example.com',    '9448456789', 'active',   5, crypt('Password@123', gen_salt('bf'))),
    ('Karthik Shetty','karthik.s@example.com',     '9620567890', 'active',   6, crypt('Password@123', gen_salt('bf'))),
    ('Divya Hegde',   'divya.hegde@example.com',   '9591678901', 'inactive', 7, crypt('Password@123', gen_salt('bf'))),
    ('Imran Khan',    'imran.khan@example.com',    '9742789012', 'active',   8, crypt('Password@123', gen_salt('bf')));

INSERT INTO category (category_name) VALUES
    ('Wallets & Bags'), ('Electronics'), ('Keys'),
    ('Clothing & Accessories'), ('Documents & Cards'), ('Others');

INSERT INTO location (location_name, location_type, block_id) VALUES
    ('Block A Lobby',      'lobby',     1),   -- 1
    ('Block A Lift 2',     'lift',      1),   -- 2
    ('Block B Parking',    'parking',   2),   -- 3
    ('Block C Lobby',      'lobby',     3),   -- 4
    ('Central Garden',     'garden',    NULL),-- 5
    ('Clubhouse',          'clubhouse', NULL),-- 6
    ('Gymnasium',          'gym',       NULL),-- 7
    ('Main Gate',          'gate',      NULL);-- 8

-- Items 1-5 belong to LOST reports, items 6-10 to FOUND reports.
-- Pairs (1,6) (2,7) (3,8) are real matches written in different words, which is
-- exactly why semantic (vector) matching is needed. 5, 9, 10 have no counterpart.
INSERT INTO item (category_id, item_name, color, brand, description) VALUES
    (1, 'Black leather wallet',  'Black',  'Fossil',  'Slim bifold leather wallet with a few cards and some cash inside'),
    (2, 'Samsung phone',         'Blue',   'Samsung', 'Blue Samsung Galaxy phone with a cracked screen guard and a transparent cover'),
    (3, 'House keys',            'Silver', NULL,      'Bunch of three silver keys on a red keychain with a small bell'),
    (4, 'Red umbrella',          'Red',    NULL,      'Large foldable red umbrella with a wooden handle'),
    (2, 'Laptop charger',        'Black',  'HP',      'HP laptop charger with a long black cable and a blue LED on the adapter'),
    (1, 'Dark brown purse',      'Brown',  NULL,      'Small dark brown leather purse containing some cards and notes, found on a bench'),
    (2, 'Blue smartphone',       'Blue',   'Galaxy',  'Galaxy smartphone in a clear case, screen has a crack protector'),
    (3, 'Bunch of keys',         'Silver', NULL,      'Three silver keys attached to a red tag with a tiny bell'),
    (6, 'Steel water bottle',    'Blue',   'Milton',  'Blue insulated steel water bottle with a dented cap'),
    (5, 'ID card holder',        'Black',  NULL,      'Black card holder with an office ID card and a metro card');

INSERT INTO lost_report (item_id, resident_id, location_id, lost_date, reported_date, status) VALUES
    (1, 1, 2, '2026-10-18', '2026-10-18', 'open'),
    (2, 2, 7, '2026-10-19', '2026-10-20', 'open'),
    (3, 4, 3, '2026-10-20', '2026-10-21', 'open'),
    (4, 5, 8, '2026-10-21', '2026-10-21', 'open'),
    (5, 6, 6, '2026-10-22', '2026-10-23', 'open');

INSERT INTO found_report (item_id, resident_id, location_id, found_date, reported_date, status) VALUES
    (6,  3, 1, '2026-10-18', '2026-10-19', 'open'),
    (7,  8, 7, '2026-10-19', '2026-10-19', 'open'),
    (8,  5, 3, '2026-10-21', '2026-10-21', 'open'),
    (9,  1, 5, '2026-10-22', '2026-10-22', 'open'),
    (10, 4, 4, '2026-10-23', '2026-10-24', 'open');
