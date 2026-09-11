-- OPENPLAY MVP — 014: promote_next_waitlisted() helper, leave_session(), confirm_promotion()

-- Internal helper only -- never granted to anon/authenticated. Always called
-- from within another SECURITY DEFINER function that has already locked the
-- sessions row for p_session_id; re-locks it here too so the function is
-- also safe if ever called as an independent entry point.
create or replace function promote_next_waitlisted(p_session_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_capacity int;
  v_occupied int;
  v_candidate session_participants%rowtype;
begin
  select capacity into v_capacity from sessions where id = p_session_id for update;

  select count(*) into v_occupied
  from session_participants
  where session_id = p_session_id
    and status in ('confirmed', 'pending_confirmation');

  if v_occupied >= v_capacity then
    return;
  end if;

  select * into v_candidate
  from session_participants
  where session_id = p_session_id and status = 'waitlisted'
  order by waitlist_order_at asc
  limit 1
  for update;

  if v_candidate.id is null then
    return;
  end if;

  update session_participants
    set status = 'pending_confirmation',
        promoted_at = now(),
        promotion_expires_at = now() + interval '15 minutes'
    where id = v_candidate.id;

  if v_candidate.user_id is not null then
    insert into notification_outbox (user_id, event_type, session_id, payload)
    values (
      v_candidate.user_id, 'waitlist_promoted', p_session_id,
      jsonb_build_object('session_id', p_session_id, 'participant_id', v_candidate.id)
    );
  end if;
  -- Guest candidates receive no notification here -- accepted MVP
  -- limitation (§3 of the v3 review): a promoted guest can only discover
  -- the offer by reopening the session with their participant_id +
  -- management_token.
end;
$$;

revoke execute on function promote_next_waitlisted(uuid) from public;
-- Intentionally no grant to anon/authenticated/service_role -- this is an
-- internal step only ever invoked from within other definer functions.

create or replace function leave_session(p_participant_id uuid, p_management_token uuid default null)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_caller uuid := auth.uid();
  v_participant session_participants%rowtype;
  v_session_id uuid;
begin
  select session_id into v_session_id from session_participants where id = p_participant_id;
  if v_session_id is null then
    raise exception 'participant not found';
  end if;

  -- Lock the session first -- the serialization point for every concurrent
  -- join/leave/promotion/cancellation on this session.
  perform 1 from sessions where id = v_session_id for update;

  select * into v_participant from session_participants where id = p_participant_id;

  if v_participant.status not in ('confirmed', 'waitlisted', 'pending_confirmation') then
    raise exception 'this participation is not active';
  end if;

  if v_participant.user_id is not null then
    if v_caller is null or v_participant.user_id <> v_caller then
      raise exception 'not authorized for this action';
    end if;
  else
    if p_management_token is null or p_management_token <> v_participant.management_token then
      raise exception 'not authorized for this action';
    end if;
  end if;

  update session_participants set status = 'left' where id = p_participant_id;

  perform promote_next_waitlisted(v_session_id);
end;
$$;

revoke execute on function leave_session(uuid, uuid) from public;
grant execute on function leave_session(uuid, uuid) to anon, authenticated;

create or replace function confirm_promotion(p_participant_id uuid, p_management_token uuid default null)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_caller uuid := auth.uid();
  v_participant session_participants%rowtype;
  v_session_id uuid;
begin
  select session_id into v_session_id from session_participants where id = p_participant_id;
  if v_session_id is null then
    raise exception 'participant not found';
  end if;

  perform 1 from sessions where id = v_session_id for update;

  select * into v_participant from session_participants where id = p_participant_id;

  if v_participant.user_id is not null then
    if v_caller is null or v_participant.user_id <> v_caller then
      raise exception 'not authorized for this action';
    end if;
  else
    if p_management_token is null or p_management_token <> v_participant.management_token then
      raise exception 'not authorized for this action';
    end if;
  end if;

  if v_participant.status <> 'pending_confirmation' or v_participant.promotion_expires_at <= now() then
    raise exception 'this offer has expired or is no longer available';
  end if;

  update session_participants
    set status = 'confirmed', promotion_expires_at = null
    where id = p_participant_id;
  -- No further promotion attempt: a pending_confirmation row already counted
  -- as occupied, so this transition does not change occupied capacity.
end;
$$;

revoke execute on function confirm_promotion(uuid, uuid) from public;
grant execute on function confirm_promotion(uuid, uuid) to anon, authenticated;
