-- OPENPLAY MVP -- 028: tell the caller which roster row is theirs, and
-- give a signed-in user a read of their own active participations.
--
-- Audit finding: get_session_roster() (migration 012) never says which row
-- belongs to the caller, so the client could only remember "my row" in
-- memory for the lifetime of one screen. After navigating away or
-- restarting the app, a registered user lost their Leave button, and a
-- promoted waitlister lost their Confirm button -- the 15-minute offer then
-- silently expired. The server already knows auth.uid(); this migration
-- simply reports it back per row.
--
-- get_session_roster() keeps every existing column and rule unchanged and
-- adds two:
--   is_self            -- true only for the caller's own registered row
--                         (always false for anon callers and guest rows;
--                         guests keep proving identity with their token)
--   waitlist_position  -- 1-based FIFO position among waitlisted rows,
--                         NULL for every other status. Derived from the same
--                         waitlist_order_at ordering promote_next_waitlisted()
--                         uses, so it is exactly the promotion order.
-- Neither discloses anything new: is_self is only ever true for the caller
-- themselves, and a row's position is already implied by the existing
-- ORDER BY waitlist_order_at.
--
-- The return type changes, so CREATE OR REPLACE is not enough -- the
-- function is dropped and recreated in this same transaction, then its
-- grants are re-established explicitly (same revoke-then-grant pattern as
-- migrations 025-027, since a newly created function would otherwise pick
-- up Supabase's default anon/authenticated EXECUTE grant).
--
-- get_my_participations() is NOT a second membership system: it reads the
-- very same session_participants rows, filtered to auth.uid(), and powers
-- the in-app "you've been offered a spot" banner / My sessions list (the
-- in-app delivery path for the waitlist_promoted event while off-app push
-- has no configured provider).

drop function if exists get_session_roster(uuid);

create function get_session_roster(p_session_id uuid)
returns table (
  participant_id          uuid,
  session_id              uuid,
  display_name            text,
  status                  participant_status_enum,
  skill_level             skill_level_enum,
  seconds_until_expiry    integer,
  is_guest                boolean,
  is_self                 boolean,
  waitlist_position       integer
)
language plpgsql
security definer
set search_path = pg_catalog, public
stable
as $$
declare
  v_caller uuid := auth.uid();
  v_is_organizer boolean;
  v_is_staff boolean;
  v_is_joined boolean;
  v_can_see_skill boolean;
  v_can_see_management boolean;
begin
  v_is_organizer := exists (
    select 1 from sessions s where s.id = p_session_id and s.created_by = v_caller
  );
  v_is_staff := exists (
    select 1 from sessions s
    join venue_staff vs on vs.venue_id = s.venue_id
    where s.id = p_session_id and vs.user_id = v_caller
  );
  v_is_joined := v_caller is not null and exists (
    select 1 from session_participants sp
    where sp.session_id = p_session_id
      and sp.user_id = v_caller
      and sp.status in ('confirmed', 'waitlisted', 'pending_confirmation')
  );
  v_can_see_skill := v_is_joined or v_is_organizer or v_is_staff;
  v_can_see_management := v_is_organizer or v_is_staff;

  return query
  select
    sp.id,
    sp.session_id,
    coalesce(p.name, sp.guest_name),
    sp.status,
    case when v_can_see_skill then p.skill_level else null end,
    case
      when sp.status = 'pending_confirmation'
           and (v_can_see_management or sp.user_id = v_caller)
      then greatest(0, ceil(extract(epoch from (sp.promotion_expires_at - now())))::integer)
      else null
    end,
    case when v_can_see_management then (sp.user_id is null) else null end,
    (v_caller is not null and sp.user_id is not null and sp.user_id = v_caller),
    case
      when sp.status = 'waitlisted' then
        (row_number() over (
          partition by (sp.status = 'waitlisted')
          order by sp.waitlist_order_at, sp.id
        ))::integer
      else null
    end
  from session_participants sp
  left join profiles p on p.id = sp.user_id
  where sp.session_id = p_session_id
    and sp.status in ('confirmed', 'waitlisted', 'pending_confirmation')
  order by sp.waitlist_order_at, sp.id;
end;
$$;

revoke execute on function get_session_roster(uuid) from public;
revoke execute on function get_session_roster(uuid) from anon, authenticated;
grant execute on function get_session_roster(uuid) to anon, authenticated;

create function get_my_participations()
returns table (
  participant_id        uuid,
  session_id            uuid,
  status                participant_status_enum,
  seconds_until_expiry  integer,
  waitlist_position     integer,
  session_status        session_status_enum,
  start_time            timestamptz,
  end_time              timestamptz,
  venue_id              uuid
)
language plpgsql
security definer
set search_path = pg_catalog, public
stable
as $$
declare
  v_caller uuid := auth.uid();
begin
  if v_caller is null then
    raise exception 'authentication required';
  end if;

  return query
  select
    sp.id,
    sp.session_id,
    sp.status,
    case
      when sp.status = 'pending_confirmation'
      then greatest(0, ceil(extract(epoch from (sp.promotion_expires_at - now())))::integer)
      else null
    end,
    case
      when sp.status = 'waitlisted' then (
        select count(*)::integer
        from session_participants w
        where w.session_id = sp.session_id
          and w.status = 'waitlisted'
          and (w.waitlist_order_at, w.id) <= (sp.waitlist_order_at, sp.id)
      )
      else null
    end,
    s.status,
    s.start_time,
    s.end_time,
    s.venue_id
  from session_participants sp
  join sessions s on s.id = sp.session_id
  where sp.user_id = v_caller
    and sp.status in ('confirmed', 'waitlisted', 'pending_confirmation')
    and s.end_time > now()
  order by s.start_time, sp.id;
end;
$$;

revoke execute on function get_my_participations() from public;
revoke execute on function get_my_participations() from anon, authenticated;
grant execute on function get_my_participations() to authenticated;
