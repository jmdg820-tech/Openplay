-- OPENPLAY MVP — 020: service_role grants
--
-- `service_role` has the BYPASSRLS attribute (granted when the role is
-- created -- in Supabase this is built in; in the local test harness it is
-- set explicitly in test/sql/000_test_harness_setup.sql), which skips row
-- level security entirely. BYPASSRLS does not imply table-level privilege,
-- though, so explicit GRANTs are still required for background workers
-- (the notification delivery/cleanup process, the expiry/reminder sweeps)
-- to read and write every table, including notification_outbox and
-- session_participants, which grant nothing at all to anon/authenticated.
--
-- This also documents, in one place, the assumption relied on throughout
-- the SECURITY DEFINER functions in this migration set: every such function
-- is created by (and therefore owned by) the migration-running role, which
-- must itself have BYPASSRLS for functions like cancel_session() and
-- claim_venue() to be able to perform writes that an ordinary client-facing
-- RLS policy would refuse. This is the standard, documented Supabase
-- convention (the `postgres` role used for migrations has BYPASSRLS) and is
-- true by construction in the local test harness (a genuine Postgres
-- superuser unconditionally bypasses RLS).

grant usage on schema public to service_role;

grant select, insert, update, delete on
  profiles, venues, venue_staff, sessions, session_participants,
  guest_contacts, push_tokens, notification_outbox, reports, blocks
to service_role;

grant execute on all functions in schema public to service_role;
