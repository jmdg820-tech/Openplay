-- OPENPLAY MVP — 012: get_session_roster(), is_venue_managed()
-- The ONLY client read surface for session_participants / venue_staff data.

create or replace function get_session_roster(p_session_id uuid)
returns table (
  participant_id          uuid,
  session_id              uuid,
  display_name            text,
  status                  participant_status_enum,
  skill_level             skill_level_enum,
  seconds_until_expiry    integer,
  is_guest                boolean
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
  -- A guest is never elevated to "joined" visibility through this function:
  -- it takes no management_token, so it has no way to verify a guest's
  -- identity. Accepted MVP limitation (per the approved spec).
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
    case when v_can_see_management then (sp.user_id is null) else null end
  from session_participants sp
  left join profiles p on p.id = sp.user_id
  where sp.session_id = p_session_id
    and sp.status in ('confirmed', 'waitlisted', 'pending_confirmation')
  order by sp.waitlist_order_at;
end;
$$;

revoke execute on function get_session_roster(uuid) from public;
grant execute on function get_session_roster(uuid) to anon, authenticated;

create or replace function is_venue_managed(p_venue_id uuid)
returns boolean
language sql
security definer
set search_path = pg_catalog, public
stable
as $$
  select exists (select 1 from venue_staff where venue_id = p_venue_id);
$$;

revoke execute on function is_venue_managed(uuid) from public;
grant execute on function is_venue_managed(uuid) to anon, authenticated;
