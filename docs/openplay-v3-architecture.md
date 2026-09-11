# OPENPLAY MVP v3 — Approved Architecture & Security Review

Status: **APPROVED, IMPLEMENTED**. This document is the checked-in record of the
architecture approved for the OPENPLAY MVP. It was originally delivered as a
19-point instruction set in chat rather than as a repo file; this document
formalizes it as the project's source of truth, alongside a live inventory of
what the migrations under `supabase/migrations/` actually implement.

OPENPLAY is fully independent from Tournament and PickleLive: no shared code,
no shared schema, no cross-project dependencies.

## Explicitly out of scope for this MVP (Phase 2+)

Private/approval-based sessions, organizations/tenants, court entities/booking,
automated court rotation, scoring, brackets, recurring sessions, payments,
SMS/email guest notifications, guest account claiming/merging.

## Schema (10 tables)

`profiles`, `venues`, `venue_staff`, `sessions`, `session_participants`,
`guest_contacts`, `push_tokens`, `notification_outbox`, `reports`, `blocks`.

Enums: `skill_level_enum`, `session_type_enum`, `session_status_enum`,
`participant_status_enum`, `contact_method_enum`, `notification_event_enum`.

Full DDL: `supabase/migrations/20260910000001_extensions_and_enums.sql`,
`20260910000002_tables.sql`, `20260910000003_indexes.sql`,
`20260910000004_triggers.sql`.

Key constraints:
- `session_participants`: CHECK enforcing `user_id XOR (guest_name AND
  management_token)`; partial unique index on `(session_id, user_id)` for
  active statuses (prevents duplicate active joins by a registered user).
- `notification_outbox`: partial unique index
  `UNIQUE(session_id, user_id) WHERE event_type = 'session_reminder'`
  (reminder idempotency).
- `reports`: `UNIQUE(reporter_user_id, reported_user_id, session_id)`
  (session-scoped uniqueness; general reports with `session_id IS NULL` are
  deduplicated at the application layer, see `submit_report()` below).

## Session roster — the only client read surface for `session_participants`

`get_session_roster(p_session_id uuid)` (migration
`20260910000012_fn_roster_and_venue_managed.sql`) returns exactly:
`participant_id, session_id, display_name, status, skill_level,
seconds_until_expiry, is_guest`. Never `user_id`, `guest_name`,
`guest_contact`, `management_token`, `waitlist_order_at`, `promoted_at`,
`promotion_expires_at`, `joined_at`, `created_at`, `updated_at`, or any other
internal column.

`skill_level` visibility: NULL for anonymous and authenticated non-members;
visible for a participant of that exact session (status in
`confirmed`/`waitlisted`/`pending_confirmation`), the session's organizer, or
venue staff of that session's venue. Guests do not get elevated visibility
through this RPC — it never accepts a `management_token`.

`session_participants` itself has RLS enabled with **zero policies** and all
privileges revoked from `public`/`anon`/`authenticated` (migration
`20260910000009_rls_participants_and_guests.sql`) — defense in depth on top
of the RPC being the only surface.

## Realtime

`session_participants` is **never** added to any Realtime publication.
`sessions` is (migration `20260910000021_realtime_sessions.sql`) — it has no
sensitive columns and is already fully public-readable via RLS, so
broadcasting its changes discloses nothing new and lets the app live-update a
session list/detail view. Roster changes are obtained only by refetching
`get_session_roster()`.

## Guest management token

Guest `session_participants` rows receive a cryptographically random
`management_token` (`gen_random_uuid()`, migration
`20260910000013_fn_join_session.sql`); registered users' rows always have
`management_token IS NULL` (enforced both procedurally and by a CHECK
constraint). The token is returned only from `join_session()`'s own guest
response, never from the roster, never logged, never placed in a URL. Guest
`leave_session()`/`confirm_promotion()` require `participant_id +
management_token`; a mismatched token produces a generic error. Losing the
token has no recovery path — the guest UI must say so explicitly. Organizers
and venue staff can still remove a guest via `remove_participant()`
(authorization comes from `auth.uid()`, not the token).

## Venue staff

Raw `venue_staff` rows are not publicly exposed. `is_venue_managed(p_venue_id
uuid)` (migration `20260910000012_fn_roster_and_venue_managed.sql`) returns
only a boolean for public callers.

## SECURITY DEFINER hardening

Every `SECURITY DEFINER` function in this project has `SET search_path =
pg_catalog, public`, `REVOKE EXECUTE ... FROM PUBLIC`, and an explicit `GRANT
EXECUTE` only to the roles that need it (`anon`/`authenticated`/
`service_role`, or no grant at all for internal-only helpers like
`promote_next_waitlisted()`). Actor identity is always derived from
`auth.uid()` inside the function body — no function accepts a caller-supplied
user id for an authorization decision (`is_venue_staff_member(p_venue_id)`
and `can_manage_session_participant(p_participant_id)` take only the
resource id, precisely to keep this true even though they're directly
callable by clients from within RLS policies). No dynamic SQL is used
anywhere. Authorization checks happen before privileged writes in every RPC.

## Reminder idempotency

The partial unique index above prevents duplicate reminder rows per
`(session_id, user_id)`. When a session's `start_time` changes
(`notify_session_change()` trigger, migration
`20260910000005_session_change_notifications.sql`), only **unsent**
`session_reminder` rows for that session are deleted
(`... AND sent_at IS NULL`); already-sent reminders are never touched. The
next `enqueue_session_reminders()` sweep re-enqueues the reminder for the new
time via `ON CONFLICT ... DO NOTHING` against the same unique index.

## Reports

Session-scoped uniqueness is a real constraint (see above). For general
reports (`session_id IS NULL`, not caught by that constraint since SQL NULLs
are never equal), `submit_report()` (migration
`20260910000018_fn_submit_report.sql`) returns the existing report id if the
same reporter filed against the same reported user within the last 5 minutes,
otherwise inserts a new one — preventing accidental double-submission while
still allowing a genuinely later, separate report.

## Concurrency

`join_session`, `leave_session`, `confirm_promotion`, `remove_participant`,
and `cancel_session` all lock the `sessions` row with `FOR UPDATE` before
reading/mutating capacity-sensitive state. Waitlist promotion
(`promote_next_waitlisted()`) additionally row-locks the specific candidate
being promoted. `expire_pending_promotions()` (scheduled sweep) locks both
the session and the expiring candidate before reverting it to `waitlisted`
with a refreshed `waitlist_order_at` (re-queued to the back of the line).

## Scheduled jobs

`expire_pending_promotions()` and `enqueue_session_reminders(p_window_minutes
int default 90)` (migration `20260910000019_fn_scheduled_jobs.sql`) are
fully implemented, SECURITY DEFINER, `service_role`-only functions. Wiring
them to an actual scheduler (`pg_cron` or a scheduled Edge Function) is
explicitly deferred to deployment-time infrastructure setup — documented,
not faked; both functions are independently callable/testable right now.

## Migrations

See `supabase/migrations/` for the full, numbered migration set (21 files as
of this writing). No migration has been applied to any remote/production
Supabase project — all execution is against a local test environment only.
