-- ============================================================
-- DEVELOPMENT STAFF ACCOUNT
-- LOCAL / DISPOSABLE DATABASE ONLY
-- ============================================================

INSERT INTO public.staff (
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
    public.crypt(
        'LostFoundDev@2026',
        public.gen_salt('bf')
    ),
    TRUE
)
ON CONFLICT (email) DO NOTHING;

-- Verify the development account
SELECT
    staff_id,
    name,
    email,
    role,
    active
FROM public.staff
WHERE email = 'admin@lostfound.local';