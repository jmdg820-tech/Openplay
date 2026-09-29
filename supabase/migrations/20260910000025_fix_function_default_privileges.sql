-- OPENPLAY MVP -- 025: restore intended function-level EXECUTE grants
--
-- Live audit (real unauthenticated REST call to /rest/v1/rpc/promote_next_waitlisted
-- returned HTTP 204) found that `revoke execute on function X from public;`
-- in every prior migration was NOT sufficient on a real Supabase project.
-- `PUBLIC` is a pseudo-role; `anon` and `authenticated` are distinct real
-- roles that Supabase's own project bootstrap grants EXECUTE to by default
-- on every new function created in the `public` schema. No migration in
-- this project ever explicitly revoked EXECUTE from `anon`/`authenticated`
-- specifically, so that platform default silently stood the whole time.
--
-- Verified directly against the live project (not assumed): EVERY custom
-- function in this schema -- not just the ones named in the audit --
-- currently has `has_function_privilege('anon', ..., 'EXECUTE') = true`
-- AND the same for `authenticated`, regardless of what each function's own
-- migration intended. This migration is the complete fix: for every
-- function, REVOKE EXECUTE from anon AND authenticated first (a clean
-- slate, independent of whatever the current, buggy state is), then GRANT
-- EXECUTE back to exactly the roles each function's original migration
-- already documented -- no function's intended access model changes here,
-- this migration only makes the already-documented intent actually hold at
-- the privilege-system level (same pattern as migration 023, which did the
-- equivalent fix for table-level grants).
--
-- `service_role` grants are untouched (migration 020's blanket grant, plus
-- migration 019's explicit grants, already cover it correctly and are not
-- affected by this bug -- service_role is not a client-facing role, it's
-- what this project's own migration scripts connect as).
--
-- `rls_auto_enable()` is a Supabase-platform-provided function (not created
-- by any OpenPlay migration) and is deliberately left untouched -- altering
-- platform-owned objects is out of this project's scope.

-- ---------------------------------------------------------------------
-- Trigger-only / fully internal functions -- must be callable by NEITHER
-- anon NOR authenticated. (handle_new_user, notify_session_change, and
-- force_blocker_identity are `returns trigger` functions that Postgres
-- itself refuses to invoke outside a trigger context, so they were not
-- actually exploitable despite the stray grant -- but the grant itself
-- still contradicted the documented "no client access" intent and is
-- closed here for defense in depth. promote_next_waitlisted and the two
-- scheduled-job functions ARE ordinary callable functions with real
-- effects and were genuinely exploitable by anonymous clients before this
-- fix -- confirmed live.)
-- ---------------------------------------------------------------------

revoke execute on function handle_new_user() from anon, authenticated;
revoke execute on function notify_session_change() from anon, authenticated;
revoke execute on function force_blocker_identity() from anon, authenticated;
revoke execute on function promote_next_waitlisted(uuid) from anon, authenticated;
revoke execute on function expire_pending_promotions() from anon, authenticated;
revoke execute on function enqueue_session_reminders(int) from anon, authenticated;

-- ---------------------------------------------------------------------
-- Functions intended for BOTH anon and authenticated -- re-assert the
-- correct grant explicitly rather than relying on the (buggy) default.
-- ---------------------------------------------------------------------

revoke execute on function is_venue_staff_member(uuid) from anon, authenticated;
grant execute on function is_venue_staff_member(uuid) to anon, authenticated;

revoke execute on function get_session_roster(uuid) from anon, authenticated;
grant execute on function get_session_roster(uuid) to anon, authenticated;

revoke execute on function is_venue_managed(uuid) from anon, authenticated;
grant execute on function is_venue_managed(uuid) to anon, authenticated;

revoke execute on function join_session(uuid, text, contact_method_enum, text) from anon, authenticated;
grant execute on function join_session(uuid, text, contact_method_enum, text) to anon, authenticated;

revoke execute on function leave_session(uuid, uuid) from anon, authenticated;
grant execute on function leave_session(uuid, uuid) to anon, authenticated;

revoke execute on function confirm_promotion(uuid, uuid) from anon, authenticated;
grant execute on function confirm_promotion(uuid, uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Functions intended for authenticated ONLY -- anon must lose EXECUTE.
-- (can_manage_session_participant was previously also anon-executable;
-- not a data leak in practice since it always evaluates to false for a
-- null auth.uid(), but it contradicted its own migration's documented
-- "authenticated only" grant, so it's corrected here for consistency.)
-- ---------------------------------------------------------------------

revoke execute on function can_manage_session_participant(uuid) from anon, authenticated;
grant execute on function can_manage_session_participant(uuid) to authenticated;

revoke execute on function remove_participant(uuid) from anon, authenticated;
grant execute on function remove_participant(uuid) to authenticated;

revoke execute on function cancel_session(uuid, text) from anon, authenticated;
grant execute on function cancel_session(uuid, text) to authenticated;

revoke execute on function claim_venue(uuid) from anon, authenticated;
grant execute on function claim_venue(uuid) to authenticated;

revoke execute on function register_push_token(text, text) from anon, authenticated;
grant execute on function register_push_token(text, text) to authenticated;

revoke execute on function submit_report(uuid, uuid, text) from anon, authenticated;
grant execute on function submit_report(uuid, uuid, text) to authenticated;

revoke execute on function report_session_participant(uuid, text) from anon, authenticated;
grant execute on function report_session_participant(uuid, text) to authenticated;

revoke execute on function block_session_participant(uuid) from anon, authenticated;
grant execute on function block_session_participant(uuid) to authenticated;
