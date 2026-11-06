-- =====================================================================
-- Lost & Found System - Claims Authentication Seed
-- File: db/seed_claims_auth.sql
-- PostgreSQL 16
--
-- WHY:
--   approve / reject / handover verify a signed assertion created by the
--   web app. The database must therefore know
--     1. the HMAC signing key (claims_private.assertion_keys), and
--     2. which database staff row each web login maps to
--        (claims_private.account_staff_map).
--   Without these rows the actions fail with
--     "Unknown or disabled assertion key"  or
--     "Authenticated account is not an active staff account".
--
-- USAGE (run as a superuser; the claims_private tables are not readable
-- by the application roles):
--
--   1. Create a 32-byte key and keep it OUT of git:
--        node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
--
--   2. Put the same values in .env.local:
--        CLAIMS_KEY_ID=dev-key-1
--        CLAIMS_HMAC_KEY_HEX=<the 64 hex characters>
--
--   3. Load them (docker example):
--        docker exec -i lost-found-postgres psql -U postgres -d lost_found_db \
--          -v kid=dev-key-1 -v key_hex=<the 64 hex characters> \
--          < db/seed_claims_auth.sql
--
-- Safe to run again: it updates the key and adds any missing mappings.
-- =====================================================================

\set ON_ERROR_STOP on

-- Refuse to continue if the variables were not supplied.
\if :{?kid}
\else
    \echo 'Missing -v kid=<key id>'
    \quit
\endif

\if :{?key_hex}
\else
    \echo 'Missing -v key_hex=<64 hex characters>'
    \quit
\endif

BEGIN;

INSERT INTO claims_private.assertion_keys (kid, hmac_key, enabled)
VALUES (:'kid', decode(:'key_hex', 'hex'), TRUE)
ON CONFLICT (kid)
DO UPDATE SET hmac_key = EXCLUDED.hmac_key,
              enabled  = TRUE;

-- The web app signs assertions with issuer 'lost-found-web' and
-- subject 'staff:<staff_id>' (see src/lib/claims-workflow.ts).
INSERT INTO claims_private.account_staff_map (issuer, subject, staff_id)
SELECT 'lost-found-web', 'staff:' || s.staff_id, s.staff_id
FROM public.staff s
WHERE s.active
ON CONFLICT DO NOTHING;

COMMIT;

\echo 'Claims authentication seed complete.'

SELECT s.staff_id, s.email, m.issuer, m.subject
FROM public.staff s
LEFT JOIN claims_private.account_staff_map m ON m.staff_id = s.staff_id
ORDER BY s.staff_id;
