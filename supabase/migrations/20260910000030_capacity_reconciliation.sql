-- OPENPLAY MVP -- 030: reconcile the roster when an organizer edits capacity
--
-- Audit finding: organizers/venue staff edit sessions.capacity through the
-- plain RLS-checked UPDATE (migration 008), and nothing reacted:
--   * lowering capacity below the players already holding a spot left the
--     session over capacity (the invariant occupied <= capacity broke);
--   * raising capacity promoted nobody -- waitlisted players stayed stuck
--     until some unrelated leave happened to trigger a promotion.
--
-- Rule implemented here (product decision, recorded in the fix plan):
--   * DECREASE below occupied (confirmed + pending_confirmation) is
--     REJECTED with a clear error. Confirmed players are never removed
--     silently; the organizer can remove players explicitly first.
--   * INCREASE on an active, not-yet-ended session promotes waitlisted
--     players FIFO into the new spots via the existing, unchanged
--     promote_next_waitlisted() (same 15-minute pending_confirmation offer,
--     same waitlist_promoted outbox row, same ordering).
--
-- Concurrency: both triggers run inside the UPDATE of the sessions row. A
-- row-level BEFORE UPDATE trigger only fires after Postgres has locked that
-- row, i.e. after any concurrent join_session()/leave_session()/
-- confirm_promotion()/expire_pending_promotions() holding
-- `SELECT ... FOR UPDATE` on the same session has committed. The occupied
-- count is therefore read under the same serialization point every other
-- capacity-sensitive path uses, so two concurrent changes can never produce
-- duplicate promotions or a confirmation above capacity.
--
-- Both functions are trigger-only: EXECUTE is revoked from PUBLIC/anon/
-- authenticated (same posture as migrations 025/027).

create or replace function enforce_capacity_not_below_occupied()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_occupied int;
begin
  select count(*) into v_occupied
  from session_participants
  where session_id = new.id
    and status in ('confirmed', 'pending_confirmation');

  if new.capacity < v_occupied then
    raise exception 'capacity cannot be lower than the number of players holding a spot (%)', v_occupied;
  end if;

  return new;
end;
$$;

revoke execute on function enforce_capacity_not_below_occupied() from public;
revoke execute on function enforce_capacity_not_below_occupied() from anon, authenticated;

create trigger sessions_enforce_capacity
  before update of capacity on sessions
  for each row
  when (new.capacity is distinct from old.capacity)
  execute function enforce_capacity_not_below_occupied();

create or replace function promote_on_capacity_increase()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_occupied int;
  v_free int;
begin
  if new.capacity <= old.capacity
     or new.status <> 'active'
     or new.end_time <= now() then
    return null;
  end if;

  select count(*) into v_occupied
  from session_participants
  where session_id = new.id
    and status in ('confirmed', 'pending_confirmation');

  v_free := new.capacity - v_occupied;

  -- promote_next_waitlisted() promotes at most one row per call and is a
  -- no-op once the session is full or the waitlist is empty, so calling it
  -- v_free times fills exactly min(free spots, waitlisted) in FIFO order.
  for i in 1..greatest(v_free, 0) loop
    perform promote_next_waitlisted(new.id);
  end loop;

  return null;
end;
$$;

revoke execute on function promote_on_capacity_increase() from public;
revoke execute on function promote_on_capacity_increase() from anon, authenticated;

create trigger sessions_promote_on_capacity_increase
  after update of capacity on sessions
  for each row
  when (new.capacity > old.capacity)
  execute function promote_on_capacity_increase();
