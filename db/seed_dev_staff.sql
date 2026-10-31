-- Permanent local development staff account.
-- Change the password before using this outside local development.

INSERT INTO staff (
    name,
    email,
    phone,
    role,
    password_hash,
    active
)
VALUES (
    'Development Admin',
    'admin@lostfound.local',
    '9000000000',
    'admin',
    crypt('LostFoundDev@2026', gen_salt('bf')),
    TRUE
)
ON CONFLICT (email) DO NOTHING;