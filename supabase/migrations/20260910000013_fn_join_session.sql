-- OPENPLAY MVP — 013: join_session()
--
-- Governing concurrency principle for this and every other capacity-sensitive
-- function: lock the SESSIONS row with `FOR UPDATE` before any read-then-act
-- sequence. This makes the session itself the serialization point, so two
-- concurrent joins for the last slot cannot both succeed, and a join cannot
-- race a concurrent leave/promotion/cancellation on the same session.

create or replace function join_session(
  p_session_id uuid,
  p_guest_name text default null,
  p_guest_contact_method contact_method_enum default null,
  p_guest_contact_value text default null
)
returns table (
  participant_id uuid,
  status participant_status_enum,
  management_token uuid
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_caller uuid := auth.uid();
  v_session sessions%rowtype;
  v_occupied int;
  v_new_status participant_status_enum;
  v_new_id uuid;
  v_token uuid;
  v_existing_guest_count int;
begin
  if v_caller is not null and (p_guest_name is not null or p_guest_contact_value is not null) then
    raise exception 'cannot join as guest while authenticated';
  end if;

  if v_caller is null then
    if p_guest_name is null or p_guest_contact_method is null or p_guest_contact_value is null then
      raise exception 'guest name and a contact method (phone or email) are required';
    end if;
  end if;

  -- Serialization point for this session: every other capacity-sensitive
  -- function takes the same lock before reading/writing participant rows.
  select * into v_session from sessions where id = p_session_id for update;

  if v_session.id is null then
    raise exception 'session not found';
  end if;

  if v_session.status <> 'active' then
    raise exception 'session is not active';
  end if;

  if v_caller is not null then
    if exists (
      select 1 from session_participants sp
      where sp.session_id = p_session_id
        and sp.user_id = v_caller
        and sp.status in ('confirmed', 'waitlisted', 'pending_confirmation')
    ) then
      raise exception 'already joined this session';
    end if;
  else
    select count(*) into v_existing_guest_count
    from session_participants sp
    join guest_contacts gc on gc.participant_id = sp.id
    where sp.session_id = p_session_id
      and sp.status in ('confirmed', 'waitlisted', 'pending_confirmation')
      and lower(gc.contact_value) = lower(p_guest_contact_value);

    if v_existing_guest_count > 0 then
      raise exception 'a guest with this contact info has already joined this session';
    end if;
  end if;

  select count(*) into v_occupied
  from session_participants sp
  where sp.session_id = p_session_id
    and sp.status in ('confirmed', 'pending_confirmation');

  if v_occupied < v_session.capacity then
    v_new_status := 'confirmed';
  else
    v_new_status := 'waitlisted';
  end if;

  if v_caller is null then
    v_token := gen_random_uuid();
  else
    v_token := null;
  end if;

  insert into session_participants (session_id, user_id, guest_name, management_token, status, waitlist_order_at)
  values (p_session_id, v_caller, p_guest_name, v_token, v_new_status, now())
  returning id into v_new_id;

  if v_caller is null then
    insert into guest_contacts (participant_id, contact_method, contact_value)
    values (v_new_id, p_guest_contact_method, p_guest_contact_value);
  end if;

  if v_caller is not null and v_new_status = 'confirmed' then
    insert into notification_outbox (user_id, event_type, session_id, payload)
    values (v_caller, 'join_confirmed', p_session_id, jsonb_build_object('session_id', p_session_id));
  end if;

  return query select v_new_id, v_new_status, v_token;
end;
$$;

revoke execute on function join_session(uuid, text, contact_method_enum, text) from public;
grant execute on function join_session(uuid, text, contact_method_enum, text) to anon, authenticated;
