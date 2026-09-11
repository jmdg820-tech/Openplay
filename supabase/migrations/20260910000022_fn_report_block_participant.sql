-- OPENPLAY MVP -- 022: report_session_participant(), block_session_participant()
--
-- Closes the MVP report/block gap: get_session_roster() deliberately never
-- returns user_id (migration 012), so a client has no way to name an
-- arbitrary roster participant as a report/block target -- only the
-- session's organizer, whose id is separately public via sessions.created_by.
--
-- This is the minimal additive surface for that, approved explicitly rather
-- than done silently: two SECURITY DEFINER RPCs that take ONLY a
-- participant_id (never a user_id, never a caller-supplied actor id),
-- resolve the target's user_id internally, and either act on it (via the
-- existing submit_report()/blocks-insert paths, inheriting their existing
-- dedup/uniqueness/self-action protections unchanged) or reject -- but
-- NEVER return that resolved user_id to the client. get_session_roster()
-- itself is untouched by this migration.
--
-- Authorization reuses the exact "joined bucket" already established by
-- get_session_roster() (migration 012) and can_manage_session_participant()
-- (migration 009): the caller must be a confirmed/waitlisted/
-- pending_confirmation participant of the SAME session as the target, or
-- that session's organizer, or its venue staff. No new authorization
-- concept is introduced.
--
-- Guest side-channel: guests have no profiles row (reports/blocks both
-- FK reported_user_id/blocked_user_id to profiles(id) NOT NULL), so
-- targeting a guest is schema-impossible, not just policy-denied. That
-- case, an unresolvable participant_id, and a participant belonging to a
-- session the caller isn't authorized on all raise -- deliberately -- the
-- exact same message text, so no response distinguishes "doesn't exist"
-- from "belongs to someone else's session" from "is a guest". A plain
-- joined participant, who is never told is_guest by get_session_roster(),
-- therefore cannot use this RPC's errors to learn it either.

create or replace function report_session_participant(
  p_participant_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_caller uuid := auth.uid();
  v_session_id uuid;
  v_target_user_id uuid;
  v_is_organizer boolean;
  v_is_staff boolean;
  v_is_joined boolean;
  v_report_id uuid;
begin
  if v_caller is null then
    raise exception 'not authorized for this action';
  end if;

  select sp.session_id, sp.user_id
    into v_session_id, v_target_user_id
    from session_participants sp
    where sp.id = p_participant_id;

  if not found then
    -- Unknown/guessed participant_id: same message as "not authorized"
    -- below -- does not confirm or deny existence.
    raise exception 'not authorized for this action';
  end if;

  v_is_organizer := exists (
    select 1 from sessions s where s.id = v_session_id and s.created_by = v_caller
  );
  v_is_staff := exists (
    select 1 from sessions s where s.id = v_session_id and is_venue_staff_member(s.venue_id)
  );
  v_is_joined := exists (
    select 1 from session_participants sp
    where sp.session_id = v_session_id
      and sp.user_id = v_caller
      and sp.status in ('confirmed', 'waitlisted', 'pending_confirmation')
  );

  if not (v_is_organizer or v_is_staff or v_is_joined) then
    raise exception 'not authorized for this action';
  end if;

  if v_target_user_id is null then
    -- Target is a guest row. Deliberately generic -- never mentions "guest".
    raise exception 'unable to complete this action for the selected participant';
  end if;

  -- Reuses submit_report() as-is: same self-report check, same 5-minute
  -- general-report dedup, same permanent session-scoped uniqueness. auth.uid()
  -- resolves the same way inside this nested SECURITY DEFINER call as it did
  -- above -- it reads a GUC, not the function's ownership context.
  v_report_id := submit_report(v_target_user_id, v_session_id, p_reason);
  return v_report_id;
end;
$$;

revoke execute on function report_session_participant(uuid, text) from public;
grant execute on function report_session_participant(uuid, text) to authenticated;

create or replace function block_session_participant(
  p_participant_id uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_caller uuid := auth.uid();
  v_session_id uuid;
  v_target_user_id uuid;
  v_is_organizer boolean;
  v_is_staff boolean;
  v_is_joined boolean;
begin
  if v_caller is null then
    raise exception 'not authorized for this action';
  end if;

  select sp.session_id, sp.user_id
    into v_session_id, v_target_user_id
    from session_participants sp
    where sp.id = p_participant_id;

  if not found then
    raise exception 'not authorized for this action';
  end if;

  v_is_organizer := exists (
    select 1 from sessions s where s.id = v_session_id and s.created_by = v_caller
  );
  v_is_staff := exists (
    select 1 from sessions s where s.id = v_session_id and is_venue_staff_member(s.venue_id)
  );
  v_is_joined := exists (
    select 1 from session_participants sp
    where sp.session_id = v_session_id
      and sp.user_id = v_caller
      and sp.status in ('confirmed', 'waitlisted', 'pending_confirmation')
  );

  if not (v_is_organizer or v_is_staff or v_is_joined) then
    raise exception 'not authorized for this action';
  end if;

  if v_target_user_id is null then
    raise exception 'unable to complete this action for the selected participant';
  end if;

  -- Real INSERT into the real table: force_blocker_identity() (migration 011)
  -- still fires and still forces blocker_user_id := auth.uid() regardless of
  -- what's passed here (belt-and-braces, consistent with v_caller anyway);
  -- blocks_no_self_block and blocks_unique still apply unchanged.
  insert into blocks (blocker_user_id, blocked_user_id) values (v_caller, v_target_user_id);
end;
$$;

revoke execute on function block_session_participant(uuid) from public;
grant execute on function block_session_participant(uuid) to authenticated;
