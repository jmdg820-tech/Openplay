-- OPENPLAY MVP -- 029: bound anonymous guest joins so a script cannot fill a session
--
-- Audit finding: join_session() is callable by `anon` (guest joining is an
-- intentional, documented feature -- see docs/openplay-v3-architecture.md
-- "Guest management token" and the app's guest-code flow). The guest path
-- only required a name and a per-session-unique, unverified contact value,
-- with no volume limit, so one script could make any session "full" and
-- push real players onto the waitlist.
--
-- This redefines join_session() with the SAME signature and the SAME body
-- as migration 026 (locking, end_time guard, capacity/FIFO logic, registered
-- path all unchanged), adding three checks to the GUEST branch only, placed
-- after the sessions row lock so the counts are serialized with every other
-- join/leave/promotion on the session:
--
--   1. Input bounds: guest_name trimmed length 1..80, contact <= 254 chars
--      (the guest name is now stored trimmed, matching the length check).
--   2. Guest cap: active guest registrations (confirmed / waitlisted /
--      pending_confirmation) may hold at most ceil(capacity / 2) rows --
--      counting the waitlist too, so guests cannot flood it either.
--   3. Guest rate limit: at most 5 guest rows CREATED for this session in
--      any rolling 10-minute window, regardless of their current status (so
--      join/leave cycling is also throttled).
--
-- Legitimate guests are unaffected in normal use; registered users are never
-- limited by these rules. Residual risk (documented, not hidden): an attacker
-- can still take up to half of a session's spots, spread across sessions.
-- Organizers/venue staff can remove guests via remove_participant(). Stronger
-- protection (CAPTCHA/Turnstile, contact verification) needs an external
-- service and is out of scope for this migration.

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
  -- Guest-abuse limits (see header). Tune here only.
  c_guest_name_max_len     constant int := 80;
  c_guest_contact_max_len  constant int := 254;
  c_guest_rate_window      constant interval := interval '10 minutes';
  c_guest_rate_max         constant int := 5;

  v_caller uuid := auth.uid();
  v_session sessions%rowtype;
  v_occupied int;
  v_new_status participant_status_enum;
  v_new_id uuid;
  v_token uuid;
  v_existing_guest_count int;
  v_active_guest_count int;
  v_recent_guest_count int;
begin
  if v_caller is not null and (p_guest_name is not null or p_guest_contact_value is not null) then
    raise exception 'cannot join as guest while authenticated';
  end if;

  if v_caller is null then
    if p_guest_name is null or p_guest_contact_method is null or p_guest_contact_value is null then
      raise exception 'guest name and a contact method (phone or email) are required';
    end if;
    if length(trim(p_guest_name)) = 0 or length(trim(p_guest_name)) > c_guest_name_max_len then
      raise exception 'guest name must be between 1 and % characters', c_guest_name_max_len;
    end if;
    if length(p_guest_contact_value) > c_guest_contact_max_len then
      raise exception 'guest contact must be at most % characters', c_guest_contact_max_len;
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

  if now() >= v_session.end_time then
    raise exception 'session has already ended';
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

    select count(*) into v_active_guest_count
    from session_participants sp
    where sp.session_id = p_session_id
      and sp.user_id is null
      and sp.status in ('confirmed', 'waitlisted', 'pending_confirmation');

    if v_active_guest_count >= ceil(v_session.capacity / 2.0) then
      raise exception 'guest spots for this session are full';
    end if;

    select count(*) into v_recent_guest_count
    from session_participants sp
    where sp.session_id = p_session_id
      and sp.user_id is null
      and sp.created_at > now() - c_guest_rate_window;

    if v_recent_guest_count >= c_guest_rate_max then
      raise exception 'too many guest sign-ups for this session right now';
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
  values (p_session_id, v_caller, case when v_caller is null then trim(p_guest_name) else null end, v_token, v_new_status, now())
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

-- Same signature as 013/026, so existing grants persist; re-stated for a
-- self-contained, auditable migration (same pattern as 025/026).
revoke execute on function join_session(uuid, text, contact_method_enum, text) from public;
revoke execute on function join_session(uuid, text, contact_method_enum, text) from anon, authenticated;
grant execute on function join_session(uuid, text, contact_method_enum, text) to anon, authenticated;
