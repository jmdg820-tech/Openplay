-- OPENPLAY MVP — 015: remove_participant(), cancel_session()
--
-- Both functions run as SECURITY DEFINER and, for cancel_session(), need to
-- write sessions.status = 'cancelled' even though the plain client UPDATE
-- policy's WITH CHECK (migration 008) restricts raw updates to status =
-- 'active' only. This relies on the documented Supabase convention that the
-- role owning migrated functions/tables (`postgres`) has BYPASSRLS, which is
-- what lets a SECURITY DEFINER function perform a write an ordinary RLS
-- policy would refuse -- the standard, intended pattern for this exact
-- situation, not an incidental bypass. (Verified true for the local test
-- harness, whose `postgres` role is a genuine superuser and therefore
-- unconditionally bypasses RLS, consistent with this assumption.)

create or replace function remove_participant(p_participant_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_caller uuid := auth.uid();
  v_session_id uuid;
  v_authorized boolean;
begin
  select session_id into v_session_id from session_participants where id = p_participant_id;
  if v_session_id is null then
    raise exception 'participant not found';
  end if;

  select exists (
    select 1 from sessions s
    where s.id = v_session_id
      and (
        s.created_by = v_caller
        or exists (select 1 from venue_staff vs where vs.venue_id = s.venue_id and vs.user_id = v_caller)
      )
  ) into v_authorized;

  if not v_authorized then
    raise exception 'not authorized for this action';
  end if;

  perform 1 from sessions where id = v_session_id for update;

  update session_participants
    set status = 'removed'
    where id = p_participant_id
      and status in ('confirmed', 'waitlisted', 'pending_confirmation');

  perform promote_next_waitlisted(v_session_id);
end;
$$;

revoke execute on function remove_participant(uuid) from public;
grant execute on function remove_participant(uuid) to authenticated;

create or replace function cancel_session(p_session_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_caller uuid := auth.uid();
  v_session sessions%rowtype;
  v_authorized boolean;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'a cancellation reason is required';
  end if;

  select * into v_session from sessions where id = p_session_id for update;
  if v_session.id is null then
    raise exception 'session not found';
  end if;

  v_authorized := v_session.created_by = v_caller
    or exists (select 1 from venue_staff vs where vs.venue_id = v_session.venue_id and vs.user_id = v_caller);

  if not v_authorized then
    raise exception 'not authorized for this action';
  end if;

  if v_session.status <> 'active' then
    raise exception 'session is already cancelled';
  end if;

  update sessions set status = 'cancelled', cancellation_reason = p_reason where id = p_session_id;
  -- Notification fan-out (session_cancelled) is handled by the
  -- notify_session_change trigger (migration 005) firing on this update.
end;
$$;

revoke execute on function cancel_session(uuid, text) from public;
grant execute on function cancel_session(uuid, text) to authenticated;
