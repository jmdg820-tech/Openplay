-- OPENPLAY MVP — 016: claim_venue()
-- First-staff claim, concurrency-safe via an explicit lock on the venue row
-- (in addition to the UNIQUE(venue_id, user_id) backstop on venue_staff).

create or replace function claim_venue(p_venue_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_caller uuid := auth.uid();
  v_venue venues%rowtype;
  v_existing_staff_count int;
begin
  if v_caller is null then
    raise exception 'authentication required';
  end if;

  select * into v_venue from venues where id = p_venue_id for update;
  if v_venue.id is null then
    raise exception 'venue not found';
  end if;

  if v_venue.created_by <> v_caller then
    raise exception 'not authorized for this action';
  end if;

  select count(*) into v_existing_staff_count from venue_staff where venue_id = p_venue_id;

  if v_existing_staff_count > 0 then
    return; -- idempotent no-op: already claimed by a prior call
  end if;

  insert into venue_staff (venue_id, user_id) values (p_venue_id, v_caller);
end;
$$;

revoke execute on function claim_venue(uuid) from public;
grant execute on function claim_venue(uuid) to authenticated;
