-- OPENPLAY MVP — 024: pg_cron scheduling for the two already-approved sweeps
--
-- expire_pending_promotions() and enqueue_session_reminders() (migration
-- 019) are unchanged by this migration -- no business logic here, only
-- wiring them to run on a schedule. Both functions are owned by `postgres`
-- (confirmed on the live project), so a job scheduled by `postgres` already
-- has implicit EXECUTE via ownership -- no additional grant is introduced,
-- and the functions' client-facing posture (EXECUTE granted only to
-- service_role, nothing for anon/authenticated) is unchanged.
--
-- Idempotency: `cron.schedule(job_name, schedule, command)` with a named
-- job (pg_cron 1.4+) UPSERTS -- re-running this migration updates the
-- existing job in place rather than creating a duplicate. Duplicate
-- notifications are prevented by the functions themselves, not by anything
-- in this migration: enqueue_session_reminders() relies on the partial
-- unique index on notification_outbox(session_id, user_id) WHERE
-- event_type='session_reminder' (migration 002) via ON CONFLICT DO
-- NOTHING, and expire_pending_promotions() relies on its own FOR UPDATE
-- locking and re-checked WHERE clause (migration 019) -- both already
-- verified safe under concurrent/overlapping execution in prior testing.

create extension if not exists pg_cron schema extensions;

select cron.schedule(
  'openplay-expire-pending-promotions',
  '* * * * *',
  $$select expire_pending_promotions();$$
);

select cron.schedule(
  'openplay-enqueue-session-reminders',
  '*/10 * * * *',
  $$select enqueue_session_reminders();$$
);
