-- =====================================================================
-- Lost & Found System - Claims Workflow Grants and Legacy Cleanup
-- File: db/claims_grants_fix.sql
-- PostgreSQL 16
--
-- WHY:
--   A database built only from the earlier scripts is missing three
--   privileges the claims workflow needs. Without them:
--     * the staff page fails with "permission denied for table resident"
--       (v_pending_claims is owned by claims_workflow_owner, and a view
--       is checked against its OWNER's privileges);
--     * approving a claim fails with "permission denied for sequence
--       audit_log_log_id_seq" (the audit trigger inserts a row);
--     * recording a handover fails with "permission denied for table
--       handover" (the report guard trigger reads it).
--   It also removes two old, unauthenticated function overloads that
--   some development databases still contain.
--
-- RUN ORDER: after claims_security.sql, triggers.sql, advanced_claims.sql
--            and pending_claims_view.sql. Run as the table owner
--            (lostfound_user) or a superuser. Safe to run repeatedly.
-- =====================================================================

BEGIN;

-- The view v_pending_claims joins these tables as claims_workflow_owner.
GRANT USAGE ON SCHEMA public TO claims_workflow_owner;
GRANT SELECT ON public.item TO claims_workflow_owner;

-- Column-level grant: the view needs only the name, never email/phone/
-- password_hash.
GRANT SELECT (resident_id, name) ON public.resident TO claims_workflow_owner;

-- The audit trigger (audit_status_change) runs inside approve/reject/
-- handover and inserts into audit_log.
GRANT INSERT ON public.audit_log TO claims_workflow_owner;
GRANT USAGE ON SEQUENCE public.audit_log_log_id_seq TO claims_workflow_owner;

-- record_handover inserts into handover, and guard_report_status (which
-- runs as claims_workflow_owner) reads it to confirm a handover exists
-- before a report may be closed.
GRANT SELECT, INSERT ON public.handover TO claims_workflow_owner;
GRANT USAGE ON SEQUENCE public.handover_handover_id_seq TO claims_workflow_owner;

-- Legacy overloads that accepted a raw staff_id with no signed assertion.
-- Anyone able to call them could act as any staff member.
DROP FUNCTION IF EXISTS public.approve_claim(integer, integer);
DROP FUNCTION IF EXISTS public.record_handover(integer, integer, character varying, text);

COMMIT;

-- Verification (all rows should show t):
SELECT 'item select' AS check_name,
       has_table_privilege('claims_workflow_owner', 'public.item', 'SELECT') AS ok
UNION ALL SELECT 'resident.name select',
       has_column_privilege('claims_workflow_owner', 'public.resident', 'name', 'SELECT')
UNION ALL SELECT 'audit_log insert',
       has_table_privilege('claims_workflow_owner', 'public.audit_log', 'INSERT')
UNION ALL SELECT 'audit sequence usage',
       has_sequence_privilege('claims_workflow_owner', 'public.audit_log_log_id_seq', 'USAGE')
UNION ALL SELECT 'handover select',
       has_table_privilege('claims_workflow_owner', 'public.handover', 'SELECT')
UNION ALL SELECT 'handover sequence usage',
       has_sequence_privilege('claims_workflow_owner', 'public.handover_handover_id_seq', 'USAGE');
