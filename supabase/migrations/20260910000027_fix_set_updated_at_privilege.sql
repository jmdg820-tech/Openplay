-- OPENPLAY MVP -- 027: close the one function migration 025 missed
--
-- Migration 025 is already applied in production under its original name,
-- so it is treated as immutable and left untouched here -- this is a
-- fix-forward migration instead of an edit to already-shipped history.
--
-- set_updated_at() was not included in migration 025's revoke list because,
-- at the time, it appeared to fall into the same "trigger-only, Postgres
-- refuses to invoke outside a trigger context" category as
-- handle_new_user/notify_session_change/force_blocker_identity, which were
-- each already safe from PUBLIC exposure because their own origin
-- migrations (004, 005, 011 respectively) explicitly revoked EXECUTE from
-- `public`. set_updated_at's origin migration (004) never did that -- it
-- was created with zero privilege statements at all, so it silently kept
-- Postgres's PUBLIC-execute default. Verified live against the production
-- project: has_function_privilege('anon'|'authenticated'|'public',
-- 'set_updated_at()', 'EXECUTE') was true for all three roles.
--
-- `PUBLIC` grants apply to every role unconditionally, independent of any
-- role-specific revoke, so both statements below are required together
-- (revoking only from anon/authenticated would do nothing while PUBLIC
-- still holds EXECUTE). Not independently exploitable in practice --
-- set_updated_at() is `returns trigger`, which Postgres refuses to invoke
-- outside a trigger context -- but closed here for defense in depth and
-- consistency with the other trigger-only functions.

revoke execute on function set_updated_at() from public;
revoke execute on function set_updated_at() from anon, authenticated;
