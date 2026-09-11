-- OPENPLAY MVP — 018: submit_report()
-- Session-scoped reports rely on the permanent UNIQUE(reporter, reported,
-- session_id) constraint (a second report about the same specific incident
-- is always redundant). General reports (session_id IS NULL) are NOT
-- protected by that constraint -- NULLs are distinct under standard SQL
-- uniqueness, by design, so a reporter can file a genuinely new complaint
-- later. This function instead collapses an accidental rapid duplicate
-- submission (same reporter, same target, no session) within 5 minutes into
-- the existing row, while still allowing a later, separate report through.

create or replace function submit_report(
  p_reported_user_id uuid,
  p_session_id uuid default null,
  p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_caller uuid := auth.uid();
  v_existing_id uuid;
  v_new_id uuid;
begin
  if v_caller is null then
    raise exception 'authentication required';
  end if;

  if p_reported_user_id = v_caller then
    raise exception 'cannot report yourself';
  end if;

  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'a reason is required';
  end if;

  if p_session_id is null then
    select id into v_existing_id
    from reports
    where reporter_user_id = v_caller
      and reported_user_id = p_reported_user_id
      and session_id is null
      and created_at > now() - interval '5 minutes'
    order by created_at desc
    limit 1;

    if v_existing_id is not null then
      return v_existing_id;
    end if;
  end if;

  insert into reports (reporter_user_id, reported_user_id, session_id, reason)
  values (v_caller, p_reported_user_id, p_session_id, p_reason)
  on conflict (reporter_user_id, reported_user_id, session_id) do nothing
  returning id into v_new_id;

  if v_new_id is null then
    select id into v_new_id
    from reports
    where reporter_user_id = v_caller
      and reported_user_id = p_reported_user_id
      and session_id is not distinct from p_session_id;
  end if;

  return v_new_id;
end;
$$;

revoke execute on function submit_report(uuid, uuid, text) from public;
grant execute on function submit_report(uuid, uuid, text) to authenticated;
